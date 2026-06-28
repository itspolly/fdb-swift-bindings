/*
 * ReverseRangeTests.swift
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

@Suite("Reverse range (integration)", .serialized)
struct ReverseRangeTests {
    private func openDatabase() async throws -> FDBDatabase {
        try await FDBClient.maybeInitialize()
        return try FDBClient.openDatabase()
    }

    private func values(_ db: FDBDatabase, _ subspace: Subspace, reverse: Bool) async throws -> [UInt8] {
        let (begin, end) = subspace.range
        return try await db.withTransaction { transaction -> [UInt8] in
            var result: [UInt8] = []
            for try await (_, value) in transaction.getRange(beginKey: begin, endKey: end, reverse: reverse) {
                result.append(value[0])
            }
            return result
        }
    }

    @Test("getRange yields ascending forward and descending in reverse")
    func reverseOrder() async throws {
        let db = try await openDatabase()
        let subspace = Subspace(Tuple("revtest", UUID().uuidString))
        try await db.withTransaction { transaction in
            for i in Int64(0) ..< 5 {
                transaction.setValue([UInt8(i)], for: subspace.pack(i))
            }
        }

        #expect(try await values(db, subspace, reverse: false) == [0, 1, 2, 3, 4])
        #expect(try await values(db, subspace, reverse: true) == [4, 3, 2, 1, 0])

        let (begin, end) = subspace.range
        try await db.withTransaction { $0.clearRange(beginKey: begin, endKey: end) }
    }
}
