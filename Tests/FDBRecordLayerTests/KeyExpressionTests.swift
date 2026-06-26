/*
 * KeyExpressionTests.swift
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

/// Builds a sample order with the given tags.
private func makeOrder(id: Int64 = 1, flower: String = "rose", price: Int64 = 10,
                       customer: String = "alice", tags: [String] = []) -> Fdb_Test_Order {
    var order = Fdb_Test_Order()
    order.orderID = id
    order.flower = flower
    order.price = price
    order.customer.id = 100
    order.customer.name = customer
    order.tags = tags
    return order
}

/// Encodes a list of keys (each a column list) to comparable bytes for assertions.
private func encoded(_ keys: [[any TupleElement]]) -> [FDB.Bytes] {
    keys.map { Tuple($0).encode() }
}

@Suite("KeyExpression")
struct KeyExpressionTests {
    @Test("single scalar field yields one single-column key")
    func singleField() {
        let expr = KeyExpression<Fdb_Test_Order>.field(\.price)
        let keys = expr.evaluate(makeOrder(price: 42))
        #expect(keys.count == 1)
        #expect(keys[0].count == 1)
        #expect(keys[0][0] as? Int64 == 42)
        #expect(!expr.producesMultipleKeys)
        #expect(expr.columnIdentities == [FieldID.keyPath(\Fdb_Test_Order.price)])
    }

    @Test("nested field via appended KeyPath")
    func nestedField() {
        let expr = KeyExpression<Fdb_Test_Order>.field(\.customer.name)
        let keys = expr.evaluate(makeOrder(customer: "bob"))
        #expect(keys[0][0] as? String == "bob")
        #expect(expr.columnIdentities == [FieldID.keyPath(\Fdb_Test_Order.customer.name)])
    }

    @Test("concat builds a multi-column key in order")
    func concatColumns() {
        let expr = KeyExpression.concat(
            KeyExpression<Fdb_Test_Order>.field(\.flower),
            KeyExpression<Fdb_Test_Order>.field(\.price)
        )
        let keys = expr.evaluate(makeOrder(flower: "tulip", price: 7))
        #expect(keys.count == 1)
        #expect(keys[0].count == 2)
        #expect(keys[0][0] as? String == "tulip")
        #expect(keys[0][1] as? Int64 == 7)
        #expect(expr.columnCount == 2)
    }

    @Test("fan-out over a repeated field yields one key per element")
    func fanOut() {
        let expr = KeyExpression<Fdb_Test_Order>.field(\.tags, .fanOut)
        let keys = expr.evaluate(makeOrder(tags: ["a", "b", "c"]))
        #expect(keys.count == 3)
        #expect(encoded(keys) == encoded([["a"], ["b"], ["c"]]))
        #expect(expr.producesMultipleKeys)
    }

    @Test("fan-out over an empty repeated field yields no keys")
    func fanOutEmpty() {
        let expr = KeyExpression<Fdb_Test_Order>.field(\.tags, .fanOut)
        #expect(expr.evaluate(makeOrder(tags: [])).isEmpty)
    }

    @Test("concatenate collapses a repeated field into one nested-tuple key")
    func concatenateFan() {
        let expr = KeyExpression<Fdb_Test_Order>.field(\.tags, .concatenate)
        let keys = expr.evaluate(makeOrder(tags: ["a", "b"]))
        #expect(keys.count == 1)
        #expect(keys[0][0] as? Tuple == Tuple("a", "b"))
        #expect(!expr.producesMultipleKeys)
    }

    @Test("concat of two fan-outs is a cartesian product")
    func cartesian() {
        let expr = KeyExpression.concat(
            KeyExpression<Fdb_Test_Order>.field(\.tags, .fanOut),
            KeyExpression<Fdb_Test_Order>.field(\.tags, .fanOut)
        )
        let keys = expr.evaluate(makeOrder(tags: ["x", "y"]))
        #expect(keys.count == 4) // 2 x 2
        #expect(encoded(keys) == encoded([["x", "x"], ["x", "y"], ["y", "x"], ["y", "y"]]))
    }
}
#endif
