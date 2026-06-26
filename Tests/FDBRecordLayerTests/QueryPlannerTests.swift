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
        return QueryPlanner.plan(recordType: recordType, node: filter.node)
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
        // customer.id has no index (customer.name does).
        let plan = plan(Query.field(\Fdb_Test_Order.customer.id).equals(5))
        #expect(plan.indexName == nil)
        #expect(plan.unionIndexNames == nil)
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

    @Test("equality + range AND selects the composite multi-column index")
    func multiColumnPrefix() {
        let plan = plan(Query.and(
            Query.field(\Fdb_Test_Order.flower).equals("rose"),
            Query.field(\Fdb_Test_Order.price).lessThan(50)
        ))
        // flowerPrice covers [flower, price] (prefix length 2), beating the single price index.
        #expect(plan.indexName == "order.flowerPrice")
    }

    @Test("OR of index-able branches plans a union")
    func orUnion() {
        let plan = plan(Query.or(
            Query.field(\Fdb_Test_Order.price).equals(10),
            Query.field(\Fdb_Test_Order.price).equals(20)
        ))
        #expect(plan.indexName == nil)
        #expect(plan.unionIndexNames == ["order.price", "order.price"])
        #expect(plan.requiresDistinct)
    }

    @Test("OR with an unindexed branch falls back to a full scan")
    func orFallsBack() {
        let plan = plan(Query.or(
            Query.field(\Fdb_Test_Order.price).equals(10),
            Query.field(\Fdb_Test_Order.customer.id).equals(5)
        ))
        #expect(plan.indexName == nil)
        #expect(plan.unionIndexNames == nil)
    }

    @Test("planner ignores indexes outside the readable set")
    func readableFilter() {
        let recordType = meta.recordType(for: Fdb_Test_Order.self)!
        let node = Query.field(\Fdb_Test_Order.price).equals(10).node
        let excluded = QueryPlanner.plan(recordType: recordType, node: node, readableIndexNames: [])
        #expect(excluded.indexName == nil)
        let included = QueryPlanner.plan(
            recordType: recordType, node: node, readableIndexNames: ["order.price"])
        #expect(included.indexName == "order.price")
    }

    @Test("coverage detection: a single equality is covered, an extra residual is not")
    func coverage() throws {
        let recordType = meta.recordType(for: Fdb_Test_Order.self)!
        let priceIndex = recordType.indexes.first { $0.name == "order.price" }!

        let coveredNode = Query.field(\Fdb_Test_Order.price).equals(10).node
        let coveredScan = QueryPlanner.scan(index: priceIndex, atoms: coveredNode.conjunctionAtoms)!
        #expect(QueryPlanner.isFullyCovered(coveredNode, by: coveredScan))

        // price index can't cover an extra predicate on flower.
        let residualNode = Query.and(
            Query.field(\Fdb_Test_Order.price).equals(10),
            Query.field(\Fdb_Test_Order.flower).equals("rose")
        ).node
        let residualScan = QueryPlanner.scan(index: priceIndex, atoms: residualNode.conjunctionAtoms)!
        #expect(!QueryPlanner.isFullyCovered(residualNode, by: residualScan))
    }
}
#endif
