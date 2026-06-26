/*
 * PrimaryKeyQueryTests.swift
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

/// Queries on the primary key (or its leading prefix) are served by a direct record-range scan,
/// with no secondary index declared.
@Suite("Primary-key queries (integration)", .serialized)
struct PrimaryKeyQueryTests {
    private func singleKeyMeta() -> RecordMetaData {
        RecordMetaData { RecordType(Fdb_Test_Order.self, key: 1, primaryKey: \.orderID) }
    }

    private func compositeKeyMeta() -> RecordMetaData {
        RecordMetaData {
            RecordType(Fdb_Test_Order.self, key: 1,
                       primaryKey: .concat(.field(\.flower), .field(\.orderID)))
        }
    }

    @Test("planner uses a primary-key scan for the key and its leading prefix, not a gap")
    func planning() {
        let single = singleKeyMeta().recordType(for: Fdb_Test_Order.self)!
        #expect(QueryPlanner.plan(recordType: single,
                                  node: Query.field(\Fdb_Test_Order.orderID).equals(2).node).usesPrimaryKey)

        let composite = compositeKeyMeta().recordType(for: Fdb_Test_Order.self)!
        // Leading column (flower) → primary-key scan.
        #expect(QueryPlanner.plan(recordType: composite,
                                  node: Query.field(\Fdb_Test_Order.flower).equals("rose").node).usesPrimaryKey)
        // Non-leading column (orderID) alone → cannot use the key; full scan.
        let gap = QueryPlanner.plan(recordType: composite,
                                    node: Query.field(\Fdb_Test_Order.orderID).equals(1).node)
        #expect(!gap.usesPrimaryKey)
        #expect(gap.indexName == nil)
    }

    @Test("primary-key equality and range queries return the right records without an index")
    func execution() async throws {
        try await RecordLayerTestCase.withStore(metaData: singleKeyMeta()) { run in
            try await run { store in
                for id in Int64(1)...4 { try await store.save(Fdb_Test_Order.sample(id: id)) }
            }
            let equal = try await run { store in
                try await store.executeQuery(
                    RecordQuery(Fdb_Test_Order.self).where(Query.field(\.orderID).equals(3)))
                    .collect().map { $0.record.orderID }
            }
            #expect(equal == [3])

            let range = try await run { store in
                try await store.executeQuery(
                    RecordQuery(Fdb_Test_Order.self).where(Query.field(\.orderID).lessThan(3)))
                    .collect().map { $0.record.orderID }
            }
            #expect(range.sorted() == [1, 2])
        }
    }
}
#endif
