/*
 * PagingTests.swift
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

/// Stateless pagination over the various plan types.
@Suite("Paging (integration)", .serialized)
struct PagingTests {
    /// Seeds 10 orders with price = id * 10.
    private func seed(_ run: StoreRunner) async throws {
        try await run { store in
            for id in Int64(1)...10 {
                try await store.save(Fdb_Test_Order.sample(id: id, price: id * 10))
            }
        }
    }

    /// Walks every page of `query`, returning the order ids in page order.
    private func collectPaged(_ run: StoreRunner, _ query: RecordQuery<Fdb_Test_Order>) async throws -> [Int64] {
        var ids: [Int64] = []
        var continuation: FDB.Bytes?
        var pages = 0
        repeat {
            let token = continuation
            let page = try await run { store in
                try await store.executeQuery(query, continuation: token)
            }
            ids.append(contentsOf: page.records.map { $0.record.orderID })
            continuation = page.continuation
            pages += 1
            #expect(pages <= 100) // guard against a non-terminating loop
        } while continuation != nil
        return ids
    }

    @Test("full-scan paging walks all records once, in order")
    func fullScanPaging() async throws {
        try await RecordLayerTestCase.withStore { run in
            try await seed(run)
            let ids = try await collectPaged(run, RecordQuery(Fdb_Test_Order.self).limited(to: 3))
            #expect(ids == Array(Int64(1)...10))
        }
    }

    @Test("index-scan paging walks all matching records once")
    func indexScanPaging() async throws {
        try await RecordLayerTestCase.withStore { run in
            try await seed(run)
            // price < 1000 matches all; planned as an index scan on order.price.
            let ids = try await collectPaged(
                run, RecordQuery(Fdb_Test_Order.self).where(Query.field(\.price).lessThan(1000)).limited(to: 4))
            #expect(ids.sorted() == Array(Int64(1)...10))
            #expect(Set(ids).count == 10) // no duplicates across pages
        }
    }

    @Test("sorted paging preserves order across pages")
    func sortedPaging() async throws {
        try await RecordLayerTestCase.withStore { run in
            try await seed(run)
            let ids = try await collectPaged(
                run, RecordQuery(Fdb_Test_Order.self).sorted(by: .field(\.price), reversed: true).limited(to: 4))
            #expect(ids == Array(Int64(1)...10).reversed())
        }
    }

    @Test("OR-union paging walks the de-duplicated union")
    func unionPaging() async throws {
        try await RecordLayerTestCase.withStore { run in
            try await seed(run)
            let ids = try await collectPaged(
                run,
                RecordQuery(Fdb_Test_Order.self).where(Query.or(
                    Query.field(\.price).equals(20),
                    Query.field(\.price).equals(40),
                    Query.field(\.price).equals(60)
                )).limited(to: 2))
            #expect(ids.sorted() == [2, 4, 6])
        }
    }
}
#endif
