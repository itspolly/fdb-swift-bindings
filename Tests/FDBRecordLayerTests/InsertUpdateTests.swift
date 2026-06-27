/*
 * InsertUpdateTests.swift
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

/// `insert` (must not exist) and `update` (must exist) existence-asserting saves.
@Suite("insert / update (integration)", .serialized)
struct InsertUpdateTests {
    @Test("insert succeeds once, then fails if the primary key already exists")
    func insert() async throws {
        try await RecordLayerTestCase.withStore { run in
            try await run { _ = try await $0.insert(Fdb_Test_Order.sample(id: 1, flower: "rose")) }
            #expect(try await run { try await $0.load(Fdb_Test_Order.self, Int64(1)) } != nil)

            var thrown: Error?
            do {
                try await run { _ = try await $0.insert(Fdb_Test_Order.sample(id: 1, flower: "tulip")) }
            } catch { thrown = error }
            if case .recordAlreadyExists = thrown as? RecordStoreError {} else {
                Issue.record("expected recordAlreadyExists, got \(String(describing: thrown))")
            }
            // The original record is untouched.
            #expect(try await run { try await $0.load(Fdb_Test_Order.self, Int64(1))?.record.flower } == "rose")
        }
    }

    @Test("update fails if the record does not exist, succeeds once it does")
    func update() async throws {
        try await RecordLayerTestCase.withStore { run in
            var thrown: Error?
            do {
                try await run { _ = try await $0.update(Fdb_Test_Order.sample(id: 2, flower: "rose")) }
            } catch { thrown = error }
            if case .recordDoesNotExist = thrown as? RecordStoreError {} else {
                Issue.record("expected recordDoesNotExist, got \(String(describing: thrown))")
            }

            try await run { _ = try await $0.insert(Fdb_Test_Order.sample(id: 2, flower: "rose")) }
            try await run { _ = try await $0.update(Fdb_Test_Order.sample(id: 2, flower: "lily")) }
            #expect(try await run { try await $0.load(Fdb_Test_Order.self, Int64(2))?.record.flower } == "lily")
        }
    }
}
#endif
