/*
 * UniqueIndexTests.swift
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

/// A `unique: true` index rejects a second record with the same key.
@Suite("Unique index (integration)", .serialized)
struct UniqueIndexTests {
    // flower is unique across orders.
    private func meta() -> RecordMetaData {
        RecordMetaData {
            RecordType(Fdb_Test_Order.self, key: 1, primaryKey: \.orderID)
                .index("uniqueFlower", on: \.flower, key: 10, unique: true)
        }
    }

    private func saveFailed(_ run: StoreRunner, _ order: Fdb_Test_Order) async throws -> Bool {
        do {
            try await run { _ = try await $0.save(order) }
            return false
        } catch let error as RecordStoreError {
            if case .uniquenessViolation = error { return true }
            throw error
        }
    }

    @Test("duplicate unique key is rejected; updates and distinct values are allowed")
    func enforcement() async throws {
        try await RecordLayerTestCase.withStore(metaData: meta()) { run in
            try await run { _ = try await $0.save(Fdb_Test_Order.sample(id: 1, flower: "rose")) }

            // A different record with the same flower is rejected.
            let rejected = try await saveFailed(run, Fdb_Test_Order.sample(id: 2, flower: "rose"))
            #expect(rejected)

            // A different flower is fine.
            try await run { _ = try await $0.save(Fdb_Test_Order.sample(id: 2, flower: "tulip")) }

            // The unique index is ALSO a normal queryable value index: a covering query (which
            // only succeeds against a usable index) returns the right entry.
            let covered = try await run { store in
                try await store.executeCoveringQuery(
                    RecordQuery(Fdb_Test_Order.self).where(Query.field(\.flower).equals("tulip")),
                    using: "uniqueFlower")
            }
            #expect(covered.count == 1)
            #expect(covered.first?.primaryKey == Tuple(Int64(2)))

            // Re-saving the SAME record (same primary key) with its own value is allowed.
            try await run { _ = try await $0.save(Fdb_Test_Order.sample(id: 1, flower: "rose", price: 99)) }
            let reloaded = try await run { try await $0.load(Fdb_Test_Order.self, Int64(1)) }
            #expect(reloaded?.record.price == 99)

            // After deleting order 1, its flower frees up for another record.
            try await run { _ = try await $0.delete(Fdb_Test_Order.self, primaryKey: Tuple(Int64(1))) }
            try await run { _ = try await $0.save(Fdb_Test_Order.sample(id: 3, flower: "rose")) }
            let owner = try await run { try await $0.load(Fdb_Test_Order.self, Int64(3)) }
            #expect(owner?.record.flower == "rose")
        }
    }
}
#endif
