/*
 * AnnotatedMetaDataTests.swift
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

/// Tests for building metadata from in-`.proto` FoundationDB field annotations.
@Suite("Proto-annotation metadata (integration)", .serialized)
struct AnnotatedMetaDataTests {
    private func metaData() throws -> RecordMetaData {
        let data = Data(base64Encoded: AnnotatedDescriptor.base64)!
        return try RecordMetaData(descriptorSetData: data, recordTypes: [Fdb_Test_AnnotatedOrder.self])
    }

    private func make(id: Int64, flower: String = "rose", price: Int64 = 10, tags: [String] = [],
                      customer: String = "alice") -> Fdb_Test_AnnotatedOrder {
        var order = Fdb_Test_AnnotatedOrder()
        order.orderID = id
        order.flower = flower
        order.price = price
        order.tags = tags
        order.customer.name = customer
        return order
    }

    @Test("metadata is derived from field annotations (primary key + indexes)")
    func metadataParsed() throws {
        let meta = try metaData()
        let recordType = meta.recordType(for: Fdb_Test_AnnotatedOrder.self)
        #expect(recordType != nil)
        // price, tags, and the nested customer.name are all annotated as indexes.
        #expect(recordType?.indexes.count == 3)
        // order_id (field 1) is the primary key.
        #expect(recordType?.primaryKeyIdentities == [FieldID.fieldNumber(1)])
    }

    @Test("a nested KeyPath query selects a nested annotation index")
    func nestedCrossStyleMatching() throws {
        let meta = try metaData()
        let recordType = meta.recordType(for: Fdb_Test_AnnotatedOrder.self)!
        // \.customer.name resolves to field path [5, 1]; the nested annotation index uses the
        // same path, so the planner selects it.
        let node = Query.field(\Fdb_Test_AnnotatedOrder.customer.name).equals("alice").node
        let plan = QueryPlanner.plan(recordType: recordType, node: node)
        #expect(plan.indexName == "AnnotatedOrder.customer.name")
    }

    @Test("save/load round-trips using the annotated primary key")
    func saveLoad() async throws {
        let meta = try metaData()
        try await RecordLayerTestCase.withStore(metaData: meta) { run in
            _ = try await run { try await $0.save(self.make(id: 7, flower: "tulip")) }
            let loaded = try await run { try await $0.load(Fdb_Test_AnnotatedOrder.self, Int64(7)) }
            #expect(loaded?.record.flower == "tulip")
            #expect(loaded?.primaryKey == Tuple(Int64(7)))
        }
    }

    @Test("annotated indexes are maintained (field-number extraction)")
    func indexMaintenance() async throws {
        let meta = try metaData()
        try await RecordLayerTestCase.withStore(metaData: meta) { run in
            _ = try await run { try await $0.save(self.make(id: 1, price: 10, tags: ["red", "white"])) }
            // price (1) + tags fan-out (2) + nested customer.name (1) = 4 index entries.
            let count = try await run { try await $0.allIndexKeys().count }
            #expect(count == 4)
        }
    }

    @Test("a KeyPath query selects an annotation-defined (field-number) index")
    func crossStyleMatching() throws {
        let meta = try metaData()
        let recordType = meta.recordType(for: Fdb_Test_AnnotatedOrder.self)!
        // The query uses a KeyPath; the index was declared by proto field number. They match
        // because the KeyPath resolves to field number 3 (price).
        let node = Query.field(\Fdb_Test_AnnotatedOrder.price).equals(20).node
        let plan = QueryPlanner.plan(recordType: recordType, node: node)
        #expect(plan.indexName == "AnnotatedOrder.price")
    }

    @Test("queries return correct results against annotation-defined records")
    func query() async throws {
        let meta = try metaData()
        try await RecordLayerTestCase.withStore(metaData: meta) { run in
            try await run { store in
                try await store.save(self.make(id: 1, flower: "rose", price: 10))
                try await store.save(self.make(id: 2, flower: "tulip", price: 20))
                try await store.save(self.make(id: 3, flower: "rose", price: 30))
            }
            let ids = try await run { store in
                var result: [Int64] = []
                let cursor = try await store.executeQuery(
                    RecordQuery(Fdb_Test_AnnotatedOrder.self).where(Query.field(\.flower).equals("rose")))
                for try await record in cursor { result.append(record.record.orderID) }
                return result.sorted()
            }
            #expect(ids == [1, 3])
        }
    }
}
#endif
