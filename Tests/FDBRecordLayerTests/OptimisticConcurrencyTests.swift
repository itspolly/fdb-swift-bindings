/*
 * OptimisticConcurrencyTests.swift
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

/// Opt-in record versions and `save(_:ifVersionMatches:)` for stateless optimistic concurrency.
@Suite("Optimistic concurrency (integration)", .serialized)
struct OptimisticConcurrencyTests {
    private func meta() -> RecordMetaData {
        RecordMetaData {
            RecordType(Fdb_Test_Order.self, key: 1, primaryKey: \.orderID).storingVersions()
        }
    }

    /// Runs a conditional save and reports whether it failed with `.versionMismatch`.
    private func mismatches(_ run: StoreRunner, _ order: Fdb_Test_Order, ifVersionMatches expected: FDBRecordVersion?) async throws -> Bool {
        do {
            try await run { _ = try await $0.save(order, ifVersionMatches: expected) }
            return false
        } catch let error as RecordStoreError {
            if case .versionMismatch = error { return true }
            throw error
        }
    }

    @Test("a stored record carries a version that changes on each save")
    func versionAssigned() async throws {
        try await RecordLayerTestCase.withStore(metaData: meta()) { run in
            try await run { _ = try await $0.save(Fdb_Test_Order.sample(id: 1, price: 10)) }
            let v1 = try await run { try await $0.load(Fdb_Test_Order.self, Int64(1))?.version }
            #expect(v1 != nil)

            try await run { _ = try await $0.save(Fdb_Test_Order.sample(id: 1, price: 20)) }
            let v2 = try await run { try await $0.load(Fdb_Test_Order.self, Int64(1))?.version }
            #expect(v2 != nil)
            #expect(v1 != v2) // version advances on rewrite
        }
    }

    @Test("conditional save succeeds on a match and fails (no retry) on a stale version")
    func conditionalSave() async throws {
        try await RecordLayerTestCase.withStore(metaData: meta()) { run in
            try await run { _ = try await $0.save(Fdb_Test_Order.sample(id: 1, price: 10)) }
            let v1 = try await run { try await $0.load(Fdb_Test_Order.self, Int64(1))?.version }

            // Update with the current version → succeeds.
            try await run { _ = try await $0.save(Fdb_Test_Order.sample(id: 1, price: 20), ifVersionMatches: v1) }
            let price1 = try await run { try await $0.load(Fdb_Test_Order.self, Int64(1))?.record.price }
            #expect(price1 == 20)

            // Update again with the now-stale v1 → versionMismatch, and the record is untouched.
            let stale = try await mismatches(run, Fdb_Test_Order.sample(id: 1, price: 999), ifVersionMatches: v1)
            #expect(stale)
            let price2 = try await run { try await $0.load(Fdb_Test_Order.self, Int64(1))?.record.price }
            #expect(price2 == 20)
        }
    }

    @Test("ifVersionMatches nil means create-only")
    func createOnly() async throws {
        try await RecordLayerTestCase.withStore(metaData: meta()) { run in
            // No record yet → nil expected succeeds.
            try await run { _ = try await $0.save(Fdb_Test_Order.sample(id: 7, price: 1), ifVersionMatches: nil) }
            #expect(try await run { try await $0.load(Fdb_Test_Order.self, Int64(7)) } != nil)

            // Now it exists → nil expected fails.
            let blocked = try await mismatches(run, Fdb_Test_Order.sample(id: 7, price: 2), ifVersionMatches: nil)
            #expect(blocked)
        }
    }
}
#endif
