/*
 * SplitHelperTests.swift
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
import Foundation
import Testing

@testable import FDBRecordLayer
import FoundationDB

/// Record splitting and inline versions, checked against the Java Record Layer's on-disk format.
@Suite("SplitHelper (integration)")
struct SplitHelperTests {
    /// Runs `body` with a database and a unique records subspace, clearing it afterwards.
    private func withSubspace(_ body: (FDBDatabase, Subspace) async throws -> Void) async throws {
        try await FDBBootstrap.shared.ensureInitialized()
        let database = try FDBClient.openDatabase()
        let subspace = Subspace(Tuple("fdbrl-split-test", UUID().uuidString)).child(Int64(1))
        let cleanup = {
            try await database.withTransaction { tx in
                tx.clearRange(beginKey: subspace.range.begin, endKey: subspace.range.end)
            }
        }
        do {
            try await body(database, subspace)
        } catch {
            try? await cleanup()
            throw error
        }
        try await cleanup()
    }

    private func allKeyValues(_ database: FDBDatabase, _ subspace: Subspace) async throws -> [(FDB.Bytes, FDB.Bytes)] {
        try await database.withTransaction { tx in
            var result: [(FDB.Bytes, FDB.Bytes)] = []
            for try await kv in tx.getRange(beginKey: subspace.range.begin, endKey: subspace.range.end) {
                result.append(kv)
            }
            return result
        }
    }

    /// The suffixes stored under `key`.
    private func suffixes(_ database: FDBDatabase, _ subspace: Subspace, _ key: Tuple) async throws -> [Int64] {
        let recordSubspace = subspace.subspace(key)
        return try await allKeyValues(database, recordSubspace).map {
            try SplitHelper.suffixIndex(Tuple(try recordSubspace.unpack($0.0)))
        }
    }

    private func bytes(_ count: Int, seed: UInt8 = 0) -> FDB.Bytes {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }
    }

    private func save(
        _ database: FDBDatabase, _ subspace: Subspace, _ key: Tuple, _ data: FDB.Bytes,
        version: FDBRecordVersion? = nil, previous: (any FDBStoredSizes)? = nil, clearBasedOnPrevious: Bool = false
    ) async throws -> SplitHelper.SizeInfo {
        try await database.withTransaction { tx in
            try SplitHelper.saveWithSplit(
                tx, subspace: subspace, key: key, serialized: data, version: version,
                clearBasedOnPreviousSizeInfo: clearBasedOnPrevious, previousSizeInfo: previous)
        }
    }

    private func load(_ database: FDBDatabase, _ subspace: Subspace, _ key: Tuple) async throws -> FDBRawRecord? {
        try await database.withTransaction { tx in
            try await SplitHelper.loadWithSplit(tx, subspace: subspace, key: key)
        }
    }

    // MARK: - Tests

    @Test("small record round-trips unsplit at suffix 0")
    func smallRecord() async throws {
        try await withSubspace { db, subspace in
            let key = Tuple(Int64(7))
            let data = bytes(1000)
            let sizes = try await save(db, subspace, key, data)
            #expect(sizes.keyCount == 1)
            #expect(!sizes.isSplit)
            #expect(sizes.valueSize == 1000)
            #expect(sizes.keySize == subspace.prefix.count + 2 + 1)

            let loaded = try #require(try await load(db, subspace, key))
            #expect(loaded.rawRecord == data)
            #expect(loaded.primaryKey == key)
            #expect(loaded.version == nil)
            #expect(!loaded.isSplit && !loaded.isVersionedInline)
            #expect(loaded.keyCount == 1)
            #expect(try await suffixes(db, subspace, key) == [0])
            #expect(try await load(db, subspace, Tuple(Int64(8))) == nil)
        }
    }

    @Test("large record splits into ≤100,000-byte chunks at suffixes 1, 2, 3")
    func largeRecord() async throws {
        try await withSubspace { db, subspace in
            let key = Tuple("big")
            let data = bytes(250_001)
            let sizes = try await save(db, subspace, key, data)
            #expect(sizes.isSplit)
            #expect(sizes.keyCount == 3)
            #expect(sizes.valueSize == 250_001)

            #expect(try await suffixes(db, subspace, key) == [1, 2, 3])
            let chunks = try await allKeyValues(db, subspace.subspace(key)).map { $0.1.count }
            #expect(chunks == [100_000, 100_000, 50_001])

            let loaded = try #require(try await load(db, subspace, key))
            #expect(loaded.rawRecord == data)
            #expect(loaded.isSplit)
            #expect(loaded.keyCount == 3)

            // Exactly SPLIT_RECORD_SIZE stays unsplit; one more byte splits.
            _ = try await save(db, subspace, Tuple("edge"), bytes(100_000))
            #expect(try await suffixes(db, subspace, Tuple("edge")) == [0])
            _ = try await save(db, subspace, Tuple("edge2"), bytes(100_001))
            #expect(try await suffixes(db, subspace, Tuple("edge2")) == [1, 2])
        }
    }

    @Test(
        "shrinking split→unsplit and growing unsplit→split leave no stale keys",
        arguments: [false, true])
    func shrinkAndGrow(clearBasedOnPrevious: Bool) async throws {
        try await withSubspace { db, subspace in
            let key = Tuple(Int64(1), "a")
            let big = bytes(350_000, seed: 1)
            let bigSizes = try await save(db, subspace, key, big, version: nil)
            #expect(try await suffixes(db, subspace, key) == [1, 2, 3, 4])

            // Split (4 chunks) -> smaller split (2 chunks).
            let medium = bytes(150_000, seed: 2)
            let mediumSizes = try await save(
                db, subspace, key, medium, previous: bigSizes, clearBasedOnPrevious: clearBasedOnPrevious)
            #expect(try await suffixes(db, subspace, key) == [1, 2])
            #expect(try await load(db, subspace, key)?.rawRecord == medium)

            // Split -> unsplit.
            let small = bytes(10, seed: 3)
            let smallSizes = try await save(
                db, subspace, key, small, previous: mediumSizes, clearBasedOnPrevious: clearBasedOnPrevious)
            #expect(try await suffixes(db, subspace, key) == [0])
            #expect(try await load(db, subspace, key)?.rawRecord == small)

            // Unsplit -> split.
            let grown = bytes(200_001, seed: 4)
            _ = try await save(
                db, subspace, key, grown, previous: smallSizes, clearBasedOnPrevious: clearBasedOnPrevious)
            #expect(try await suffixes(db, subspace, key) == [1, 2, 3])
            let loaded = try #require(try await load(db, subspace, key))
            #expect(loaded.rawRecord == grown)
            #expect(loaded.isSplit)
        }
    }

    @Test("versioned record shrinking drops the old version key when unversioned", arguments: [false, true])
    func versionedToUnversioned(clearBasedOnPrevious: Bool) async throws {
        try await withSubspace { db, subspace in
            let key = Tuple(Int64(3))
            let version = FDBRecordVersion(bytes: [0, 0, 0, 0, 0, 0, 0, 9, 0, 1, 0, 2])
            let first = try await save(db, subspace, key, bytes(120_000), version: version)
            #expect(first.isVersionedInline)
            #expect(try await suffixes(db, subspace, key) == [-1, 1, 2])
            _ = try await save(db, subspace, key, bytes(5), previous: first, clearBasedOnPrevious: clearBasedOnPrevious)
            #expect(try await suffixes(db, subspace, key) == [0])
            #expect(try await load(db, subspace, key)?.version == nil)
        }
    }

    @Test("delete removes every key of a split, versioned record", arguments: [false, true])
    func delete(clearBasedOnPrevious: Bool) async throws {
        try await withSubspace { db, subspace in
            let key = Tuple(Int64(5))
            let neighbor = Tuple(Int64(6))
            let version = FDBRecordVersion(bytes: [0, 0, 0, 0, 0, 0, 0, 9, 0, 1, 0, 0])
            let sizes = try await save(db, subspace, key, bytes(220_000), version: version)
            _ = try await save(db, subspace, neighbor, bytes(10))
            try await db.withTransaction { tx in
                try SplitHelper.deleteSplit(
                    tx, subspace: subspace, key: key,
                    clearBasedOnPreviousSizeInfo: clearBasedOnPrevious, previousSizeInfo: sizes)
            }
            #expect(try await suffixes(db, subspace, key) == [])
            #expect(try await load(db, subspace, key) == nil)
            #expect(try await load(db, subspace, neighbor)?.rawRecord == bytes(10))
            #expect(try await db.withTransaction { tx in
                try await SplitHelper.keyExists(tx, subspace: subspace, key: key)
            } == false)
            #expect(try await db.withTransaction { tx in
                try await SplitHelper.keyExists(tx, subspace: subspace, key: neighbor)
            } == true)
        }
    }

    @Test("complete version round-trips at suffix -1")
    func completeVersion() async throws {
        try await withSubspace { db, subspace in
            let key = Tuple(Int64(10))
            let version = FDBRecordVersion(bytes: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0x01, 0x02])
            let sizes = try await save(db, subspace, key, bytes(50), version: version)
            #expect(sizes.keyCount == 2)
            #expect(sizes.valueSize == 50 + 13)
            #expect(sizes.isVersionedInline)
            let loaded = try #require(try await load(db, subspace, key))
            #expect(loaded.version == version)
            #expect(loaded.isVersionedInline)
            #expect(loaded.keyCount == 2)
            #expect(loaded.valueSize == 63)
        }
    }

    @Test("incomplete version is completed at commit and reads back with its local version")
    func incompleteVersion() async throws {
        try await withSubspace { db, subspace in
            let key = Tuple(Int64(11))
            let data = bytes(130_000)
            let tx = try db.createTransaction()
            let sizes = try SplitHelper.saveWithSplit(
                tx, subspace: subspace, key: key, serialized: data,
                version: .incomplete(localVersion: 0x0105))
            #expect(sizes.keyCount == 3)
            #expect(sizes.valueSize == 130_000 + 13)
            _ = try await tx.commit()
            let committed = try tx.getCommittedVersion()

            let loaded = try #require(try await load(db, subspace, key))
            let version = try #require(loaded.version)
            #expect(version.isComplete)
            #expect(version.localVersion == 0x0105)
            let expectedPrefix = withUnsafeBytes(of: UInt64(committed).bigEndian) { Array($0) }
            #expect(Array(version.globalVersion.prefix(8)) == expectedPrefix)
            #expect(loaded.rawRecord == data)

            // The stored value is exactly Tuple(Versionstamp(...)).pack().
            let raw = try #require(try await db.withTransaction { tx in
                try await tx.getValue(for: subspace.pack(Tuple(Int64(11), Int64(-1))))
            })
            #expect(raw == [0x33] + version.bytes)
        }
    }

    @Test("with a version cache, an incomplete version is readable in the saving transaction")
    func incompleteVersionWithCache() async throws {
        try await withSubspace { db, subspace in
            let key = Tuple(Int64(12))
            let other = Tuple(Int64(13))
            let tx = try db.createTransaction()
            let cache = InMemoryVersionMutationCache()
            try SplitHelper.saveWithSplit(
                tx, subspace: subspace, key: key, serialized: bytes(20), version: .incomplete(localVersion: 3),
                versionCache: cache)
            try SplitHelper.saveWithSplit(
                tx, subspace: subspace, key: other, serialized: bytes(20), version: .incomplete(localVersion: 4),
                versionCache: cache)
            let loaded = try #require(try await SplitHelper.loadWithSplit(
                tx, subspace: subspace, key: key, versionCache: cache))
            #expect(loaded.version == .incomplete(localVersion: 3))
            #expect(loaded.keyCount == 2)
            let scanned = try await SplitHelper.scanRecords(tx, subspace: subspace, versionCache: cache).collect()
            #expect(scanned.map(\.version) == [.incomplete(localVersion: 3), .incomplete(localVersion: 4)])

            // Deleting drops the pending mutation (the caller also drops the local version).
            let versionKey = subspace.pack(Tuple(Int64(13), Int64(-1)))
            try SplitHelper.deleteSplit(tx, subspace: subspace, key: other, versionCache: cache)
            cache.removeLocalVersion(key: versionKey)

            cache.applyVersionMutations(to: tx)
            _ = try await tx.commit()

            let after = try #require(try await load(db, subspace, key))
            #expect(after.version?.isComplete == true)
            #expect(after.version?.localVersion == 3)
            #expect(try await suffixes(db, subspace, other) == [])
        }
    }

    @Test("unsplitter reassembles a mixed range forward and reverse, with continuations")
    func unsplitter() async throws {
        try await withSubspace { db, subspace in
            let v1 = FDBRecordVersion(bytes: [0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1])
            let v3 = FDBRecordVersion(bytes: [0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 3])
            let records: [(Tuple, FDB.Bytes, FDBRecordVersion?)] = [
                (Tuple(Int64(1)), bytes(10, seed: 1), v1),           // unsplit + version
                (Tuple(Int64(2)), bytes(210_000, seed: 2), nil),     // split, no version
                (Tuple(Int64(3)), bytes(120_000, seed: 3), v3),      // split + version
                (Tuple(Int64(4)), bytes(30, seed: 4), nil),          // unsplit, no version
            ]
            for (key, data, version) in records {
                _ = try await save(db, subspace, key, data, version: version)
            }

            for reverse in [false, true] {
                let expected = reverse ? Array(records.reversed()) : records
                let results = try await db.withTransaction { tx in
                    var out: [SplitHelper.KeyValueUnsplitter<FDB.AsyncKVSequence>.Result] = []
                    for try await r in SplitHelper.scanRecords(tx, subspace: subspace, reverse: reverse) {
                        out.append(r)
                    }
                    return out.map { ($0.record, $0.continuation) }
                }
                #expect(results.map(\.0.primaryKey) == expected.map(\.0))
                #expect(results.map(\.0.rawRecord) == expected.map(\.1))
                #expect(results.map(\.0.version) == expected.map(\.2))
                #expect(results.map(\.0.isSplit) == expected.map { $0.1.count > SplitHelper.splitRecordSize })
                #expect(results.map(\.0.keyCount) == [2, 3, 3, 1].reversedIf(reverse))

                // Resume from each record boundary: the remainder must match exactly.
                for (i, (_, continuation)) in results.enumerated() {
                    let rest = try await db.withTransaction { tx in
                        try await SplitHelper.scanRecords(
                            tx, subspace: subspace, continuation: continuation, reverse: reverse
                        ).collect()
                    }
                    #expect(rest.map(\.primaryKey) == expected.dropFirst(i + 1).map(\.0))
                    #expect(rest.map(\.rawRecord) == expected.dropFirst(i + 1).map(\.1))
                    #expect(rest.map(\.version) == expected.dropFirst(i + 1).map(\.2))
                }
            }

            // Continuations are the last key consumed relative to the records subspace (Java's
            // KeyValueCursor format): forward ends on the last data key; reverse on the version.
            let forwardFirst = try await db.withTransaction { tx in
                var it = SplitHelper.scanRecords(tx, subspace: subspace).makeAsyncIterator()
                return try await it.next()!.continuation
            }
            #expect(forwardFirst == [0x15, 0x01, 0x14])
            let reverseThird = try await db.withTransaction { tx in
                var it = SplitHelper.scanRecords(tx, subspace: subspace, reverse: true).makeAsyncIterator()
                _ = try await it.next()
                return try await it.next()!.continuation
            }
            #expect(reverseThird == [0x15, 0x03, 0x13, 0xFE])
        }
    }

    @Test("unsplitter rejects a record missing its first chunk")
    func unsplitterMissingStart() async throws {
        try await withSubspace { db, subspace in
            _ = try await save(db, subspace, Tuple(Int64(1)), bytes(250_000))
            try await db.withTransaction { tx in
                tx.clear(key: subspace.pack(Tuple(Int64(1), Int64(1))))
            }
            for reverse in [false, true] {
                await #expect(throws: SplitHelperError.self) {
                    try await db.withTransaction { tx in
                        _ = try await SplitHelper.scanRecords(tx, subspace: subspace, reverse: reverse).collect()
                    }
                }
            }
            await #expect(throws: SplitHelperError.self) {
                _ = try await load(db, subspace, Tuple(Int64(1)))
            }
        }
    }

    @Test("exact bytes written for a known unsplit and split record")
    func exactBytes() async throws {
        try await withSubspace { db, subspace in
            let p = subspace.prefix
            // Unsplit record, pk (42), with a complete version.
            let version = FDBRecordVersion(bytes: [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x01, 0x02, 0x03, 0x04, 0x05, 0x00, 0x07])
            _ = try await save(db, subspace, Tuple(Int64(42)), [0xDE, 0xAD], version: version)
            // Split record, pk ("k", -3).
            let big = bytes(100_001, seed: 9)
            _ = try await save(db, subspace, Tuple("k", Int64(-3)), big)

            let kvs = try await allKeyValues(db, subspace)
            let expected: [(FDB.Bytes, FDB.Bytes)] = [
                // "k" = 0x02 'k' 0x00; -3 = 0x13 0xFC. (Strings sort before ints.)
                (p + [0x02, 0x6B, 0x00, 0x13, 0xFC, 0x15, 0x01], Array(big[0..<100_000])),
                (p + [0x02, 0x6B, 0x00, 0x13, 0xFC, 0x15, 0x02], [big[100_000]]),
                // Int 42 = 0x15 0x2A; suffix -1 = 0x13 0xFE; suffix 0 = 0x14; suffix 1 = 0x15 0x01.
                (p + [0x15, 0x2A, 0x13, 0xFE],
                 [0x33, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x01, 0x02, 0x03, 0x04, 0x05, 0x00, 0x07]),
                (p + [0x15, 0x2A, 0x14], [0xDE, 0xAD]),
            ]
            #expect(kvs.count == expected.count)
            for (actual, want) in zip(kvs, expected) {
                #expect(actual.0 == want.0)
                #expect(actual.1 == want.1)
            }

            // The value passed to SET_VERSIONSTAMPED_VALUE for an incomplete version:
            // 0x33, ten 0xFF placeholder bytes, the local version, then little-endian offset 1.
            #expect(try SplitHelper.packVersion(.incomplete(localVersion: 0x0102))
                == [0x33] + FDB.Bytes(repeating: 0xFF, count: 10) + [0x01, 0x02, 0x01, 0x00, 0x00, 0x00])
        }
    }

    @Test("validation errors match Java")
    func validation() async throws {
        try await withSubspace { db, subspace in
            try await db.withTransaction { tx in
                #expect(throws: SplitHelperError.recordTooLong(valueSize: 100_001)) {
                    try SplitHelper.saveWithSplit(
                        tx, subspace: subspace, key: Tuple(Int64(1)), serialized: self.bytes(100_001),
                        version: nil, splitLongRecords: false)
                }
                #expect(throws: SplitHelperError.cannotIncludeVersionInOldUnsplitFormat) {
                    try SplitHelper.saveWithSplit(
                        tx, subspace: subspace, key: Tuple(Int64(1)), serialized: [1], version: .incomplete(localVersion: 0),
                        splitLongRecords: false, omitUnsplitSuffix: true)
                }
                #expect(throws: SplitHelperError.versionstampInKeyAndValue) {
                    try SplitHelper.saveWithSplit(
                        tx, subspace: subspace, key: Tuple(Versionstamp.incomplete(1)), serialized: [1],
                        version: .incomplete(localVersion: 0))
                }
                #expect(throws: SplitHelperError.invalidSplitNumber("-2")) {
                    try SplitHelper.validatePrimaryKeySuffixNumber(Tuple(Int64(1), Int64(-2)))
                }
            }
        }
    }
}

private extension Array {
    func reversedIf(_ condition: Bool) -> [Element] { condition ? reversed() : self }
}
#endif
