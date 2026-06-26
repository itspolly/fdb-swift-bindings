/*
 * IndexBuildTests.swift
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

/// Adding an index to a populated store: it opens `writeOnly` (hidden from queries) and becomes
/// `readable` only after an online build backfills the existing records.
@Suite("Online index building (integration)", .serialized)
struct IndexBuildTests {
    private func baseMeta() -> RecordMetaData {
        RecordMetaData { RecordType(Fdb_Test_Order.self, primaryKey: \.orderID) }
    }

    private func extendedMeta() -> RecordMetaData {
        RecordMetaData {
            RecordType(Fdb_Test_Order.self, primaryKey: \.orderID).index("priceIdx", on: \.price)
        }
    }

    @Test("new index on a populated store is writeOnly until built, then readable")
    func buildOnPopulatedStore() async throws {
        try await FDBBootstrap.shared.ensureInitialized()
        let db = try FDBClient.openDatabase()
        let subspace = Subspace(Tuple("fdbrl-idxbuild", UUID().uuidString))

        // Populate with metadata that has NO price index.
        try await db.withRecordContext { context in
            let store = try await FDBRecordStore.open(context: context, subspace: subspace, metaData: baseMeta())
            for id in Int64(1)...5 {
                try await store.save(Fdb_Test_Order.sample(id: id, price: id * 10))
            }
        }

        // Reopen with the price index declared → it should be writeOnly.
        let stateBefore = try await db.withRecordContext { context in
            let store = try await FDBRecordStore.open(context: context, subspace: subspace, metaData: extendedMeta())
            return store.indexState(named: "priceIdx")
        }
        #expect(stateBefore == .writeOnly)

        // A covering query must fail while the index is not readable.
        var threwBeforeBuild = false
        do {
            _ = try await db.withRecordContext { context in
                let store = try await FDBRecordStore.open(context: context, subspace: subspace, metaData: extendedMeta())
                return try await store.executeCoveringQuery(
                    RecordQuery(Fdb_Test_Order.self).where(Query.field(\.price).equals(30)), using: "priceIdx")
            }
        } catch {
            threwBeforeBuild = true
        }
        #expect(threwBeforeBuild)

        // Build the index online, in small batches (exercises the resume loop).
        try await db.buildIndex(subspace: subspace, metaData: extendedMeta(), indexName: "priceIdx", batchSize: 2)

        // Now readable, and the backfilled existing records are covered by the index.
        let (stateAfter, covered) = try await db.withRecordContext { context in
            let store = try await FDBRecordStore.open(context: context, subspace: subspace, metaData: extendedMeta())
            let entries = try await store.executeCoveringQuery(
                RecordQuery(Fdb_Test_Order.self).where(Query.field(\.price).equals(30)), using: "priceIdx")
            return (store.indexState(named: "priceIdx"), entries)
        }
        #expect(stateAfter == .readable)
        #expect(covered.count == 1)
        #expect(covered.first?.primaryKey == Tuple(Int64(3))) // price 30 → order 3

        // A normal query now finds the backfilled records too.
        let ids = try await db.withRecordContext { context in
            let store = try await FDBRecordStore.open(context: context, subspace: subspace, metaData: extendedMeta())
            var result: [Int64] = []
            for try await record in try await store.executeQuery(
                RecordQuery(Fdb_Test_Order.self).where(Query.field(\.price).lessThan(35))) {
                result.append(record.record.orderID)
            }
            return result.sorted()
        }
        #expect(ids == [1, 2, 3])

        // Cleanup.
        try await db.withRecordContext { context in
            let store = try await FDBRecordStore.open(context: context, subspace: subspace, metaData: extendedMeta())
            try await store.deleteAllRecords()
        }
    }
}
#endif
