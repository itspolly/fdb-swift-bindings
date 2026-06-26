/*
 * EnumIndexTests.swift
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

// A protobuf enum becomes indexable with a zero-body conformance: the library supplies the
// implementation for any RawRepresentable whose RawValue is Int (which every proto enum is).
extension Fdb_Test_Color: IndexableValue {}

/// Indexing on a protobuf enum field, including as a column of a composite index.
@Suite("Enum index (integration)", .serialized)
struct EnumIndexTests {
    private func meta() -> RecordMetaData {
        RecordMetaData {
            RecordType(Fdb_Test_Order.self, key: 1, primaryKey: \.orderID)
                .index("order.color", on: \.color, key: 10)
                .index("order.flowerColor",
                       on: .concat(.field(\.flower), .field(\.color)), key: 11)
        }
    }

    @Test("enum fields can be indexed (singular and as a composite column)")
    func enumIndexing() async throws {
        try await RecordLayerTestCase.withStore(metaData: meta()) { run in
            try await run { store in
                var red = Fdb_Test_Order.sample(id: 1, flower: "rose")
                red.color = .red
                var blue = Fdb_Test_Order.sample(id: 2, flower: "rose")
                blue.color = .blue
                try await store.save(red)
                try await store.save(blue)
            }
            // 2 records × 2 indexes = 4 entries; the enum encodes to its raw value.
            let count = try await run { try await $0.allIndexKeys().count }
            #expect(count == 4)

            let loaded = try await run { try await $0.load(Fdb_Test_Order.self, Int64(2)) }
            #expect(loaded?.record.color == .blue)
        }
    }
}
#endif
