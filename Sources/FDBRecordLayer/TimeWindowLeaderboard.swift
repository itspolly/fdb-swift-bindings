/*
 * TimeWindowLeaderboard.swift
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
import FoundationDB
import SwiftProtobuf

// Java's `TIME_WINDOW_LEADERBOARD` index (package `...foundationdb.leaderboard`), with the same
// on-disk layout. For an index with subspace key `I` in a store at `S`:
//
// - `S/3/I` (the secondary subspace's own key) → `TimeWindowLeaderboardDirectory` protobuf:
//   the configured leaderboards (time windows), each with a small integer subspace key `k`.
// - `S/3/I/(null, <group...>)` → `TimeWindowLeaderboardSubDirectory` protobuf (per-group
//   `high_score_first` override).
// - `S/2/I/(k, <group...>, <score>, <timestamp>, <tiebreakers...>, <primaryKey...>)` → empty
//   tuple: the record's best score in leaderboard `k`. With high-score-first the score is
//   stored negated, so ascending key order is always best-first.
// - `S/3/I/(k, <group...>)/...` → the leaderboard's `RankedSet` over the packed
//   `(score, timestamp, tiebreakers...)` tuples.
// - `S/2/I` (the index subspace's own key) → the latest timestamp ever indexed (8-byte
//   little-endian, maintained with an atomic `MAX`), used to decide whether adding a window
//   requires a rebuild.
//
// The index's root expression is a grouping: `<group columns...>` then the grouped part
// `<score, timestamp, other tiebreakers / context...>` (``ErasedIndex/groupedCount`` columns,
// at least two).

// MARK: - Errors

/// Errors raised by time-window leaderboard indexes.
public enum TimeWindowLeaderboardError: Error, Sendable, Equatable {
    /// The named index is not a `time_window_leaderboard` index.
    case notALeaderboardIndex(String)
    /// The index definition can't be a leaderboard (its grouped part needs a score and a timestamp).
    case invalidIndexDefinition(String)
    /// A window update asked to flip `highScoreFirst` with ``TimeWindowLeaderboardWindowUpdate/Rebuild/never``.
    case cannotChangeHighScoreFirstWithoutRebuild
    /// The stored directory or sub-directory could not be decoded.
    case corruptDirectory
    /// A score or timestamp column has an unsupported type.
    case invalidScore(String)
    /// A record function was evaluated on a record whose scores span several groups.
    case recordHasMoreThanOneGroup
    /// A grouped query did not supply exactly the index's grouping columns.
    case groupMismatch(expected: Int, actual: Int)
    /// The index has no leaderboard directory yet (no window update has been performed).
    case noDirectory
    /// A leaderboard's ranked-set level count is out of range.
    case invalidLevels(Int32)
}

// MARK: - Directory model

/// One leaderboard (time window) of a time-window leaderboard index — Java's `TimeWindowLeaderboard`.
public struct TimeWindowLeaderboard: Sendable, Hashable, CustomStringConvertible {
    /// The type of the all-time leaderboard (Java's `ALL_TIME_LEADERBOARD_TYPE`).
    public static let allTimeLeaderboardType: Int32 = 0

    /// The caller-defined leaderboard type (e.g. "daily", "weekly"); `0` is all-time.
    public let type: Int32
    /// Inclusive start of the window.
    public let startTimestamp: Int64
    /// Exclusive end of the window.
    public let endTimestamp: Int64
    /// The leaderboard's key within the index's primary and secondary subspaces.
    public let subspaceKey: Tuple
    /// The number of ranked-set levels.
    public let nlevels: Int32

    public init(type: Int32, startTimestamp: Int64, endTimestamp: Int64, subspaceKey: Tuple, nlevels: Int32) {
        self.type = type
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
        self.subspaceKey = subspaceKey
        self.nlevels = nlevels
    }

    /// Whether `timestamp` falls in `[startTimestamp, endTimestamp)`.
    public func containsTimestamp(_ timestamp: Int64) -> Bool {
        startTimestamp <= timestamp && timestamp < endTimestamp
    }

    public var description: String {
        "TimeWindowLeaderboard{type=\(type), startTimestamp=\(startTimestamp), endTimestamp=\(endTimestamp), "
            + "subspaceKey=\(subspaceKey.elements), nlevels=\(nlevels)}"
    }

    /// Java's `compareTo`: type, then start, then *wider* first, then subspace key, then levels.
    static func precedes(_ a: TimeWindowLeaderboard, _ b: TimeWindowLeaderboard) -> Bool {
        if a.type != b.type { return a.type < b.type }
        if a.startTimestamp != b.startTimestamp { return a.startTimestamp < b.startTimestamp }
        if a.endTimestamp != b.endTimestamp { return a.endTimestamp > b.endTimestamp }
        let ak = a.subspaceKey.encode(), bk = b.subspaceKey.encode()
        if ak != bk { return ak.lexicographicallyPrecedes(bk) }
        return a.nlevels < b.nlevels
    }

    /// `TimeWindowLeaderboardProto.TimeWindowLeaderboard`: every field is set explicitly, as in
    /// Java's `toProto`, so each is written even when zero.
    var protoFields: ProtoFields {
        var fields = ProtoFields()
        fields.setVarint(1, UInt64(UInt32(bitPattern: type)))            // uint32 type
        fields.setVarint(2, UInt64(bitPattern: startTimestamp))          // uint64 start_timestamp
        fields.setVarint(3, UInt64(bitPattern: endTimestamp))            // uint64 end_timestamp
        fields.setBytes(5, subspaceKey.encode())                         // bytes subspace_key
        fields.setVarint(6, ProtoFields.raw(nlevels))                    // int32 nlevels
        return fields
    }

    init(decoding bytes: FDB.Bytes) throws {
        guard let fields = try? ProtoFields(decoding: bytes),
              let subspaceKey = try? Tuple(Tuple.decode(from: fields.bytes(5) ?? [])) else {
            throw TimeWindowLeaderboardError.corruptDirectory
        }
        self.init(
            type: Int32(truncatingIfNeeded: fields.varint(1) ?? 0),
            startTimestamp: Int64(bitPattern: fields.varint(2) ?? 0),
            endTimestamp: Int64(bitPattern: fields.varint(3) ?? 0),
            subspaceKey: subspaceKey,
            nlevels: ProtoFields.int32(fields.varint(6)) ?? Int32(RankedSet.defaultLevels))
    }
}

/// The set of leaderboards of a time-window leaderboard index — Java's
/// `TimeWindowLeaderboardDirectory`, stored at the index's secondary subspace key.
public struct TimeWindowLeaderboardDirectory: Sendable {
    /// Whether higher scores rank first (the default for groups without a sub-directory).
    public let highScoreFirst: Bool
    /// The `updateTimestamp` of the last window update.
    public internal(set) var updateTimestamp: Int64 = 0
    /// The next leaderboard subspace key to allocate.
    public internal(set) var nextKey: Int32 = 0
    /// The leaderboards by type, each list in Java's order (start ascending, wider first).
    public internal(set) var leaderboards: [Int32: [TimeWindowLeaderboard]] = [:]

    public init(highScoreFirst: Bool) {
        self.highScoreFirst = highScoreFirst
    }

    /// The first (oldest, then widest) leaderboard of `type` containing `timestamp`.
    public func oldestLeaderboardMatching(type: Int32, timestamp: Int64) -> TimeWindowLeaderboard? {
        leaderboards[type]?.first { $0.containsTimestamp(timestamp) }
    }

    /// The leaderboard of `type` with exactly this window, if any.
    public func findLeaderboard(type: Int32, startTimestamp: Int64, endTimestamp: Int64) -> TimeWindowLeaderboard? {
        leaderboards[type]?.first { $0.startTimestamp == startTimestamp && $0.endTimestamp == endTimestamp }
    }

    /// Every leaderboard, in Java's iteration (and serialization) order.
    public var allLeaderboards: [TimeWindowLeaderboard] {
        leaderboards.keys.sorted().flatMap { leaderboards[$0]! }
    }

    mutating func addLeaderboard(type: Int32, startTimestamp: Int64, endTimestamp: Int64, nlevels: Int32) {
        let key = Tuple(Int64(nextKey))
        nextKey &+= 1
        insert(TimeWindowLeaderboard(type: type, startTimestamp: startTimestamp, endTimestamp: endTimestamp,
                                     subspaceKey: key, nlevels: nlevels))
    }

    private mutating func insert(_ leaderboard: TimeWindowLeaderboard) {
        var list = leaderboards[leaderboard.type] ?? []
        let at = list.firstIndex { TimeWindowLeaderboard.precedes(leaderboard, $0) } ?? list.count
        list.insert(leaderboard, at: at)
        leaderboards[leaderboard.type] = list
    }

    mutating func removeLeaderboards(where shouldRemove: (TimeWindowLeaderboard) -> Bool) -> [TimeWindowLeaderboard] {
        var removed: [TimeWindowLeaderboard] = []
        for type in leaderboards.keys.sorted() {
            let list = leaderboards[type]!
            removed += list.filter(shouldRemove)
            leaderboards[type] = list.filter { !shouldRemove($0) }
        }
        return removed
    }

    /// The serialized `TimeWindowLeaderboardDirectory` message, byte-identical to Java's.
    public func encode() -> FDB.Bytes {
        var fields = ProtoFields()
        fields.setVarint(1, UInt64(bitPattern: updateTimestamp))         // uint64 update_timestamp
        fields.setVarint(2, highScoreFirst ? 1 : 0)                      // bool high_score_first
        fields.setVarint(3, UInt64(UInt32(bitPattern: nextKey)))         // uint32 next_key
        fields.setRepeatedBytes(4, allLeaderboards.map { $0.protoFields.encode() })
        return fields.encode()
    }

    /// Decodes a serialized `TimeWindowLeaderboardDirectory`.
    public init(decoding bytes: FDB.Bytes) throws {
        guard let fields = try? ProtoFields(decoding: bytes) else {
            throw TimeWindowLeaderboardError.corruptDirectory
        }
        highScoreFirst = (fields.varint(2) ?? 0) != 0
        updateTimestamp = Int64(bitPattern: fields.varint(1) ?? 0)
        nextKey = Int32(truncatingIfNeeded: fields.varint(3) ?? 0)
        for bytes in fields.repeatedBytes(4) {
            insert(try TimeWindowLeaderboard(decoding: bytes))
        }
    }
}

/// A per-group override of `highScoreFirst` — Java's `TimeWindowLeaderboardSubDirectory`.
public struct TimeWindowLeaderboardSubDirectory: Sendable, Hashable {
    public let group: Tuple
    public let highScoreFirst: Bool

    public init(group: Tuple, highScoreFirst: Bool) {
        self.group = group
        self.highScoreFirst = highScoreFirst
    }

    /// The serialized `TimeWindowLeaderboardSubDirectory` message.
    public func encode() -> FDB.Bytes {
        var fields = ProtoFields()
        fields.setVarint(1, highScoreFirst ? 1 : 0)
        return fields.encode()
    }

    init(group: Tuple, decoding bytes: FDB.Bytes) throws {
        guard let fields = try? ProtoFields(decoding: bytes) else {
            throw TimeWindowLeaderboardError.corruptDirectory
        }
        self.init(group: group, highScoreFirst: (fields.varint(1) ?? 0) != 0)
    }
}

// MARK: - Operations

/// Adds and removes leaderboards (time windows) — Java's `TimeWindowLeaderboardWindowUpdate`.
public struct TimeWindowLeaderboardWindowUpdate: Sendable {
    /// When to rebuild the index (transactionally, within the update's transaction).
    public enum Rebuild: Sendable, Hashable {
        /// Always discard the directory and rebuild.
        case always
        /// Never rebuild; new windows only see records saved from now on.
        case never
        /// Rebuild when the directory is new, `highScoreFirst` changes, the all-time leaderboard
        /// is added, or a new window starts at or before the latest indexed timestamp.
        case ifOverlappingChanged
    }

    /// `count` windows of one type: window `i` is `[base + i * startIncrement, ... + duration)`.
    public struct TimeWindowSpec: Sendable, Hashable {
        public let type: Int32
        public let baseTimestamp: Int64
        public let startIncrement: Int64
        public let duration: Int64
        public let count: Int

        public init(type: Int32, baseTimestamp: Int64, startIncrement: Int64, duration: Int64, count: Int) {
            self.type = type
            self.baseTimestamp = baseTimestamp
            self.startIncrement = startIncrement
            self.duration = duration
            self.count = count
        }
    }

    public var updateTimestamp: Int64
    public var highScoreFirst: Bool
    /// Leaderboards (other than all-time) ending at or before this are deleted.
    public var deleteBefore: Int64
    /// Whether to ensure the all-time leaderboard exists.
    public var allTime: Bool
    public var specs: [TimeWindowSpec]
    /// Ranked-set levels for newly added leaderboards.
    public var nlevels: Int32
    public var rebuild: Rebuild

    public init(updateTimestamp: Int64, highScoreFirst: Bool, deleteBefore: Int64, allTime: Bool,
                specs: [TimeWindowSpec], nlevels: Int32 = 6, rebuild: Rebuild) {
        self.updateTimestamp = updateTimestamp
        self.highScoreFirst = highScoreFirst
        self.deleteBefore = deleteBefore
        self.allTime = allTime
        self.specs = specs
        self.nlevels = nlevels
        self.rebuild = rebuild
    }
}

/// Java's `TimeWindowLeaderboardWindowUpdateResult`.
public struct TimeWindowLeaderboardWindowUpdateResult: Sendable, Hashable {
    /// Whether the directory changed.
    public let changed: Bool
    /// Whether the index was rebuilt.
    public let rebuilt: Bool
}

/// The index operations a time-window leaderboard index supports (Java's `IndexOperation`
/// subclasses in the `leaderboard` package), run with ``FDBRecordStore/performIndexOperation(indexNamed:_:)``.
public enum TimeWindowLeaderboardIndexOperation: Sendable {
    /// `TimeWindowLeaderboardWindowUpdate`.
    case windowUpdate(TimeWindowLeaderboardWindowUpdate)
    /// `TimeWindowLeaderboardScoreTrim`: keep only the scores some leaderboard would index.
    case scoreTrim(scores: [Tuple], includesGroup: Bool)
    /// `TimeWindowLeaderboardDirectoryOperation`.
    case directory
    /// `TimeWindowLeaderboardSubDirectoryOperation`.
    case subDirectory(group: Tuple)
    /// `TimeWindowLeaderboardSaveSubDirectory`.
    case saveSubDirectory(TimeWindowLeaderboardSubDirectory)
}

/// The result of a ``TimeWindowLeaderboardIndexOperation``.
public enum TimeWindowLeaderboardIndexOperationResult: Sendable {
    case windowUpdate(TimeWindowLeaderboardWindowUpdateResult)
    case scoreTrim([Tuple])
    case directory(TimeWindowLeaderboardDirectory?)
    case subDirectory(TimeWindowLeaderboardSubDirectory)
}

/// A rank range for leaderboard scans (Java's rank `TupleRange` after the group prefix).
/// `nil` bounds are open; a negative low bound starts from the top.
public struct LeaderboardRankRange: Sendable, Hashable {
    public var low: Int64?
    public var lowInclusive: Bool
    public var high: Int64?
    public var highInclusive: Bool

    public init(low: Int64? = nil, lowInclusive: Bool = true, high: Int64? = nil, highInclusive: Bool = true) {
        self.low = low
        self.lowInclusive = lowInclusive
        self.high = high
        self.highInclusive = highInclusive
    }

    public init(_ range: ClosedRange<Int64>) { self.init(low: range.lowerBound, high: range.upperBound) }
    public init(_ range: Range<Int64>) {
        self.init(low: range.lowerBound, high: range.upperBound, highInclusive: false)
    }

    /// Every rank.
    public static let all = LeaderboardRankRange()
    /// Exactly one rank.
    public static func exactly(_ rank: Int64) -> LeaderboardRankRange { .init(rank ... rank) }
}

/// An entry returned by a leaderboard scan: the index key with the leaderboard key removed and
/// the score in its natural sign (`<group...>, score, timestamp, tiebreakers...`), and the
/// record's primary key.
public struct TimeWindowLeaderboardEntry: Sendable, Hashable {
    public let key: Tuple
    public let primaryKey: Tuple
}

/// Java's `TimeWindowRankAndEntry`: the record's best score in a leaderboard and its rank
/// (`nil` when that score isn't in the leaderboard's ranked set, e.g. the record was deleted).
public struct TimeWindowRankAndEntry: Sendable, Hashable {
    public let rank: Int64?
    /// `score, timestamp, tiebreakers...` (no group), score in its natural sign.
    public let entry: Tuple

    /// Java's `TIME_WINDOW_RANK_AND_ENTRY` tuple: `(rank, score, timestamp, ...)`.
    public var tuple: Tuple { Tuple([rank.map { $0 as any TupleElement } ?? NullValue()] + entry.elements) }
}

// MARK: - Maintainer hook

/// Java's `TimeWindowLeaderboardIndexMaintainer`.
enum TimeWindowLeaderboardMaintainer {
    /// Java's `isIdempotent`: `!config.isCountDuplicates()`.
    static func isIdempotent(_ index: ErasedIndex) -> Bool {
        !((try? RankedSet.Config(indexOptions: index.options))?.countDuplicates ?? false)
    }

    /// Java's `StandardIndexMaintainer.update` with the leaderboard's `commonKeys` (skip only
    /// when the entries are completely unchanged; otherwise redo all of them, since removing a
    /// score can make an older one the best, and a better score displaces the previous best).
    static func update(_ maintainer: IndexMaintainer, old: IndexableRecord?, new: IndexableRecord?) async throws {
        let oldEntries = old.map { $0.entries(for: maintainer.index) }
        let newEntries = new.map { $0.entries(for: maintainer.index) }
        if let oldEntries, let newEntries, oldEntries.map(Tuple.init) == newEntries.map(Tuple.init) {
            return
        }
        let leaderboards = LeaderboardIndex(store: maintainer.store, index: maintainer.index)
        if let old, let oldEntries, !oldEntries.isEmpty {
            try await leaderboards.updateIndexKeys(old, remove: true, oldEntries)
        }
        if let new, let newEntries, !newEntries.isEmpty {
            try await leaderboards.updateIndexKeys(new, remove: false, newEntries)
        }
    }
}

// MARK: - Implementation

/// A loaded directory plus the sub-directories read so far (Java caches them on the directory).
struct LoadedLeaderboardDirectory {
    var directory: TimeWindowLeaderboardDirectory
    var subdirectories: [Tuple: TimeWindowLeaderboardSubDirectory] = [:]
}

/// A potential index key for a score (Java's `OrderedScoreIndexKey`): ordered by the
/// (possibly negated) score key, i.e. best score, then earliest timestamp, then tiebreakers.
struct OrderedScoreKey {
    /// The original entry columns (group included when present).
    let entry: [any TupleElement]
    /// `score, timestamp, tiebreakers...`, the score negated for high-score-first.
    let scoreKey: [any TupleElement]
    let scoreBytes: FDB.Bytes
    let timestamp: Int64
}

/// Scores of one group, sorted and de-duplicated by score key (Java's `TreeSet`).
struct GroupedScores {
    let group: Tuple
    var keys: [OrderedScoreKey]
}

struct LeaderboardIndex {
    /// Java's `SUB_DIRECTORY_PREFIX`: `Tuple.from(null)`, which can't collide with leaderboard keys.
    static let subDirectoryPrefix: FDB.Bytes = [0x00]

    let store: FDBRecordStore
    let index: ErasedIndex

    var tr: any TransactionProtocol { store.transaction }
    var indexSubspace: Subspace { store.indexSubspace(index) }
    var secondarySubspace: Subspace { store.indexSecondarySubspace(index) }

    /// Java's `RankedSetIndexHelper.getConfig`.
    func baseConfig() throws -> RankedSet.Config {
        try RankedSet.Config(indexOptions: index.options)
    }

    /// The base config with the leaderboard's own level count.
    func config(for leaderboard: TimeWindowLeaderboard) throws -> RankedSet.Config {
        guard leaderboard.nlevels >= 2 && Int(leaderboard.nlevels) <= RankedSet.maxLevels else {
            throw TimeWindowLeaderboardError.invalidLevels(leaderboard.nlevels)
        }
        let base = try baseConfig()
        return RankedSet.Config(hashFunction: base.hashFunction, nlevels: Int(leaderboard.nlevels),
                                countDuplicates: base.countDuplicates)
    }

    /// Java's `getGroupingCount()`: the root expression's columns before the grouped part.
    func groupingCount() throws -> Int {
        let columns = index.columnIdentities.count
        guard index.groupedCount >= 2, columns >= index.groupedCount else {
            throw TimeWindowLeaderboardError.invalidIndexDefinition(
                "\(index.name): the grouped part must hold at least a score and a timestamp")
        }
        return columns - index.groupedCount
    }

    func rankedSet(_ leaderboard: TimeWindowLeaderboard, group: Tuple) throws -> RankedSet {
        RankedSet(subspace: secondarySubspace.subspace(Tuple(leaderboard.subspaceKey.elements + group.elements)),
                  config: try config(for: leaderboard))
    }

    // MARK: Directory storage

    func loadDirectory() async throws -> LoadedLeaderboardDirectory? {
        guard let bytes = try await tr.getValue(for: secondarySubspace.prefix) else { return nil }
        return LoadedLeaderboardDirectory(directory: try TimeWindowLeaderboardDirectory(decoding: bytes))
    }

    func saveDirectory(_ directory: TimeWindowLeaderboardDirectory) {
        tr.setValue(directory.encode(), for: secondarySubspace.prefix)
    }

    func subDirectoryKey(_ group: Tuple) -> FDB.Bytes {
        secondarySubspace.prefix + Self.subDirectoryPrefix + group.encode()
    }

    func loadSubDirectory(_ loaded: inout LoadedLeaderboardDirectory, group: Tuple) async throws -> TimeWindowLeaderboardSubDirectory {
        if let cached = loaded.subdirectories[group] { return cached }
        let sub: TimeWindowLeaderboardSubDirectory
        if let bytes = try await tr.getValue(for: subDirectoryKey(group)) {
            sub = try TimeWindowLeaderboardSubDirectory(group: group, decoding: bytes)
        } else {
            sub = TimeWindowLeaderboardSubDirectory(group: group, highScoreFirst: loaded.directory.highScoreFirst)
        }
        loaded.subdirectories[group] = sub
        return sub
    }

    func saveSubDirectory(_ sub: TimeWindowLeaderboardSubDirectory) {
        tr.setValue(sub.encode(), for: subDirectoryKey(sub.group))
    }

    func isHighScoreFirst(_ loaded: inout LoadedLeaderboardDirectory, group: Tuple) async throws -> Bool {
        try await loadSubDirectory(&loaded, group: group).highScoreFirst
    }

    // MARK: Scores

    /// Java's `groupOrderedScoreIndexKeys`.
    func groupOrderedScoreKeys(
        _ entries: [[any TupleElement]], _ loaded: inout LoadedLeaderboardDirectory, includesGroup: Bool
    ) async throws -> [GroupedScores] {
        let groupPrefixSize = try groupingCount()
        var groups: [GroupedScores] = []
        var positions: [Tuple: Int] = [:]
        for entry in entries {
            var group = Tuple()
            var scoreKey = entry
            if includesGroup && groupPrefixSize > 0 {
                guard entry.count >= groupPrefixSize else {
                    throw TimeWindowLeaderboardError.groupMismatch(expected: groupPrefixSize, actual: entry.count)
                }
                group = Tuple(Array(entry.prefix(groupPrefixSize)))
                scoreKey = Array(entry.dropFirst(groupPrefixSize))
            }
            let highScoreFirst = includesGroup
                ? try await isHighScoreFirst(&loaded, group: group)
                : loaded.directory.highScoreFirst
            if highScoreFirst {
                scoreKey = try Self.negateScore(scoreKey)
            }
            guard scoreKey.count >= 2, let timestamp = Self.long(scoreKey[1]) else {
                throw TimeWindowLeaderboardError.invalidScore("\(index.name): timestamp column must be an integer")
            }
            let key = OrderedScoreKey(entry: entry, scoreKey: scoreKey, scoreBytes: Tuple(scoreKey).encode(),
                                      timestamp: timestamp)
            let position: Int
            if let existing = positions[group] {
                position = existing
            } else {
                position = groups.count
                positions[group] = position
                groups.append(GroupedScores(group: group, keys: []))
            }
            Self.insertSorted(key, into: &groups[position].keys)
        }
        return groups
    }

    /// Inserts into a list sorted by score bytes, ignoring a key equal to one already present
    /// (Java's `TreeSet.add`, which compares score keys only).
    static func insertSorted(_ key: OrderedScoreKey, into keys: inout [OrderedScoreKey]) {
        var lo = 0, hi = keys.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if keys[mid].scoreBytes.lexicographicallyPrecedes(key.scoreBytes) { lo = mid + 1 } else { hi = mid }
        }
        if lo < keys.count && keys[lo].scoreBytes == key.scoreBytes { return }
        keys.insert(key, at: lo)
    }

    // MARK: Update

    /// Java's `updateIndexKeys`: for each leaderboard and group, the record's best score inside
    /// the window gets an index entry and a ranked-set element.
    func updateIndexKeys(_ record: IndexableRecord, remove: Bool, _ entries: [[any TupleElement]]) async throws {
        guard var loaded = try await loadDirectory() else { return }
        let groupedScores = try await groupOrderedScoreKeys(entries, &loaded, includesGroup: true)
        let primaryKey = record.primaryKey.encode()
        for leaderboard in loaded.directory.allLeaderboards {
            for scores in groupedScores {
                guard let best = scores.keys.first(where: { leaderboard.containsTimestamp($0.timestamp) }) else { continue }
                let leaderboardGroupKey = leaderboard.subspaceKey.elements + scores.group.elements
                let entryKey = Tuple(leaderboardGroupKey + best.scoreKey)
                // The ordinary B-tree entry (value: the empty tuple).
                let keyBytes = indexSubspace.prefix + entryKey.encode() + primaryKey
                if remove {
                    tr.clear(key: keyBytes)
                } else {
                    if keyBytes.count > FDBLimits.maxKeySize {
                        throw RecordStoreError.keyTooLarge(index: index.name, size: keyBytes.count)
                    }
                    tr.setValue([], for: keyBytes)
                }
                // The leaderboard's ranked set. Each leaderboard picks at most one score per
                // record and group, so this is the record's only element in this set.
                let config = try config(for: leaderboard)
                let rankedSet = RankedSet(subspace: secondarySubspace.subspace(Tuple(leaderboardGroupKey)), config: config)
                try await RankedSetIndexHelper.updateRankedSet(
                    tr, rankedSet: rankedSet, score: best.scoreBytes, remove: remove,
                    valueRange: indexSubspace.range(entryKey), config: config)
            }
        }
        // Track the latest timestamp ever indexed, so adding a window that starts before it
        // knows existing records must be indexed (Java: atomic MAX of encodeSignedLong).
        if let latest = groupedScores.flatMap({ $0.keys.map(\.timestamp) }).max() {
            tr.atomicOp(key: indexSubspace.prefix, param: IndexMaintainer.littleEndian(latest), mutationType: .max)
        }
    }

    /// Java's `deleteWhere`: clears every leaderboard's entries and ranked sets under `prefix`
    /// (inclusive of keys at the group root).
    func deleteWhere(_ directory: TimeWindowLeaderboardDirectory, prefix: Tuple) {
        for leaderboard in directory.allLeaderboards {
            let key = Tuple(leaderboard.subspaceKey.elements + prefix.elements)
            for space in [indexSubspace, secondarySubspace] {
                let begin = space.pack(key)
                tr.clearRange(beginKey: begin, endKey: Self.strinc(begin))
            }
        }
    }

    // MARK: Operations

    func perform(_ operation: TimeWindowLeaderboardIndexOperation) async throws -> TimeWindowLeaderboardIndexOperationResult {
        switch operation {
        case .windowUpdate(let update):
            return .windowUpdate(try await windowUpdate(update))
        case .scoreTrim(let scores, let includesGroup):
            return .scoreTrim(try await trimScores(scores, includesGroup: includesGroup))
        case .directory:
            return .directory(try await loadDirectory()?.directory)
        case .subDirectory(let group):
            guard var loaded = try await loadDirectory() else { throw TimeWindowLeaderboardError.noDirectory }
            return .subDirectory(try await loadSubDirectory(&loaded, group: group))
        case .saveSubDirectory(let sub):
            saveSubDirectory(sub)
            return .subDirectory(sub)
        }
    }

    /// Java's `UpdateState`: load, update, check overlap, save (and maybe rebuild).
    func windowUpdate(_ update: TimeWindowLeaderboardWindowUpdate) async throws -> TimeWindowLeaderboardWindowUpdateResult {
        var rebuild = update.rebuild == .always
        var changed = false
        var isRebuildConditional: Bool { !rebuild && update.rebuild == .ifOverlappingChanged }

        // loadDirectory / setDirectory
        var directory = rebuild ? nil : try await loadDirectory()?.directory
        if let existing = directory, existing.highScoreFirst != update.highScoreFirst {
            if update.rebuild == .never { throw TimeWindowLeaderboardError.cannotChangeHighScoreFirstWithoutRebuild }
            directory = nil
        }
        if directory == nil {
            directory = TimeWindowLeaderboardDirectory(highScoreFirst: update.highScoreFirst)
            if isRebuildConditional { rebuild = true }
        }
        var dir = directory!

        // update
        dir.updateTimestamp = update.updateTimestamp
        // The all-time leaderboard is never deleted, even with `deleteBefore` = Int64.max.
        let deleted = dir.removeLeaderboards {
            $0.type != TimeWindowLeaderboard.allTimeLeaderboardType && update.deleteBefore >= $0.endTimestamp
        }
        for leaderboard in deleted {
            // Java clears only the single key `pack(subspaceKey)` here, orphaning the window's
            // entries (never read again: keys are not reused without a full rebuild). Clearing
            // the whole window is equivalent for every reader and reclaims the space.
            for space in [indexSubspace, secondarySubspace] {
                let begin = space.pack(leaderboard.subspaceKey)
                tr.clearRange(beginKey: begin, endKey: Self.strinc(begin))
            }
            changed = true
        }
        if update.allTime, dir.leaderboards[TimeWindowLeaderboard.allTimeLeaderboardType]?.isEmpty ?? true {
            dir.addLeaderboard(type: TimeWindowLeaderboard.allTimeLeaderboardType,
                               startTimestamp: .min, endTimestamp: .max, nlevels: update.nlevels)
            if isRebuildConditional { rebuild = true }
            changed = true
        }
        var earliestAddedStartTimestamp = Int64.max
        for spec in update.specs {
            for i in 0 ..< max(0, spec.count) {
                let start = spec.baseTimestamp &+ spec.startIncrement &* Int64(i)
                let end = start &+ spec.duration
                if dir.findLeaderboard(type: spec.type, startTimestamp: start, endTimestamp: end) == nil {
                    dir.addLeaderboard(type: spec.type, startTimestamp: start, endTimestamp: end, nlevels: update.nlevels)
                    earliestAddedStartTimestamp = min(earliestAddedStartTimestamp, start)
                    changed = true
                }
            }
        }

        // checkOverlappingChanged: a record already indexed at or after a new window's start
        // means existing records must be indexed into it, which is done by rebuilding.
        if changed, let maxBytes = try await tr.getValue(for: indexSubspace.prefix) {
            let latestEntryTimestamp = IndexMaintainer.decodeLittleEndian(maxBytes)
            if latestEntryTimestamp >= earliestAddedStartTimestamp, isRebuildConditional {
                rebuild = true
            }
        }

        // save
        if rebuild { deleteWhere(dir, prefix: Tuple()) }
        if changed { saveDirectory(dir) }
        if rebuild { try await rebuildIndex() }
        return TimeWindowLeaderboardWindowUpdateResult(changed: changed, rebuilt: rebuild)
    }

    /// Java's `FDBRecordStore.rebuildIndex` (via `OnlineIndexer.rebuildIndexAsync`): clear the
    /// index, mark it write-only with the whole range built, index every record within this
    /// transaction, and mark it readable. The directory (at the secondary subspace's own key)
    /// survives the clear; sub-directories do not, as in Java.
    func rebuildIndex() async throws {
        try await store.clearAndMarkIndexWriteOnly(index.name)
        // Java clears `startsWith(indexSubspace)`, which includes the latest-timestamp key.
        tr.clear(key: indexSubspace.prefix)
        _ = try await store.indexRangeSet(index).insertRange(tr, begin: nil, end: nil)
        let maintainer = store.indexMaintainer(for: index)
        for try await record in store.scanRecords() {
            guard record.recordType.indexes.contains(where: { $0.name == index.name }) else { continue }
            try await maintainer.update(old: nil, new: record)
        }
        try await store.markIndexReadable(index.name)
    }

    /// Java's `trimScores`: the scores (from `scores`) that some leaderboard would index, ordered
    /// best first and de-duplicated by score key.
    func trimScores(_ scores: [Tuple], includesGroup: Bool) async throws -> [Tuple] {
        guard var loaded = try await loadDirectory() else { return scores }
        let grouped = try await groupOrderedScoreKeys(scores.map(\.elements), &loaded, includesGroup: includesGroup)
        var trimmed: [OrderedScoreKey] = []
        for leaderboard in loaded.directory.allLeaderboards {
            for scores in grouped {
                if let best = scores.keys.first(where: { leaderboard.containsTimestamp($0.timestamp) }) {
                    Self.insertSorted(best, into: &trimmed)
                }
            }
        }
        return trimmed.map { Tuple($0.entry) }
    }

    // MARK: Queries

    /// Java's `evaluateEqualRange` prologue: the oldest matching leaderboard (if any).
    func leaderboard(type: Int32, timestamp: Int64) async throws -> (LoadedLeaderboardDirectory, TimeWindowLeaderboard)? {
        guard let loaded = try await loadDirectory(),
              let leaderboard = loaded.directory.oldestLeaderboardMatching(type: type, timestamp: timestamp) else {
            return nil
        }
        return (loaded, leaderboard)
    }

    func checkGroup(_ group: Tuple) throws {
        let expected = try groupingCount()
        guard group.count == expected else {
            throw TimeWindowLeaderboardError.groupMismatch(expected: expected, actual: group.count)
        }
    }

    /// Java's `timeWindowRankAndEntry`.
    func rankAndEntry(entries: [[any TupleElement]], type: Int32, timestamp: Int64) async throws -> TimeWindowRankAndEntry? {
        guard var (loaded, leaderboard) = try await leaderboard(type: type, timestamp: timestamp) else { return nil }
        let grouped = try await groupOrderedScoreKeys(entries, &loaded, includesGroup: true)
        guard let scores = grouped.first else { return nil }
        guard grouped.count == 1 else { throw TimeWindowLeaderboardError.recordHasMoreThanOneGroup }
        guard let best = scores.keys.first(where: { leaderboard.containsTimestamp($0.timestamp) }) else { return nil }
        let highScoreFirst = try await isHighScoreFirst(&loaded, group: scores.group)
        let rankedSet = try rankedSet(leaderboard, group: scores.group)
        try await rankedSet.preloadForLookup(tr, snapshot: true)
        let rank = try await rankedSet.rank(tr, key: best.scoreBytes, nullIfMissing: true)
        let entry = highScoreFirst ? try Self.unnegateStoredScore(best.scoreKey) : best.scoreKey
        return TimeWindowRankAndEntry(rank: rank, entry: Tuple(entry))
    }

    /// Java's `TIME_WINDOW_COUNT`.
    func count(type: Int32, timestamp: Int64, group: Tuple) async throws -> Int64? {
        try checkGroup(group)
        guard let (_, leaderboard) = try await leaderboard(type: type, timestamp: timestamp) else { return nil }
        return try await rankedSet(leaderboard, group: group).size(tr)
    }

    /// Java's `SCORE_FOR_TIME_WINDOW_RANK`.
    func scoreForRank(type: Int32, timestamp: Int64, group: Tuple, rank: Int64) async throws -> Tuple? {
        try checkGroup(group)
        guard var (loaded, leaderboard) = try await leaderboard(type: type, timestamp: timestamp) else { return nil }
        let rankedSet = try rankedSet(leaderboard, group: group)
        try await rankedSet.preloadForLookup(tr, snapshot: true)
        guard let bytes = try await rankedSet.getNth(tr, rank: rank) else { return nil }
        let score = try Tuple.decode(from: bytes)
        let highScoreFirst = try await isHighScoreFirst(&loaded, group: group)
        return Tuple(highScoreFirst ? try Self.unnegateStoredScore(score) : score)
    }

    /// Java's `TIME_WINDOW_RANK_FOR_SCORE`: the rank `score` (a full or partial score key)
    /// has, or would have, in the leaderboard.
    func rankForScore(type: Int32, timestamp: Int64, group: Tuple, score: Tuple) async throws -> Int64? {
        try checkGroup(group)
        guard var (loaded, leaderboard) = try await leaderboard(type: type, timestamp: timestamp) else { return nil }
        let highScoreFirst = try await isHighScoreFirst(&loaded, group: group)
        let values = highScoreFirst ? try Self.negateScore(score.elements) : score.elements
        let rankedSet = try rankedSet(leaderboard, group: group)
        try await rankedSet.preloadForLookup(tr, snapshot: true)
        return try await rankedSet.rank(tr, key: Tuple(values).encode(), nullIfMissing: false)
    }

    /// Java's `scan` with `BY_RANK` / `BY_TIME_WINDOW`: ranks map to scores through the
    /// leaderboard's ranked set, then the leaderboard's entries are scanned best-first.
    func scanByRank(type: Int32, timestamp: Int64, group: Tuple, ranks: LeaderboardRankRange,
                    limit: Int?) async throws -> [TimeWindowLeaderboardEntry] {
        try checkGroup(group)
        guard var (loaded, leaderboard) = try await leaderboard(type: type, timestamp: timestamp) else { return [] }
        let base = indexSubspace.pack(Tuple(leaderboard.subspaceKey.elements + group.elements))

        // RankedSetIndexHelper.rankRangeToScoreRange
        let startFromBeginning = ranks.low.map { $0 < 0 } ?? true
        let lowInclusive = startFromBeginning ? true : ranks.lowInclusive
        if let high = ranks.high, high < 0 || (!ranks.highInclusive && high == 0) { return [] }
        if let high = ranks.high, !ranks.highInclusive, !lowInclusive, high == ranks.low { return [] }
        var begin = base
        var end = Self.strinc(base)
        if !(startFromBeginning && ranks.high == nil) {
            let rankedSet = try rankedSet(leaderboard, group: group)
            // An uninitialized ranked set is empty (Java would initialize it here).
            if try await rankedSet.initNeeded(tr, snapshot: true) { return [] }
            try await rankedSet.preloadForLookup(tr, snapshot: true)
            guard let lowScore = try await rankedSet.getNth(tr, rank: startFromBeginning ? 0 : ranks.low!) else { return [] }
            begin = lowInclusive ? base + lowScore : Self.strinc(base + lowScore)
            if let high = ranks.high, let highScore = try await rankedSet.getNth(tr, rank: high) {
                end = ranks.highInclusive ? Self.strinc(base + highScore) : base + highScore
            }
        }

        let groupPrefixSize = group.count
        let highScoreFirst = try await isHighScoreFirst(&loaded, group: group)
        let skip = leaderboard.subspaceKey.count
        let pkCount = index.primaryKeyColumnCount
        var result: [TimeWindowLeaderboardEntry] = []
        for (key, _) in try await scan(begin: begin, end: end, limit: limit) {
            let elements = Array(try indexSubspace.unpack(key).dropFirst(skip))
            guard elements.count >= pkCount + groupPrefixSize + 1 else { continue }
            var entry = Array(elements.dropLast(pkCount))
            if highScoreFirst {
                entry = Array(entry.prefix(groupPrefixSize))
                    + (try Self.unnegateStoredScore(Array(entry.dropFirst(groupPrefixSize))))
            }
            result.append(TimeWindowLeaderboardEntry(key: Tuple(entry), primaryKey: Tuple(Array(elements.suffix(pkCount)))))
        }
        return result
    }

    /// Reads `[begin, end)` batch by batch (stopping at `limit`) without leaving a prefetch in flight.
    func scan(begin: FDB.Bytes, end: FDB.Bytes, limit: Int?) async throws -> [(FDB.Bytes, FDB.Bytes)] {
        var out: [(FDB.Bytes, FDB.Bytes)] = []
        var beginSelector = FDB.KeySelector.firstGreaterOrEqual(begin)
        guard begin.lexicographicallyPrecedes(end) else { return [] }
        while true {
            var batchLimit = 0
            if let limit {
                batchLimit = limit - out.count
                if batchLimit <= 0 { break }
            }
            let batch = try await tr.getRangeNative(
                beginSelector: beginSelector, endSelector: .firstGreaterOrEqual(end),
                limit: batchLimit, snapshot: false, reverse: false)
            out += batch.records
            guard batch.more, let last = batch.records.last else { break }
            beginSelector = .firstGreaterThan(last.0)
        }
        return out
    }

    // MARK: Helpers

    /// `ByteArrayUtil.strinc`: the first key after every key starting with `key`.
    static func strinc(_ key: FDB.Bytes) -> FDB.Bytes {
        var bytes = key
        while let last = bytes.last, last == 0xFF { bytes.removeLast() }
        guard !bytes.isEmpty else { return [0xFF] }
        bytes[bytes.count - 1] += 1
        return bytes
    }

    static func long(_ element: any TupleElement) -> Int64? {
        switch element {
        case let v as Int64: return v
        case let v as Int: return Int64(v)
        case let v as Int32: return Int64(v)
        case let v as UInt64 where v <= UInt64(Int64.max): return Int64(v)
        default: return nil
        }
    }

    /// Java's `negateScoreForHighScoreFirst(entry, 0)` with `TupleHelpers.negate`: the one long
    /// whose negation isn't a long, `Long.MIN_VALUE`, becomes the integer 2^63.
    static func negateScore(_ scoreKey: [any TupleElement]) throws -> [any TupleElement] {
        guard let first = scoreKey.first else { return scoreKey }
        let negated: any TupleElement
        switch first {
        case let v as Int64: negated = v == .min ? TupleTwoToThe63() : -v
        case let v as Int: negated = Int64(v) == .min ? TupleTwoToThe63() : -Int64(v)
        case let v as Int32: negated = -Int64(v)
        case let v as UInt64 where v <= UInt64(Int64.max): negated = -Int64(v)
        case let v as UInt64 where v == UInt64(1) << 63: negated = Int64.min
        case is TupleTwoToThe63: negated = Int64.min
        case let v as Double: negated = -v
        case let v as Float: negated = -v
        default: throw TimeWindowLeaderboardError.invalidScore("score must be numeric, not \(type(of: first))")
        }
        return [negated] + scoreKey.dropFirst()
    }

    /// Un-negates a score key decoded from storage. The Swift tuple layer decodes a stored 2^63
    /// (the negation of `Long.MIN_VALUE`) as `Int64.min`, so that value maps back to itself.
    static func unnegateStoredScore(_ scoreKey: [any TupleElement]) throws -> [any TupleElement] {
        if let first = scoreKey.first as? Int64, first == .min { return scoreKey }
        return try negateScore(scoreKey)
    }
}

/// The tuple integer 2^63 (Java's `BigInteger` negation of `Long.MIN_VALUE`), encoded as an
/// 8-byte positive integer exactly as Java's tuple layer does. Encode-only.
struct TupleTwoToThe63: TupleElement {
    func encodeTuple() -> FDB.Bytes { [0x1C, 0x80, 0, 0, 0, 0, 0, 0, 0] }
    static func decodeTuple(from _: FDB.Bytes, at _: inout Int) throws -> TupleTwoToThe63 {
        throw TupleError.unsupportedType
    }
}

// MARK: - Store API

extension FDBRecordStore {
    func leaderboardIndex(named name: String) throws -> LeaderboardIndex {
        let index = try erasedIndexOrThrow(name)
        guard index.type == .timeWindowLeaderboard else { throw TimeWindowLeaderboardError.notALeaderboardIndex(name) }
        return LeaderboardIndex(store: self, index: index)
    }

    func scannableLeaderboardIndex<M: SwiftProtobuf.Message>(_ type: M.Type, named name: String) throws -> LeaderboardIndex {
        let index = try scannableIndex(type, named: name)
        guard index.type == .timeWindowLeaderboard else { throw TimeWindowLeaderboardError.notALeaderboardIndex(name) }
        return LeaderboardIndex(store: self, index: index)
    }

    // MARK: Index operations

    /// Performs a leaderboard index operation — Java's `performIndexOperation` with the
    /// `leaderboard` package's operations. Works whatever the index's state.
    public func performIndexOperation(
        indexNamed name: String, _ operation: TimeWindowLeaderboardIndexOperation
    ) async throws -> TimeWindowLeaderboardIndexOperationResult {
        try await leaderboardIndex(named: name).perform(operation)
    }

    /// Adds and deletes time windows (Java's `TimeWindowLeaderboardWindowUpdate`), rebuilding
    /// the index within this transaction when the update requires it.
    @discardableResult
    public func updateTimeWindowLeaderboards(
        indexNamed name: String, _ update: TimeWindowLeaderboardWindowUpdate
    ) async throws -> TimeWindowLeaderboardWindowUpdateResult {
        try await leaderboardIndex(named: name).windowUpdate(update)
    }

    /// The index's leaderboard directory, or `nil` before the first window update.
    public func timeWindowLeaderboardDirectory(indexNamed name: String) async throws -> TimeWindowLeaderboardDirectory? {
        try await leaderboardIndex(named: name).loadDirectory()?.directory
    }

    /// The group's sub-directory (its `highScoreFirst`, defaulting to the directory's).
    public func timeWindowLeaderboardSubDirectory(indexNamed name: String, group: Tuple) async throws -> TimeWindowLeaderboardSubDirectory {
        guard case .subDirectory(let sub) = try await performIndexOperation(indexNamed: name, .subDirectory(group: group)) else {
            preconditionFailure("unexpected result")
        }
        return sub
    }

    /// Overrides `highScoreFirst` for one group. As in Java, existing entries are not re-indexed.
    public func saveTimeWindowLeaderboardSubDirectory(indexNamed name: String, _ sub: TimeWindowLeaderboardSubDirectory) throws {
        try leaderboardIndex(named: name).saveSubDirectory(sub)
    }

    /// Java's `TimeWindowLeaderboardScoreTrim`: of `scores` (index-entry tuples, with the group
    /// when `includesGroup`), those some leaderboard would index, best first.
    public func trimTimeWindowLeaderboardScores(
        indexNamed name: String, scores: [Tuple], includesGroup: Bool = true
    ) async throws -> [Tuple] {
        try await leaderboardIndex(named: name).trimScores(scores, includesGroup: includesGroup)
    }

    // MARK: Record functions

    /// Java's `TIME_WINDOW_RANK_AND_ENTRY` record function (and, with the defaults, `RANK` on the
    /// all-time leaderboard): the record's best score in the oldest leaderboard of
    /// `leaderboardType` containing `timestamp`, and its rank there. `nil` when there is no such
    /// leaderboard or the record has no score in it.
    public func timeWindowRankAndEntry<M: SwiftProtobuf.Message & Sendable>(
        _ record: M, indexNamed name: String,
        leaderboardType: Int32 = TimeWindowLeaderboard.allTimeLeaderboardType, timestamp: Int64 = 0
    ) async throws -> TimeWindowRankAndEntry? {
        guard let recordType = metaData.recordType(for: M.self) else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }
        let leaderboards = try scannableLeaderboardIndex(M.self, named: name)
        let entries = recordType.indexEntries(leaderboards.index, record, version: nil)
        return try await leaderboards.rankAndEntry(entries: entries, type: leaderboardType, timestamp: timestamp)
    }

    /// Java's `TIME_WINDOW_RANK` record function (`RANK` with the defaults).
    public func timeWindowRank<M: SwiftProtobuf.Message & Sendable>(
        _ record: M, indexNamed name: String,
        leaderboardType: Int32 = TimeWindowLeaderboard.allTimeLeaderboardType, timestamp: Int64 = 0
    ) async throws -> Int64? {
        try await timeWindowRankAndEntry(record, indexNamed: name, leaderboardType: leaderboardType,
                                         timestamp: timestamp)?.rank
    }

    // MARK: Aggregate functions

    /// Java's `TIME_WINDOW_COUNT`: the number of distinct scores in the group's leaderboard.
    public func timeWindowCount<M: SwiftProtobuf.Message>(
        _ type: M.Type, indexNamed name: String, leaderboardType: Int32 = TimeWindowLeaderboard.allTimeLeaderboardType,
        timestamp: Int64 = 0, group: Tuple = Tuple()
    ) async throws -> Int64? {
        try await scannableLeaderboardIndex(type, named: name).count(type: leaderboardType, timestamp: timestamp, group: group)
    }

    /// Java's `SCORE_FOR_TIME_WINDOW_RANK`: the score key (`score, timestamp, tiebreakers...`)
    /// at `rank` (0 = best), or `nil` when out of range.
    public func scoreForTimeWindowRank<M: SwiftProtobuf.Message>(
        _ type: M.Type, indexNamed name: String, leaderboardType: Int32 = TimeWindowLeaderboard.allTimeLeaderboardType,
        timestamp: Int64 = 0, group: Tuple = Tuple(), rank: Int64
    ) async throws -> Tuple? {
        try await scannableLeaderboardIndex(type, named: name)
            .scoreForRank(type: leaderboardType, timestamp: timestamp, group: group, rank: rank)
    }

    /// Java's `TIME_WINDOW_RANK_FOR_SCORE`: the rank `score` (`score[, timestamp, ...]`) has, or
    /// would take, in the leaderboard.
    public func timeWindowRankForScore<M: SwiftProtobuf.Message>(
        _ type: M.Type, indexNamed name: String, leaderboardType: Int32 = TimeWindowLeaderboard.allTimeLeaderboardType,
        timestamp: Int64 = 0, group: Tuple = Tuple(), score: Tuple
    ) async throws -> Int64? {
        try await scannableLeaderboardIndex(type, named: name)
            .rankForScore(type: leaderboardType, timestamp: timestamp, group: group, score: score)
    }

    // MARK: Scans

    /// Scans a group's entries in a leaderboard by rank, best first — Java's `BY_TIME_WINDOW`
    /// scan (`BY_RANK` with the default all-time leaderboard).
    public func scanTimeWindowLeaderboard<M: SwiftProtobuf.Message>(
        _ type: M.Type, indexNamed name: String, leaderboardType: Int32 = TimeWindowLeaderboard.allTimeLeaderboardType,
        timestamp: Int64 = 0, group: Tuple = Tuple(), ranks: LeaderboardRankRange = .all, limit: Int? = nil
    ) async throws -> [TimeWindowLeaderboardEntry] {
        try await scannableLeaderboardIndex(type, named: name)
            .scanByRank(type: leaderboardType, timestamp: timestamp, group: group, ranks: ranks, limit: limit)
    }

    /// The records of ``scanTimeWindowLeaderboard(_:indexNamed:leaderboardType:timestamp:group:ranks:limit:)``,
    /// in rank order.
    public func timeWindowLeaderboardRecords<M: SwiftProtobuf.Message & Sendable>(
        _ type: M.Type, indexNamed name: String, leaderboardType: Int32 = TimeWindowLeaderboard.allTimeLeaderboardType,
        timestamp: Int64 = 0, group: Tuple = Tuple(), ranks: LeaderboardRankRange = .all, limit: Int? = nil
    ) async throws -> [FDBStoredRecord<M>] {
        guard let recordType = metaData.recordType(for: M.self) else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }
        var records: [FDBStoredRecord<M>] = []
        for entry in try await scanTimeWindowLeaderboard(
            type, indexNamed: name, leaderboardType: leaderboardType, timestamp: timestamp,
            group: group, ranks: ranks, limit: limit) {
            if let record: FDBStoredRecord<M> = try await loadTyped(entry.primaryKey, recordType: recordType, filter: nil) {
                records.append(record)
            }
        }
        return records
    }
}
#endif
