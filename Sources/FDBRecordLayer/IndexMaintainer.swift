/*
 * IndexMaintainer.swift
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

/// FoundationDB's size limits, checked before writing so oversize entries fail with a clear
/// error instead of an opaque commit failure (Java's `checkKeyValueSizes`).
enum FDBLimits {
    static let maxKeySize = 10_000
    static let maxValueSize = 100_000
}

// MARK: - Dispatch

extension FDBRecordStore {
    /// Updates every index affected by a record change — Java's `updateSecondaryIndexes`.
    ///
    /// Each index is maintained according to its state:
    /// - readable / readable-unique-pending: always updated;
    /// - write-only: idempotent indexes are updated directly; non-idempotent ones (counts, sums,
    ///   rank with duplicates) only for records the build has already passed, so the build and
    ///   concurrent writes never both count the same record (Java's `updateWhileWriteOnly`);
    /// - disabled: skipped.
    func updateSecondaryIndexes(old: IndexableRecord?, new: IndexableRecord?) async throws {
        var seen = Set<String>()
        for record in [old, new].compactMap({ $0 }) {
            for index in record.recordType.indexes where seen.insert(index.name).inserted {
                // Records of a type that doesn't declare the index contribute nothing to it.
                let oldForIndex = old.flatMap { $0.recordType.indexes.contains { $0.name == index.name } ? $0 : nil }
                let newForIndex = new.flatMap { $0.recordType.indexes.contains { $0.name == index.name } ? $0 : nil }
                let maintainer = indexMaintainer(for: index)
                switch indexState(named: index.name) {
                case .disabled:
                    continue
                case .writeOnly:
                    try await maintainer.updateWhileWriteOnly(old: oldForIndex, new: newForIndex)
                case .readable, .readableUniquePending:
                    try await maintainer.update(old: oldForIndex, new: newForIndex)
                }
            }
        }
    }

    /// The maintainer for an index (Java's `getIndexMaintainer`).
    func indexMaintainer(for index: ErasedIndex) -> IndexMaintainer {
        IndexMaintainer(store: self, index: index)
    }

    /// Whether the unique index has any recorded uniqueness violation.
    func hasUniquenessViolations(_ index: ErasedIndex) async throws -> Bool {
        let (begin, end) = indexUniquenessViolationsSubspace(index).range
        let result = try await transaction.getRangeNative(
            beginSelector: .firstGreaterOrEqual(begin), endSelector: .firstGreaterOrEqual(end),
            limit: 1, snapshot: false)
        return !result.records.isEmpty
    }

    /// The recorded uniqueness violations of a unique index: (indexed value, primary key,
    /// conflicting primary key).
    public func scanUniquenessViolations(indexNamed name: String) async throws -> [(value: Tuple, primaryKey: Tuple, existingKey: Tuple?)] {
        let index = try erasedIndexOrThrow(name)
        let space = indexUniquenessViolationsSubspace(index)
        let (begin, end) = space.range
        let pkCount = index.primaryKeyColumnCount
        var result: [(Tuple, Tuple, Tuple?)] = []
        for try await (key, value) in transaction.getRange(beginKey: begin, endKey: end) {
            let elements = try space.unpack(key)
            let valueKey = Tuple(Array(elements.dropLast(pkCount)))
            let pk = Tuple(Array(elements.suffix(pkCount)))
            let existing = value.isEmpty ? nil : Tuple(try Tuple.decode(from: value))
            result.append((valueKey, pk, existing))
        }
        return result
    }
}

// MARK: - Maintainer

/// Computes and applies index changes for one index — the union of Java's
/// `StandardIndexMaintainer` subclasses (`ValueIndexMaintainer`, `AtomicMutationIndexMaintainer`,
/// `VersionIndexMaintainer`, `RankIndexMaintainer`), writing the same keys and values.
struct IndexMaintainer {
    let store: FDBRecordStore
    let index: ErasedIndex

    var transaction: any TransactionProtocol { store.transaction }
    var indexSubspace: Subspace { store.indexSubspace(index) }

    /// Java's `AtomicMutation.Standard` for atomic index types.
    enum AtomicMutation {
        case count, countUpdates, countNotNull, sumLong, maxEverTuple, minEverTuple
        case maxEverLong, minEverLong, maxEverVersion
        case countClearWhenZero, countNotNullClearWhenZero, sumLongClearWhenZero

        var isIdempotent: Bool {
            switch self {
            case .count, .countUpdates, .countNotNull, .sumLong,
                 .countClearWhenZero, .countNotNullClearWhenZero, .sumLongClearWhenZero:
                return false
            default:
                return true
            }
        }

        var mutationType: FDB.MutationType {
            switch self {
            case .count, .countUpdates, .countNotNull, .sumLong,
                 .countClearWhenZero, .countNotNullClearWhenZero, .sumLongClearWhenZero:
                return .add
            case .maxEverTuple: return .byteMax
            case .minEverTuple: return .byteMin
            case .maxEverLong: return .max
            case .minEverLong: return .min
            case .maxEverVersion: return .setVersionstampedValue
            }
        }

        var clearsWhenZero: Bool {
            self == .countClearWhenZero || self == .countNotNullClearWhenZero || self == .sumLongClearWhenZero
        }

        var allowsNegative: Bool { self != .minEverLong && self != .maxEverLong }
    }

    var atomicMutation: AtomicMutation? {
        switch index.type {
        case .count: return index.clearWhenZero ? .countClearWhenZero : .count
        case .countUpdates: return .countUpdates
        case .countNotNull: return index.clearWhenZero ? .countNotNullClearWhenZero : .countNotNull
        case .sum: return index.clearWhenZero ? .sumLongClearWhenZero : .sumLong
        case .minEverTuple: return .minEverTuple
        case .maxEverTuple: return .maxEverTuple
        case .minEverLong: return .minEverLong
        case .maxEverLong: return .maxEverLong
        case .maxEverVersion: return .maxEverVersion
        case .value, .min, .max, .version, .rank, .text, .timeWindowLeaderboard: return nil
        }
    }

    /// The ranked-set configuration from the index's options (Java's
    /// `RankedSetIndexHelper.getConfig`); invalid options fall back to the defaults.
    var rankConfig: RankedSet.Config {
        (try? RankedSet.Config(indexOptions: index.options)) ?? .default
    }

    /// Java's `isIdempotent`: whether applying an update twice leaves the index unchanged.
    var isIdempotent: Bool {
        if let atomicMutation { return atomicMutation.isIdempotent }
        switch index.type {
        case .rank: return !rankConfig.countDuplicates
        case .text: return TextIndexMaintainer.isIdempotent(index)
        case .timeWindowLeaderboard: return TimeWindowLeaderboardMaintainer.isIdempotent(index)
        default: return true
        }
    }

    /// Java's `skipUpdateForUnchangedKeys`: `count_updates` counts every save.
    var skipUpdateForUnchangedKeys: Bool { index.type != .countUpdates }

    // MARK: Update

    /// Java's `StandardIndexMaintainer.update` (text and leaderboard indexes override it, as in Java).
    func update(old: IndexableRecord?, new: IndexableRecord?) async throws {
        switch index.type {
        case .text:
            try await TextIndexMaintainer.update(self, old: old, new: new)
            return
        case .timeWindowLeaderboard:
            try await TimeWindowLeaderboardMaintainer.update(self, old: old, new: new)
            return
        default:
            break
        }
        var oldEntries = old.map { $0.entries(for: index) } ?? []
        var newEntries = new.map { $0.entries(for: index) } ?? []
        if old != nil, new != nil, skipUpdateForUnchangedKeys {
            let oldKeys = oldEntries.map { Tuple($0).encode() }
            let newKeys = Set(newEntries.map { Tuple($0).encode() })
            let common = Set(oldKeys).intersection(newKeys)
            if !common.isEmpty {
                oldEntries.removeAll { common.contains(Tuple($0).encode()) }
                newEntries.removeAll { common.contains(Tuple($0).encode()) }
            }
        }
        if let old, !oldEntries.isEmpty { try await updateIndexKeys(old, remove: true, oldEntries) }
        if let new, !newEntries.isEmpty { try await updateIndexKeys(new, remove: false, newEntries) }
    }

    /// Java's `updateWhileWriteOnly`: idempotent indexes update directly; others only for
    /// records inside the build's already-built ranges. What a "range" is depends on how the
    /// index is being built (its indexing type stamp): primary keys for the by-records methods,
    /// source-index entry keys for BY_INDEX.
    func updateWhileWriteOnly(old: IndexableRecord?, new: IndexableRecord?) async throws {
        if isIdempotent {
            try await update(old: old, new: new)
            return
        }
        let stamp = try await store.loadIndexingTypeStamp(index)
        switch stamp?.method {
        case nil, .byRecords?, .multiTargetByRecords?, .mutualByRecords?:
            // A missing stamp: either the build has not started (nothing is built, so nothing is
            // updated) or a by-records build that did not write one.
            guard let primaryKey = (old ?? new).map({ $0.buildRangeKey ?? $0.primaryKey }) else { return }
            // Non-snapshot: if the indexer later builds this range, one of us conflicts.
            if try await isBuilt(rangeKey: primaryKey) {
                try await update(old: old, new: new)
            }
        case .byIndex?:
            let sourceKey = stamp!.sourceIndexSubspaceKey ?? []
            guard let source = store.metaData.allIndexes.first(where: { $0.subspaceTupleKey.encode() == sourceKey }) else {
                throw RecordStoreError.unknownIndex("source index with subspace key \(RangeSet.printable(sourceKey))")
            }
            try await updateWriteOnlyByIndex(source: source, old: old, new: new)
        default:
            throw RecordStoreError.unsupportedStoreFeature("index build method \(stamp!.method)")
        }
    }

    /// Whether the build has covered `rangeKey` (Java's `addedRangeWithKey`), with a read
    /// conflict on that key so a concurrent build of it conflicts with this transaction.
    private func isBuilt(rangeKey: Tuple) async throws -> Bool {
        try await store.indexRangeSet(index).contains(transaction, key: rangeKey.encode())
    }

    /// Java's `StandardIndexMaintainer.updateWriteOnlyByIndex`: the build's range set is keyed by
    /// the source index's entry keys, so each side of the change is applied only if its source
    /// entry is already in a built range.
    private func updateWriteOnlyByIndex(source: ErasedIndex, old: IndexableRecord?, new: IndexableRecord?) async throws {
        let oldEntryKey = try Self.singletonEntryKey(source, old)
        let newEntryKey = try Self.singletonEntryKey(source, new)
        switch (oldEntryKey, newEntryKey) {
        case let (oldKey?, newKey?):
            if oldKey.encode() == newKey.encode() {
                if try await isBuilt(rangeKey: oldKey) { try await update(old: old, new: new) }
            } else {
                // Different source entries: remove the old (if built) and add the new (if built).
                let oldBuilt = try await isBuilt(rangeKey: oldKey)
                let newBuilt = try await isBuilt(rangeKey: newKey)
                if oldBuilt { try await update(old: old, new: nil) }
                if newBuilt { try await update(old: nil, new: new) }
            }
        case let (key?, nil), let (nil, key?):
            if try await isBuilt(rangeKey: key) { try await update(old: old, new: new) }
        case (nil, nil):
            // Neither record is in the source index, so neither is in this one.
            return
        }
    }

    /// Java's `evaluateSingletonIndexKey`: the record's single entry key in a source index (the
    /// indexed value followed by the primary key), or `nil` if it has no entry there.
    static func singletonEntryKey(_ source: ErasedIndex, _ record: IndexableRecord?) throws -> Tuple? {
        guard let record, record.recordType.indexes.contains(where: { $0.name == source.name }) else { return nil }
        let entries = record.entries(for: source)
        if entries.isEmpty { return nil }
        guard entries.count == 1 else {
            throw RecordStoreError.unsupportedStoreFeature(
                "index \(source.name) produced \(entries.count) entries for use as a source index")
        }
        return Tuple(entries[0] + record.primaryKey.elements)
    }

    private func updateIndexKeys(_ record: IndexableRecord, remove: Bool, _ entries: [[any TupleElement]]) async throws {
        if let atomicMutation {
            try updateAtomic(record, remove: remove, entries, atomicMutation)
            return
        }
        for entry in entries {
            switch index.type {
            case .version:
                try updateVersionKey(record, remove: remove, entry)
            case .rank:
                try await updateValueKey(record, remove: remove, entry)
                try await updateRankedSet(record, remove: remove, entry)
            default:
                try await updateValueKey(record, remove: remove, entry)
            }
        }
    }

    // MARK: Value (and unique) entries

    private func updateValueKey(_ record: IndexableRecord, remove: Bool, _ valueKey: [any TupleElement]) async throws {
        let keyBytes = indexSubspace.prefix + Tuple(valueKey).encode() + record.primaryKey.encode()
        if remove {
            transaction.clear(key: keyBytes)
            let state = store.indexState(named: index.name)
            if index.unique, state == .writeOnly || state == .readableUniquePending {
                try await removeUniquenessViolations(valueKey: valueKey, primaryKey: record.primaryKey)
            }
            return
        }
        try checkKeySize(keyBytes)
        if index.unique, !Self.containsNull(valueKey) {
            try await checkUniqueness(record, valueKey: valueKey)
        }
        transaction.setValue([], for: keyBytes)
    }

    /// Java's `checkUniqueness`: any other primary key under the same value is a violation —
    /// recorded (both ways) while the index is write-only, an error otherwise. The non-snapshot
    /// range read makes concurrent inserts of the same value conflict.
    private func checkUniqueness(_ record: IndexableRecord, valueKey: [any TupleElement]) async throws {
        let prefix = indexSubspace.prefix + Tuple(valueKey).encode()
        let pkCount = index.primaryKeyColumnCount
        let writeOnly = store.indexState(named: index.name) == .writeOnly
        for try await (existing, _) in transaction.getRange(beginKey: prefix, endKey: prefix + [0xFF]) {
            let existingPK = Tuple(Array(try Tuple.decode(from: Array(existing.dropFirst(prefix.count))).suffix(pkCount)))
            guard existingPK.encode() != record.primaryKey.encode() else { continue }
            if writeOnly {
                addUniquenessViolation(valueKey: valueKey, primaryKey: record.primaryKey, existingKey: existingPK)
                addUniquenessViolation(valueKey: valueKey, primaryKey: existingPK, existingKey: record.primaryKey)
            } else {
                throw RecordStoreError.uniquenessViolation(index: index.name)
            }
        }
    }

    private func addUniquenessViolation(valueKey: [any TupleElement], primaryKey: Tuple, existingKey: Tuple?) {
        let key = store.indexUniquenessViolationsSubspace(index).prefix + Tuple(valueKey).encode() + primaryKey.encode()
        transaction.setValue(existingKey?.encode() ?? [], for: key)
    }

    /// Java's `removeUniquenessViolationsAsync`: drop this record's violation and, if only one
    /// record remains under the value, that last one too.
    private func removeUniquenessViolations(valueKey: [any TupleElement], primaryKey: Tuple) async throws {
        let valueSpace = store.indexUniquenessViolationsSubspace(index).subspace(Tuple(valueKey))
        transaction.clear(key: valueSpace.prefix + primaryKey.encode())
        let (begin, end) = valueSpace.range
        let remaining = try await transaction.getRangeNative(
            beginSelector: .firstGreaterOrEqual(begin), endSelector: .firstGreaterOrEqual(end),
            limit: 2, snapshot: false)
        if remaining.records.count == 1 {
            transaction.clear(key: remaining.records[0].0)
        }
    }

    /// Java's `IndexEntry.keyContainsNonUniqueNull`: nulls never collide in unique indexes.
    static func containsNull(_ columns: [any TupleElement]) -> Bool {
        columns.contains { $0 is NullValue }
    }

    private func checkKeySize(_ key: FDB.Bytes) throws {
        if key.count > FDBLimits.maxKeySize {
            throw RecordStoreError.keyTooLarge(index: index.name, size: key.count)
        }
    }

    // MARK: Version entries

    /// Java's `VersionIndexMaintainer.updateOneKeyAsync`: an entry whose version is incomplete
    /// (saved in this transaction) is a buffered versionstamped-key mutation, so a later save or
    /// delete in the same transaction can cancel it.
    private func updateVersionKey(_ record: IndexableRecord, remove: Bool, _ valueKey: [any TupleElement]) throws {
        let entry = Tuple(valueKey + record.primaryKey.elements)
        let hasIncomplete = valueKey.contains { ($0 as? Versionstamp)?.isIncomplete == true }
        guard valueKey.contains(where: { $0 is Versionstamp }) else {
            throw RecordStoreError.missingLocalVersion(index: index.name)
        }
        if hasIncomplete {
            let keyBytes = try indexSubspace.packWithVersionstamp(entry)
            if remove {
                store.context.removeVersionMutation(key: keyBytes)
            } else {
                try checkKeySize(keyBytes)
                store.context.addVersionMutation(.setVersionstampedKey, key: keyBytes, value: [])
            }
        } else {
            let keyBytes = indexSubspace.pack(entry)
            if remove {
                transaction.clear(key: keyBytes)
            } else {
                try checkKeySize(keyBytes)
                transaction.setValue([], for: keyBytes)
            }
        }
    }

    // MARK: Atomic entries

    /// Java's `AtomicMutationIndexMaintainer.updateIndexKeys`.
    private func updateAtomic(_ record: IndexableRecord, remove: Bool, _ entries: [[any TupleElement]], _ mutation: AtomicMutation) throws {
        for entry in entries {
            let groupCount = max(0, entry.count - index.groupedCount)
            let group = Array(entry.prefix(groupCount))
            let grouped = Array(entry.dropFirst(groupCount))
            guard let param = try mutationParam(mutation, grouped: grouped, remove: remove) else { continue }
            if !mutation.allowsNegative, let value = grouped.first.flatMap(Self.integer), value < 0 {
                throw RecordStoreError.negativeValueInEverIndex(index: index.name)
            }
            let key = indexSubspace.pack(Tuple(group))
            if mutation == .maxEverVersion {
                if grouped.contains(where: { ($0 as? Versionstamp)?.isIncomplete == true }) {
                    // Keep only the largest incomplete version per group; all share the same
                    // placeholder global version, so byte order is local-version order.
                    store.context.updateVersionMutation(.setVersionstampedValue, key: key, value: param) { old, new in
                        old.lexicographicallyPrecedes(new) ? new : old
                    }
                } else {
                    transaction.atomicOp(key: key, param: param, mutationType: .byteMax)
                }
            } else {
                transaction.atomicOp(key: key, param: param, mutationType: mutation.mutationType)
                if mutation.clearsWhenZero {
                    transaction.atomicOp(key: key, param: Self.littleEndian(0), mutationType: .compareAndClear)
                }
            }
        }
    }

    /// Java's `AtomicMutation.Standard.getMutationParam`; `nil` means "no mutation".
    private func mutationParam(_ mutation: AtomicMutation, grouped: [any TupleElement], remove: Bool) throws -> FDB.Bytes? {
        switch mutation {
        case .countNotNull, .countNotNullClearWhenZero:
            return Self.containsNull(grouped) ? nil : Self.littleEndian(remove ? -1 : 1)
        case .count, .countClearWhenZero:
            return Self.littleEndian(remove ? -1 : 1)
        case .countUpdates:
            return remove ? nil : Self.littleEndian(1)
        case .sumLong, .sumLongClearWhenZero:
            guard let value = grouped.first.flatMap(Self.integer) else { return nil }
            // Wrapping negation: the sum is kept mod 2^64, so removing Int64.min still cancels.
            return Self.littleEndian(remove ? 0 &- value : value)
        case .maxEverLong, .minEverLong:
            guard !remove, let value = grouped.first.flatMap(Self.integer) else { return nil }
            return Self.littleEndian(value)
        case .maxEverVersion:
            guard !remove else { return nil }
            let tuple = Tuple(grouped)
            return grouped.contains { ($0 as? Versionstamp)?.isIncomplete == true }
                ? try tuple.packWithVersionstamp() : tuple.encode()
        case .maxEverTuple, .minEverTuple:
            return remove ? nil : Tuple(grouped).encode()
        }
    }

    static func integer(_ element: any TupleElement) -> Int64? {
        switch element {
        case let v as Int64: return v
        case let v as Int: return Int64(v)
        case let v as Int32: return Int64(v)
        case let v as UInt64: return Int64(bitPattern: v)
        case let v as Bool: return v ? 1 : 0
        default: return nil
        }
    }

    static func littleEndian(_ value: Int64) -> FDB.Bytes {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    static func decodeLittleEndian(_ bytes: FDB.Bytes) -> Int64 {
        var result: UInt64 = 0
        for (offset, byte) in bytes.prefix(8).enumerated() { result |= UInt64(byte) << (8 * UInt64(offset)) }
        return Int64(bitPattern: result)
    }

    // MARK: Rank

    /// Java's `RankIndexMaintainer.updateIndexKeys`: alongside the value entry, the score is
    /// added to / removed from the group's ranked set in the secondary subspace.
    private func updateRankedSet(_ record: IndexableRecord, remove: Bool, _ entry: [any TupleElement]) async throws {
        let groupCount = max(0, entry.count - index.groupedCount)
        let group = Tuple(Array(entry.prefix(groupCount)))
        let score = Tuple(Array(entry.dropFirst(groupCount))).encode()
        let config = rankConfig
        let rankedSet = RankedSet(subspace: store.indexSecondarySubspace(index).subspace(group), config: config)
        let valuePrefix = indexSubspace.prefix + Tuple(entry).encode()
        try await RankedSetIndexHelper.updateRankedSet(
            transaction, rankedSet: rankedSet, score: score, remove: remove,
            valueRange: (valuePrefix, valuePrefix + [0xFF]), config: config)
    }
}

extension FDBRecordStore {
    /// Loads how the index is being built (Java's `loadIndexingTypeStampAsync`).
    func loadIndexingTypeStamp(_ index: ErasedIndex) async throws -> IndexBuildIndexingStamp? {
        guard let bytes = try await transaction.getValue(for: indexingTypeStampKey(index)) else { return nil }
        return try IndexBuildIndexingStamp(decoding: bytes)
    }
}
#endif
