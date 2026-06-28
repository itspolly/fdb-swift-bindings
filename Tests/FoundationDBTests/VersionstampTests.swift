/*
 * VersionstampTests.swift
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

@Suite("Versionstamp tuple encoding")
struct VersionstampEncodingTests {
    private func readLE32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        UInt32(littleEndian: Array(bytes).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
    }

    @Test("a complete versionstamp round-trips through tuple encoding")
    func roundTrip() throws {
        let version = Array<UInt8>(0 ..< 10)
        let stamp = Versionstamp(transactionVersion: version, userVersion: 7)
        let decoded = try Tuple.decode(from: Tuple(stamp).encode())
        let back = decoded.first as? Versionstamp
        #expect(back?.transactionVersion == version)
        #expect(back?.userVersion == 7)
        #expect(back?.isIncomplete == false)
    }

    @Test("an incomplete versionstamp round-trips as incomplete")
    func incompleteRoundTrip() throws {
        let decoded = try Tuple.decode(from: Tuple(Versionstamp.incomplete(3)).encode())
        let back = decoded.first as? Versionstamp
        #expect(back?.isIncomplete == true)
        #expect(back?.userVersion == 3)
    }

    @Test("packWithVersionstamp appends the correct little-endian offset")
    func offset() throws {
        // [0x33][12 payload] → versionstamp starts at index 1.
        let packed = try Tuple(Versionstamp.incomplete()).packWithVersionstamp()
        #expect(packed.count == 1 + Versionstamp.payloadSize + 4)
        #expect(readLE32(packed.suffix(4)) == 1)

        // "a" → [0x02, 0x61, 0x00] (3 bytes), so 0x33 is at index 3, versionstamp at 4.
        let prefixed = try Tuple("a", Versionstamp.incomplete()).packWithVersionstamp()
        #expect(readLE32(prefixed.suffix(4)) == 4)
    }

    @Test("subspace packWithVersionstamp accounts for the prefix")
    func subspaceOffset() throws {
        let subspace = Subspace(prefix: [0xAA, 0xBB])
        let packed = try subspace.packWithVersionstamp(Tuple(Versionstamp.incomplete()))
        // prefix (2) + 0x33, so the versionstamp starts at index 3.
        #expect(readLE32(packed.suffix(4)) == 3)
    }

    @Test("packWithVersionstamp requires exactly one incomplete versionstamp")
    func requiresOne() {
        #expect(throws: TupleError.self) { try Tuple("a").packWithVersionstamp() }
        #expect(throws: TupleError.self) {
            try Tuple(Versionstamp.incomplete(), Versionstamp.incomplete(1)).packWithVersionstamp()
        }
    }
}

@Suite("Versionstamped keys (integration)", .serialized)
struct VersionstampedKeyTests {
    private func openDatabase() async throws -> FDBDatabase {
        try await FDBClient.maybeInitialize()
        return try FDBClient.openDatabase()
    }

    @Test("versionstamped-key appends form an ordered, complete event log")
    func eventLog() async throws {
        let db = try await openDatabase()
        let log = Subspace(Tuple("evtlog", UUID().uuidString))

        for index in 0 ..< 3 {
            try await db.withTransaction { transaction in
                let key = try log.packWithVersionstamp(Tuple(Versionstamp.incomplete()))
                transaction.setVersionstampedKey(key, value: Array("event-\(index)".utf8))
            }
        }

        let (begin, end) = log.range
        let (values, firstStampComplete) = try await db.withTransaction { transaction -> ([String], Bool) in
            var values: [String] = []
            var firstComplete = false
            for try await (key, value) in transaction.getRange(beginKey: begin, endKey: end) {
                values.append(String(decoding: value, as: UTF8.self))
                if values.count == 1, let stamp = try log.unpack(key).first as? Versionstamp {
                    firstComplete = !stamp.isIncomplete
                }
            }
            return (values, firstComplete)
        }

        #expect(values == ["event-0", "event-1", "event-2"]) // commit order preserved
        #expect(firstStampComplete) // the placeholder was replaced with a real versionstamp

        try await db.withTransaction { $0.clearRange(beginKey: begin, endKey: end) }
    }
}
