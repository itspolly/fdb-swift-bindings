/*
 * SubspaceTests.swift
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

import FoundationDB

@Suite("Subspace")
struct SubspaceTests {
    @Test("pack then unpack round-trips tuple elements")
    func packUnpackRoundTrip() throws {
        let s = Subspace(Tuple("app", Int64(1)))
        let key = s.pack(Tuple("user", Int64(42)))
        #expect(s.contains(key))

        let elements = try s.unpack(key)
        #expect(elements.count == 2)
        #expect(elements[0] as? String == "user")
        #expect(elements[1] as? Int64 == 42)
    }

    @Test("keys carry the subspace prefix and child keys nest")
    func prefixing() {
        let root = Subspace(Tuple("R"))
        let child = root.child("records", Int64(7))
        let key = child.pack(Int64(99))

        #expect(root.contains(key))
        #expect(child.contains(key))
        // Child prefix extends the parent prefix.
        #expect(child.prefix.starts(with: root.prefix))
    }

    @Test("unpacking a foreign key throws")
    func unpackForeignKey() {
        let a = Subspace(Tuple("A"))
        let b = Subspace(Tuple("B"))
        let key = a.pack(Int64(1))
        #expect(throws: SubspaceError.keyNotInSubspace) {
            _ = try b.unpack(key)
        }
    }

    @Test("range brackets all keys in the subspace")
    func ranges() {
        let s = Subspace(Tuple("data"))
        let (begin, end) = s.range
        let lowKey = s.pack(Int64(-1_000_000))
        let highKey = s.pack("zzzzzzzz")

        // Every key in the subspace sorts within [begin, end).
        let outside = Subspace(Tuple("dataa")).pack(Int64(0))
        #expect(lexLess(begin, lowKey) || begin == lowKey)
        #expect(lexLess(highKey, end))
        #expect(!s.contains(outside))
    }

    /// Byte-wise lexicographic less-than, matching FDB key ordering.
    private func lexLess(_ a: FDB.Bytes, _ b: FDB.Bytes) -> Bool {
        for (x, y) in zip(a, b) where x != y { return x < y }
        return a.count < b.count
    }
}

@Suite("KeySpacePath")
struct KeySpacePathTests {
    @Test("path children extend the prefix and resolve to a subspace")
    func resolution() throws {
        let path = KeySpacePath("app").child("tenant-1").child(Int64(2))
        let subspace = path.toSubspace()

        let key = subspace.pack("k")
        let elements = try subspace.unpack(key)
        #expect(elements[0] as? String == "k")

        // The resolved prefix equals the equivalent tuple encoding.
        let equivalent = Tuple("app", "tenant-1", Int64(2)).encode()
        #expect(subspace.prefix == equivalent)
    }
}

/// Demonstrates that `Subspace` composes with the plain (non-Record-Layer) transaction API:
/// `pack`/`range`/`unpack` produce and consume the `FDB.Bytes` keys those methods use.
@Suite("Subspace with base transactions (integration)", .serialized)
struct SubspaceIntegrationTests {
    @Test("subspace keys round-trip through setValue/getRange/clearRange")
    func roundTrip() async throws {
        try await FDBClient.maybeInitialize()
        let db = try FDBClient.openDatabase()
        let space = Subspace(Tuple("fdbswift-subspace-test", UUID().uuidString))

        try await db.withTransaction { transaction in
            transaction.setValue([10], for: space.pack(Int64(1)))
            transaction.setValue([20], for: space.pack(Int64(2)))
            // A key outside the subspace, to prove the range scan is bounded.
            transaction.setValue([99], for: [UInt8]("fdbswift-other".utf8))
        }

        let pairs: [(Int64, UInt8)] = try await db.withTransaction { transaction in
            var result: [(Int64, UInt8)] = []
            let (begin, end) = space.range
            for try await (key, value) in transaction.getRange(beginKey: begin, endKey: end) {
                let elements = try space.unpack(key)
                result.append((elements[0] as! Int64, value[0]))
            }
            return result
        }

        #expect(pairs.map(\.0) == [1, 2])
        #expect(pairs.map(\.1) == [10, 20])

        // Cleanup, again via the base API and the subspace range.
        try await db.withTransaction { transaction in
            let (begin, end) = space.range
            transaction.clearRange(beginKey: begin, endKey: end)
            transaction.clear(key: [UInt8]("fdbswift-other".utf8))
        }
    }
}
