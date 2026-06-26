/*
 * StableKeysTests.swift
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
import Foundation
import Testing

@testable import FDBRecordLayer
import FoundationDB

/// Explicit stable keys make the on-disk layout independent of declaration order, and let an
/// index be cleared/retired without disturbing others.
@Suite("Stable keys (integration)", .serialized)
struct StableKeysTests {
    // Declared order: Order, then Item.
    private func metaA() -> RecordMetaData {
        RecordMetaData {
            RecordType(Fdb_Test_Order.self, key: 1, primaryKey: \.orderID)
                .index("orderPrice", on: \.price, key: 10)
            RecordType(Fdb_Test_Item.self, key: 2, primaryKey: \.sku)
                .index("itemCat", on: \.category, key: 20)
        }
    }

    // Reversed declaration AND index order, same explicit keys.
    private func metaB() -> RecordMetaData {
        RecordMetaData {
            RecordType(Fdb_Test_Item.self, key: 2, primaryKey: \.sku)
                .index("itemCat", on: \.category, key: 20)
            RecordType(Fdb_Test_Order.self, key: 1, primaryKey: \.orderID)
                .index("orderPrice", on: \.price, key: 10)
        }
    }

    @Test("reordering the schema with stable keys preserves data and indexes")
    func reorderIsSafe() async throws {
        try await FDBBootstrap.shared.ensureInitialized()
        let db = try FDBClient.openDatabase()
        let subspace = Subspace(Tuple("fdbrl-stablekeys", UUID().uuidString))

        try await db.withRecordContext { context in
            let store = try await FDBRecordStore.open(context: context, subspace: subspace, metaData: metaA())
            try await store.save(Fdb_Test_Order.sample(id: 1, price: 10))
            try await store.save(Fdb_Test_Item.sample(sku: "x", category: "flower"))
        }

        // Read back with the reordered schema — same keys → same physical locations.
        let (order, item, ids) = try await db.withRecordContext { context in
            let store = try await FDBRecordStore.open(context: context, subspace: subspace, metaData: metaB())
            let order = try await store.load(Fdb_Test_Order.self, Int64(1))
            let item = try await store.load(Fdb_Test_Item.self, "x")
            var ids: [Int64] = []
            for try await record in try await store.executeQuery(
                RecordQuery(Fdb_Test_Order.self).where(Query.field(\.price).equals(10))) {
                ids.append(record.record.orderID)
            }
            return (order, item, ids)
        }
        #expect(order?.record.price == 10)
        #expect(item?.record.category == "flower")
        #expect(ids == [1]) // the price index still resolves under the reordered schema

        try await db.withRecordContext { context in
            let store = try await FDBRecordStore.open(context: context, subspace: subspace, metaData: metaB())
            try await store.deleteAllRecords()
        }
    }

    private func twoIndexMeta() -> RecordMetaData {
        RecordMetaData {
            RecordType(Fdb_Test_Order.self, key: 1, primaryKey: \.orderID)
                .index("orderPrice", on: \.price, key: 10)
                .index("orderFlower", on: \.flower, key: 11)
        }
    }

    @Test("clearIndex removes one index's data and leaves others intact")
    func clearIndexIsolated() async throws {
        try await RecordLayerTestCase.withStore(metaData: twoIndexMeta()) { run in
            try await run { store in
                try await store.save(Fdb_Test_Order.sample(id: 1, flower: "rose", price: 10))
                try await store.save(Fdb_Test_Order.sample(id: 2, flower: "tulip", price: 20))
            }
            // 2 records × 2 indexes = 4 entries.
            let before = try await run { try await $0.allIndexKeys().count }
            #expect(before == 4)

            try await run { try await $0.clearIndex(named: "orderPrice") }
            let after = try await run { try await $0.allIndexKeys().count }
            #expect(after == 2) // only orderFlower remains

            // The surviving index still serves queries.
            let byFlower = try await run { store in
                try await store.executeQuery(
                    RecordQuery(Fdb_Test_Order.self).where(Query.field(\.flower).equals("rose"))).collect()
            }
            #expect(byFlower.map { $0.record.orderID } == [1])

            // The cleared index's field still returns correct results (now via full scan).
            let byPrice = try await run { store in
                try await store.executeQuery(
                    RecordQuery(Fdb_Test_Order.self).where(Query.field(\.price).equals(20))).collect()
            }
            #expect(byPrice.map { $0.record.orderID } == [2])
        }
    }
}
#endif
