/*
 * RankedSetTests.swift
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

/// Ports of the Java fdb-extensions `RankedSetTest`, plus pinned on-disk bytes and hash vectors
/// that lock in compatibility with Java's `RankedSet`.
@Suite("RankedSet (integration)", .serialized)
struct RankedSetTests {
    // MARK: - Helpers

    /// Runs `body` with an initialized ranked set in a fresh, unique subspace, clearing it after.
    private func withRankedSet(
        config: RankedSet.Config = .default,
        _ body: (_ db: FDBDatabase, _ rs: RankedSet) async throws -> Void
    ) async throws {
        try await FDBBootstrap.shared.ensureInitialized()
        let db = try FDBClient.openDatabase()
        let subspace = Subspace(Tuple("fdbrl-test", "rankedset", UUID().uuidString))
        let rs = RankedSet(subspace: subspace, config: config)
        try await db.withTransaction { try await rs.`init`($0) }
        let cleanup = {
            try await db.withTransaction { tr async throws in
                let range = subspace.range
                tr.clearRange(beginKey: range.begin, endKey: range.end)
            }
        }
        do {
            try await body(db, rs)
        } catch {
            try? await cleanup()
            throw error
        }
        try await cleanup()
    }

    private static func key(_ value: Int) -> FDB.Bytes { Tuple(value).encode() }

    private static func hex(_ bytes: FDB.Bytes) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func isConflict(_ error: Error) -> Bool {
        (error as? FDBError)?.code == 1020 // not_committed
    }

    // MARK: - Hash functions and config (no cluster needed)

    @Test("hash functions match Java/Guava reference values")
    func hashVectors() {
        // java.util.Arrays.hashCode(byte[]) uses signed bytes.
        #expect(RankedSet.HashFunction.jdkArrayHash.hash([]) == 1)
        #expect(RankedSet.HashFunction.jdkArrayHash.hash([1, 2, 3]) == 30817)
        #expect(RankedSet.HashFunction.jdkArrayHash.hash([0xFF]) == 30)
        #expect(RankedSet.HashFunction.jdkArrayHash.hash(Self.key(180)) == 0x600)
        // java.util.zip.CRC32 of "123456789" is 0xCBF43926, cast to int.
        #expect(RankedSet.HashFunction.crcHash.hash(Array("123456789".utf8)) == Int32(bitPattern: 0xCBF4_3926))
        #expect(RankedSet.HashFunction.crcHash.hash([]) == 0)
        // Guava murmur3_32_fixed (seed 0).
        #expect(RankedSet.HashFunction.murmur3.hash([]) == 0)
        #expect(RankedSet.HashFunction.murmur3.hash(Array("hello".utf8)) == 0x248B_FA47)
        #expect(RankedSet.HashFunction.murmur3.hash(Array("The quick brown fox jumps over the lazy dog".utf8))
            == 0x2E4F_F723)
        #expect(RankedSet.levelFanValues == [0, 0xF, 0xFF, 0xFFF, 0xFFFF, 0xFFFFF, 0xFFFFFF, 0xFFFFFFF])
    }

    @Test("Config defaults and index options mirror RankedSetIndexHelper.getConfig")
    func configFromOptions() throws {
        let defaults = try RankedSet.Config(indexOptions: [:])
        #expect(defaults.nlevels == 6)
        #expect(defaults.countDuplicates == false)
        #expect(defaults.hashFunction.name == "JDK")
        #expect(RankedSet.Config.default.nlevels == 6)

        let custom = try RankedSet.Config(indexOptions: [
            "rankHashFunction": "CRC", "rankNLevels": "4", "rankCountDuplicates": "TRUE",
        ])
        #expect(custom.hashFunction.name == "CRC")
        #expect(custom.nlevels == 4)
        #expect(custom.countDuplicates)
        #expect(try RankedSet.Config(indexOptions: ["rankCountDuplicates": "yes"]).countDuplicates == false)
        #expect(throws: RankedSetError.self) { try RankedSet.Config(indexOptions: ["rankNLevels": "9"]) }
        #expect(throws: RankedSetError.self) { try RankedSet.Config(indexOptions: ["rankNLevels": "x"]) }
        #expect(throws: RankedSetError.self) { try RankedSet.Config(indexOptions: ["rankHashFunction": "SHA"]) }
    }

    // MARK: - On-disk format

    @Test("on-disk keys and values are byte-identical to Java's RankedSet")
    func exactBytes() async throws {
        try await withRankedSet { db, rs in
            // JDK hashes: Tuple(4) -> 0x650 (level 1), Tuple(180) -> 0x600 (level 2),
            // Tuple(1) and Tuple(200) stay on level 0. Insert out of order.
            try await db.withTransaction { tr async throws in
                for value in [200, 4, 1, 180] {
                    #expect(try await rs.add(tr, key: Self.key(value)))
                }
            }
            let rows = try await db.withTransaction { tr async throws in
                var rows: [String] = []
                let range = rs.subspace.range
                for try await (k, v) in tr.getRange(beginKey: range.begin, endKey: range.end) {
                    rows.append(Self.hex(Array(k.dropFirst(rs.subspace.prefix.count))) + " " + Self.hex(v))
                }
                return rows
            }
            // (level, bytes) tuple suffix -> 8-byte little-endian count.
            #expect(rows == [
                "140100 0000000000000000",       // (0, b"")
                "1401150100 0100000000000000",   // (0, Tuple(1))
                "1401150400 0100000000000000",   // (0, Tuple(4))
                "140115b400 0100000000000000",   // (0, Tuple(180))
                "140115c800 0100000000000000",   // (0, Tuple(200))
                "15010100 0100000000000000",     // (1, b"")       covers 1
                "150101150400 0100000000000000", // (1, Tuple(4))  covers 4
                "15010115b400 0200000000000000", // (1, Tuple(180)) covers 180, 200
                "15020100 0200000000000000",     // (2, b"")       covers 1, 4
                "15020115b400 0200000000000000", // (2, Tuple(180))
                "15030100 0400000000000000",
                "15040100 0400000000000000",
                "15050100 0400000000000000",
            ])
        }
    }

    @Test("init writes zero sentinels on every level; initNeeded reflects them")
    func initSentinels() async throws {
        try await FDBBootstrap.shared.ensureInitialized()
        let db = try FDBClient.openDatabase()
        let subspace = Subspace(Tuple("fdbrl-test", "rankedset", UUID().uuidString))
        let rs = RankedSet(subspace: subspace, config: RankedSet.Config(nlevels: 3))
        #expect(try await db.withTransaction { try await rs.initNeeded($0, snapshot: true) })
        try await db.withTransaction { try await rs.`init`($0) }
        #expect(try await db.withTransaction { try await rs.initNeeded($0) } == false)
        let rows = try await db.withTransaction { tr async throws in
            var rows: [String] = []
            for try await (k, v) in tr.getRange(beginKey: subspace.range.begin, endKey: subspace.range.end) {
                rows.append(Self.hex(Array(k.dropFirst(subspace.prefix.count))) + " " + Self.hex(v))
            }
            let range = subspace.range
            tr.clearRange(beginKey: range.begin, endKey: range.end)
            return rows
        }
        #expect(rows == ["140100 0000000000000000", "15010100 0000000000000000", "15020100 0000000000000000"])
    }

    // MARK: - Java RankedSetTest ports

    @Test("basic add/rank/getNth/remove (Java basic, basicCrc, basicChange, basicRandom)",
          arguments: [("JDK", "JDK"), ("CRC", "CRC"), ("JDK", "CRC"), ("RANDOM", "RANDOM"), ("MURMUR3", "MURMUR3")])
    func basic(first: String, second: String) async throws {
        let keys = (0 ..< 100).map { Tuple(String(UnicodeScalar(UInt8($0)))).encode() }
        try await withRankedSet { db, base in
            try await db.withTransaction { tr async throws in
                var rs = RankedSet(subspace: base.subspace, config: .init(hashFunction: try .named(first)))
                for k in keys {
                    #expect(try await rs.add(tr, key: k))
                }
                #expect(try await rs.add(tr, key: keys[10]) == false)
                rs = RankedSet(subspace: base.subspace, config: .init(hashFunction: try .named(second)))
                #expect(try await rs.size(tr) == 100)
                for (i, k) in keys.enumerated() {
                    #expect(try await rs.rank(tr, key: k) == Int64(i))
                }
                for (i, k) in keys.enumerated() {
                    #expect(try await rs.getNth(tr, rank: Int64(i)) == k)
                }
                #expect(try await rs.getNth(tr, rank: 100) == nil)
                #expect(try await rs.getNth(tr, rank: -1) == nil)
                #expect(try await rs.checkConsistency(tr).isConsistent)
                for k in keys {
                    #expect(try await rs.remove(tr, key: k))
                }
                #expect(try await rs.remove(tr, key: keys[20]) == false)
                #expect(try await rs.size(tr) == 0)
                #expect(try await rs.checkConsistency(tr).isConsistent)
            }
        }
    }

    @Test("counted duplicates (Java duplicates)")
    func duplicates() async throws {
        let keys = (0 ..< 10).map { Self.key($0) }
        try await withRankedSet(config: .init(countDuplicates: true)) { db, rs in
            try await db.withTransaction { tr async throws in
                for (i, k) in keys.enumerated() {
                    for _ in 0 ... i {
                        #expect(try await rs.add(tr, key: k))
                    }
                }
                #expect(try await rs.size(tr) == 10 * 11 / 2)
                for (i, k) in keys.enumerated() {
                    #expect(try await rs.count(tr, key: k) == Int64(i + 1))
                }
                var n: Int64 = 0
                for (i, k) in keys.enumerated() {
                    #expect(try await rs.rank(tr, key: k) == n)
                    n += Int64(i + 1)
                }
                n = 0
                for (i, k) in keys.enumerated() {
                    for _ in 0 ... i {
                        #expect(try await rs.getNth(tr, rank: n) == k)
                        n += 1
                    }
                }
                #expect(try await rs.checkConsistency(tr).isConsistent)
                for (i, k) in keys.enumerated() {
                    for j in 1 ... i + 2 {
                        #expect(try await rs.remove(tr, key: k) == (j <= i + 1))
                    }
                }
                #expect(try await rs.size(tr) == 0)
            }
        }
    }

    @Test("rank with nullIfMissing=false (Java rankAsThoughPresent)")
    func rankAsThoughPresent() async throws {
        try await withRankedSet { db, rs in
            try await db.withTransaction { tr async throws in
                for i in stride(from: 5, to: 100, by: 10) {
                    try await rs.add(tr, key: Self.key(i))
                }
                for i in 0 ..< 100 {
                    #expect(try await rs.rank(tr, key: Self.key(i), nullIfMissing: false) == Int64((i + 4) / 10))
                    #expect(try await rs.rank(tr, key: Self.key(i)) == (i % 10 == 5 ? Int64(i / 10) : nil))
                }
            }
        }
    }

    @Test("empty keys are rejected")
    func emptyKey() async throws {
        try await withRankedSet { db, rs in
            try await db.withTransaction { tr async throws in
                await #expect(throws: RankedSetError.emptyKey) { try await rs.add(tr, key: []) }
                await #expect(throws: RankedSetError.emptyKey) { try await rs.remove(tr, key: []) }
                await #expect(throws: RankedSetError.emptyKey) { try await rs.contains(tr, key: []) }
                await #expect(throws: RankedSetError.emptyKey) { try await rs.rank(tr, key: []) }
            }
        }
    }

    @Test("clear empties the set and restores the sentinels")
    func clear() async throws {
        try await withRankedSet { db, rs in
            try await db.withTransaction { tr async throws in
                for i in 0 ..< 50 { try await rs.add(tr, key: Self.key(i)) }
                try await rs.clear(tr)
                #expect(try await rs.size(tr) == 0)
                #expect(try await rs.initNeeded(tr) == false)
                #expect(try await rs.getNth(tr, rank: 0) == nil)
                try await rs.add(tr, key: Self.key(7))
                #expect(try await rs.rank(tr, key: Self.key(7)) == 0)
            }
        }
    }

    @Test("concurrent adds of level-0-only keys do not conflict (Java concurrentAdd)")
    func concurrentAdd() async throws {
        try await withRankedSet { db, rs in
            // Tuple(20) goes onto level 1; Tuple(30) and Tuple(40) do not.
            _ = try await db.withTransaction { try await rs.add($0, key: Self.key(20)) }
            let tr1 = try db.createTransaction()
            let tr2 = try db.createTransaction()
            try await rs.add(tr1, key: Self.key(30))
            try await rs.add(tr2, key: Self.key(40))
            _ = try await tr1.commit()
            _ = try await tr2.commit()
            try await db.withTransaction { tr async throws in
                #expect(try await rs.rank(tr, key: Self.key(20)) == 0)
                #expect(try await rs.rank(tr, key: Self.key(30)) == 1)
                #expect(try await rs.rank(tr, key: Self.key(40)) == 2)
                #expect(try await rs.checkConsistency(tr).isConsistent)
            }
        }
    }

    @Test("an add racing a remove of its predecessor conflicts (Java concurrentRemove)")
    func concurrentRemove() async throws {
        try await withRankedSet { db, rs in
            // Create a higher-level entry.
            _ = try await db.withTransaction { try await rs.add($0, key: Self.key(20)) }
            let tr1 = try db.createTransaction()
            let tr2 = try db.createTransaction()
            // Removes from all levels.
            try await rs.remove(tr1, key: Self.key(20))
            // Increments the 20 entry on the upper levels, which tr1 removes.
            try await rs.add(tr2, key: Self.key(30))
            _ = try await tr1.commit()
            var conflicted = false
            do {
                _ = try await tr2.commit()
            } catch {
                conflicted = Self.isConflict(error)
            }
            #expect(conflicted)
            _ = try await db.withTransaction { try await rs.add($0, key: Self.key(30)) }
            try await db.withTransaction { tr async throws in
                // Had tr2 committed it would have incremented 20 on level 1, so 20 would be returned.
                #expect(try await rs.getNth(tr, rank: 0) == Self.key(30))
                #expect(try await rs.checkConsistency(tr).isConsistent)
            }
        }
    }

    @Test("concurrent adds that insert between a predecessor and the key conflict")
    func concurrentInsertConflict() async throws {
        try await withRankedSet { db, rs in
            // Both 4 and 20 go onto level 1; adding each reads [prev + 0x00, key) on level 1
            // and writes its own level-1 key, so the second commit must conflict.
            let tr1 = try db.createTransaction()
            let tr2 = try db.createTransaction()
            try await rs.add(tr1, key: Self.key(20))
            try await rs.add(tr2, key: Self.key(4))
            _ = try await tr1.commit()
            var conflicted = false
            do {
                _ = try await tr2.commit()
            } catch {
                conflicted = Self.isConflict(error)
            }
            #expect(conflicted)
        }
    }

    // MARK: - Randomized (Java randomSingleThread / randomFiveThreads[WithDuplicates])

    /// Seeded generator so failures reproduce.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E4B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Sorted multiset of single-byte keys used as the reference model.
    private struct Model: Sendable {
        var counts = [Int](repeating: 0, count: 256)
        let countDuplicates: Bool
        var size: Int64 { Int64(counts.reduce(0, +)) }
        func rank(_ b: UInt8) -> Int64 { Int64(counts[..<Int(b)].reduce(0, +)) }
        /// Java's `rank(key, nullIfMissing: false)`: an absent key ranks one past its
        /// predecessor's rank (not past all of its duplicates), or 0 below every key.
        func rankAsThoughPresent(_ b: UInt8) -> Int64 {
            if counts[Int(b)] > 0 { return rank(b) }
            guard let prev = (0 ..< Int(b)).last(where: { counts[$0] > 0 }) else { return 0 }
            return rank(UInt8(prev)) + 1
        }
        func nth(_ r: Int64) -> FDB.Bytes? {
            var remaining = r
            for (b, c) in counts.enumerated() where c > 0 {
                if remaining < c { return [UInt8(b)] }
                remaining -= Int64(c)
            }
            return nil
        }
        mutating func add(_ b: UInt8) -> Bool {
            if counts[Int(b)] > 0 && !countDuplicates { return false }
            counts[Int(b)] += 1
            return true
        }
        mutating func remove(_ b: UInt8) -> Bool {
            guard counts[Int(b)] > 0 else { return false }
            counts[Int(b)] -= 1
            return true
        }
    }

    @Test("random ops checked against a sorted model", arguments: [false, true])
    func randomAgainstModel(countDuplicates: Bool) async throws {
        var rng = SplitMix64(state: countDuplicates ? 42 : 7)
        try await withRankedSet(config: .init(countDuplicates: countDuplicates)) { db, rs in
            var model = Model(countDuplicates: countDuplicates)
            for step in 0 ..< 600 {
                let op = Int.random(in: 0 ..< 100, using: &rng)
                let byte = UInt8.random(in: 0 ... 255, using: &rng)
                let probe = UInt8.random(in: 0 ... 255, using: &rng)
                let nthRank = Int64.random(in: 0 ... 300, using: &rng)
                let before = model
                model = try await db.withTransaction { tr async throws in
                    var m = before
                    let k: FDB.Bytes = [byte]
                    switch op {
                    case 0 ..< 55:
                        let expected = m.add(byte)
                        #expect(try await rs.add(tr, key: k) == expected)
                    case 55 ..< 95:
                        let expected = m.remove(byte)
                        #expect(try await rs.remove(tr, key: k) == expected)
                    case 95 ..< 97:
                        try await rs.clear(tr)
                        m = Model(countDuplicates: countDuplicates)
                    default:
                        break
                    }
                    #expect(try await rs.size(tr) == m.size)
                    let p: FDB.Bytes = [probe]
                    let present = m.counts[Int(probe)] > 0
                    #expect(try await rs.contains(tr, key: p) == present)
                    #expect(try await rs.count(tr, key: p) == Int64(m.counts[Int(probe)]))
                    #expect(try await rs.rank(tr, key: p) == (present ? m.rank(probe) : nil))
                    #expect(try await rs.rank(tr, key: p, nullIfMissing: false) == m.rankAsThoughPresent(probe))
                    #expect(try await rs.getNth(tr, rank: nthRank) == m.nth(nthRank))
                    if step % 25 == 0 {
                        let consistency = try await rs.checkConsistency(tr)
                        #expect(consistency.isConsistent, "\(consistency)")
                        for r in 0 ..< m.size {
                            #expect(try await rs.getNth(tr, rank: r) == m.nth(r))
                        }
                    }
                    return m
                }
            }
            #expect(try await db.withTransaction { try await rs.checkConsistency($0).isConsistent })
        }
    }

    @Test("concurrent random ops stay consistent", arguments: [false, true])
    func randomConcurrent(countDuplicates: Bool) async throws {
        try await withRankedSet(config: .init(countDuplicates: countDuplicates)) { db, rs in
            try await withThrowingTaskGroup(of: Void.self) { group in
                for worker in 0 ..< 5 {
                    group.addTask {
                        var rng = SplitMix64(state: UInt64(worker) &* 1_000_003 &+ (countDuplicates ? 1 : 0))
                        for _ in 0 ..< 150 {
                            let op = Int.random(in: 0 ..< 6, using: &rng)
                            let key: FDB.Bytes = [UInt8.random(in: 0 ... 255, using: &rng)]
                            let pick = UInt64.random(in: 0 ... UInt64.max, using: &rng)
                            try await db.withTransaction { tr async throws in
                                switch op {
                                case 0:
                                    try await rs.add(tr, key: key)
                                case 1:
                                    let size1 = try await rs.size(tr)
                                    let wasPresent = try await rs.contains(tr, key: key)
                                    let didInsert = try await rs.add(tr, key: key)
                                    let size2 = try await rs.size(tr)
                                    if countDuplicates {
                                        #expect(didInsert)
                                        #expect(size2 == size1 + 1)
                                    } else {
                                        #expect(wasPresent != didInsert)
                                        #expect(size2 == size1 + (wasPresent ? 0 : 1))
                                    }
                                case 2:
                                    try await rs.remove(tr, key: key)
                                case 3:
                                    let size1 = try await rs.size(tr)
                                    let wasPresent = try await rs.contains(tr, key: key)
                                    let didErase = try await rs.remove(tr, key: key)
                                    let size2 = try await rs.size(tr)
                                    #expect(wasPresent == didErase)
                                    #expect(size2 == size1 - (wasPresent ? 1 : 0))
                                case 4:
                                    // Java clears 1 in 6; keep it rarer so the set builds up.
                                    if pick % 8 == 0 {
                                        try await rs.clear(tr)
                                        #expect(try await rs.size(tr) == 0)
                                    }
                                default:
                                    let size = try await rs.size(tr)
                                    if size > 0 {
                                        let r = Int64(pick % UInt64(size))
                                        let k = try #require(try await rs.getNth(tr, rank: r))
                                        let r2 = try #require(try await rs.rank(tr, key: k))
                                        let below = try await rs.getRange(tr, beginKey: [0x00], endKey: k)
                                        if countDuplicates {
                                            let d = try await rs.count(tr, key: k)
                                            var r3: Int64 = 0
                                            for pk in below { r3 += try await rs.count(tr, key: pk) }
                                            #expect(d > 0 && r >= r2 && r < r2 + d && r2 == r3)
                                        } else {
                                            #expect(r == r2 && r2 == Int64(below.count))
                                        }
                                    }
                                }
                                let consistency = try await rs.checkConsistency(tr)
                                #expect(consistency.isConsistent, "\(consistency)")
                            }
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
    }
}
#endif
