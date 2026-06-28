/*
 * WatchTests.swift
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

import Foundation
import Testing

@testable import FoundationDB

@Suite("Watch (integration)", .serialized)
struct WatchTests {
    private func openDatabase() async throws -> FDBDatabase {
        try await FDBClient.maybeInitialize()
        return try FDBClient.openDatabase()
    }

    private func uniqueKey() -> FDB.Bytes {
        Array("fdb-watch-\(UUID().uuidString)".utf8)
    }

    @Test("a watch fires after the key changes")
    func watchFires() async throws {
        let db = try await openDatabase()
        let key = uniqueKey()
        try await db.withTransaction { $0.setValue([1], for: key) }

        // Arm the watch (relative to the value read here), then commit.
        let watch = try await db.withTransaction { transaction -> FDBWatch in
            _ = try await transaction.getValue(for: key)
            return transaction.watch(key: key)
        }

        // A later change to the key fires the watch.
        try await db.withTransaction { $0.setValue([2], for: key) }
        try await watch.wait()

        let value = try await db.withTransaction { try await $0.getValue(for: key) }
        #expect(value == [2])

        try await db.withTransaction { $0.clear(key: key) }
    }

    @Test("watch stream yields the current value then each change")
    func watchStream() async throws {
        let db = try await openDatabase()
        let key = uniqueKey()
        try await db.withTransaction { $0.setValue([10], for: key) }

        var iterator = db.watch(key: key).makeAsyncIterator()

        guard let first = try await iterator.next() else {
            Issue.record("stream ended before the current value")
            return
        }
        #expect(first == [10])

        try await db.withTransaction { $0.setValue([20], for: key) }
        guard let second = try await iterator.next() else {
            Issue.record("stream ended before the change")
            return
        }
        #expect(second == [20])

        // Dropping the iterator cancels the underlying watch.
        try await db.withTransaction { $0.clear(key: key) }
    }
}
