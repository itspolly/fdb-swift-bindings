/*
 * EqualityQueryTests.swift
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

/// `equals`/`notEquals` work on `Equatable` fields that are not `Comparable` (e.g. `Bool`,
/// protobuf enums); the ordering comparisons remain restricted to `Comparable` fields.
@Suite("Equality on non-Comparable fields (integration)", .serialized)
struct EqualityQueryTests {
    private func meta() -> RecordMetaData {
        RecordMetaData { RecordType(Fdb_Test_Order.self, key: 1, primaryKey: \.orderID) }
    }

    @Test("equals matches Bool and enum fields")
    func equalsNonComparable() async throws {
        try await RecordLayerTestCase.withStore(metaData: meta()) { run in
            try await run { store in
                for (id, fulfilled, color): (Int64, Bool, Fdb_Test_Color) in
                    [(1, true, .red), (2, false, .blue), (3, true, .blue)] {
                    var order = Fdb_Test_Order.sample(id: id)
                    order.fulfilled = fulfilled
                    order.color = color
                    try await store.save(order)
                }
            }

            let fulfilled = try await run { store in
                try await store.executeQuery(
                    RecordQuery(Fdb_Test_Order.self).where(Query.field(\.fulfilled).equals(true)))
                    .collect().map { $0.record.orderID }
            }
            #expect(fulfilled.sorted() == [1, 3])

            let blue = try await run { store in
                try await store.executeQuery(
                    RecordQuery(Fdb_Test_Order.self).where(Query.field(\.color).equals(.blue)))
                    .collect().map { $0.record.orderID }
            }
            #expect(blue.sorted() == [2, 3])

            let notFulfilled = try await run { store in
                try await store.executeQuery(
                    RecordQuery(Fdb_Test_Order.self).where(Query.field(\.fulfilled).notEquals(true)))
                    .collect().map { $0.record.orderID }
            }
            #expect(notFulfilled == [2])
        }
    }
}
#endif
