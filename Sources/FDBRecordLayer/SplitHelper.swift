/*
 * SplitHelper.swift
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
import Synchronization

// MARK: - Errors

/// Errors raised while splitting or reassembling records. Mirrors the exceptions thrown by the
/// Java Record Layer's `SplitHelper`.
enum SplitHelperError: Error, Sendable, Equatable {
    /// A version was supplied while saving in the legacy unsplit format (no suffix).
    case cannotIncludeVersionInOldUnsplitFormat
    /// Both the primary key and the value were to carry an incomplete versionstamp.
    case versionstampInKeyAndValue
    /// The record exceeds ``SplitHelper/splitRecordSize`` but splitting is disabled.
    /// (Java: `FDBStoreValueSizeException`.)
    case recordTooLong(valueSize: Int)
    /// Two writes used the same versionstamped key in one transaction.
    case keyWithVersionOverwritten
    /// A non-initial split chunk (or a lone version) was found without the record's first chunk.
    case foundSplitWithoutStart(nextIndex: Int64, reverse: Bool)
    /// Split chunks were not consecutive.
    case foundSplitOutOfOrder(expected: Int64, found: Int64)
    /// Both an unsplit value (suffix 0) and split chunks were found for one record.
    case unsplitFollowedBySplit
    /// More than one unsplit value was found for one record.
    case moreThanOneUnsplitValue
    /// A key in a record's subspace had more than one tuple element after the primary key.
    case expectedSingleKeyExtension
    /// A record-version key was found while reading with the old (separate) version format.
    case recordVersionInOldFormat
    /// A key's trailing suffix was not a valid split number.
    case invalidSplitNumber(String)
    /// A key or version value could not be decoded.
    case invalidEncoding(String)
}

// MARK: - Sizes

/// Size information about a record as stored in the database. Mirrors Java's `FDBStoredSizes`.
protocol FDBStoredSizes: Sendable {
    /// Number of keys used to store the record (including the version key, if any).
    var keyCount: Int { get }
    /// Total byte length of those keys.
    var keySize: Int { get }
    /// Total byte length of those values.
    var valueSize: Int { get }
    /// Whether the record was split across more than one data key.
    var isSplit: Bool { get }
    /// Whether the record's version is stored inline (at suffix `-1`) with the record.
    var isVersionedInline: Bool { get }
}

/// A record as read from (or written to) the database, before deserialization: the primary key,
/// the reassembled serialized bytes, the inline version (if any), and how it was stored.
/// Mirrors Java's `FDBRawRecord`.
struct FDBRawRecord: FDBStoredSizes, Sendable, Equatable {
    let primaryKey: Tuple
    let rawRecord: FDB.Bytes
    let version: FDBRecordVersion?
    let keyCount: Int
    let keySize: Int
    let valueSize: Int
    let isSplit: Bool
    let isVersionedInline: Bool

    init(primaryKey: Tuple, rawRecord: FDB.Bytes, version: FDBRecordVersion?, sizes: any FDBStoredSizes) {
        self.init(
            primaryKey: primaryKey, rawRecord: rawRecord, version: version,
            keyCount: sizes.keyCount, keySize: sizes.keySize, valueSize: sizes.valueSize,
            isSplit: sizes.isSplit, isVersionedInline: sizes.isVersionedInline)
    }

    init(
        primaryKey: Tuple, rawRecord: FDB.Bytes, version: FDBRecordVersion?,
        keyCount: Int, keySize: Int, valueSize: Int, isSplit: Bool, isVersionedInline: Bool
    ) {
        self.primaryKey = primaryKey
        self.rawRecord = rawRecord
        self.version = version
        self.keyCount = keyCount
        self.keySize = keySize
        self.valueSize = valueSize
        self.isSplit = isSplit
        self.isVersionedInline = isVersionedInline
    }

    var hasVersion: Bool { version != nil }
}

// MARK: - Version helpers

extension FDBRecordVersion {
    /// The global-version placeholder of an incomplete version (Java's
    /// `INCOMPLETE_GLOBAL_VERSION`): ten `0xFF` bytes, identical to the tuple layer's incomplete
    /// ``Versionstamp`` placeholder.
    static let incompleteGlobalVersion = FDB.Bytes(repeating: 0xFF, count: 10)

    /// An incomplete version: the commit versionstamp is not yet known; `localVersion` orders it
    /// within the transaction. Matches Java's `FDBRecordVersion.incomplete(int)`.
    static func incomplete(localVersion: Int) -> FDBRecordVersion {
        precondition((0...0xFFFF).contains(localVersion), "local version out of range")
        return FDBRecordVersion(
            bytes: incompleteGlobalVersion + [UInt8(localVersion >> 8), UInt8(localVersion & 0xFF)])
    }

    /// Whether the global version is known (i.e. is not the incomplete placeholder).
    var isComplete: Bool {
        globalVersion != Self.incompleteGlobalVersion
    }

    /// The tuple-layer form of this version (Java's `toVersionstamp()`).
    var versionstamp: Versionstamp {
        let local = UInt16(localVersion ?? 0)
        return isComplete
            ? Versionstamp(transactionVersion: globalVersion, userVersion: local)
            : Versionstamp.incomplete(local)
    }

    /// Builds a version from a tuple-layer versionstamp (Java's `fromVersionstamp`).
    init(versionstamp: Versionstamp) {
        self.init(
            bytes: versionstamp.transactionVersion
                + [UInt8(versionstamp.userVersion >> 8), UInt8(versionstamp.userVersion & 0xFF)])
    }
}

// MARK: - Version mutation cache

/// Deferred versionstamp mutations and local-version bookkeeping for one transaction (the
/// `addVersionMutation` / `getLocalVersion` family on Java's `FDBRecordContext`).
///
/// FoundationDB refuses to read a key touched by a versionstamp mutation in the same transaction
/// (`accessed_unreadable`). Java therefore defers `SET_VERSIONSTAMPED_*` mutations to commit time
/// and remembers each record's local version, so a record saved with an incomplete version can
/// still be loaded (its version reported as incomplete) within the saving transaction. Pass a
/// cache to the ``SplitHelper`` functions to get that behavior; the owner must call
/// ``VersionMutationCache/applyVersionMutations(to:)`` (or equivalent) right before committing.
protocol VersionMutationCache: AnyObject, Sendable {
    /// Records a versionstamp mutation to apply at commit, returning any previous value for `key`.
    func addVersionMutation(_ type: FDB.MutationType, key: FDB.Bytes, value: FDB.Bytes) -> FDB.Bytes?
    /// Drops a pending versionstamp mutation, returning its value if there was one.
    @discardableResult func removeVersionMutation(key: FDB.Bytes) -> FDB.Bytes?
    /// Remembers that the record version stored at `key` has the given local version.
    func addToLocalVersionCache(key: FDB.Bytes, localVersion: Int)
    /// The local version cached for the record version at `key`, if any.
    func getLocalVersion(key: FDB.Bytes) -> Int?
    /// Forgets the cached local version at `key`, returning whether there was one.
    @discardableResult func removeLocalVersion(key: FDB.Bytes) -> Bool
}

/// A simple, thread-safe ``VersionMutationCache``.
final class InMemoryVersionMutationCache: VersionMutationCache {
    private struct State {
        var mutations: [FDB.Bytes: (type: FDB.MutationType, value: FDB.Bytes)] = [:]
        var localVersions: [FDB.Bytes: Int] = [:]
    }

    private let state = Mutex(State())

    init() {}

    func addVersionMutation(_ type: FDB.MutationType, key: FDB.Bytes, value: FDB.Bytes) -> FDB.Bytes? {
        state.withLock { $0.mutations.updateValue((type, value), forKey: key)?.value }
    }

    @discardableResult func removeVersionMutation(key: FDB.Bytes) -> FDB.Bytes? {
        state.withLock { $0.mutations.removeValue(forKey: key)?.value }
    }

    func addToLocalVersionCache(key: FDB.Bytes, localVersion: Int) {
        state.withLock { $0.localVersions[key] = localVersion }
    }

    func getLocalVersion(key: FDB.Bytes) -> Int? {
        state.withLock { $0.localVersions[key] }
    }

    @discardableResult func removeLocalVersion(key: FDB.Bytes) -> Bool {
        state.withLock { $0.localVersions.removeValue(forKey: key) != nil }
    }

    /// Issues every pending versionstamp mutation on `transaction` (in key order, as Java does).
    /// Call once, immediately before commit; no reads of the affected keys may follow.
    func applyVersionMutations(to transaction: any TransactionProtocol) {
        let pending = state.withLock { $0.mutations }
        for key in pending.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let mutation = pending[key]!
            transaction.atomicOp(key: key, param: mutation.value, mutationType: mutation.type)
        }
    }
}

// MARK: - SplitHelper

/// Splits serialized records across multiple key-value pairs and reassembles them, storing each
/// record's version inline. A port of the Java Record Layer's `SplitHelper`, byte-for-byte
/// compatible with its on-disk format.
///
/// For a record with primary key `pk` in the records subspace `S` (modern format,
/// `splitLongRecords = true`, unsplit suffix not omitted):
///
/// | key              | value                                                        |
/// |------------------|--------------------------------------------------------------|
/// | `S/pk.../-1`     | `Tuple(Versionstamp(version))` (13 bytes) — only if versioned |
/// | `S/pk.../0`      | whole record, if ≤ ``splitRecordSize`` bytes                  |
/// | `S/pk.../1, 2…`  | consecutive ≤ ``splitRecordSize``-byte chunks otherwise       |
///
/// Incomplete versions are written with `SET_VERSIONSTAMPED_VALUE` (the tuple-packed incomplete
/// versionstamp followed by its 4-byte little-endian offset, `1`). FoundationDB forbids reading
/// such a key in the writing transaction, so callers that may re-read a record after saving it
/// must pass a ``VersionMutationCache`` (as Java's store does via `FDBRecordContext`); without
/// one the mutation is issued immediately on the transaction.
enum SplitHelper {
    /// Records larger than this many bytes are split into chunks of at most this size.
    static let splitRecordSize = 100_000
    /// Key suffix of the record's inline version.
    static let recordVersion: Int64 = -1
    /// Key suffix of an unsplit record.
    static let unsplitRecord: Int64 = 0
    /// Key suffix of the first chunk of a split record; later chunks count up from here.
    static let startSplitRecord: Int64 = 1
    /// Byte length of a packed record version value (`0x33` + 12 version bytes).
    static let packedVersionLength = 1 + 12

    /// Accumulator for key/value sizes while loading or saving records. Mirrors Java's
    /// `SplitHelper.SizeInfo`.
    struct SizeInfo: FDBStoredSizes, Sendable, Equatable {
        var keyCount = 0
        var keySize = 0
        var valueSize = 0
        var isSplit = false
        var isVersionedInline = false

        init() {}

        mutating func set(key: FDB.Bytes, value: FDB.Bytes) {
            keyCount = 1
            keySize = key.count
            valueSize = value.count
        }

        mutating func add(key: FDB.Bytes, value: FDB.Bytes) {
            keyCount += 1
            keySize += key.count
            valueSize += value.count
        }

        /// Accounts for a version key whose value is not (yet) readable.
        mutating func add(key: FDB.Bytes, version: FDBRecordVersion?) {
            guard version != nil else { return }
            keyCount += 1
            keySize += key.count
            valueSize += SplitHelper.packedVersionLength
            isVersionedInline = true
        }

        mutating func add(_ sizes: any FDBStoredSizes) {
            keyCount += sizes.keyCount
            keySize += sizes.keySize
            valueSize += sizes.valueSize
        }

        mutating func reset() {
            self = SizeInfo()
        }
    }

    // MARK: Save

    /// Saves `serialized` under `key`, splitting it if necessary, clearing any previous record's
    /// keys, and writing `version` (if given) at suffix `-1`.
    ///
    /// - Parameters:
    ///   - subspace: the records subspace.
    ///   - key: the record's primary key.
    ///   - version: the version to store inline. If incomplete, a `SET_VERSIONSTAMPED_VALUE`
    ///     mutation is issued (via `versionCache` when given) and the local version cached.
    ///   - splitLongRecords: whether records over ``splitRecordSize`` may be split; if `false`
    ///     such records throw ``SplitHelperError/recordTooLong(valueSize:)``.
    ///   - omitUnsplitSuffix: legacy format: when not splitting, store at `key` without suffix `0`.
    ///   - clearBasedOnPreviousSizeInfo: clear only the keys `previousSizeInfo` says exist
    ///     (Java's store passes `true`); otherwise the whole record range is cleared.
    ///   - previousSizeInfo: sizes of the record being replaced, or `nil` if none existed.
    ///   - unrollSingleRecordDeletes: with `clearBasedOnPreviousSizeInfo`, clear individual keys
    ///     (plus one write-conflict range over the record) instead of a range clear. Java's
    ///     `UNROLL_SINGLE_RECORD_DELETES` property, default `true`.
    ///   - versionCache: deferred versionstamp mutations / local version cache, if any.
    /// - Returns: size information for what was written.
    @discardableResult
    static func saveWithSplit(
        _ transaction: any TransactionProtocol,
        subspace: Subspace,
        key: Tuple,
        serialized: FDB.Bytes,
        version: FDBRecordVersion?,
        splitLongRecords: Bool = true,
        omitUnsplitSuffix: Bool = false,
        clearBasedOnPreviousSizeInfo: Bool = false,
        previousSizeInfo: (any FDBStoredSizes)? = nil,
        unrollSingleRecordDeletes: Bool = true,
        versionCache: (any VersionMutationCache)? = nil
    ) throws -> SizeInfo {
        if omitUnsplitSuffix && version != nil {
            throw SplitHelperError.cannotIncludeVersionInOldUnsplitFormat
        }
        let hasVersionInKey = hasIncompleteVersionstamp(key)
        if version != nil && hasVersionInKey {
            throw SplitHelperError.versionstampInKeyAndValue
        }
        var sizeInfo = SizeInfo()
        if serialized.count > splitRecordSize {
            if !splitLongRecords {
                throw SplitHelperError.recordTooLong(valueSize: serialized.count)
            }
            try writeSplitRecord(
                transaction, subspace: subspace, key: key, serialized: serialized,
                hasVersionInKey: hasVersionInKey,
                clearBasedOnPreviousSizeInfo: clearBasedOnPreviousSizeInfo,
                previousSizeInfo: previousSizeInfo, unrollSingleRecordDeletes: unrollSingleRecordDeletes,
                versionCache: versionCache, sizeInfo: &sizeInfo)
        } else {
            // An incomplete version in the key means earlier keys for this record (whose versions
            // were completed by earlier commits) can't be found, so nothing is cleared.
            if !hasVersionInKey
                && (splitLongRecords || previousSizeInfo == nil || previousSizeInfo!.isVersionedInline)
            {
                try clearPreviousSplitRecord(
                    transaction, subspace: subspace, key: key,
                    clearBasedOnPreviousSizeInfo: clearBasedOnPreviousSizeInfo,
                    previousSizeInfo: previousSizeInfo, unrollSingleRecordDeletes: unrollSingleRecordDeletes,
                    versionCache: versionCache)
            }
            let recordKey = (splitLongRecords || !omitUnsplitSuffix) ? appending(key, unsplitRecord) : key
            let keyBytes = try writeSplitValue(
                transaction, subspace: subspace, recordKey: recordKey, value: serialized,
                versionCache: versionCache)
            sizeInfo.set(key: keyBytes, value: serialized)
            sizeInfo.isSplit = false
        }
        try writeVersion(
            transaction, subspace: subspace, key: key, version: version,
            versionCache: versionCache, sizeInfo: &sizeInfo)
        return sizeInfo
    }

    private static func writeSplitRecord(
        _ transaction: any TransactionProtocol, subspace: Subspace, key: Tuple, serialized: FDB.Bytes,
        hasVersionInKey: Bool, clearBasedOnPreviousSizeInfo: Bool, previousSizeInfo: (any FDBStoredSizes)?,
        unrollSingleRecordDeletes: Bool, versionCache: (any VersionMutationCache)?, sizeInfo: inout SizeInfo
    ) throws {
        if !hasVersionInKey {
            try clearPreviousSplitRecord(
                transaction, subspace: subspace, key: key,
                clearBasedOnPreviousSizeInfo: clearBasedOnPreviousSizeInfo,
                previousSizeInfo: previousSizeInfo, unrollSingleRecordDeletes: unrollSingleRecordDeletes,
                versionCache: versionCache)
        }
        var index = startSplitRecord
        var offset = 0
        while offset < serialized.count {
            let nextOffset = min(offset + splitRecordSize, serialized.count)
            let valueBytes = Array(serialized[offset..<nextOffset])
            let keyBytes = try writeSplitValue(
                transaction, subspace: subspace, recordKey: appending(key, index), value: valueBytes,
                versionCache: versionCache)
            if offset == 0 {
                sizeInfo.set(key: keyBytes, value: valueBytes)
                sizeInfo.isSplit = true
            } else {
                sizeInfo.add(key: keyBytes, value: valueBytes)
            }
            index += 1
            offset = nextOffset
        }
    }

    private static func writeSplitValue(
        _ transaction: any TransactionProtocol, subspace: Subspace, recordKey: Tuple, value: FDB.Bytes,
        versionCache: (any VersionMutationCache)?
    ) throws -> FDB.Bytes {
        if hasIncompleteVersionstamp(recordKey) {
            let keyBytes = try subspace.packWithVersionstamp(recordKey)
            if let versionCache {
                if versionCache.addVersionMutation(.setVersionstampedKey, key: keyBytes, value: value) != nil {
                    throw SplitHelperError.keyWithVersionOverwritten
                }
            } else {
                transaction.atomicOp(key: keyBytes, param: value, mutationType: .setVersionstampedKey)
            }
            return keyBytes
        } else {
            let keyBytes = subspace.pack(recordKey)
            transaction.setValue(value, for: keyBytes)
            return keyBytes
        }
    }

    private static func writeVersion(
        _ transaction: any TransactionProtocol, subspace: Subspace, key: Tuple, version: FDBRecordVersion?,
        versionCache: (any VersionMutationCache)?, sizeInfo: inout SizeInfo
    ) throws {
        guard let version else {
            sizeInfo.isVersionedInline = false
            return
        }
        let keyBytes = subspace.pack(appending(key, recordVersion))
        let valueBytes = try packVersion(version)
        if version.isComplete {
            transaction.setValue(valueBytes, for: keyBytes)
        } else if let versionCache {
            _ = versionCache.addVersionMutation(.setVersionstampedValue, key: keyBytes, value: valueBytes)
            versionCache.addToLocalVersionCache(key: keyBytes, localVersion: version.localVersion ?? 0)
        } else {
            transaction.atomicOp(key: keyBytes, param: valueBytes, mutationType: .setVersionstampedValue)
        }
        sizeInfo.isVersionedInline = true
        sizeInfo.add(key: keyBytes, value: valueBytes)
        if !version.isComplete {
            // The 4-byte versionstamp offset is stripped by FoundationDB; don't count it.
            sizeInfo.valueSize -= 4
        }
    }

    /// Computes the sizes `saveWithSplit` would write, without writing anything.
    static func dryRunSaveWithSplitOnlySetSizeInfo(
        subspace: Subspace, key: Tuple, serialized: FDB.Bytes, version: FDBRecordVersion?,
        splitLongRecords: Bool = true, omitUnsplitSuffix: Bool = false
    ) throws -> SizeInfo {
        var sizeInfo = SizeInfo()
        if serialized.count > splitRecordSize {
            var index = startSplitRecord
            var offset = 0
            while offset < serialized.count {
                let nextOffset = min(offset + splitRecordSize, serialized.count)
                let keyBytes = subspace.pack(appending(key, index))
                let valueBytes = Array(serialized[offset..<nextOffset])
                if offset == 0 {
                    sizeInfo.set(key: keyBytes, value: valueBytes)
                    sizeInfo.isSplit = true
                } else {
                    sizeInfo.add(key: keyBytes, value: valueBytes)
                }
                index += 1
                offset = nextOffset
            }
        } else {
            let recordKey = (splitLongRecords || !omitUnsplitSuffix) ? appending(key, unsplitRecord) : key
            sizeInfo.set(key: subspace.pack(recordKey), value: serialized)
            sizeInfo.isSplit = false
        }
        if let version {
            let keyBytes = subspace.pack(appending(key, recordVersion))
            sizeInfo.isVersionedInline = true
            sizeInfo.add(key: keyBytes, value: try packVersion(version))
            if !version.isComplete { sizeInfo.valueSize -= 4 }
        } else {
            sizeInfo.isVersionedInline = false
        }
        return sizeInfo
    }

    // MARK: Version packing

    /// Encodes a version as stored at suffix `-1`: `Tuple(versionstamp).pack()` when complete, or
    /// `Tuple(versionstamp).packWithVersionstamp()` (17 bytes, for `SET_VERSIONSTAMPED_VALUE`)
    /// when incomplete.
    static func packVersion(_ version: FDBRecordVersion) throws -> FDB.Bytes {
        let tuple = Tuple(version.versionstamp)
        return version.isComplete ? tuple.encode() : try tuple.packWithVersionstamp()
    }

    /// Decodes a value written at suffix `-1`.
    static func unpackVersion(_ packed: FDB.Bytes?) throws -> FDBRecordVersion? {
        guard let packed else { return nil }
        let elements = try Tuple.decode(from: packed)
        guard let stamp = elements.first as? Versionstamp else {
            throw SplitHelperError.invalidEncoding("record version value is not a versionstamp")
        }
        return FDBRecordVersion(versionstamp: stamp)
    }

    // MARK: Clear / delete

    private static func clearPreviousSplitRecord(
        _ transaction: any TransactionProtocol, subspace: Subspace, key: Tuple,
        clearBasedOnPreviousSizeInfo: Bool, previousSizeInfo: (any FDBStoredSizes)?,
        unrollSingleRecordDeletes: Bool, versionCache: (any VersionMutationCache)?
    ) throws {
        let keySplitSubspace = subspace.subspace(key)
        let range = keySplitSubspace.range
        if clearBasedOnPreviousSizeInfo {
            if let previousSizeInfo {
                if unrollSingleRecordDeletes {
                    // Clear each key individually (letting storage optimize single-key clears), but
                    // still cover the whole record with one write conflict range.
                    try transaction.addConflictRange(beginKey: range.begin, endKey: range.end, type: .write)
                    for offset in offsets(previousSizeInfo) {
                        transaction.clear(key: keySplitSubspace.pack(offset))
                    }
                } else if previousSizeInfo.isSplit || previousSizeInfo.isVersionedInline {
                    // The new record might be shorter than the previous split one.
                    transaction.clearRange(beginKey: range.begin, endKey: range.end)
                } else {
                    // Previously unsplit, with the unsplit suffix.
                    transaction.clear(key: keySplitSubspace.pack(unsplitRecord))
                }
            }
        } else {
            // Clears both an unsplit record and a previous, longer split record.
            transaction.clearRange(beginKey: range.begin, endKey: range.end)
        }
        if let versionCache {
            let versionKey = keySplitSubspace.pack(recordVersion)
            if versionCache.getLocalVersion(key: versionKey) != nil {
                versionCache.removeVersionMutation(key: versionKey)
            }
        }
    }

    /// The suffixes a record with the given sizes occupies (Java's `offsets`).
    static func offsets(_ sizes: any FDBStoredSizes) -> [Int64] {
        var result: [Int64] = []
        if sizes.isVersionedInline {
            result.append(recordVersion)
        }
        if sizes.isSplit {
            var current = startSplitRecord
            while result.count < sizes.keyCount {
                result.append(current)
                current += 1
            }
        } else {
            result.append(unsplitRecord)
        }
        return result
    }

    /// Deletes a record's keys, clearing only as much as needed.
    ///
    /// As in Java, the local version cache entry is left in place (the store removes it with
    /// ``VersionMutationCache/removeLocalVersion(key:)`` when deleting a record whose version
    /// was incomplete); only the pending version mutation is dropped.
    static func deleteSplit(
        _ transaction: any TransactionProtocol,
        subspace: Subspace,
        key: Tuple,
        splitLongRecords: Bool = true,
        missingUnsplitRecordSuffix: Bool = false,
        clearBasedOnPreviousSizeInfo: Bool = false,
        previousSizeInfo: (any FDBStoredSizes)? = nil,
        unrollSingleRecordDeletes: Bool = true,
        versionCache: (any VersionMutationCache)? = nil
    ) throws {
        if !splitLongRecords && missingUnsplitRecordSuffix {
            transaction.clear(key: subspace.pack(key))
        } else {
            try clearPreviousSplitRecord(
                transaction, subspace: subspace, key: key,
                clearBasedOnPreviousSizeInfo: clearBasedOnPreviousSizeInfo,
                previousSizeInfo: previousSizeInfo, unrollSingleRecordDeletes: unrollSingleRecordDeletes,
                versionCache: versionCache)
        }
    }

    // MARK: Load

    /// Loads the record at `key`, reassembling split chunks and reading its inline version.
    ///
    /// Does a single range read over the record's subspace. If `versionCache` holds a local
    /// version for the record, the version is reported as incomplete.
    ///
    /// - Returns: the raw record, or `nil` if no record exists.
    static func loadWithSplit(
        _ transaction: any TransactionProtocol,
        subspace: Subspace,
        key: Tuple,
        splitLongRecords: Bool = true,
        missingUnsplitRecordSuffix: Bool = false,
        snapshot: Bool = false,
        versionCache: (any VersionMutationCache)? = nil
    ) async throws -> FDBRawRecord? {
        if !splitLongRecords && missingUnsplitRecordSuffix {
            let keyBytes = subspace.pack(key)
            guard let value = try await transaction.getValue(for: keyBytes, snapshot: snapshot) else {
                return nil
            }
            return FDBRawRecord(
                primaryKey: key, rawRecord: value, version: nil, keyCount: 1, keySize: keyBytes.count,
                valueSize: value.count, isSplit: false, isVersionedInline: false)
        }
        let recordSubspace = subspace.subspace(key)
        let range = recordSubspace.range
        var unsplitter = SingleKeyUnsplitter(key: key, keySplitSubspace: recordSubspace)
        if let versionCache {
            let versionKey = recordSubspace.pack(recordVersion)
            if let localVersion = versionCache.getLocalVersion(key: versionKey) {
                unsplitter.version = .incomplete(localVersion: localVersion)
                unsplitter.sizeInfo.add(key: versionKey, version: unsplitter.version)
            }
        }
        for try await (k, v) in transaction.getRange(beginKey: range.begin, endKey: range.end, snapshot: snapshot) {
            try unsplitter.append(key: k, value: v)
        }
        return try unsplitter.finish()
    }

    /// Reassembles a single record from a forward scan of its subspace (Java's
    /// `SingleKeyUnsplitter`).
    private struct SingleKeyUnsplitter {
        let key: Tuple
        let keySplitSubspace: Subspace
        var sizeInfo = SizeInfo()
        var lastIndex: Int64 = 0
        var result: FDB.Bytes?
        var version: FDBRecordVersion?

        init(key: Tuple, keySplitSubspace: Subspace) {
            self.key = key
            self.keySplitSubspace = keySplitSubspace
        }

        mutating func append(key kvKey: FDB.Bytes, value: FDB.Bytes) throws {
            let subkey = try SplitHelper.unpackKey(keySplitSubspace, kvKey)
            guard subkey.count == 1 else { throw SplitHelperError.expectedSingleKeyExtension }
            let index = try SplitHelper.suffixIndex(subkey)
            if index == SplitHelper.unsplitRecord {
                if result != nil { throw SplitHelperError.moreThanOneUnsplitValue }
                result = value
                sizeInfo.add(key: kvKey, value: value)
                sizeInfo.isSplit = false
            } else if index == lastIndex + 1
                || (lastIndex == SplitHelper.recordVersion && index == SplitHelper.startSplitRecord)
            {
                if index == SplitHelper.startSplitRecord {
                    if result != nil { throw SplitHelperError.unsplitFollowedBySplit }
                    result = value
                    sizeInfo.add(key: kvKey, value: value)
                    sizeInfo.isSplit = true
                } else {
                    result! += value
                    sizeInfo.add(key: kvKey, value: value)
                }
                lastIndex = index
            } else if index == SplitHelper.recordVersion {
                version = try SplitHelper.unpackVersion(value)
                sizeInfo.isVersionedInline = true
                sizeInfo.add(key: kvKey, value: value)
            } else if lastIndex >= SplitHelper.startSplitRecord {
                throw SplitHelperError.foundSplitOutOfOrder(expected: lastIndex + 1, found: index)
            } else {
                throw SplitHelperError.foundSplitWithoutStart(nextIndex: index, reverse: false)
            }
        }

        func finish() throws -> FDBRawRecord? {
            if let result {
                return FDBRawRecord(primaryKey: key, rawRecord: result, version: version, sizes: sizeInfo)
            } else if version != nil {
                throw SplitHelperError.foundSplitWithoutStart(nextIndex: SplitHelper.recordVersion, reverse: false)
            }
            return nil
        }
    }

    /// Whether any key exists for the record at `key`.
    static func keyExists(
        _ transaction: any TransactionProtocol,
        subspace: Subspace,
        key: Tuple,
        splitLongRecords: Bool = true,
        missingUnsplitRecordSuffix: Bool = false,
        snapshot: Bool = false
    ) async throws -> Bool {
        if !splitLongRecords && missingUnsplitRecordSuffix {
            return try await transaction.getValue(for: subspace.pack(key), snapshot: snapshot) != nil
        }
        let keyBytes = subspace.pack(key)
        let result = try await transaction.getRangeNative(
            beginSelector: .firstGreaterOrEqual(keyBytes),
            endSelector: .firstGreaterOrEqual(strinc(keyBytes)),
            limit: 1, snapshot: snapshot, reverse: false)
        return !result.records.isEmpty
    }

    // MARK: Scanning

    /// Scans records in `range` (default: the whole records subspace), resuming after
    /// `continuation` (from ``KeyValueUnsplitter/Result/continuation``) if given.
    ///
    /// Continuations are Java `KeyValueCursor` continuations: the last key consumed, with the
    /// records-subspace prefix removed. A forward scan resumes at the first key after it; a
    /// reverse scan ends (exclusively) at it.
    static func scanRecords(
        _ transaction: any TransactionProtocol,
        subspace: Subspace,
        range: (begin: FDB.Bytes, end: FDB.Bytes)? = nil,
        continuation: FDB.Bytes? = nil,
        reverse: Bool = false,
        snapshot: Bool = false,
        versionCache: (any VersionMutationCache)? = nil
    ) -> KeyValueUnsplitter<FDB.AsyncKVSequence> {
        let bounds = range ?? subspace.range
        var begin = FDB.KeySelector.firstGreaterOrEqual(bounds.begin)
        var end = FDB.KeySelector.firstGreaterOrEqual(bounds.end)
        if let continuation {
            let resumeKey = subspace.prefix + continuation
            if reverse {
                end = .firstGreaterOrEqual(resumeKey)
            } else {
                begin = .firstGreaterThan(resumeKey)
            }
        }
        let kvs = transaction.getRange(
            beginSelector: begin, endSelector: end, snapshot: snapshot, reverse: reverse)
        return KeyValueUnsplitter(
            subspace: subspace, keyValues: kvs, reverse: reverse, versionCache: versionCache)
    }

    /// Turns a (forward or reverse) scan of raw key-values in a records subspace into whole
    /// records, each with its inline version. Mirrors Java's `SplitHelper.KeyValueUnsplitter`;
    /// it only ever stops between records, so every ``Result/continuation`` is a record boundary.
    struct KeyValueUnsplitter<Base: AsyncSequence>: AsyncSequence where Base.Element == (FDB.Bytes, FDB.Bytes) {
        /// One reassembled record plus the continuation to resume the scan after it.
        struct Result {
            let record: FDBRawRecord
            /// The last key consumed for this record, relative to the records subspace.
            let continuation: FDB.Bytes
        }
        typealias Element = Result

        let subspace: Subspace
        let keyValues: Base
        let reverse: Bool
        let oldVersionFormat: Bool
        let versionCache: (any VersionMutationCache)?

        init(
            subspace: Subspace, keyValues: Base, reverse: Bool = false, oldVersionFormat: Bool = false,
            versionCache: (any VersionMutationCache)? = nil
        ) {
            self.subspace = subspace
            self.keyValues = keyValues
            self.reverse = reverse
            self.oldVersionFormat = oldVersionFormat
            self.versionCache = versionCache
        }

        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(
                subspace: subspace, inner: keyValues.makeAsyncIterator(), reverse: reverse,
                oldVersionFormat: oldVersionFormat, versionCache: versionCache)
        }

        /// Collects every record.
        func collect() async throws -> [FDBRawRecord] {
            var records: [FDBRawRecord] = []
            for try await result in self { records.append(result.record) }
            return records
        }

        struct AsyncIterator: AsyncIteratorProtocol {
            let subspace: Subspace
            var inner: Base.AsyncIterator
            let reverse: Bool
            let oldVersionFormat: Bool
            let versionCache: (any VersionMutationCache)?

            private var pending: (FDB.Bytes, FDB.Bytes)?
            private var exhausted = false

            // State of the record being assembled.
            private var nextValue: FDB.Bytes?
            private var nextKey: Tuple?
            private var nextSubspace: Subspace?
            private var nextVersion: FDBRecordVersion?
            private var nextPrefix: FDB.Bytes?
            private var nextIndex: Int64 = 0
            private var sizeInfo = SizeInfo()
            private var continuation: FDB.Bytes = []

            init(
                subspace: Subspace, inner: Base.AsyncIterator, reverse: Bool, oldVersionFormat: Bool,
                versionCache: (any VersionMutationCache)?
            ) {
                self.subspace = subspace
                self.inner = inner
                self.reverse = reverse
                self.oldVersionFormat = oldVersionFormat
                self.versionCache = versionCache
            }

            mutating func next() async throws -> Result? {
                try await appendUntilNewKey()
                if nextVersion != nil && nextValue == nil {
                    throw SplitHelperError.foundSplitWithoutStart(nextIndex: SplitHelper.recordVersion, reverse: reverse)
                }
                if !oldVersionFormat, let nextKey, let versionCache {
                    // Account for an incomplete version written earlier in this transaction.
                    let versionKey = subspace.subspace(nextKey).pack(SplitHelper.recordVersion)
                    if let localVersion = versionCache.getLocalVersion(key: versionKey) {
                        nextVersion = .incomplete(localVersion: localVersion)
                        sizeInfo.isVersionedInline = true
                        sizeInfo.keyCount += 1
                        sizeInfo.keySize += versionKey.count
                        sizeInfo.valueSize += SplitHelper.packedVersionLength
                    }
                }
                guard let value = nextValue, let key = nextKey else { return nil }
                sizeInfo.isVersionedInline = nextVersion != nil
                let record = FDBRawRecord(primaryKey: key, rawRecord: value, version: nextVersion, sizes: sizeInfo)
                nextValue = nil
                nextKey = nil
                nextSubspace = nil
                nextVersion = nil
                nextPrefix = nil
                return Result(record: record, continuation: continuation)
            }

            /// Consumes key-values until the current record is known to be complete.
            private mutating func appendUntilNewKey() async throws {
                if let kv = pending {
                    pending = nil
                    if try append(kv) { return }
                }
                guard !exhausted else { return }
                while let kv = try await inner.next() {
                    if try append(kv) { return }
                }
                exhausted = true
                if reverse, nextValue != nil, nextIndex != SplitHelper.startSplitRecord,
                   nextIndex != SplitHelper.unsplitRecord, nextIndex != SplitHelper.recordVersion
                {
                    throw SplitHelperError.foundSplitWithoutStart(nextIndex: nextIndex, reverse: true)
                }
            }

            /// Processes one key-value; returns whether the current record is complete.
            private mutating func append(_ kv: (FDB.Bytes, FDB.Bytes)) throws -> Bool {
                guard let prefix = nextPrefix else {
                    continuation = Array(kv.0.dropFirst(subspace.prefix.count))
                    return try appendFirst(kv)
                }
                if kv.0.starts(with: prefix) {
                    continuation = Array(kv.0.dropFirst(subspace.prefix.count))
                    return try appendNext(kv)
                }
                if reverse && nextIndex != SplitHelper.unsplitRecord && nextIndex != SplitHelper.startSplitRecord
                    && nextIndex != SplitHelper.recordVersion
                {
                    throw SplitHelperError.foundSplitWithoutStart(nextIndex: nextIndex, reverse: true)
                }
                pending = kv
                return true
            }

            private mutating func appendFirst(_ kv: (FDB.Bytes, FDB.Bytes)) throws -> Bool {
                let keyTuple = try SplitHelper.unpackKey(subspace, kv.0)
                guard keyTuple.count >= 1 else {
                    throw SplitHelperError.invalidSplitNumber("record key has no suffix")
                }
                let primaryKey = SplitHelper.dropLast(keyTuple)
                nextKey = primaryKey
                nextSubspace = subspace.subspace(primaryKey)
                nextPrefix = nextSubspace!.prefix
                nextValue = kv.1
                nextIndex = try SplitHelper.suffixIndex(keyTuple)
                sizeInfo = SizeInfo()
                sizeInfo.set(key: kv.0, value: kv.1)
                if nextIndex == SplitHelper.unsplitRecord {
                    // Forward: the only key. Reverse: a version key may still precede it.
                    sizeInfo.isSplit = false
                    return !reverse
                } else if !reverse && nextIndex == SplitHelper.recordVersion {
                    if oldVersionFormat { throw SplitHelperError.recordVersionInOldFormat }
                    sizeInfo.isVersionedInline = true
                    nextVersion = try SplitHelper.unpackVersion(kv.1)
                    nextValue = nil
                    return false
                } else if (reverse && nextIndex != SplitHelper.recordVersion) || nextIndex == SplitHelper.startSplitRecord {
                    // Start (forward) or end (reverse) of a split record.
                    sizeInfo.isSplit = true
                    return false
                } else {
                    throw SplitHelperError.foundSplitWithoutStart(nextIndex: nextIndex, reverse: reverse)
                }
            }

            private mutating func appendNext(_ kv: (FDB.Bytes, FDB.Bytes)) throws -> Bool {
                let subkey = try SplitHelper.unpackKey(nextSubspace!, kv.0)
                let index = try SplitHelper.suffixIndex(subkey)
                sizeInfo.add(key: kv.0, value: kv.1)
                if !reverse && nextIndex == SplitHelper.recordVersion
                    && (index == SplitHelper.unsplitRecord || index == SplitHelper.startSplitRecord)
                {
                    // Forward scan whose first key was the version.
                    nextValue = kv.1
                    nextIndex = index
                    sizeInfo.isSplit = index == SplitHelper.startSplitRecord
                    return index == SplitHelper.unsplitRecord
                } else if !reverse && index == nextIndex + 1 {
                    nextValue! += kv.1
                    nextIndex = index
                    return false
                } else if reverse && index == SplitHelper.recordVersion
                    && (nextIndex == SplitHelper.startSplitRecord || nextIndex == SplitHelper.unsplitRecord)
                {
                    // The version is always a record's first key, so a reverse scan is done.
                    if oldVersionFormat { throw SplitHelperError.recordVersionInOldFormat }
                    nextVersion = try SplitHelper.unpackVersion(kv.1)
                    nextIndex = index
                    return true
                } else if reverse && index == nextIndex - 1 && index != SplitHelper.recordVersion {
                    nextValue = kv.1 + nextValue!
                    nextIndex = index
                    return false
                } else {
                    let expected = nextIndex + (reverse ? -1 : 1)
                    if (reverse && expected == SplitHelper.startSplitRecord)
                        || (!reverse && nextIndex == SplitHelper.recordVersion)
                    {
                        throw SplitHelperError.foundSplitWithoutStart(nextIndex: index, reverse: reverse)
                    }
                    throw SplitHelperError.foundSplitOutOfOrder(expected: expected, found: index)
                }
            }
        }
    }

    // MARK: Key utilities

    /// Unpacks `key` relative to `subspace`.
    static func unpackKey(_ subspace: Subspace, _ key: FDB.Bytes) throws -> Tuple {
        do {
            return Tuple(try subspace.unpack(key))
        } catch {
            throw SplitHelperError.invalidEncoding("unable to unpack key: \(error)")
        }
    }

    /// Ensures the last element of `keyTuple` is a valid split suffix (-1, 0, or ≥ 1).
    static func validatePrimaryKeySuffixNumber(_ keyTuple: Tuple) throws {
        let index = try suffixIndex(keyTuple)
        if index != recordVersion && index != unsplitRecord && !(index >= startSplitRecord) {
            throw SplitHelperError.invalidSplitNumber("\(index)")
        }
    }

    /// The integer suffix (last element) of `tuple`.
    static func suffixIndex(_ tuple: Tuple) throws -> Int64 {
        guard tuple.count > 0, let last = tuple[tuple.count - 1] else {
            throw SplitHelperError.invalidSplitNumber("empty key")
        }
        if let value = last as? Int64 { return value }
        if let value = last as? Int { return Int64(value) }
        if let value = last as? Int32 { return Int64(value) }
        throw SplitHelperError.invalidSplitNumber("not a number")
    }

    static func elements(_ tuple: Tuple) -> [any TupleElement] {
        (0..<tuple.count).map { tuple[$0]! }
    }

    static func appending(_ tuple: Tuple, _ element: any TupleElement) -> Tuple {
        Tuple(elements(tuple) + [element])
    }

    static func dropLast(_ tuple: Tuple) -> Tuple {
        Tuple(Array(elements(tuple).dropLast()))
    }

    static func hasIncompleteVersionstamp(_ tuple: Tuple) -> Bool {
        elements(tuple).contains { element in
            if let stamp = element as? Versionstamp { return stamp.isIncomplete }
            if let nested = element as? Tuple { return hasIncompleteVersionstamp(nested) }
            return false
        }
    }

    /// The first key not prefixed by `key` (FoundationDB's `strinc`).
    static func strinc(_ key: FDB.Bytes) -> FDB.Bytes {
        var bytes = key
        while let last = bytes.last, last == 0xFF { bytes.removeLast() }
        precondition(!bytes.isEmpty, "key must contain a byte other than 0xFF")
        bytes[bytes.count - 1] += 1
        return bytes
    }
}
#endif
