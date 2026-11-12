/*
 * RankedSet.swift
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

/// Errors raised by ``RankedSet``.
enum RankedSetError: Error, Sendable, Equatable {
    /// Keys must be non-empty (the empty key is the per-level sentinel). Java: `IllegalArgumentException`.
    case emptyKey
    /// `getPreviousKey` found no entry on a level — the set was not initialized. Java: `IllegalStateException`.
    case noKeyFoundOnLevel(Int)
    /// A count key was missing or held fewer than 8 bytes.
    case malformedCount
    /// A stored key did not decode as `(level, bytes)`.
    case malformedKey
    /// An invalid configuration / index option value.
    case invalidConfig(String)
}

/// A port of the Java fdb-extensions `com.apple.foundationdb.async.RankedSet`, byte-for-byte
/// compatible with its on-disk format.
///
/// Supports retrieval of elements by rank (``rank(_:key:nullIfMissing:snapshot:)``) and of the
/// element at a rank (``getNth(_:rank:snapshot:)``), ordered lexicographically by key bytes.
///
/// The set is a skip list with ``Config/nlevels`` levels stored in ``subspace``. Every entry is
/// keyed by the tuple `(level, key)` and its value is the number of elements between this key
/// (inclusive) and the next key on the same level (exclusive), as an 8-byte little-endian
/// integer. Level 0 holds one entry per element (count 1, or the number of duplicates when
/// ``Config/countDuplicates``). Each level begins with the sentinel `(level, b"")` written by
/// ``init(_:)``. A key appears on level `l > 0` when the low `4 * l` bits of its hash are zero.
struct RankedSet: Sendable {
    // MARK: - Hash functions

    /// Computes the 32-bit hash used to decide which levels a key splits.
    ///
    /// Changing the hash of an existing set tends to unbalance it but never breaks it.
    struct HashFunction: Sendable {
        /// The name used for this function by the `rankHashFunction` index option, if any.
        let name: String
        let hash: @Sendable (FDB.Bytes) -> Int32

        init(name: String, hash: @escaping @Sendable (FDB.Bytes) -> Int32) {
            self.name = name
            self.hash = hash
        }

        /// Java `RankedSet.JDK_ARRAY_HASH`: `java.util.Arrays.hashCode(byte[])` over signed bytes.
        static let jdkArrayHash = HashFunction(name: "JDK") { key in
            var result: Int32 = 1
            for byte in key {
                result = 31 &* result &+ Int32(Int8(bitPattern: byte))
            }
            return result
        }

        /// Java `RankedSet.CRC_HASH`: `java.util.zip.CRC32` (IEEE, zlib) truncated to `int`.
        static let crcHash = HashFunction(name: "CRC") { key in
            Int32(bitPattern: CRC32.checksum(key))
        }

        /// Java `RankedSet.RANDOM_HASH`: ignores the key.
        static let randomHash = HashFunction(name: "RANDOM") { _ in
            Int32.random(in: Int32.min ... Int32.max)
        }

        /// Record Layer `RankedSetHashFunctions.MURMUR3`: Guava `Hashing.murmur3_32_fixed()`
        /// (seed 0) `.hashBytes(key).asInt()`.
        static let murmur3 = HashFunction(name: "MURMUR3") { key in
            Int32(bitPattern: Murmur3.hash32(key, seed: 0))
        }

        /// Java `RankedSet.DEFAULT_HASH_FUNCTION` (kept as the JDK hash for compatibility).
        static let `default` = jdkArrayHash

        /// Looks up a hash function by its `rankHashFunction` option name, mirroring
        /// `RankedSetHashFunctions.getHashFunction` (`JDK`, `CRC`, `RANDOM`, `MURMUR3`).
        static func named(_ name: String) throws -> HashFunction {
            switch name {
            case "JDK": return .jdkArrayHash
            case "CRC": return .crcHash
            case "RANDOM": return .randomHash
            case "MURMUR3": return .murmur3
            default: throw RankedSetError.invalidConfig("hash function not found: \(name)")
            }
        }
    }

    // MARK: - Config

    /// `log2` of the fan-out between levels (Java `LEVEL_FAN_POW`).
    static let levelFanPow = 4
    /// Java `MAX_LEVELS` = `Integer.SIZE / LEVEL_FAN_POW`.
    static let maxLevels = 32 / levelFanPow
    /// Java `DEFAULT_LEVELS`.
    static let defaultLevels = 6
    /// `2^(l * LEVEL_FAN_POW) - 1` per level (Java `LEVEL_FAN_VALUES`).
    static let levelFanValues: [Int32] = (0 ..< maxLevels).map { level in
        Int32(truncatingIfNeeded: (1 << (level * levelFanPow)) - 1)
    }

    /// Index option names consumed by `RankedSetIndexHelper.getConfig` (Java `IndexOptions`).
    enum IndexOptionKeys {
        static let hashFunction = "rankHashFunction"
        static let nlevels = "rankNLevels"
        static let countDuplicates = "rankCountDuplicates"
    }

    /// Configuration mirroring Java `RankedSet.Config`.
    struct Config: Sendable {
        /// The hash that determines the level splits. Default: ``HashFunction/jdkArrayHash``.
        var hashFunction: HashFunction
        /// The number of skip-list levels (2 ... ``RankedSet/maxLevels``). Default: 6.
        /// Changing this for an existing set is not supported.
        let nlevels: Int
        /// Whether duplicate keys are counted separately (raising the ranks above them). Default: false.
        var countDuplicates: Bool

        /// Java `RankedSet.DEFAULT_CONFIG`: JDK hash, 6 levels, duplicates not counted.
        static let `default` = Config()

        init(hashFunction: HashFunction = .default,
             nlevels: Int = RankedSet.defaultLevels,
             countDuplicates: Bool = false) {
            precondition(nlevels >= 2 && nlevels <= RankedSet.maxLevels,
                         "levels must be between 2 and \(RankedSet.maxLevels)")
            self.hashFunction = hashFunction
            self.nlevels = nlevels
            self.countDuplicates = countDuplicates
        }

        /// Parses the standard rank index options, mirroring `RankedSetIndexHelper.getConfig`:
        /// `rankHashFunction` (a ``HashFunction/named(_:)`` name), `rankNLevels`
        /// (`Integer.parseInt`, 2...8) and `rankCountDuplicates` (`Boolean.parseBoolean`:
        /// case-insensitive `"true"`, anything else false). Absent options take the defaults.
        init(indexOptions options: [String: String]) throws {
            var hashFunction = HashFunction.default
            var nlevels = RankedSet.defaultLevels
            var countDuplicates = false
            if let name = options[IndexOptionKeys.hashFunction] {
                hashFunction = try HashFunction.named(name)
            }
            if let levels = options[IndexOptionKeys.nlevels] {
                guard let parsed = Int32(levels) else {
                    throw RankedSetError.invalidConfig("invalid \(IndexOptionKeys.nlevels): \(levels)")
                }
                guard parsed >= 2 && Int(parsed) <= RankedSet.maxLevels else {
                    throw RankedSetError.invalidConfig("levels must be between 2 and \(RankedSet.maxLevels)")
                }
                nlevels = Int(parsed)
            }
            if let duplicates = options[IndexOptionKeys.countDuplicates] {
                countDuplicates = duplicates.lowercased() == "true"
            }
            self.init(hashFunction: hashFunction, nlevels: nlevels, countDuplicates: countDuplicates)
        }
    }

    // MARK: - State

    /// The subspace holding this ranked set.
    let subspace: Subspace
    /// The configuration.
    let config: Config

    init(subspace: Subspace, config: Config = .default) {
        self.subspace = subspace
        self.config = config
    }

    // MARK: - Initialization

    /// Writes the per-level sentinel `(level, b"") = 0` for each level that lacks one.
    ///
    /// Reads each sentinel non-snapshot (as Java does); callers that only want to initialize
    /// when needed should check ``initNeeded(_:snapshot:)`` with a snapshot read first, as
    /// `RankedSetIndexHelper.init` does, to avoid conflicting with concurrent atomic adds.
    func `init`(_ tr: any TransactionProtocol) async throws {
        try await initLevels(tr)
    }

    /// Whether ``init(_:)`` needs to be called (the level-0 sentinel is absent).
    func initNeeded(_ tr: any TransactionProtocol, snapshot: Bool = false) async throws -> Bool {
        try await countCheckedKey(tr, [], snapshot: snapshot) == nil
    }

    // MARK: - Mutations

    /// Adds `key` to the set.
    ///
    /// - Returns: `false` if the key was already present and duplicates are not counted;
    ///   otherwise `true` (a counted duplicate raises the ranks above it by one).
    @discardableResult
    func add(_ tr: any TransactionProtocol, key: FDB.Bytes) async throws -> Bool {
        try Self.checkKey(key)
        let keyHash = config.hashFunction.hash(key)
        let count = try await countCheckedKey(tr, key, snapshot: false)
        let duplicate = (count ?? 0) > 0
        if duplicate && !config.countDuplicates {
            return false
        }
        let nlevels = config.nlevels
        addLevelZeroKey(tr, key, increment: duplicate)
        // Because each level's mask contains the previous level's, the levels the key is
        // inserted into (hash bits zero, not a duplicate) form a prefix 1..<firstIncrement; every
        // later level only increments a predecessor's count. Java runs each insert after all
        // lower levels complete and the increments in parallel; this is the same schedule.
        var level = 1
        while level < nlevels && !duplicate && (keyHash & Self.levelFanValues[level]) == 0 {
            try await addInsertLevelKey(tr, key, level: level)
            level += 1
        }
        let firstIncrement = level
        try await withThrowingTaskGroup(of: Void.self) { group in
            for level in firstIncrement ..< nlevels {
                group.addTask {
                    try await addIncrementLevelKey(tr, key, level: level, orEqual: duplicate)
                }
            }
            try await group.waitForAll()
        }
        return true
    }

    /// Removes one occurrence of `key`.
    ///
    /// - Returns: `true` if the key was present (and so the set was modified).
    @discardableResult
    func remove(_ tr: any TransactionProtocol, key: FDB.Bytes) async throws -> Bool {
        try Self.checkKey(key)
        guard let count = try await countCheckedKey(tr, key, snapshot: false), count > 0 else {
            return false
        }
        // Works even if this set does not count duplicates but an earlier one did.
        let duplicate = count > 1
        if duplicate {
            // Always subtract one, never clearing a count key. Concurrent removes both
            // subtracting from two conflict on the level-0 key (already read), so no atomic op.
            tr.setValue(Self.encodeLong(count - 1), for: levelKey(0, key))
        } else {
            tr.clear(key: levelKey(0, key))
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for level in 1 ..< config.nlevels {
                group.addTask {
                    if duplicate {
                        let prevKey = try await getPreviousKey(tr, level: level, key: key, orEqual: true)
                        tr.atomicOp(key: levelKey(level, prevKey), param: Self.encodeLong(-1), mutationType: .add)
                    } else {
                        // Does not consult the hash to decide which levels hold the key, so the
                        // hash function may change (or be random); counts never reach zero.
                        let k = levelKey(level, key)
                        async let current = tr.getValue(for: k, snapshot: false)
                        async let previous = getPreviousKey(tr, level: level, key: key, orEqual: false)
                        let (c, prevKey) = try await (current, previous)
                        var countChange: Int64 = -1
                        if let c {
                            // Give the erased key's remaining count back to its neighbor.
                            countChange += try Self.decodeLong(c)
                            tr.clear(key: k)
                        }
                        tr.atomicOp(key: levelKey(level, prevKey), param: Self.encodeLong(countChange), mutationType: .add)
                    }
                }
            }
            try await group.waitForAll()
        }
        return true
    }

    /// Clears the whole set and re-writes the level sentinels.
    func clear(_ tr: any TransactionProtocol) async throws {
        let range = subspace.range
        tr.clearRange(beginKey: range.begin, endKey: range.end)
        try await initLevels(tr)
    }

    // MARK: - Reads

    /// Whether `key` is present.
    func contains(_ tr: any TransactionProtocol, key: FDB.Bytes, snapshot: Bool = false) async throws -> Bool {
        try Self.checkKey(key)
        return (try await countCheckedKey(tr, key, snapshot: snapshot) ?? 0) > 0
    }

    /// The number of occurrences of `key`: 0 if absent, 1 if present and duplicates are not
    /// counted, else the duplicate count.
    func count(_ tr: any TransactionProtocol, key: FDB.Bytes, snapshot: Bool = false) async throws -> Int64 {
        try Self.checkKey(key)
        return try await countCheckedKey(tr, key, snapshot: snapshot) ?? 0
    }

    /// The `rank`th element (0-based), also called *select*; `nil` when out of bounds.
    func getNth(_ tr: any TransactionProtocol, rank: Int64, snapshot: Bool = false) async throws -> FDB.Bytes? {
        if rank < 0 {
            return nil
        }
        var rank = rank
        var key: FDB.Bytes = []
        for level in stride(from: config.nlevels - 1, through: 0, by: -1) {
            let levelSubspace = subspace.subspace(Tuple(level))
            let begin = levelSubspace.pack(Tuple([key as any TupleElement]))
            var descend = false
            var found = false
            try await scan(tr, begin: .firstGreaterOrEqual(begin), end: .firstGreaterOrEqual(levelSubspace.range.end),
                           snapshot: snapshot) { k, v in
                key = try Self.decodeKeyBytes(levelSubspace, k, index: 0)
                if rank == 0 && !key.isEmpty {
                    // Moved along to exactly the right rank: this is the key.
                    found = true
                    return false
                }
                let count = try Self.decodeLong(v)
                if count > rank {
                    // Narrow the search on the next finer level.
                    descend = true
                    return false
                }
                rank -= count
                return true
            }
            if found {
                return key
            }
            if !descend {
                // Not enough elements on this level.
                return nil
            }
        }
        // Down to the finest level without landing exactly on the rank: only possible within a
        // run of counted duplicates.
        return config.countDuplicates ? key : nil
    }

    /// The keys in `[beginKey, endKey)` in order (Java `getRangeList`).
    func getRange(_ tr: any TransactionProtocol, beginKey: FDB.Bytes, endKey: FDB.Bytes, snapshot: Bool = false) async throws -> [FDB.Bytes] {
        try Self.checkKey(beginKey)
        var keys: [FDB.Bytes] = []
        try await scan(tr, begin: .firstGreaterOrEqual(levelKey(0, beginKey)), end: .firstGreaterOrEqual(levelKey(0, endKey)),
                       snapshot: snapshot) { k, _ in
            keys.append(try Self.decodeKeyBytes(subspace, k, index: 1))
            return true
        }
        return keys
    }

    /// The 0-based rank of `key`.
    ///
    /// - Parameter nullIfMissing: when `true` (the default) returns `nil` for an absent key;
    ///   when `false` returns the rank the key would have if it were present. As in Java, with
    ///   ``Config/countDuplicates`` an absent key's rank is `rank(predecessor) + 1`, not
    ///   `rank(predecessor) + count(predecessor)` (level 0 adds one past the last entry).
    func rank(_ tr: any TransactionProtocol, key: FDB.Bytes, nullIfMissing: Bool = true, snapshot: Bool = false) async throws -> Int64? {
        try Self.checkKey(key)
        if nullIfMissing {
            guard let count = try await countCheckedKey(tr, key, snapshot: snapshot), count > 0 else {
                return nil
            }
            return try await rankLookup(tr, key, keyShouldBePresent: true, snapshot: snapshot)
        }
        return try await rankLookup(tr, key, keyShouldBePresent: false, snapshot: snapshot)
    }

    /// The number of elements (sum of the coarsest level's counts).
    func size(_ tr: any TransactionProtocol, snapshot: Bool = false) async throws -> Int64 {
        let range = subspace.range(Tuple(config.nlevels - 1))
        return try await sumCounts(tr, begin: range.begin, end: range.end, snapshot: snapshot)
    }

    /// Reads the last `nlevels` keys of the set (the sparse upper levels) to warm the
    /// read-your-writes cache before lookups. `RankedSetIndexHelper` issues it as a snapshot read.
    func preloadForLookup(_ tr: any TransactionProtocol, snapshot: Bool = true) async throws {
        let range = subspace.range
        _ = try await tr.getRangeNative(
            beginSelector: .firstGreaterOrEqual(range.begin), endSelector: .firstGreaterOrEqual(range.end),
            limit: config.nlevels, snapshot: snapshot, reverse: true)
    }

    // MARK: - Consistency (testing aid; Java `checkConsistency`)

    struct Consistency: Sendable, CustomStringConvertible {
        var isConsistent: Bool
        var level = 0
        var prevCount: Int64 = 0
        var count: Int64 = 0
        var description: String {
            "Consistency{consistent:\(isConsistent), level:\(level), prevCount:\(prevCount), count:\(count)}"
        }
    }

    /// Verifies that every count on levels `1..<nlevels` equals the sum of the finer level's
    /// counts it spans.
    func checkConsistency(_ tr: any TransactionProtocol) async throws -> Consistency {
        for level in 1 ..< config.nlevels {
            var prevKey: FDB.Bytes?
            var prevCount: Int64 = 0
            let range = subspace.range(Tuple(level))
            var entries: [(FDB.Bytes, Int64)] = []
            try await scan(tr, begin: .firstGreaterOrEqual(range.begin), end: .firstGreaterOrEqual(range.end),
                           snapshot: false) { k, v in
                entries.append((try Self.decodeKeyBytes(subspace, k, index: 1), try Self.decodeLong(v)))
                return true
            }
            for index in 0 ... entries.count {
                let next: FDB.Bytes? = index < entries.count ? entries[index].0 : nil
                if let prevKey {
                    let count = try await countRange(tr, level: level - 1, beginKey: prevKey, endKey: next)
                    if prevCount != count {
                        return Consistency(isConsistent: false, level: level, prevCount: prevCount, count: count)
                    }
                }
                if index < entries.count {
                    prevKey = entries[index].0
                    prevCount = entries[index].1
                }
            }
        }
        return Consistency(isConsistent: true)
    }

    // MARK: - Internal

    private static func checkKey(_ key: FDB.Bytes) throws {
        if key.isEmpty {
            throw RankedSetError.emptyKey
        }
    }

    /// `subspace.pack(Tuple.from(level, key))`.
    private func levelKey(_ level: Int, _ key: FDB.Bytes) -> FDB.Bytes {
        subspace.pack(Tuple([level as any TupleElement, key as any TupleElement]))
    }

    private func countCheckedKey(_ tr: any TransactionProtocol, _ key: FDB.Bytes, snapshot: Bool) async throws -> Int64? {
        guard let value = try await tr.getValue(for: levelKey(0, key), snapshot: snapshot) else {
            return nil
        }
        return try Self.decodeLong(value)
    }

    private func addLevelZeroKey(_ tr: any TransactionProtocol, _ key: FDB.Bytes, increment: Bool) {
        let k = levelKey(0, key)
        let v = Self.encodeLong(1)
        if increment {
            tr.atomicOp(key: k, param: v, mutationType: .add)
        } else {
            tr.setValue(v, for: k)
        }
    }

    private func addIncrementLevelKey(_ tr: any TransactionProtocol, _ key: FDB.Bytes, level: Int, orEqual: Bool) async throws {
        let prevKey = try await getPreviousKey(tr, level: level, key: key, orEqual: orEqual)
        tr.atomicOp(key: levelKey(level, prevKey), param: Self.encodeLong(1), mutationType: .add)
    }

    private func addInsertLevelKey(_ tr: any TransactionProtocol, _ key: FDB.Bytes, level: Int) async throws {
        let prevKey = try await getPreviousKey(tr, level: level, key: key, orEqual: false)
        async let prevValue = tr.getValue(for: levelKey(level, prevKey), snapshot: false)
        async let newPrevCountF = countRange(tr, level: level - 1, beginKey: prevKey, endKey: key)
        let (prevBytes, newPrevCount) = try await (prevValue, newPrevCountF)
        guard let prevBytes else { throw RankedSetError.malformedCount }
        let prevCount = try Self.decodeLong(prevBytes)
        let count = prevCount - newPrevCount + 1
        tr.setValue(Self.encodeLong(newPrevCount), for: levelKey(level, prevKey))
        tr.setValue(Self.encodeLong(count), for: levelKey(level, key))
    }

    private func rankLookup(_ tr: any TransactionProtocol, _ key: FDB.Bytes, keyShouldBePresent: Bool, snapshot: Bool) async throws -> Int64 {
        var rankKey: FDB.Bytes = []
        var rank: Int64 = 0
        for level in stride(from: config.nlevels - 1, through: 0, by: -1) {
            let levelSubspace = subspace.subspace(Tuple(level))
            var lastCount: Int64 = 0
            try await scan(tr,
                           begin: .firstGreaterOrEqual(levelSubspace.pack(Tuple([rankKey as any TupleElement]))),
                           end: .firstGreaterThan(levelSubspace.pack(Tuple([key as any TupleElement]))),
                           snapshot: snapshot) { k, v in
                rankKey = try Self.decodeKeyBytes(levelSubspace, k, index: 0)
                lastCount = try Self.decodeLong(v)
                rank += lastCount
                return true
            }
            // Totalled this level: back off the last entry and descend from it.
            rank -= lastCount
            if rankKey == key {
                // Exact match on this level: no need for finer levels.
                break
            }
            if !keyShouldBePresent && level == 0 && lastCount > 0 {
                // An absent key ranks just after the last key below it — unless it is below every
                // key, which shows as the level-0 sentinel's zero count.
                rank += 1
            }
        }
        return rank
    }

    /// Sum of the counts on `level` in `[beginKey, endKey)`; `nil` bounds mean the level's ends.
    private func countRange(_ tr: any TransactionProtocol, level: Int, beginKey: FDB.Bytes?, endKey: FDB.Bytes?) async throws -> Int64 {
        let levelRange = subspace.range(Tuple(level))
        let begin = beginKey.map { levelKey(level, $0) } ?? levelRange.begin
        let end = endKey.map { levelKey(level, $0) } ?? levelRange.end
        return try await sumCounts(tr, begin: begin, end: end, snapshot: false)
    }

    private func sumCounts(_ tr: any TransactionProtocol, begin: FDB.Bytes, end: FDB.Bytes, snapshot: Bool) async throws -> Int64 {
        var total: Int64 = 0
        try await scan(tr, begin: .firstGreaterOrEqual(begin), end: .firstGreaterOrEqual(end), snapshot: snapshot) { _, v in
            total += try Self.decodeLong(v)
            return true
        }
        return total
    }

    /// Reads `[begin, end)` forward batch by batch, feeding each pair to `body` until it returns
    /// `false` or the range ends.
    ///
    /// Deliberately not `FDB.AsyncKVSequence`: that iterator always prefetches the next batch in a
    /// detached task, so stopping early (as `getNth` does) would leave a read in flight that can
    /// race the commit ("Operation issued while a commit was outstanding") and would add read
    /// conflicts for rows never consumed. This loop only reads the batches it consumes.
    private func scan(
        _ tr: any TransactionProtocol, begin: FDB.KeySelector, end: FDB.KeySelector, snapshot: Bool,
        _ body: (FDB.Bytes, FDB.Bytes) throws -> Bool
    ) async throws {
        var begin = begin
        while true {
            let batch = try await tr.getRangeNative(
                beginSelector: begin, endSelector: end, limit: 0, snapshot: snapshot, reverse: false)
            for (k, v) in batch.records {
                if try !body(k, v) {
                    return
                }
            }
            guard batch.more, let last = batch.records.last else {
                return
            }
            begin = .firstGreaterThan(last.0)
        }
    }

    /// The key preceding `key` on `level` (or equal to it when `orEqual`), found with a snapshot
    /// read plus explicit read conflicts exactly as Java does:
    /// - unless it is `key` itself, `[prev + 0x00, levelKey(key))`, so a concurrent insert between
    ///   them conflicts (but incrementing `key` itself does not);
    /// - the level-0 key of the predecessor, so removing it entirely conflicts.
    private func getPreviousKey(_ tr: any TransactionProtocol, level: Int, key: FDB.Bytes, orEqual: Bool) async throws -> FDB.Bytes {
        let k = levelKey(level, key)
        let result = try await tr.getRangeNative(
            beginSelector: .firstGreaterOrEqual(levelKey(level, [])),
            endSelector: .firstGreaterOrEqual(orEqual ? k + [0x00] : k),
            limit: 1, snapshot: true, reverse: true)
        guard let prevk = result.records.first?.0 else {
            throw RankedSetError.noKeyFoundOnLevel(level)
        }
        if !orEqual || prevk != k {
            try tr.addConflictRange(beginKey: prevk + [0x00], endKey: k, type: .read)
        }
        let prevKey = try Self.decodeKeyBytes(subspace, prevk, index: 1)
        let levelZero = levelKey(0, prevKey)
        try tr.addConflictRange(beginKey: levelZero, endKey: levelZero + [0x00], type: .read)
        return prevKey
    }

    private func initLevels(_ tr: any TransactionProtocol) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for level in 0 ..< config.nlevels {
                group.addTask {
                    let k = levelKey(level, [])
                    if try await tr.getValue(for: k, snapshot: false) == nil {
                        tr.setValue(Self.encodeLong(0), for: k)
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    /// The byte-string element at `index` of `key` unpacked from `subspace`.
    private static func decodeKeyBytes(_ subspace: Subspace, _ key: FDB.Bytes, index: Int) throws -> FDB.Bytes {
        let elements = try subspace.unpack(key)
        guard index < elements.count, let bytes = elements[index] as? FDB.Bytes else {
            throw RankedSetError.malformedKey
        }
        return bytes
    }

    /// 8-byte little-endian (Java `ByteBuffer.order(LITTLE_ENDIAN).putLong`).
    static func encodeLong(_ value: Int64) -> FDB.Bytes {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    /// Reads the first 8 bytes little-endian (Java `ByteBuffer.order(LITTLE_ENDIAN).getLong`).
    static func decodeLong(_ bytes: FDB.Bytes) throws -> Int64 {
        guard bytes.count >= 8 else { throw RankedSetError.malformedCount }
        var value: UInt64 = 0
        for i in 0 ..< 8 {
            value |= UInt64(bytes[i]) << (8 * i)
        }
        return Int64(bitPattern: value)
    }
}

// MARK: - Hash implementations

/// IEEE CRC-32 (reflected polynomial 0xEDB88320), identical to `java.util.zip.CRC32` / zlib.
fileprivate enum CRC32 {
    private static let table: [UInt32] = (0 ..< 256).map { n in
        var c = UInt32(n)
        for _ in 0 ..< 8 {
            c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    static func checksum(_ bytes: FDB.Bytes) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// MurmurHash3 x86_32, identical to Guava `Hashing.murmur3_32_fixed(seed)`.
fileprivate enum Murmur3 {
    private static let c1: UInt32 = 0xCC9E_2D51
    private static let c2: UInt32 = 0x1B87_3593

    private static func mixK1(_ k: UInt32) -> UInt32 {
        var k1 = k &* c1
        k1 = (k1 << 15) | (k1 >> 17)
        return k1 &* c2
    }

    private static func mixH1(_ h: UInt32, _ k1: UInt32) -> UInt32 {
        var h1 = h ^ k1
        h1 = (h1 << 13) | (h1 >> 19)
        return h1 &* 5 &+ 0xE654_6B64
    }

    static func hash32(_ bytes: FDB.Bytes, seed: UInt32) -> UInt32 {
        var h1 = seed
        var i = 0
        while i + 4 <= bytes.count {
            let k1 = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
            h1 = mixH1(h1, mixK1(k1))
            i += 4
        }
        var k1: UInt32 = 0
        var shift: UInt32 = 0
        while i < bytes.count {
            k1 ^= UInt32(bytes[i]) << shift
            i += 1
            shift += 8
        }
        h1 ^= mixK1(k1)
        // fmix
        h1 ^= UInt32(truncatingIfNeeded: bytes.count)
        h1 ^= h1 >> 16
        h1 = h1 &* 0x85EB_CA6B
        h1 ^= h1 >> 13
        h1 = h1 &* 0xC2B2_AE35
        h1 ^= h1 >> 16
        return h1
    }
}
#endif
