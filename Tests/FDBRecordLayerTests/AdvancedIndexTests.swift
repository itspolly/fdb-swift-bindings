/*
 * AdvancedIndexTests.swift
 *
 * This source file is part of the FoundationDB open source project
 *
 * Copyright 2016-2025 Apple Inc. and the FoundationDB project authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#if RecordLayer
import Testing

@testable import FDBRecordLayer
import FoundationDB

/// Integration tests for aggregate, rank, and version indexes (require a running cluster).
@Suite("Advanced indexes (integration)", .serialized)
struct AdvancedIndexTests {
    private func withAdvancedStore(_ body: (_ run: StoreRunner) async throws -> Void) async throws {
        try await RecordLayerTestCase.withStore(metaData: RecordLayerTestCase.advancedMetaData(), body)
    }

    @Test("count aggregate index tracks per-group and total counts")
    func countIndex() async throws {
        try await withAdvancedStore { run in
            try await run { store in
                try await store.save(Fdb_Test_Item.sample(sku: "a", category: "flower"))
                try await store.save(Fdb_Test_Item.sample(sku: "b", category: "flower"))
                try await store.save(Fdb_Test_Item.sample(sku: "c", category: "vase"))
            }
            let (flowers, vases, total) = try await run { store in
                (try await store.aggregate(Fdb_Test_Item.self, indexNamed: "item.countByCategory", group: Tuple("flower")),
                 try await store.aggregate(Fdb_Test_Item.self, indexNamed: "item.countByCategory", group: Tuple("vase")),
                 try await store.aggregateTotal(Fdb_Test_Item.self, indexNamed: "item.countByCategory"))
            }
            #expect(flowers == 2)
            #expect(vases == 1)
            #expect(total == 3)

            // Deleting decrements the group's count.
            try await run { try await $0.delete(Fdb_Test_Item.self, primaryKey: Tuple("a")) }
            let flowersAfter = try await run {
                try await $0.aggregate(Fdb_Test_Item.self, indexNamed: "item.countByCategory", group: Tuple("flower"))
            }
            #expect(flowersAfter == 1)
        }
    }

    @Test("sum aggregate index tracks grouped sums and reacts to updates")
    func sumIndex() async throws {
        try await withAdvancedStore { run in
            try await run { store in
                try await store.save(Fdb_Test_Item.sample(sku: "a", quantity: 3, category: "flower"))
                try await store.save(Fdb_Test_Item.sample(sku: "b", quantity: 5, category: "flower"))
            }
            let sum1 = try await run {
                try await $0.aggregate(Fdb_Test_Item.self, indexNamed: "item.sumQtyByCategory", group: Tuple("flower"))
            }
            #expect(sum1 == 8)

            // Update b's quantity 5 -> 10; sum should become 13.
            try await run { try await $0.save(Fdb_Test_Item.sample(sku: "b", quantity: 10, category: "flower")) }
            let sum2 = try await run {
                try await $0.aggregate(Fdb_Test_Item.self, indexNamed: "item.sumQtyByCategory", group: Tuple("flower"))
            }
            #expect(sum2 == 13)
        }
    }

    @Test("rank index reports the number of records ordered before a value")
    func rankIndex() async throws {
        try await withAdvancedStore { run in
            try await run { store in
                for (id, price) in [(Int64(1), Int64(10)), (2, 20), (3, 30), (4, 40)] {
                    try await store.save(Fdb_Test_Order.sample(id: id, price: price))
                }
            }
            let (rankOf25, rankOf10, rankOf100) = try await run { store in
                (try await store.rank(Fdb_Test_Order.self, indexNamed: "order.priceRank", lessThan: Int64(25)),
                 try await store.rank(Fdb_Test_Order.self, indexNamed: "order.priceRank", lessThan: Int64(10)),
                 try await store.rank(Fdb_Test_Order.self, indexNamed: "order.priceRank", lessThan: Int64(100)))
            }
            #expect(rankOf25 == 2) // prices 10, 20
            #expect(rankOf10 == 0) // nothing strictly less than 10
            #expect(rankOf100 == 4) // all four
        }
    }

    @Test("version index scans records in commit order across transactions")
    func versionIndex() async throws {
        try await withAdvancedStore { run in
            // Each save is its own transaction, so commit versions strictly increase.
            try await run { try await $0.save(Fdb_Test_Order.sample(id: 30)) }
            try await run { try await $0.save(Fdb_Test_Order.sample(id: 10)) }
            try await run { try await $0.save(Fdb_Test_Order.sample(id: 20)) }

            let order = try await run { store in
                var ids: [Int64] = []
                for try await record in try store.scanByVersion(Fdb_Test_Order.self, indexNamed: "order.version") {
                    ids.append(record.record.orderID)
                }
                return ids
            }
            // Insertion order, not primary-key order.
            #expect(order == [30, 10, 20])
        }
    }

    @Test("min/max indexes report grouped extrema and recompute correctly on delete")
    func minMax() async throws {
        try await withAdvancedStore { run in
            try await run { store in
                try await store.save(Fdb_Test_Item.sample(sku: "a", quantity: 3, category: "flower"))
                try await store.save(Fdb_Test_Item.sample(sku: "b", quantity: 7, category: "flower"))
                try await store.save(Fdb_Test_Item.sample(sku: "c", quantity: 5, category: "flower"))
            }
            let (minimum, maximum) = try await run { store in
                (try await store.minimum(Fdb_Test_Item.self, indexNamed: "item.minQtyByCategory", group: Tuple("flower")) as? Int64,
                 try await store.maximum(Fdb_Test_Item.self, indexNamed: "item.maxQtyByCategory", group: Tuple("flower")) as? Int64)
            }
            #expect(minimum == 3)
            #expect(maximum == 7)

            // Delete the current maximum; the extremum must drop (the win over atomic max).
            try await run { try await $0.delete(Fdb_Test_Item.self, primaryKey: Tuple("b")) }
            let maxAfterDelete = try await run {
                try await $0.maximum(Fdb_Test_Item.self, indexNamed: "item.maxQtyByCategory", group: Tuple("flower")) as? Int64
            }
            #expect(maxAfterDelete == 5)
        }
    }
}
#endif
