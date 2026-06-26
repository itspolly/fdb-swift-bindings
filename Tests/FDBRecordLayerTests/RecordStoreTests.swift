/*
 * RecordStoreTests.swift
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

/// Integration tests for save/load/delete and value-index maintenance.
///
/// These require a running FoundationDB cluster (see the README). Each test runs in its own
/// isolated subspace and cleans up afterwards.
@Suite("FDBRecordStore (integration)", .serialized)
struct RecordStoreTests {
    @Test("save then load round-trips a record across transactions")
    func saveLoadRoundTrip() async throws {
        try await RecordLayerTestCase.withStore { run in
            try await run { store in
                try await store.save(Fdb_Test_Order.sample(id: 1, flower: "rose", price: 10))
            }
            let loaded = try await run { store in
                try await store.load(Fdb_Test_Order.self, Int64(1))
            }
            #expect(loaded != nil)
            #expect(loaded?.record.flower == "rose")
            #expect(loaded?.record.price == 10)
            #expect(loaded?.primaryKey == Tuple(Int64(1)))
        }
    }

    @Test("loading a missing record returns nil")
    func loadMissing() async throws {
        try await RecordLayerTestCase.withStore { run in
            let loaded = try await run { store in
                try await store.load(Fdb_Test_Order.self, Int64(999))
            }
            #expect(loaded == nil)
        }
    }

    @Test("saving the same primary key overwrites the record")
    func overwrite() async throws {
        try await RecordLayerTestCase.withStore { run in
            try await run { try await $0.save(Fdb_Test_Order.sample(id: 2, flower: "rose")) }
            try await run { try await $0.save(Fdb_Test_Order.sample(id: 2, flower: "tulip")) }
            let loaded = try await run { try await $0.load(Fdb_Test_Order.self, Int64(2)) }
            #expect(loaded?.record.flower == "tulip")
        }
    }

    @Test("multiple record types coexist in one store")
    func multipleTypes() async throws {
        try await RecordLayerTestCase.withStore { run in
            try await run { store in
                try await store.save(Fdb_Test_Order.sample(id: 3))
                try await store.save(Fdb_Test_Item.sample(sku: "ABC"))
            }
            let (order, item) = try await run { store in
                (try await store.load(Fdb_Test_Order.self, Int64(3)),
                 try await store.load(Fdb_Test_Item.self, "ABC"))
            }
            #expect(order != nil)
            #expect(item?.record.name == "thing")
        }
    }

    @Test("delete removes the record")
    func delete() async throws {
        try await RecordLayerTestCase.withStore { run in
            try await run { try await $0.save(Fdb_Test_Order.sample(id: 4)) }
            let deleted = try await run { try await $0.delete(Fdb_Test_Order.self, primaryKey: Tuple(Int64(4))) }
            #expect(deleted)
            let loaded = try await run { try await $0.load(Fdb_Test_Order.self, Int64(4)) }
            #expect(loaded == nil)
        }
    }

    @Test("scan returns all records of a type in primary-key order")
    func scan() async throws {
        try await RecordLayerTestCase.withStore { run in
            try await run { store in
                for id in [Int64(30), 10, 20] {
                    try await store.save(Fdb_Test_Order.sample(id: id))
                }
                try await store.save(Fdb_Test_Item.sample(sku: "X")) // should not appear
            }
            let ids = try await run { store in
                try await store.scan(Fdb_Test_Order.self).collect().map { $0.record.orderID }
            }
            #expect(ids == [10, 20, 30])
        }
    }

    @Test("value indexes are created, diffed, and removed")
    func indexMaintenance() async throws {
        try await RecordLayerTestCase.withStore { run in
            // price (1) + 2 tags fan-out (2) + customerName (1) = 4 index entries.
            try await run { store in
                try await store.save(Fdb_Test_Order.sample(id: 5, price: 10, tags: ["a", "b"]))
            }
            let afterInsert = try await run { try await $0.allIndexKeys().count }
            #expect(afterInsert == 4)

            // Updating tags to a single value should leave: price(1) + 1 tag + name(1) = 3.
            try await run { store in
                try await store.save(Fdb_Test_Order.sample(id: 5, price: 10, tags: ["c"]))
            }
            let afterUpdate = try await run { try await $0.allIndexKeys().count }
            #expect(afterUpdate == 3)

            // Deleting the record removes all of its index entries.
            try await run { try await $0.delete(Fdb_Test_Order.self, primaryKey: Tuple(Int64(5))) }
            let afterDelete = try await run { try await $0.allIndexKeys().count }
            #expect(afterDelete == 0)
        }
    }
}
#endif
