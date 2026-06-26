/*
 * QueryPlannerTests.swift
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

/// Unit tests for index selection. No cluster required.
@Suite("QueryPlanner")
struct QueryPlannerTests {
    private let meta = RecordLayerTestCase.standardMetaData()

    private func plan(_ filter: QueryComponent<Fdb_Test_Order>) -> QueryPlan {
        let recordType = meta.recordType(for: Fdb_Test_Order.self)!
        return QueryPlanner.plan(recordType: recordType, atoms: filter.atoms)
    }

    @Test("equality on an indexed field selects that index")
    func equalitySelectsIndex() {
        let plan = plan(Query.field(\Fdb_Test_Order.price).equals(10))
        #expect(plan.indexName == "order.price")
    }

    @Test("range on an indexed field selects that index")
    func rangeSelectsIndex() {
        let plan = plan(Query.field(\Fdb_Test_Order.price).lessThan(10))
        #expect(plan.indexName == "order.price")
    }

    @Test("comparison on an unindexed field falls back to a full scan")
    func unindexedFallsBack() {
        let plan = plan(Query.field(\Fdb_Test_Order.flower).equals("rose"))
        #expect(plan.indexName == nil)
    }

    @Test("nested-field index is selected")
    func nestedIndex() {
        let plan = plan(Query.field(\Fdb_Test_Order.customer.name).equals("alice"))
        #expect(plan.indexName == "order.customerName")
    }

    @Test("AND prefers the equality conjunct's index over a range")
    func andPrefersEquality() {
        // price has a range predicate (indexed) and customerName has equality (indexed);
        // equality is preferred.
        let plan = plan(Query.and(
            Query.field(\Fdb_Test_Order.price).greaterThan(5),
            Query.field(\Fdb_Test_Order.customer.name).equals("alice")
        ))
        #expect(plan.indexName == "order.customerName")
    }

    @Test("repeated membership selects the fan-out index and requires distinct")
    func fanOutIndex() {
        let plan = plan(Query.any(\Fdb_Test_Order.tags).equals("red"))
        #expect(plan.indexName == "order.byTag")
        #expect(plan.requiresDistinct)
    }

    @Test("OR is not index-eligible")
    func orNotIndexed() {
        let plan = plan(Query.or(
            Query.field(\Fdb_Test_Order.price).equals(10),
            Query.field(\Fdb_Test_Order.price).equals(20)
        ))
        #expect(plan.indexName == nil)
    }
}
#endif
