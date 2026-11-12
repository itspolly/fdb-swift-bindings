/*
 * RangeSetTests.swift
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

/// Ports of fdb-extensions' `RangeSetTest`, plus on-disk format checks pinning compatibility with
/// the Java `RangeSet`.
@Suite("RangeSet (integration)", .serialized)
struct RangeSetTests {
    typealias Range = RangeSet.Range

    private static let deadc0de: FDB.Bytes = [0xDE, 0xAD, 0xC0, 0xDE]
    private static let notCommitted: Int32 = 1020

    /// Fixture: a database and a range set in a unique subspace, cleared afterwards.
    struct Fixture {
        let db: FDBDatabase
        let subspace: Subspace
        let rs: RangeSet

        @discardableResult
        func run<T: Sendable>(_ body: (any TransactionProtocol) async throws -> T) async throws -> T {
            try await db.withTransaction(body)
        }

        /// All raw key-value pairs in the range set's subspace.
        func rawEntries() async throws -> [(FDB.Bytes, FDB.Bytes)] {
            try await run { tx in
                var out: [(FDB.Bytes, FDB.Bytes)] = []
                for try await kv in tx.getRange(beginKey: subspace.range.begin, endKey: subspace.range.end) {
                    out.append(kv)
                }
                return out
            }
        }

        /// Java `MultipleTransactions.create`: `n` transactions whose read versions all precede any
        /// of their commits, each with a write-conflict key so that read-only ones still get
        /// conflict-checked.
        func multi(_ n: Int) async throws -> [any TransactionProtocol] {
            var trs: [any TransactionProtocol] = []
            for _ in 0 ..< n {
                let tr = try db.createTransaction()
                _ = try await tr.getReadVersion()
                try tr.addConflictRange(beginKey: RangeSetTests.deadc0de, endKey: RangeSetTests.deadc0de + [0x00], type: .write)
                trs.append(tr)
            }
            return trs
        }

        /// Java `MultipleTransactions.commit`: commits in order; those in `expectedConflicts` must fail
        /// with `not_committed` and all others must succeed.
        func commit(_ trs: [any TransactionProtocol], expectedConflicts: Set<Int> = [],
                    sourceLocation: SourceLocation = #_sourceLocation) async throws {
            for (i, tr) in trs.enumerated() {
                do {
                    _ = try await tr.commit()
                    #expect(!expectedConflicts.contains(i), "transaction \(i) should not have committed",
                            sourceLocation: sourceLocation)
                } catch let error as FDBError {
                    #expect(expectedConflicts.contains(i), "transaction \(i) failed: \(error)",
                            sourceLocation: sourceLocation)
                    #expect(error.code == RangeSetTests.notCommitted, sourceLocation: sourceLocation)
                }
            }
        }
    }

    private func withRangeSet(_ body: (Fixture) async throws -> Void) async throws {
        try await FDBBootstrap.shared.ensureInitialized()
        let db = try FDBClient.openDatabase()
        let subspace = Subspace(Tuple("fdbrl-rangeset-test", UUID().uuidString))
        let fixture = Fixture(db: db, subspace: subspace, rs: RangeSet(subspace: subspace))
        let cleanup = {
            try await db.withTransaction { tx in
                tx.clearRange(beginKey: subspace.range.begin, endKey: subspace.range.end)
            }
        }
        do {
            try await body(fixture)
        } catch {
            try? await cleanup()
            throw error
        }
        try await cleanup()
    }

    private static func contains(_ ranges: [Range], _ key: FDB.Bytes) -> Bool {
        ranges.contains { !key.lexicographicallyPrecedes($0.begin) && key.lexicographicallyPrecedes($0.end) }
    }

    private static func disjoint(_ r1: Range, _ r2: Range) -> Bool {
        !r2.begin.lexicographicallyPrecedes(r1.end) || !r1.begin.lexicographicallyPrecedes(r2.end)
    }

    private static func createKeys() -> [FDB.Bytes] {
        (0x00 ..< 0xFF).flatMap { (i: Int) -> [FDB.Bytes] in
            let b = UInt8(i)
            return [[b], [b, 0x00], [b, 0x10], [b, 0xFF]]
        }
    }

    private static func eq(_ a: [Range], _ b: [Range]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.begin == $1.begin && $0.end == $1.end }
    }

    /// Checks `contains` for every key against `ranges`; returns how many keys are present.
    @discardableResult
    private func checkConsistent(_ f: Fixture, _ ranges: [Range], _ keys: [FDB.Bytes]) async throws -> Int {
        let rs = f.rs
        let actual = try await f.run { tx in
            try await withThrowingTaskGroup(of: (Int, Bool).self) { group in
                for (i, key) in keys.enumerated() {
                    group.addTask { (i, try await rs.contains(tx, key: key)) }
                }
                var out = [Bool](repeating: false, count: keys.count)
                for try await (i, contained) in group { out[i] = contained }
                return out
            }
        }
        var present = 0
        for (key, contained) in zip(keys, actual) {
            let expected = Self.contains(ranges, key)
            #expect(expected == contained, "key \(RangeSet.printable(key)) vs ranges \(ranges)")
            if expected { present += 1 }
        }
        return present
    }

    /// Every stored range is non-empty and they are sorted and non-overlapping.
    private func checkIncreasing(_ f: Fixture) async throws {
        var last: FDB.Bytes?
        for (k, v) in try await f.rawEntries() {
            guard let key = try f.subspace.unpack(k).first as? FDB.Bytes else {
                Issue.record("malformed key")
                return
            }
            #expect(key.lexicographicallyPrecedes(v))
            if let last { #expect(!key.lexicographicallyPrecedes(last)) }
            last = v
        }
    }

    // MARK: - On-disk format

    @Test("on-disk format matches Java: key = subspace.pack(begin bytes), value = raw end bytes")
    func onDiskFormat() async throws {
        try await withRangeSet { f in
            let p = f.subspace.prefix
            // A begin containing \x00 exercises tuple byte-string escaping.
            try await f.run { try await f.rs.insertRange($0, begin: [0x10, 0x00], end: [0x20]) }
            var entries = try await f.rawEntries()
            #expect(entries.count == 1)
            #expect(entries[0].0 == p + [0x01, 0x10, 0x00, 0xFF, 0x00])
            #expect(entries[0].1 == [0x20])

            // Gap filling (non-requireEmpty) writes one entry per gap and does not coalesce.
            try await f.run { try await f.rs.insertRange($0, begin: [0x05], end: [0x30]) }
            entries = try await f.rawEntries()
            #expect(entries.map(\.0) == [p + [0x01, 0x05, 0x00], p + [0x01, 0x10, 0x00, 0xFF, 0x00], p + [0x01, 0x20, 0x00]])
            #expect(entries.map(\.1) == [[0x10, 0x00], [0x20], [0x30]])

            // requireEmpty abutting the previous range's end extends that entry in place.
            let wrote = try await f.run { try await f.rs.insertRange($0, begin: [0x30], end: [0x40], requireEmpty: true) }
            #expect(wrote)
            entries = try await f.rawEntries()
            #expect(entries.count == 3)
            #expect(entries[2].0 == p + [0x01, 0x20, 0x00])
            #expect(entries[2].1 == [0x40])

            // nil bounds are FIRST_KEY (\x00) / FINAL_KEY (\xff).
            try await f.run { f.rs.clear($0) }
            try await f.run { try await f.rs.insertRange($0, begin: nil, end: nil) }
            entries = try await f.rawEntries()
            #expect(entries.count == 1)
            #expect(entries[0].0 == p + [0x01, 0x00, 0xFF, 0x00])
            #expect(entries[0].1 == [0xFF])
            #expect(try await f.run { try await f.rs.rep($0) } == "\\x00 -> \\xff\n")
        }
    }

    // MARK: - Basic operations

    @Test("clear and isEmpty")
    func clear() async throws {
        try await withRangeSet { f in
            try await f.run { $0.setValue([0xC0, 0xDE], for: f.subspace.pack([0xDE, 0xAD] as FDB.Bytes)) }
            #expect(try await f.rawEntries().count == 1)
            #expect(try await f.run { try await f.rs.isEmpty($0) } == false)
            try await f.run { f.rs.clear($0) }
            #expect(try await f.rawEntries().isEmpty)
            #expect(try await f.run { try await f.rs.isEmpty($0) } == true)
        }
    }

    @Test("contains reads ranges written in the Java format")
    func contains() async throws {
        try await withRangeSet { f in
            try await f.run { tx in
                tx.setValue([0x66], for: f.subspace.pack([0x10] as FDB.Bytes))
                tx.setValue([0x88], for: f.subspace.pack([0x77] as FDB.Bytes))
                tx.setValue([0x99], for: f.subspace.pack([0x88] as FDB.Bytes))
                tx.setValue([0x99, 0x00], for: f.subspace.pack([0x99] as FDB.Bytes))
            }
            let cases: [(FDB.Bytes, Bool)] = [
                ([0x05], false),
                ([0x10], true), ([0x10, 0x66], true), ([0x55], true),
                ([0x66], false), ([0x66, 0x00], false), ([0x70, 0x00], false),
                ([0x77], true), ([0x77, 0x00], true), ([0x79, 0x00], true), ([0x88], true), ([0x99], true),
                ([0x99, 0x00], false), ([0xAA], false),
            ]
            for (key, expected) in cases {
                let snap = try await f.run { try await f.rs.contains($0, key: key, snapshot: true) }
                let ser = try await f.run { try await f.rs.contains($0, key: key) }
                #expect(snap == expected, "\(RangeSet.printable(key))")
                #expect(ser == expected, "\(RangeSet.printable(key))")
            }
        }
    }

    @Test("invalid keys and ranges are rejected")
    func invalidArguments() async throws {
        try await withRangeSet { f in
            for key: FDB.Bytes in [[], [0xFF], [0xFF, 0x00]] {
                await #expect(throws: RangeSetError.keyOutOfRange(key)) {
                    try await f.run { try await f.rs.contains($0, key: key) }
                }
            }
            await #expect(throws: RangeSetError.keyOutOfRange([])) {
                try await f.run { try await f.rs.insertRange($0, begin: [], end: [0x00]) }
            }
            await #expect(throws: RangeSetError.invertedRange(begin: [0x15], end: [0x05])) {
                try await f.run { try await f.rs.insertRange($0, begin: [0x15], end: [0x05]) }
            }
            await #expect(throws: RangeSetError.keyOutOfRange([0xFF, 0x10])) {
                try await f.run { try await f.rs.insertRange($0, begin: [0xFF, 0x10], end: [0xFF, 0x15]) }
            }
            // An empty range is a no-op.
            let wroteEmpty = try await f.run { try await f.rs.insertRange($0, begin: [0x05], end: [0x05]) }
            #expect(wroteEmpty == false)
        }
    }

    @Test("isFirstKey / isFinalKey")
    func isFirstOrFinalKey() {
        #expect(RangeSet.isFirstKey([0x00]))
        #expect(!RangeSet.isFirstKey([0xFF]))
        #expect(!RangeSet.isFirstKey([0x77]))
        #expect(!RangeSet.isFinalKey([0x00]))
        #expect(RangeSet.isFinalKey([0xFF]))
        #expect(!RangeSet.isFinalKey([0x77]))
        #expect(RangeSet.nullIfFirst([0x00]) == nil)
        #expect(RangeSet.nullIfFinal([0xFF]) == nil)
        #expect(RangeSet.nullIfFinal([0x77]) == [0x77])
    }

    @Test("insert: overlapping inserts, with and without requireEmpty")
    func insert() async throws {
        try await withRangeSet { f in
            let keys = Self.createKeys()
            let rangeSource: [Range] = [
                ([0x10], [0x11]),                   // an initial range (startsWith 0x10)
                ([0x30], [0x31]),                   // a second disjoint range
                ([0x20], [0x21]),                   // a third between them
                ([0x05], [0x10, 0x10]),             // overlapping the first
                ([0x2F], [0x30, 0x10]),             // overlapping the third
                ([0x30, 0x10], [0x40]),             // overlapping the third
                ([0x05, 0x10], [0x12]),             // just a little at the end
                ([0x20, 0x14], [0x30, 0x00]),       // between 0x20 and 0x30
                ([0x03], [0x42]),                   // over everything
                ([0x10, 0x11], [0x41]),             // entirely within
                ([0x50], [0x50, 0x00]),             // exactly one key
            ]
            for pass in 0 ..< 2 {
                var ranges: [Range] = []
                var last = 0
                for range in rangeSource {
                    let empty = ranges.allSatisfy { Self.disjoint(range, $0) }
                    var changes = try await f.run { try await f.rs.insertRange($0, range, requireEmpty: pass == 1) }
                    if pass == 1 {
                        #expect(empty == changes)
                        if !empty {
                            changes = try await f.run { try await f.rs.insertRange($0, range) }
                        }
                    }
                    ranges.append(range)
                    try await checkIncreasing(f)
                    let present = try await checkConsistent(f, ranges, keys)
                    #expect((present != last) == changes)
                    last = present
                }
                try await f.run { f.rs.clear($0) }
            }
        }
    }

    @Test("missingRanges, with bounds and limits")
    func missingRanges() async throws {
        try await withRangeSet { f in
            let initial = try await f.run { try await f.rs.missingRanges($0) }
            #expect(Self.eq(initial, [([0x00], [0xFF])]))

            let toAdd: [Range] = [
                ([0x10], [0x20]), ([0x20], [0x20, 0x00]), ([0x30], [0x40]), ([0x40, 0x00], [0x50]),
                ([0x60], [0x6A]), ([0x62], [0x70]), ([0x71], [0x72]), ([0x72], [0x7F]),
            ]
            let expected: [Range] = [
                ([0x00], [0x10]), ([0x20, 0x00], [0x30]), ([0x40], [0x40, 0x00]),
                ([0x50], [0x60]), ([0x70], [0x71]), ([0x7F], [0xFF]),
            ]
            let added = try await f.run { tx in
                var out: [Bool] = []
                for r in toAdd { out.append(try await f.rs.insertRange(tx, r)) }
                return out
            }
            #expect(added.allSatisfy { $0 })

            #expect(Self.eq(try await f.run { try await f.rs.missingRanges($0) }, expected))
            #expect(Self.eq(try await f.run { try await f.rs.missingRanges($0, begin: [0x00], end: [0x60]) },
                            Array(expected.prefix(4))))
            #expect(Self.eq(try await f.run { try await f.rs.missingRanges($0, ([0x00], [0x60])) },
                            Array(expected.prefix(4))))
            #expect(Self.eq(try await f.run { try await f.rs.missingRanges($0, begin: [0x00], end: [0x60], limit: 2) },
                            Array(expected.prefix(2))))
            #expect(Self.eq(try await f.run { try await f.rs.missingRanges($0, begin: [0x00], end: [0x60], limit: 1) },
                            Array(expected.prefix(1))))
            // Begin inside an existing range starts the first gap at that range's end.
            #expect(Self.eq(try await f.run { try await f.rs.missingRanges($0, begin: [0x15], end: [0x35]) },
                            [([0x20, 0x00], [0x30])]))
            // The streaming variant yields the same gaps lazily.
            let tx = try f.db.createTransaction()
            var streamed: [Range] = []
            var iterator = try f.rs.missingRangeSequence(tx).makeAsyncIterator()
            while streamed.count < 3, let r = try await iterator.next() {
                streamed.append(r)
            }
            tx.cancel()
            #expect(Self.eq(streamed, Array(expected.prefix(3))))
        }
    }

    // MARK: - Conflicts

    @Test("contains adds a read conflict on the key unless snapshot", arguments: [false, true])
    func containsReadConflict(snapshot: Bool) async throws {
        try await withRangeSet { f in
            let tr = try f.db.createTransaction()
            #expect(try await f.rs.contains(tr, key: [0x20], snapshot: snapshot) == false)
            #expect(try await f.run { try await f.rs.insertRange($0, begin: [0x10], end: [0x30]) })
            tr.setValue(Self.deadc0de, for: f.subspace.pack([0xF0, 0x01] as FDB.Bytes))
            try await f.commit([tr], expectedConflicts: snapshot ? [] : [0])
        }
    }

    @Test("snapshot contains with an explicit addReadConflictKey conflicts")
    func snapshotContainsWithExplicitReadConflict() async throws {
        try await withRangeSet { f in
            let tr = try f.db.createTransaction()
            #expect(try await f.rs.contains(tr, key: [0x20], snapshot: true) == false)
            try f.rs.addReadConflictKey(tr, key: [0x20])
            #expect(try await f.run { try await f.rs.insertRange($0, begin: [0x10], end: [0x30]) })
            tr.setValue(Self.deadc0de, for: f.subspace.pack([0xF0, 0x01] as FDB.Bytes))
            try await f.commit([tr], expectedConflicts: [0])
        }
    }

    @Test("reads and inserts of non-overlapping ranges do not conflict")
    func readAndEditNonOverlappingRanges() async throws {
        try await withRangeSet { f in
            let trs = try await f.multi(3)
            #expect(try await f.rs.insertRange(trs[0], ([0x02], [0x03]), requireEmpty: true))
            #expect(Self.eq(try await f.rs.missingRanges(trs[1], ([0x00], [0x01])), [([0x00], [0x01])]))
            #expect(Self.eq(try await f.rs.missingRanges(trs[2], ([0x04], [0x05])), [([0x04], [0x05])]))
            try await f.commit(trs)
        }
    }

    @Test("reads overlapping a concurrent insert conflict; disjoint or snapshot reads do not")
    func concurrentlyExpandReadRange() async throws {
        try await withRangeSet { f in
            let r1: Range = ([0x02], [0x03])
            try await f.run { try await f.rs.insertRange($0, r1) }

            let trs = try await f.multi(18)
            var i = 0
            func next() -> any TransactionProtocol { defer { i += 1 }; return trs[i] }
            #expect(try await f.rs.insertRange(next(), ([0x03], [0x04]), requireEmpty: true))

            // Should succeed
            #expect(try await f.rs.contains(next(), key: [0x02, 0x01]))
            #expect(try await f.rs.contains(next(), key: [0x01, 0x01]) == false)
            #expect(try await f.rs.contains(next(), key: [0x04]) == false)
            #expect(try await f.rs.missingRanges(next(), ([0x02, 0x01], [0x02, 0x02])).count == 0)
            #expect(try await f.rs.missingRanges(next(), ([0x01, 0x01], [0x01, 0x02])).count == 1)
            #expect(try await f.rs.missingRanges(next(), ([0x01, 0x01], [0x02])).count == 1)
            #expect(try await f.rs.missingRanges(next(), ([0x04], [0x05])).count == 1)
            #expect(try await f.rs.missingRanges(next(), snapshot: true).count == 2)
            #expect(try await f.rs.isEmpty(next(), snapshot: true) == false)

            // Should fail
            let failAfter = i
            #expect(try await f.rs.contains(next(), key: [0x03]) == false)
            #expect(try await f.rs.contains(next(), key: [0x03, 0x01]) == false)
            #expect(try await f.rs.contains(next(), key: [0x02])) // key 0x02 itself is updated
            #expect(try await f.rs.missingRanges(next(), ([0x01], [0x05])).count == 2)
            #expect(try await f.rs.missingRanges(next(), ([0x01], [0x02, 0x01])).count == 1)
            #expect(try await f.rs.missingRanges(next(), r1).count == 0)
            #expect(try await f.rs.missingRanges(next(), ([0x03, 0x01], [0x04, 0x01])).count == 1)
            #expect(try await f.rs.isEmpty(next()) == false)

            #expect(i == trs.count)
            try await f.commit(trs, expectedConflicts: Set(failAfter ..< trs.count))
        }
    }

    @Test("a read of a range fails if an overlapping range is inserted concurrently")
    func failIfKeyInRangeIsInsertedConcurrently() async throws {
        try await withRangeSet { f in
            let trs = try await f.multi(2)
            let r: Range = ([0x01], [0x02])
            #expect(try await f.rs.insertRange(trs[0], ([0x00, 0x01], [0x01, 0x01]), requireEmpty: true))
            #expect(Self.eq(try await f.rs.missingRanges(trs[1], r), [r]))
            try await f.commit(trs, expectedConflicts: [1])
        }
    }

    private func assertGaps(_ f: Fixture, _ fullRange: Range, _ gaps: [Range], _ lastInRange: FDB.Bytes) async throws {
        let tr = try f.db.createTransaction()
        #expect(Self.eq(try await f.rs.missingRanges(tr, fullRange), gaps))
        var expectedAll: [Range] = [([0x00], fullRange.begin)]
        expectedAll += gaps.dropLast()
        expectedAll.append((lastInRange, [0xFF]))
        #expect(Self.eq(try await f.rs.missingRanges(tr), expectedAll))

        try await f.rs.insertRange(tr, fullRange)
        #expect(try await f.rs.missingRanges(tr, fullRange).isEmpty)
        #expect(Self.eq(try await f.rs.missingRanges(tr), [([0x00], fullRange.begin), (fullRange.end, [0xFF])]))
        tr.cancel()
    }

    @Test("concurrent inserts of non-overlapping ranges all commit")
    func insertNonOverlappingRanges() async throws {
        try await withRangeSet { f in
            let n = 10
            let trs = try await f.multi(n)
            for i in 0 ..< n {
                let b = UInt8(i + 1)
                #expect(try await f.rs.insertRange(trs[i], ([b], [b, 0x00]), requireEmpty: i % 2 == 0))
            }
            try await f.commit(trs)
            let gaps: [Range] = (0 ..< n).map { (i: Int) -> Range in (begin: [UInt8(i + 1), 0x00], end: [UInt8(i + 2)]) }
            try await assertGaps(f, ([1], [UInt8(n + 1)]), gaps, [UInt8(n), 0x00])
        }
    }

    @Test("concurrent inserts of overlapping ranges conflict")
    func insertOverlappingRanges() async throws {
        try await withRangeSet { f in
            let n = 10
            let trs = try await f.multi(n)
            for i in 0 ..< n {
                #expect(try await f.rs.insertRange(trs[i], ([UInt8(i + 1)], [UInt8(i + 2), 0x00])))
            }
            // Committed in order: each odd transaction overlaps the even one before it.
            try await f.commit(trs, expectedConflicts: Set((0 ..< n).filter { $0 % 2 != 0 }))
            let gaps: [Range] = (0 ..< n).filter { $0 % 2 != 0 }.map { (i: Int) -> Range in (begin: [UInt8(i + 1), 0x00], end: [UInt8(i + 2)]) }
            try await assertGaps(f, ([1], [UInt8(n + 1)]), gaps, [UInt8(n), 0x00])
        }
    }

    @Test("concurrent inserts of abutting ranges all commit")
    func insertAbuttingRanges() async throws {
        try await withRangeSet { f in
            let n = 10
            let trs = try await f.multi(n)
            for i in 0 ..< n {
                #expect(try await f.rs.insertRange(trs[i], ([UInt8(i + 1)], [UInt8(i + 2)]), requireEmpty: i % 2 == 0))
            }
            try await f.commit(trs)
            try await assertGaps(f, ([1], [UInt8(n + 1)]), [], [UInt8(n + 1)])
        }
    }

    @Test("filling gaps conflicts only with readers of keys in the gaps")
    func concurrentlyReadAndFillInGaps() async throws {
        try await withRangeSet { f in
            let ranges: [Range] = (0 ..< 10).map { (i: Int) -> Range in
                let b = UInt8(2 * i + 1)
                return (begin: [b], end: [b + 1])
            }
            try await f.run { tx in
                for r in ranges { try await f.rs.insertRange(tx, r, requireEmpty: true) }
            }
            let maxRangeByte = 2 * ranges.count + 1
            let trs = try await f.multi(maxRangeByte + 1)
            #expect(try await f.rs.insertRange(trs[0], begin: nil, end: nil))
            var conflicts: Set<Int> = []
            for i in 0 ..< maxRangeByte {
                let inARange = i % 2 != 0
                #expect(try await f.rs.contains(trs[i + 1], key: [UInt8(i), 0x00]) == inARange)
                if !inARange { conflicts.insert(i + 1) }
            }
            try await f.commit(trs, expectedConflicts: conflicts)
        }
    }

    @Test("concurrent inserts: disjoint succeed, overlapping conflict, readers inside the new range conflict")
    func concurrentWithInsert() async throws {
        try await withRangeSet { f in
            let keys = Self.createKeys()
            var ranges: [Range] = []

            // Two disjoint (abutting) ranges: both succeed.
            do {
                let trs = try await f.multi(2)
                let r1: Range = ([0x01], [0x02]), r2: Range = ([0x02], [0x03])
                async let a = f.rs.insertRange(trs[0], r1)
                async let b = f.rs.insertRange(trs[1], r2)
                #expect(try await a)
                #expect(try await b)
                try await f.commit(trs)
                ranges += [r1, r2]
            }
            try await checkConsistent(f, ranges, keys)
            try await checkIncreasing(f)

            // Two overlapping ranges: the second fails.
            do {
                let trs = try await f.multi(2)
                let r1: Range = ([0x03], [0x05]), r2: Range = ([0x04], [0x06])
                async let a = f.rs.insertRange(trs[0], r1)
                async let b = f.rs.insertRange(trs[1], r2)
                #expect(try await a)
                #expect(try await b)
                try await f.commit(trs, expectedConflicts: [1])
                ranges.append(r1)
            }
            try await checkConsistent(f, ranges, keys)
            try await checkIncreasing(f)

            // Reads during the write: the ones inside the inserted range conflict.
            let specificKeys: [FDB.Bytes] = [
                [0x06, 0xFF], [0x07], [0x07, 0x00], [0x07, 0x10], [0x08], [0x08, 0x00], [0x08, 0x10], [0x09],
            ]
            do {
                let trs = try await f.multi(specificKeys.count + 1)
                let r1: Range = ([0x07], [0x08])
                #expect(try await f.rs.insertRange(trs[0], r1))
                var conflicting: Set<Int> = []
                for (i, key) in specificKeys.enumerated() {
                    #expect(try await f.rs.contains(trs[i + 1], key: key) == false)
                    if Self.contains([r1], key) { conflicting.insert(i + 1) }
                }
                try await f.commit(trs, expectedConflicts: conflicting)
                ranges.append(r1)
            }
            try await checkConsistent(f, ranges, keys)
            try await checkIncreasing(f)
        }
    }
}
#endif
