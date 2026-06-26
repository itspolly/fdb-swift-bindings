/*
 * QueryIntegrationTests.swift
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

/// End-to-end query tests (require a running cluster).
@Suite("RecordQuery (integration)", .serialized)
struct QueryIntegrationTests {
    /// Seeds a standard set of orders and returns the runner.
    private func seed(_ run: StoreRunner) async throws {
        try await run { store in
            try await store.save(Fdb_Test_Order.sample(id: 1, flower: "rose", price: 10, customer: "alice", tags: ["red", "fragrant"]))
            try await store.save(Fdb_Test_Order.sample(id: 2, flower: "tulip", price: 20, customer: "bob", tags: ["red"]))
            try await store.save(Fdb_Test_Order.sample(id: 3, flower: "rose", price: 30, customer: "alice", tags: ["white"]))
            try await store.save(Fdb_Test_Order.sample(id: 4, flower: "lily", price: 40, customer: "carol", tags: ["white", "fragrant"]))
        }
    }

    private func ids<S: AsyncSequence>(_ cursor: S) async throws -> [Int64]
    where S.Element == FDBStoredRecord<Fdb_Test_Order> {
        var result: [Int64] = []
        for try await record in cursor { result.append(record.record.orderID) }
        return result.sorted()
    }

    @Test("equality query via index")
    func equalityIndex() async throws {
        try await RecordLayerTestCase.withStore { run in
            try await seed(run)
            let ids = try await run { store in
                try await self.ids(try await store.executeQuery(
                    RecordQuery(Fdb_Test_Order.self).where(Query.field(\.price).equals(20))))
            }
            #expect(ids == [2])
        }
    }

    @Test("range query via index")
    func rangeIndex() async throws {
        try await RecordLayerTestCase.withStore { run in
            try await seed(run)
            let ids = try await run { store in
                try await self.ids(try await store.executeQuery(
                    RecordQuery(Fdb_Test_Order.self).where(Query.field(\.price).lessThan(30))))
            }
            #expect(ids == [1, 2])
        }
    }

    @Test("full scan with residual filter on an unindexed field")
    func residualFilter() async throws {
        try await RecordLayerTestCase.withStore { run in
            try await seed(run)
            let ids = try await run { store in
                try await self.ids(try await store.executeQuery(
                    RecordQuery(Fdb_Test_Order.self).where(Query.field(\.flower).equals("rose"))))
            }
            #expect(ids == [1, 3])
        }
    }

    @Test("AND combines an index scan with a residual predicate")
    func andIndexPlusResidual() async throws {
        try await RecordLayerTestCase.withStore { run in
            try await seed(run)
            // customerName is indexed; flower is residual.
            let ids = try await run { store in
                try await self.ids(try await store.executeQuery(
                    RecordQuery(Fdb_Test_Order.self).where(Query.and(
                        Query.field(\.customer.name).equals("alice"),
                        Query.field(\.flower).equals("rose")
                    ))))
            }
            #expect(ids == [1, 3])
        }
    }

    @Test("repeated membership query via fan-out index, de-duplicated")
    func fanOutMembership() async throws {
        try await RecordLayerTestCase.withStore { run in
            try await seed(run)
            let ids = try await run { store in
                try await self.ids(try await store.executeQuery(
                    RecordQuery(Fdb_Test_Order.self).where(Query.any(\.tags).equals("fragrant"))))
            }
            #expect(ids == [1, 4])
        }
    }

    @Test("sorted query returns records in sort order")
    func sortedQuery() async throws {
        try await RecordLayerTestCase.withStore { run in
            try await seed(run)
            let prices = try await run { store in
                var result: [Int64] = []
                let cursor = try await store.executeQuery(
                    RecordQuery(Fdb_Test_Order.self)
                        .where(Query.field(\.customer.name).equals("alice"))
                        .sorted(by: .field(\.price), reversed: true))
                for try await record in cursor { result.append(record.record.price) }
                return result
            }
            #expect(prices == [30, 10]) // descending
        }
    }

    @Test("equality + range AND uses the composite index")
    func multiColumnRange() async throws {
        try await RecordLayerTestCase.withStore { run in
            try await seed(run)
            // rose orders are 1 (price 10) and 3 (price 30); only 1 has price < 30.
            let ids = try await run { store in
                try await self.ids(try await store.executeQuery(
                    RecordQuery(Fdb_Test_Order.self).where(Query.and(
                        Query.field(\.flower).equals("rose"),
                        Query.field(\.price).lessThan(30)
                    ))))
            }
            #expect(ids == [1])
        }
    }

    @Test("OR query unions index scans and de-duplicates")
    func orUnion() async throws {
        try await RecordLayerTestCase.withStore { run in
            try await seed(run)
            let ids = try await run { store in
                try await self.ids(try await store.executeQuery(
                    RecordQuery(Fdb_Test_Order.self).where(Query.or(
                        Query.field(\.price).equals(10),
                        Query.field(\.price).equals(40)
                    ))))
            }
            #expect(ids == [1, 4])
        }
    }

    @Test("covering query returns index entries without loading records")
    func coveringQuery() async throws {
        try await RecordLayerTestCase.withStore { run in
            try await seed(run)
            let covered = try await run { store in
                try await store.executeCoveringQuery(
                    RecordQuery(Fdb_Test_Order.self).where(Query.field(\.price).equals(20)),
                    using: "order.price")
            }
            #expect(covered.count == 1)
            #expect(covered.first?.primaryKey == Tuple(Int64(2)))
            #expect(covered.first?.columns.first as? Int64 == 20)
        }
    }

    @Test("covering query throws when the filter is not covered by the index")
    func coveringQueryNotCovered() async throws {
        try await RecordLayerTestCase.withStore { run in
            try await seed(run)
            var thrown: Error?
            do {
                _ = try await run { store in
                    try await store.executeCoveringQuery(
                        RecordQuery(Fdb_Test_Order.self).where(Query.and(
                            Query.field(\.price).equals(20),
                            Query.field(\.flower).equals("tulip")
                        )),
                        using: "order.price")
                }
            } catch {
                thrown = error
            }
            #expect(thrown is RecordStoreError)
        }
    }

    @Test("count matches executeQuery for covered and uncovered filters")
    func countFastPath() async throws {
        try await RecordLayerTestCase.withStore { run in
            try await seed(run)
            let (covered, residual, all) = try await run { store in
                (try await store.count(RecordQuery(Fdb_Test_Order.self).where(Query.field(\.price).lessThan(30))),
                 try await store.count(RecordQuery(Fdb_Test_Order.self).where(Query.field(\.flower).equals("rose"))),
                 try await store.count(RecordQuery(Fdb_Test_Order.self)))
            }
            #expect(covered == 2)  // prices 10, 20 (index-only)
            #expect(residual == 2) // rose: ids 1, 3 (full scan + residual)
            #expect(all == 4)
        }
    }
}
#endif
