/*
 * CompositePrimaryKeyTests.swift
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

/// A composite (multi-column) primary key works across save/load/delete/query and is decoded
/// correctly from index entries.
@Suite("Composite primary key (integration)", .serialized)
struct CompositePrimaryKeyTests {
    private func meta() -> RecordMetaData {
        RecordMetaData {
            RecordType(Fdb_Test_Order.self, primaryKey: .concat(.field(\.flower), .field(\.orderID)))
                .index("price", on: \.price)
        }
    }

    @Test("save/load/delete and index queries with a two-column primary key")
    func compositeKey() async throws {
        try await RecordLayerTestCase.withStore(metaData: meta()) { run in
            try await run { store in
                try await store.save(Fdb_Test_Order.sample(id: 1, flower: "rose", price: 10))
                try await store.save(Fdb_Test_Order.sample(id: 2, flower: "rose", price: 20))
                try await store.save(Fdb_Test_Order.sample(id: 1, flower: "tulip", price: 30))
            }

            // Load by the full composite key.
            let loaded = try await run { store in
                try await store.load(Fdb_Test_Order.self, primaryKey: Tuple("rose", Int64(2)))
            }
            #expect(loaded?.record.price == 20)
            #expect(loaded?.primaryKey == Tuple("rose", Int64(2)))

            // Same orderID under a different flower is a distinct record.
            let other = try await run { store in
                try await store.load(Fdb_Test_Order.self, primaryKey: Tuple("tulip", Int64(1)))
            }
            #expect(other?.record.price == 30)

            // An index query returns records whose primaryKey is the full composite tuple.
            let byPrice = try await run { store in
                try await store.executeQuery(
                    RecordQuery(Fdb_Test_Order.self).where(Query.field(\.price).equals(20))).collect()
            }
            #expect(byPrice.count == 1)
            #expect(byPrice.first?.primaryKey == Tuple("rose", Int64(2)))

            // Delete by composite key removes only that record.
            let deleted = try await run { store in
                try await store.delete(Fdb_Test_Order.self, primaryKey: Tuple("rose", Int64(1)))
            }
            #expect(deleted)
            let remaining = try await run { store in
                try await store.scan(Fdb_Test_Order.self).collect().map { $0.primaryKey }
            }
            #expect(remaining.count == 2)
            #expect(!remaining.contains(Tuple("rose", Int64(1))))
        }
    }
}
#endif
