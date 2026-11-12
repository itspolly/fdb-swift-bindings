/*
 * TimeWindowLeaderboardTests.swift
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

/// Ports of Java's `LeaderboardIndexTest` plus exact on-disk layout checks for the
/// `time_window_leaderboard` index.
@Suite("Time-window leaderboard index (integration)", .serialized)
struct TimeWindowLeaderboardTests {
    typealias Record = Fdb_Test_LeaderboardRecord

    static let indexName = "LeaderboardIndex"
    static let tenUnits: Int32 = 2
    static let fiveUnits: Int32 = 3
    static let allTime = TimeWindowLeaderboard.allTimeLeaderboardType

    // MARK: - Metadata (Java's UngroupedNestedLeaderboards / GroupedNestedLeaderboards)

    /// `field("scores", FanOut).nest(concat(score, timestamp)).ungrouped()`.
    static let ungroupedNode: KeyExpressionNode =
        .nest(number: 3, fanType: .fanOut, child: .then([.field(number: 1, fanType: nil), .field(number: 2, fanType: nil)]))

    /// `field("scores", FanOut).nest(concat(score, timestamp, context)).groupBy(field("game_id"))`.
    static let groupedNode: KeyExpressionNode = .then([
        .field(number: 2, fanType: nil),
        .nest(number: 3, fanType: .fanOut, child: .then([
            .field(number: 1, fanType: nil), .field(number: 2, fanType: nil), .field(number: 3, fanType: nil),
        ])),
    ])

    static func ungroupedMetaData(name: String = indexName) -> RecordMetaData {
        RecordMetaData {
            RecordType(Record.self, primaryKey: \.name)
                .index(name, on: .structured(ungroupedNode), type: .timeWindowLeaderboard, groupedCount: 2)
        }
    }

    /// Grouped by game, with the MURMUR3 rank hash (as Java's test configures it).
    static func groupedMetaData() -> RecordMetaData {
        RecordMetaData(multiTypeIndexes: [
            MultiTypeIndex(indexName, on: groupedNode, type: .timeWindowLeaderboard, recordTypes: [Record.self],
                           groupedCount: 3, options: [IndexOptions.rankHashFunction: "MURMUR3"]),
        ]) {
            RecordType(Record.self, primaryKey: \.name)
        }
    }

    // MARK: - Harness

    private func database() async throws -> FDBDatabase {
        try await FDBBootstrap.shared.ensureInitialized()
        return try FDBClient.openDatabase()
    }

    private struct Harness {
        let db: FDBDatabase
        let subspace: Subspace
        let meta: RecordMetaData

        /// Runs `body` in a committed transaction.
        @discardableResult
        func run<T: Sendable>(_ body: (FDBRecordStore) async throws -> T) async throws -> T {
            try await db.withRecordContext { context in
                try await body(try await FDBRecordStore.open(context: context, subspace: subspace, metaData: meta))
            }
        }

        /// Runs `body` in a transaction that is never committed (Java's "NOTE: no commit").
        @discardableResult
        func uncommitted<T: Sendable>(_ body: (FDBRecordStore) async throws -> T) async throws -> T {
            let context = FDBRecordContext(transaction: try db.createTransaction())
            return try await body(try await FDBRecordStore.open(context: context, subspace: subspace, metaData: meta))
        }

        func cleanup() async throws {
            try await db.withRecordContext { FDBRecordStore.deleteStore(context: $0, subspace: subspace) }
        }
    }

    private func withHarness(_ meta: RecordMetaData, _ body: (Harness) async throws -> Void) async throws {
        let harness = Harness(db: try await database(), subspace: Subspace(Tuple("fdbrl-leaderboard", UUID().uuidString)),
                              meta: meta)
        do {
            try await body(harness)
        } catch {
            try? await harness.cleanup()
            throw error
        }
        try await harness.cleanup()
    }

    // MARK: - Helpers (Java's Leaderboards)

    /// Each score row is `[score, timestamp, context]`.
    private static func addScores(_ store: FDBRecordStore, _ name: String, _ gameID: String, _ scores: [Int64]) async throws {
        var record = try await store.load(Record.self, primaryKey: Tuple(name))?.record ?? {
            var r = Record()
            r.name = name
            r.gameID = gameID
            return r
        }()
        for i in stride(from: 0, to: scores.count, by: 3) {
            var entry = Fdb_Test_LeaderboardEntry()
            entry.score = scores[i]
            entry.timestamp = scores[i + 1]
            entry.context = scores[i + 2]
            record.scores.append(entry)
        }
        try await store.save(record)
    }

    private static func standardUpdate(highScoreFirst: Bool, base: Int64,
                                       rebuild: TimeWindowLeaderboardWindowUpdate.Rebuild = .ifOverlappingChanged)
        -> TimeWindowLeaderboardWindowUpdate {
        TimeWindowLeaderboardWindowUpdate(
            updateTimestamp: 1_700_000_000_000, highScoreFirst: highScoreFirst, deleteBefore: base, allTime: true,
            specs: [
                .init(type: tenUnits, baseTimestamp: base, startIncrement: 5, duration: 10, count: 20),
                .init(type: fiveUnits, baseTimestamp: base, startIncrement: 1, duration: 5, count: 10),
            ],
            rebuild: rebuild)
    }

    @discardableResult
    private static func updateWindows(_ store: FDBRecordStore, highScoreFirst: Bool, base: Int64,
                                      rebuild: TimeWindowLeaderboardWindowUpdate.Rebuild = .ifOverlappingChanged)
        async throws -> TimeWindowLeaderboardWindowUpdateResult {
        try await store.updateTimeWindowLeaderboards(
            indexNamed: indexName, standardUpdate(highScoreFirst: highScoreFirst, base: base, rebuild: rebuild))
    }

    private static func addInitialScores(_ store: FDBRecordStore) async throws {
        // Before the default range.
        try await addScores(store, "patroclus", "game-1", [1000, 11001, 111])
        // Both higher and lower scores than hector, so wins in both directions.
        try await addScores(store, "achilles", "game-1", [
            100, 10101, 666,
            99, 10102, 665, // Does not help any
            200, 10105, 667,
            300, 10201, 668,
        ])
        // Another game.
        try await addScores(store, "helen", "game-2", [750, 11001, 555])
        try await addScores(store, "hector", "game-1", [150, 10101, 777, 160, 10105, 778, 170, 10201, 779])
        // After the default range.
        try await addScores(store, "hecuba", "game-1", [750, 11201, 888])
    }

    private func basicSetup(_ h: Harness, highScoreFirst: Bool) async throws {
        try await h.run { store in
            try await Self.updateWindows(store, highScoreFirst: highScoreFirst, base: 10100)
            try await Self.addInitialScores(store)
        }
    }

    private static func names(_ store: FDBRecordStore, type: Int32 = allTime, timestamp: Int64 = 0,
                              group: Tuple = Tuple(), ranks: LeaderboardRankRange = .all,
                              limit: Int? = nil) async throws -> [String] {
        try await store.timeWindowLeaderboardRecords(
            Record.self, indexNamed: indexName, leaderboardType: type, timestamp: timestamp,
            group: group, ranks: ranks, limit: limit).map(\.record.name)
    }

    private static func record(_ store: FDBRecordStore, _ name: String) async throws -> Record {
        try #require(try await store.load(Record.self, primaryKey: Tuple(name))).record
    }

    private static func rank(_ store: FDBRecordStore, _ record: Record, type: Int32 = allTime,
                             timestamp: Int64 = 0) async throws -> Int64? {
        try await store.timeWindowRank(record, indexNamed: indexName, leaderboardType: type, timestamp: timestamp)
    }

    private static func allKeys(_ tx: any TransactionProtocol, _ space: Subspace) async throws -> [(FDB.Bytes, FDB.Bytes)] {
        // Include the subspace's own key, which the leaderboard uses.
        let result = try await tx.getRangeNative(beginKey: space.prefix, endKey: space.prefix + [0xFF], limit: 0, snapshot: false)
        #expect(!result.more)
        return result.records
    }

    private static func le(_ value: Int64) -> FDB.Bytes { withUnsafeBytes(of: value.littleEndian) { Array($0) } }

    // MARK: - On-disk format

    @Test("directory, index entries, ranked sets and the latest-timestamp key match Java's bytes")
    func exactBytes() async throws {
        try await withHarness(Self.ungroupedMetaData(name: "lb")) { h in
            try await h.run { store in
                let result = try await store.updateTimeWindowLeaderboards(indexNamed: "lb", .init(
                    updateTimestamp: 1234, highScoreFirst: false, deleteBefore: 0, allTime: true,
                    specs: [.init(type: 2, baseTimestamp: 100, startIncrement: 10, duration: 10, count: 1)],
                    rebuild: .never))
                #expect(result == TimeWindowLeaderboardWindowUpdateResult(changed: true, rebuilt: false))
                var record = Record()
                record.name = "a"
                record.gameID = "g"
                var entry = Fdb_Test_LeaderboardEntry()
                entry.score = 50
                entry.timestamp = 105
                entry.context = 7
                record.scores = [entry]
                try await store.save(record)
            }

            let s = h.subspace.prefix
            let lb: FDB.Bytes = [0x02, 0x6C, 0x62, 0x00]          // "lb"
            let indexSpace = s + [0x15, 0x02] + lb                 // S/2/"lb"
            let secondary = s + [0x15, 0x03] + lb                  // S/3/"lb"

            // TimeWindowLeaderboardDirectory{update_timestamp=1234, high_score_first=false, next_key=2,
            //   leaderboards=[{type=0, start=Long.MIN, end=Long.MAX, subspace_key=(0), nlevels=6},
            //                 {type=2, start=100, end=110, subspace_key=(1), nlevels=6}]}
            let directory: FDB.Bytes = [0x08, 0xD2, 0x09, 0x10, 0x00, 0x18, 0x02,
                                        0x22, 0x1C,
                                        0x08, 0x00,
                                        0x10, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01,
                                        0x18, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F,
                                        0x2A, 0x01, 0x14,
                                        0x30, 0x06,
                                        0x22, 0x0C,
                                        0x08, 0x02, 0x10, 0x64, 0x18, 0x6E, 0x2A, 0x02, 0x15, 0x01, 0x30, 0x06]

            // Ranked set of each leaderboard: (level, b"") sentinels plus (0, pack(50, 105)). The
            // JDK hash of [15 32 15 69] is 1597938 (low nibble 2), so the score is on level 0 only
            // and every coarser sentinel counts it.
            let score: FDB.Bytes = [0x01, 0x15, 0x32, 0x15, 0x69, 0x00]   // bytes element pack(50, 105)
            func rankedSet(_ leaderboardKey: FDB.Bytes) -> [(FDB.Bytes, FDB.Bytes)] {
                let rs = secondary + leaderboardKey
                return [(rs + [0x14, 0x01, 0x00], Self.le(0)), (rs + [0x14] + score, Self.le(1))]
                    + (1 ... 5).map { level in (rs + [0x15, UInt8(level), 0x01, 0x00], Self.le(1)) }
            }
            let expectedSecondary = [(secondary, directory)] + rankedSet([0x14]) + rankedSet([0x15, 0x01])

            // Index entries (leaderboard key, score, timestamp, primary key) → empty tuple, after
            // the latest-timestamp key S/2/"lb" → 105 (little-endian).
            let pk: FDB.Bytes = [0x02, 0x61, 0x00]
            let expectedIndex: [(FDB.Bytes, FDB.Bytes)] = [
                (indexSpace, Self.le(105)),
                (indexSpace + [0x14, 0x15, 0x32, 0x15, 0x69] + pk, []),
                (indexSpace + [0x15, 0x01, 0x15, 0x32, 0x15, 0x69] + pk, []),
            ]

            try await h.db.withTransaction { tx in
                let secondaryKVs = try await Self.allKeys(tx, Subspace(prefix: secondary))
                #expect(secondaryKVs.map(\.0) == expectedSecondary.map(\.0))
                #expect(secondaryKVs.map(\.1) == expectedSecondary.map(\.1))
                let indexKVs = try await Self.allKeys(tx, Subspace(prefix: indexSpace))
                #expect(indexKVs.map(\.0) == expectedIndex.map(\.0))
                #expect(indexKVs.map(\.1) == expectedIndex.map(\.1))
            }

            // The directory round-trips and re-encodes to the same bytes.
            let decoded = try TimeWindowLeaderboardDirectory(decoding: directory)
            #expect(decoded.encode() == directory)
            #expect(decoded.allLeaderboards.map(\.subspaceKey) == [Tuple(Int64(0)), Tuple(Int64(1))])
            #expect(decoded.allLeaderboards[0].startTimestamp == .min && decoded.allLeaderboards[0].endTimestamp == .max)

            // Sub-directory: S/3/"lb"/(null, "g") → {high_score_first: true}.
            try await h.run { store in
                try store.saveTimeWindowLeaderboardSubDirectory(
                    indexNamed: "lb", TimeWindowLeaderboardSubDirectory(group: Tuple("g"), highScoreFirst: true))
            }
            try await h.db.withTransaction { tx in
                let value = try await tx.getValue(for: secondary + [0x00, 0x02, 0x67, 0x00], snapshot: false)
                #expect(value == [0x08, 0x01])
            }
        }
    }

    @Test("high-score-first stores negated scores, and Long.MIN_VALUE negates to the integer 2^63")
    func mostNegativeHighScoreFirst() async throws {
        try await withHarness(Self.groupedMetaData()) { h in
            try await basicSetup(h, highScoreFirst: true)
            try await h.run { (store: FDBRecordStore) async throws in
                for score in [Int64.min + 1, Int64.min] {
                    #expect(try await store.timeWindowRankForScore(
                        Record.self, indexNamed: Self.indexName, timestamp: -1, group: Tuple("game-1"),
                        score: Tuple(score)) == 4)
                }
            }
            try await h.run { store in
                _ = try await store.delete(Record.self, primaryKey: Tuple("helen"))
                try await Self.addScores(store, "helen", "game-1", [.min, 10101, 888])
                #expect(try await Self.names(store, group: Tuple("game-1"))
                    == ["patroclus", "hecuba", "achilles", "hector", "helen"])
                let helen = try await Self.record(store, "helen")
                let rankAndEntry = try await store.timeWindowRankAndEntry(helen, indexNamed: Self.indexName)
                #expect(rankAndEntry == TimeWindowRankAndEntry(rank: 4, entry: Tuple(Int64.min, Int64(10101), Int64(888))))
            }
            // On disk the negated score is 1C 80 00 00 00 00 00 00 00 (all-time leaderboard key 0).
            try await h.db.withTransaction { (tx: any TransactionProtocol) async throws in
                let index = h.subspace.prefix + [0x15, 0x02] + Tuple(Self.indexName).encode()
                let key = index + Tuple(Int64(0), "game-1").encode() + [0x1C, 0x80, 0, 0, 0, 0, 0, 0, 0]
                    + Tuple(Int64(10101), Int64(888), "helen").encode()
                #expect(try await tx.getValue(for: key, snapshot: false) == [])
            }
        }
    }

    // MARK: - Ranks and scans (Java's basic* tests)

    @Test("ungrouped, low score first")
    func basicUngrouped() async throws {
        try await withHarness(Self.ungroupedMetaData()) { h in
            try await basicSetup(h, highScoreFirst: false)
            try await h.run { store in
                #expect(try await Self.names(store) == ["achilles", "hector", "helen", "hecuba", "patroclus"])
                #expect(try await Self.names(store, ranks: .init(0 ... 1)) == ["achilles", "hector"])
                #expect(try await Self.names(store, ranks: .exactly(1)) == ["hector"])
                #expect(try await Self.names(store, type: Self.tenUnits, timestamp: 10101) == ["achilles", "hector"])
                #expect(try await Self.names(store, type: Self.fiveUnits, timestamp: 10102) == ["achilles", "hector"])
                #expect(try await Self.names(store, type: Self.fiveUnits, timestamp: 10107) == ["hector", "achilles"])
                let helen = try await Self.record(store, "helen")
                #expect(try await Self.rank(store, helen) == 2)
                #expect(try await Self.rank(store, helen, type: Self.tenUnits, timestamp: 10102) == nil)

                // Entries carry the natural score; a missing window yields nothing.
                let entries = try await store.scanTimeWindowLeaderboard(Record.self, indexNamed: Self.indexName,
                                                                        ranks: .init(0 ..< 2))
                #expect(entries.map(\.key) == [Tuple(Int64(99), Int64(10102)), Tuple(Int64(150), Int64(10101))])
                #expect(entries.map(\.primaryKey) == [Tuple("achilles"), Tuple("hector")])
                #expect(try await Self.names(store, type: 99, timestamp: 10102).isEmpty)
            }
        }
    }

    @Test("ungrouped, high score first")
    func basicUngroupedReverse() async throws {
        try await withHarness(Self.ungroupedMetaData()) { h in
            try await basicSetup(h, highScoreFirst: true)
            try await h.run { store in
                #expect(try await Self.names(store) == ["patroclus", "helen", "hecuba", "achilles", "hector"])
                #expect(try await Self.names(store, ranks: .init(0 ... 1)) == ["patroclus", "helen"])
                #expect(try await Self.names(store, ranks: .exactly(1)) == ["helen"])
                #expect(try await Self.names(store, type: Self.tenUnits, timestamp: 10101) == ["achilles", "hector"])
                #expect(try await Self.names(store, type: Self.fiveUnits, timestamp: 10102) == ["hector", "achilles"])
                #expect(try await Self.names(store, type: Self.fiveUnits, timestamp: 10106) == ["achilles", "hector"])
                let helen = try await Self.record(store, "helen")
                #expect(try await Self.rank(store, helen) == 1)
                #expect(try await Self.rank(store, helen, type: Self.tenUnits, timestamp: 10102) == nil)
                let entries = try await store.scanTimeWindowLeaderboard(Record.self, indexNamed: Self.indexName, limit: 2)
                #expect(entries.map(\.key) == [Tuple(Int64(1000), Int64(11001)), Tuple(Int64(750), Int64(11001))])
            }
        }
    }

    @Test("empty and missing records rank nil", arguments: [false, true])
    func emptyAndMissing(highScoreFirst: Bool) async throws {
        try await withHarness(Self.ungroupedMetaData()) { h in
            try await basicSetup(h, highScoreFirst: highScoreFirst)
            try await h.uncommitted { store in
                let achilles = try await Self.record(store, "achilles")
                _ = try await store.delete(Record.self, primaryKey: Tuple("achilles"))
                #expect(try await Self.rank(store, achilles) == nil)
                #expect(try await Self.rank(store, achilles, type: Self.tenUnits, timestamp: 10102) == nil)
            }
            try await h.uncommitted { store in
                let helen = try await Self.record(store, "helen")
                try await store.deleteAllRecords()
                #expect(try await Self.names(store).isEmpty)
                #expect(try await Self.names(store, ranks: .init(0 ... 2)).isEmpty)
                #expect(try await store.scoreForTimeWindowRank(Record.self, indexNamed: Self.indexName,
                                                               timestamp: -1, rank: 42) == nil)
                #expect(try await Self.rank(store, helen) == nil)
                #expect(try await Self.rank(store, helen, type: Self.tenUnits, timestamp: 10102) == nil)
            }
        }
    }

    @Test("grouped: ranks, windows, record functions, counts, score/rank lookups")
    func basicGrouped() async throws {
        try await withHarness(Self.groupedMetaData()) { h in
            try await basicSetup(h, highScoreFirst: true)
            try await h.run { store in
                let game1 = Tuple("game-1")
                #expect(try await Self.names(store, group: game1) == ["patroclus", "hecuba", "achilles", "hector"])
                #expect(try await Self.names(store, group: game1, ranks: .init(0 ... 1)) == ["patroclus", "hecuba"])
                #expect(try await Self.names(store, group: game1, ranks: .exactly(1)) == ["hecuba"])
                #expect(try await Self.names(store, type: Self.tenUnits, timestamp: 10100, group: game1) == ["achilles", "hector"])
                #expect(try await Self.names(store, type: Self.tenUnits, timestamp: 10100, group: game1, limit: 1) == ["achilles"])
                #expect(try await Self.names(store, type: Self.tenUnits, timestamp: 10102, group: game1,
                                             ranks: .init(0 ... 1)) == ["achilles", "hector"])
                #expect(try await Self.names(store, type: Self.fiveUnits, timestamp: 10100, group: game1,
                                             ranks: .init(0 ... 1)) == ["hector", "achilles"])
                // Rank ranges with exclusive / open ends (Java's queryRanges).
                #expect(try await Self.names(store, group: game1, ranks: .init(low: 2)) == ["achilles", "hector"])
                #expect(try await Self.names(store, group: game1, ranks: .init(low: 1, lowInclusive: false)) == ["achilles", "hector"])
                #expect(try await Self.names(store, group: game1, ranks: .init(high: 2)) == ["patroclus", "hecuba", "achilles"])
                #expect(try await Self.names(store, group: game1, ranks: .init(0 ..< 2)) == ["patroclus", "hecuba"])
                #expect(try await Self.names(store, group: game1, ranks: .init(low: 1, lowInclusive: false, high: 4,
                                                                               highInclusive: false)) == ["achilles", "hector"])

                let patroclus = try await Self.record(store, "patroclus")
                let achilles = try await Self.record(store, "achilles")
                let hecuba = try await Self.record(store, "hecuba")
                #expect(try await Self.rank(store, patroclus) == 0)
                #expect(try await Self.rank(store, achilles) == 2)
                #expect(try await Self.rank(store, hecuba) == 1)
                #expect(try await Self.rank(store, patroclus, type: Self.tenUnits, timestamp: 10100) == nil)
                #expect(try await Self.rank(store, achilles, type: Self.tenUnits, timestamp: 10100) == 0)
                #expect(try await Self.rank(store, hecuba, type: Self.tenUnits, timestamp: 10100) == nil)

                func entry(_ r: Record, _ type: Int32, _ ts: Int64) async throws -> Tuple? {
                    try await store.timeWindowRankAndEntry(r, indexNamed: Self.indexName, leaderboardType: type, timestamp: ts)?.tuple
                }
                #expect(try await entry(patroclus, Self.allTime, -1) == Tuple(Int64(0), Int64(1000), Int64(11001), Int64(111)))
                #expect(try await entry(achilles, Self.allTime, -1) == Tuple(Int64(2), Int64(300), Int64(10201), Int64(668)))
                #expect(try await entry(hecuba, Self.allTime, -1) == Tuple(Int64(1), Int64(750), Int64(11201), Int64(888)))
                #expect(try await entry(patroclus, Self.tenUnits, 10100) == nil)
                #expect(try await entry(achilles, Self.tenUnits, 10100) == Tuple(Int64(0), Int64(200), Int64(10105), Int64(667)))

                #expect(try await store.timeWindowCount(Record.self, indexNamed: Self.indexName, timestamp: -1, group: game1) == 4)
                #expect(try await store.timeWindowCount(Record.self, indexNamed: Self.indexName, timestamp: -1,
                                                        group: Tuple("game-2")) == 1)
                #expect(try await store.timeWindowCount(Record.self, indexNamed: Self.indexName, leaderboardType: Self.tenUnits,
                                                        timestamp: 10100, group: game1) == 2)

                #expect(try await store.scoreForTimeWindowRank(Record.self, indexNamed: Self.indexName, timestamp: -1,
                                                               group: game1, rank: 1)
                    == Tuple(Int64(750), Int64(11201), Int64(888)))
                #expect(try await store.timeWindowRankForScore(Record.self, indexNamed: Self.indexName, timestamp: -1,
                                                               group: game1, score: Tuple(Int64(750))) == 1)
                // Not present; it would take over 2nd place.
                #expect(try await store.timeWindowRankForScore(Record.self, indexNamed: Self.indexName, timestamp: -1,
                                                               group: game1, score: Tuple(Int64(751))) == 1)

                await #expect(throws: TimeWindowLeaderboardError.self) {
                    _ = try await Self.names(store) // the group is required
                }
            }
        }
    }

    @Test("records missing from a group still report the entry they would have")
    func missingFromGroup() async throws {
        try await withHarness(Self.groupedMetaData()) { h in
            try await basicSetup(h, highScoreFirst: true)
            try await h.uncommitted { store in
                let achilles = try await Self.record(store, "achilles")
                _ = try await store.delete(Record.self, primaryKey: Tuple("achilles"))
                #expect(try await Self.rank(store, achilles) == nil)
                #expect(try await Self.rank(store, achilles, type: Self.tenUnits, timestamp: 10100) == nil)
                let e1 = try await store.timeWindowRankAndEntry(achilles, indexNamed: Self.indexName, timestamp: -1)
                #expect(e1?.tuple == Tuple(NullValue(), Int64(300), Int64(10201), Int64(668)))
                let e2 = try await store.timeWindowRankAndEntry(achilles, indexNamed: Self.indexName,
                                                                leaderboardType: Self.tenUnits, timestamp: 10100)
                #expect(e2?.tuple == Tuple(NullValue(), Int64(200), Int64(10105), Int64(667)))
            }
        }
    }

    // MARK: - Changes

    @Test("updating and deleting records moves their best scores")
    func changeGrouped() async throws {
        try await withHarness(Self.groupedMetaData()) { h in
            try await basicSetup(h, highScoreFirst: true)
            let game1 = Tuple("game-1")
            try await h.run { store in
                var achilles = try await Self.record(store, "achilles")
                achilles.scores.remove(at: 3)
                achilles.scores.remove(at: 2)
                try await store.save(achilles)
                #expect(try await Self.names(store, group: game1) == ["patroclus", "hecuba", "hector", "achilles"])
                #expect(try await Self.rank(store, try await Self.record(store, "hecuba")) == 1)
                #expect(try await Self.rank(store, achilles) == 3)
                #expect(try await Self.rank(store, achilles, type: Self.tenUnits, timestamp: 10102) == 1)
            }
            try await h.run { store in
                try await Self.addScores(store, "achilles", "game-1", [350, 10108, 669])
                #expect(try await Self.names(store, group: game1) == ["patroclus", "hecuba", "achilles", "hector"])
                let achilles = try await Self.record(store, "achilles")
                #expect(try await Self.rank(store, achilles) == 2)
                #expect(try await Self.rank(store, achilles, type: Self.tenUnits, timestamp: 10102) == 0)
            }
            try await h.run { store in
                _ = try await store.delete(Record.self, primaryKey: Tuple("patroclus"))
                #expect(try await Self.names(store, group: game1) == ["hecuba", "achilles", "hector"])
                #expect(try await Self.rank(store, try await Self.record(store, "hecuba")) == 0)
                #expect(try await Self.rank(store, try await Self.record(store, "achilles")) == 1)
            }
            // Every ranked set stays consistent through the changes.
            try await h.run { store in
                let index = try store.leaderboardIndex(named: Self.indexName)
                let directory = try #require(try await index.loadDirectory()).directory
                for leaderboard in directory.allLeaderboards {
                    for game in ["game-1", "game-2"] {
                        let consistency = try await index.rankedSet(leaderboard, group: Tuple(game))
                            .checkConsistency(store.transaction)
                        #expect(consistency.isConsistent, "\(leaderboard) \(game): \(consistency)")
                    }
                }
            }
        }
    }

    @Test("omitting all-time leaves only the windows")
    func omitAllTime() async throws {
        try await withHarness(Self.groupedMetaData()) { h in
            try await h.run { store in
                try await store.updateTimeWindowLeaderboards(indexNamed: Self.indexName, .init(
                    updateTimestamp: 1, highScoreFirst: true, deleteBefore: 10100, allTime: false,
                    specs: [.init(type: Self.tenUnits, baseTimestamp: 10100, startIncrement: 5, duration: 10, count: 20)],
                    rebuild: .ifOverlappingChanged))
                try await Self.addInitialScores(store)
            }
            try await h.run { store in
                #expect(try await Self.names(store, group: Tuple("game-1")).isEmpty)
                #expect(try await Self.names(store, type: Self.tenUnits, timestamp: 10100, group: Tuple("game-1"))
                    == ["achilles", "hector"])
                let achilles = try await Self.record(store, "achilles")
                #expect(try await Self.rank(store, achilles) == nil)
                #expect(try await Self.rank(store, achilles, type: Self.tenUnits, timestamp: 10100) == 0)
            }
        }
    }

    // MARK: - Window updates and rebuilds

    @Test("window updates rebuild only when a new window overlaps indexed data", arguments: [true, false])
    func updateOverlapping(rebuild: Bool) async throws {
        try await withHarness(Self.groupedMetaData()) { h in
            try await basicSetup(h, highScoreFirst: true)
            try await h.uncommitted { store in
                let result = try await Self.updateWindows(store, highScoreFirst: true, base: 10100)
                #expect(result == TimeWindowLeaderboardWindowUpdateResult(changed: false, rebuilt: false))
            }
            try await h.uncommitted { store in
                // All new windows start after the latest indexed timestamp (11201).
                let result = try await Self.updateWindows(store, highScoreFirst: true, base: 11500)
                #expect(result == TimeWindowLeaderboardWindowUpdateResult(changed: true, rebuilt: false))
            }
            try await h.uncommitted { store in
                let result = try await Self.updateWindows(store, highScoreFirst: true, base: 10500,
                                                          rebuild: rebuild ? .ifOverlappingChanged : .never)
                #expect(result == TimeWindowLeaderboardWindowUpdateResult(changed: true, rebuilt: rebuild))
                if rebuild {
                    // The rebuilt index has the new windows populated: [10500, 10510) ... and
                    // FIVE_UNITS windows hold nothing before 10500's neighbourhood.
                    #expect(store.indexState(named: Self.indexName) == .readable)
                    #expect(try await Self.names(store, group: Tuple("game-1")) == ["patroclus", "hecuba", "achilles", "hector"])
                    #expect(try await Self.names(store, type: Self.tenUnits, timestamp: 10600, group: Tuple("game-1")).isEmpty)
                }
            }
        }
    }

    @Test("changing highScoreFirst rebuilds (and is refused without a rebuild)")
    func rebuildChangeDirection() async throws {
        try await withHarness(Self.groupedMetaData()) { h in
            try await basicSetup(h, highScoreFirst: false)
            let game1 = Tuple("game-1")
            try await h.run { (store: FDBRecordStore) async throws in
                #expect(try await Self.names(store, group: game1) == ["achilles", "hector", "hecuba", "patroclus"])
                #expect(try await Self.names(store, type: Self.tenUnits, timestamp: 10100, group: game1,
                                             ranks: .init(0 ... 1)) == ["achilles", "hector"])
            }
            await #expect(throws: TimeWindowLeaderboardError.cannotChangeHighScoreFirstWithoutRebuild) {
                try await h.uncommitted { store in
                    try await Self.updateWindows(store, highScoreFirst: true, base: 10100, rebuild: .never)
                }
            }
            try await h.run { store in
                let result = try await Self.updateWindows(store, highScoreFirst: true, base: 10100)
                #expect(result == TimeWindowLeaderboardWindowUpdateResult(changed: true, rebuilt: true))
            }
            try await h.run { store in
                #expect(try await Self.names(store, group: game1) == ["patroclus", "hecuba", "achilles", "hector"])
                #expect(try await Self.names(store, type: Self.tenUnits, timestamp: 10100, group: game1,
                                             ranks: .init(0 ... 1)) == ["achilles", "hector"])
                let directory = try #require(try await store.timeWindowLeaderboardDirectory(indexNamed: Self.indexName))
                #expect(directory.highScoreFirst)
                // A rebuild starts a fresh directory: keys are reallocated from 0.
                #expect(directory.allLeaderboards.first?.subspaceKey == Tuple(Int64(0)))
            }
        }
    }

    @Test("rebuild always re-indexes existing records into the new windows")
    func rebuildAlways() async throws {
        try await withHarness(Self.groupedMetaData()) { h in
            try await h.run { store in
                // No windows yet covering the scores, and never rebuilt on change.
                try await store.updateTimeWindowLeaderboards(indexNamed: Self.indexName, .init(
                    updateTimestamp: 1, highScoreFirst: true, deleteBefore: 0, allTime: true, specs: [], rebuild: .never))
                try await Self.addInitialScores(store)
                let result = try await Self.updateWindows(store, highScoreFirst: true, base: 10100, rebuild: .never)
                #expect(result == TimeWindowLeaderboardWindowUpdateResult(changed: true, rebuilt: false))
                // Existing records weren't indexed into the new windows.
                #expect(try await Self.names(store, type: Self.tenUnits, timestamp: 10100, group: Tuple("game-1")).isEmpty)
            }
            try await h.run { store in
                let result = try await Self.updateWindows(store, highScoreFirst: true, base: 10100, rebuild: .always)
                #expect(result == TimeWindowLeaderboardWindowUpdateResult(changed: true, rebuilt: true))
                #expect(try await Self.names(store, type: Self.tenUnits, timestamp: 10100, group: Tuple("game-1"))
                    == ["achilles", "hector"])
            }
        }
    }

    // Java's assertTimestamps.
    private static func assertTimestamps(_ store: FDBRecordStore, type: Int32, starts: [Int64], ends: [Int64]) async throws {
        let directory = try #require(try await store.timeWindowLeaderboardDirectory(indexNamed: indexName))
        let leaderboards = directory.leaderboards[type] ?? []
        #expect(leaderboards.map(\.startTimestamp) == starts)
        #expect(leaderboards.map(\.endTimestamp) == ends)
    }

    // Java's addMoreScores.
    private static func addMoreScores(_ store: FDBRecordStore, initial: Int64, _ range: Range<Int64>) async throws {
        for i in range {
            try await addScores(store, "winner\(i)", "game-1", [1000 + i, initial + i, 111])
            try await addScores(store, "loser\(i)", "game-1", [900 + i, initial + i, 111])
        }
    }

    // Java's assertLeaderboardResults: the oldest window containing a timestamp is scanned.
    private static func assertLeaderboardResults(_ store: FDBRecordStore, count: Int64, type: Int32, initial: Int64,
                                                 startIncrement: Int64, duration: Int64, initialName: Int64) async throws {
        var lookup: Int64 = 0
        for i in 0 ..< count {
            let start = i * startIncrement
            let end = start + duration
            while lookup < end {
                let expected = (start ..< end).reversed().map { "winner\($0 + initialName)" }
                    + (start ..< end).reversed().map { "loser\($0 + initialName)" }
                let actual = try await names(store, type: type, timestamp: lookup + initial)
                #expect(actual == expected, "leaderboard timestamp \(lookup + initial) (i=\(i))")
                lookup += 1
            }
        }
    }

    @Test("deleteBefore drops old windows (never all-time) and keeps the rest working")
    func deleteBefore() async throws {
        try await withHarness(Self.ungroupedMetaData()) { h in
            try await h.run { store in
                let result = try await store.updateTimeWindowLeaderboards(indexNamed: Self.indexName, .init(
                    updateTimestamp: 1, highScoreFirst: true, deleteBefore: 10100, allTime: true,
                    specs: [
                        .init(type: Self.tenUnits, baseTimestamp: 10100, startIncrement: 5, duration: 10, count: 5),
                        .init(type: Self.fiveUnits, baseTimestamp: 10100, startIncrement: 1, duration: 5, count: 25),
                    ],
                    rebuild: .ifOverlappingChanged))
                #expect(result.changed)
                try await Self.assertTimestamps(store, type: Self.tenUnits, starts: (0 ..< 5).map { $0 * 5 + 10100 },
                                                ends: (0 ..< 5).map { $0 * 5 + 10110 })
                try await Self.assertTimestamps(store, type: Self.fiveUnits, starts: (0 ..< 25).map { $0 + 10100 },
                                                ends: (0 ..< 25).map { $0 + 10105 })
                try await Self.addMoreScores(store, initial: 10100, 0 ..< 25)
            }
            try await h.run { store in
                try await Self.assertLeaderboardResults(store, count: 3, type: Self.tenUnits, initial: 10100,
                                                        startIncrement: 5, duration: 10, initialName: 0)
                try await Self.assertLeaderboardResults(store, count: 15, type: Self.fiveUnits, initial: 10100,
                                                        startIncrement: 1, duration: 5, initialName: 0)
            }
            let deleteBefore: Int64 = 10100 + 10
            let firstTenKey = try await h.run { store in
                try #require(try await store.timeWindowLeaderboardDirectory(indexNamed: Self.indexName)?
                    .leaderboards[Self.tenUnits]?.first?.subspaceKey)
            }
            try await h.run { store in
                let result = try await store.updateTimeWindowLeaderboards(indexNamed: Self.indexName, .init(
                    updateTimestamp: 2, highScoreFirst: true, deleteBefore: deleteBefore, allTime: true,
                    specs: [
                        .init(type: Self.tenUnits, baseTimestamp: 10125, startIncrement: 5, duration: 10, count: 3),
                        .init(type: Self.fiveUnits, baseTimestamp: 10125, startIncrement: 1, duration: 5, count: 20),
                    ],
                    rebuild: .ifOverlappingChanged))
                try await Self.assertTimestamps(store, type: Self.tenUnits, starts: (0 ..< 7).map { $0 * 5 + 10105 },
                                                ends: (0 ..< 7).map { $0 * 5 + 10115 })
                try await Self.assertTimestamps(store, type: Self.fiveUnits, starts: (0 ..< 39).map { $0 + 10106 },
                                                ends: (0 ..< 39).map { $0 + 10111 })
                #expect(result == TimeWindowLeaderboardWindowUpdateResult(changed: true, rebuilt: false))
                try await Self.addMoreScores(store, initial: 10100, 25 ..< 50)
            }
            // The deleted window's entries and ranked set are gone.
            try await h.db.withTransaction { tx in
                for space: Int64 in [2, 3] {
                    let prefix = h.subspace.prefix + Tuple(space, Self.indexName).encode() + firstTenKey.encode()
                    let kvs = try await tx.getRangeNative(beginKey: prefix, endKey: prefix + [0xFF], limit: 1, snapshot: false)
                    #expect(kvs.records.isEmpty)
                }
            }
            try await h.run { store in
                let directory = try #require(try await store.timeWindowLeaderboardDirectory(indexNamed: Self.indexName))
                #expect(directory.leaderboards[Self.tenUnits]?.count == 7)
                #expect(directory.leaderboards[Self.fiveUnits]?.count == 39)
                #expect(directory.allLeaderboards.filter { $0.type != Self.allTime }.allSatisfy { $0.endTimestamp > deleteBefore })
                try await Self.assertLeaderboardResults(store, count: 5, type: Self.tenUnits, initial: 10105,
                                                        startIncrement: 5, duration: 10, initialName: 5)
                try await Self.assertLeaderboardResults(store, count: 25, type: Self.fiveUnits, initial: 10106,
                                                        startIncrement: 1, duration: 5, initialName: 6)
            }
        }
    }

    @Test("deleting everything before Long.MAX_VALUE keeps the all-time leaderboard", arguments: [true, false])
    func deleteAllButAllTime(requestAllTime: Bool) async throws {
        try await withHarness(Self.groupedMetaData()) { h in
            try await basicSetup(h, highScoreFirst: true)
            try await h.run { store in
                let result = try await store.updateTimeWindowLeaderboards(indexNamed: Self.indexName, .init(
                    updateTimestamp: 2, highScoreFirst: true, deleteBefore: .max, allTime: requestAllTime,
                    specs: [], rebuild: .ifOverlappingChanged))
                #expect(result == TimeWindowLeaderboardWindowUpdateResult(changed: true, rebuilt: false))
            }
            try await h.run { store in
                #expect(try await Self.rank(store, try await Self.record(store, "hector")) == 3)
                let directory = try #require(try await store.timeWindowLeaderboardDirectory(indexNamed: Self.indexName))
                #expect(directory.allLeaderboards.map(\.type) == [Self.allTime])
            }
        }
    }

    // MARK: - Sub-directories, trimming

    @Test("a group's sub-directory overrides the direction", arguments: [false, true])
    func subDirectory(highScoreFirst: Bool) async throws {
        try await withHarness(Self.groupedMetaData()) { h in
            try await h.run { store in
                try await Self.updateWindows(store, highScoreFirst: false, base: 10100)
                try store.saveTimeWindowLeaderboardSubDirectory(
                    indexNamed: Self.indexName,
                    TimeWindowLeaderboardSubDirectory(group: Tuple("game-1"), highScoreFirst: highScoreFirst))
                try await Self.addInitialScores(store)
            }
            try await h.run { store in
                #expect(try await Self.names(store, group: Tuple("game-1")) == (highScoreFirst
                    ? ["patroclus", "hecuba", "achilles", "hector"]
                    : ["achilles", "hector", "hecuba", "patroclus"]))
                let sub = try await store.timeWindowLeaderboardSubDirectory(indexNamed: Self.indexName, group: Tuple("game-1"))
                #expect(sub.highScoreFirst == highScoreFirst)
                let other = try await store.timeWindowLeaderboardSubDirectory(indexNamed: Self.indexName, group: Tuple("game-2"))
                #expect(other.highScoreFirst == false)
            }
        }
    }

    @Test("score trim keeps the best score per window, best first")
    func trimScores() async throws {
        try await withHarness(Self.groupedMetaData()) { h in
            try await basicSetup(h, highScoreFirst: true)
            try await h.run { store in
                let untrimmed: [Tuple] = [
                    Tuple("game-1", Int64(100), Int64(10101), Int64(666)),
                    Tuple("game-1", Int64(99), Int64(10102), Int64(665)),
                    Tuple("game-1", Int64(200), Int64(10105), Int64(667)),
                    Tuple("game-1", Int64(300), Int64(10201), Int64(668)),
                ]
                let trimmed = try await store.trimTimeWindowLeaderboardScores(indexNamed: Self.indexName, scores: untrimmed)
                #expect(trimmed == [
                    Tuple("game-1", Int64(300), Int64(10201), Int64(668)),
                    Tuple("game-1", Int64(200), Int64(10105), Int64(667)),
                    Tuple("game-1", Int64(100), Int64(10101), Int64(666)),
                ])
            }
        }
    }

    @Test("queries require a scannable index; operations require a leaderboard index")
    func scannabilityAndTypes() async throws {
        try await withHarness(Self.groupedMetaData()) { h in
            try await basicSetup(h, highScoreFirst: true)
            try await h.uncommitted { store in
                try await store.markIndexWriteOnly(Self.indexName)
                await #expect(throws: RecordStoreError.self) {
                    _ = try await Self.names(store, group: Tuple("game-1"))
                }
                // Writes are still maintained while write-only (the index is idempotent).
                try await Self.addScores(store, "ajax", "game-1", [5000, 10101, 1])
                _ = try await store.markIndexReadable(Self.indexName)
                #expect(try await Self.names(store, group: Tuple("game-1"), limit: 1) == ["ajax"])
                await #expect(throws: (any Error).self) {
                    _ = try await store.performIndexOperation(indexNamed: "nope", .directory)
                }
            }
        }
    }
}
#endif
