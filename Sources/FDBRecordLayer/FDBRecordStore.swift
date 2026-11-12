/*
 * FDBRecordStore.swift
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
import FoundationDB
import SwiftProtobuf
import Synchronization

/// Errors raised by ``FDBRecordStore``.
public enum RecordStoreError: Error, Sendable {
    /// A record of a type not present in the metadata was saved/loaded.
    case unknownRecordType(String)
    /// The store's header carries a format version this implementation can't read (written by
    /// a newer client, or older than ``FormatVersion/minimumSupported``).
    case incompatibleFormatVersion(found: Int, expected: Int)
    /// The store uses a Java feature this implementation does not support (named in the payload).
    case unsupportedStoreFeature(String)
    /// The store header could not be decoded.
    case corruptHeader
    /// An index type whose maintainer is not yet implemented was encountered.
    case unsupportedIndexType(IndexType)
    /// A query or operation referenced an index name not present in the metadata.
    case unknownIndex(String)
    /// A covering query's filter is not fully satisfiable by the named index alone.
    case queryNotCovered(String)
    /// A save would violate a unique index (another record already has the same key), or a
    /// unique index has outstanding violations and can't be made readable.
    case uniquenessViolation(index: String)
    /// A conditional save's expected version did not match the stored version. Not retryable —
    /// the caller should re-read and decide.
    case versionMismatch
    /// `save(_:ifVersionMatches:)` was used on a store whose metadata does not store versions.
    case recordVersioningDisabled(String)
    /// `insert(_:)` found an existing record with the same primary key.
    case recordAlreadyExists(String)
    /// `update(_:)` found no existing record with the given primary key.
    case recordDoesNotExist(String)
    /// More than 65,536 versioned records were written in a single transaction, exhausting the
    /// 2-byte local-version counter that keeps their versions distinct.
    case localVersionExhausted
    /// A `version` index was asked to write an entry without a version to stamp it with.
    case missingLocalVersion(index: String)
    /// The store's recorded metadata version is newer than the metadata this client opened it
    /// with — another client has upgraded the schema (Java's `RecordStoreStaleMetaDataVersionException`).
    case staleMetaData(stored: Int, local: Int)
    /// The store's recorded user version is newer than the one this client supplied.
    case staleUserVersion(stored: Int, local: Int)
    /// The subspace has data but no store header (Java: "Record store has no info but is not empty").
    case storeHasNoHeaderButIsNotEmpty
    /// The open's ``StoreExistenceCheck`` failed.
    case storeDoesNotExist
    case storeAlreadyExists
    /// The store is locked (see ``DataStoreInfo/StoreLockState``).
    case storeIsLocked(state: DataStoreInfo.LockState, reason: String)
    /// The store was written by the pre-Java-layout Swift record layer and must be migrated with
    /// ``FoundationDB/DatabaseProtocol/migrateLegacyRecordStore(subspace:metaData:)`` first.
    case legacyStoreNeedsMigration(formatVersion: Int)
    /// An index can't be made readable because part of it is unbuilt.
    case indexNotBuilt(String)
    /// An index entry or record exceeds FoundationDB's key (10,000 bytes) or value (100,000
    /// bytes) size limits.
    case keyTooLarge(index: String?, size: Int)
    case valueTooLarge(index: String?, size: Int)
    /// A stored record was of a different type than the one requested.
    case recordTypeMismatch(expected: String, found: String)
    /// A `min_ever_long`/`max_ever_long` index was given a negative value.
    case negativeValueInEverIndex(index: String)
    /// An index build was blocked by an operator (Java's indexing stamp `block`).
    case indexBuildBlocked(String)
    /// A stored record's bytes are not a valid record union.
    case corruptRecord
}

/// What ``FDBRecordStore/open(context:subspace:metaData:existenceCheck:userVersion:bypassFullStoreLockReason:)``
/// requires about the store's prior existence — Java's `StoreExistenceCheck`.
public enum StoreExistenceCheck: Sendable {
    /// Create the store if it has no header, even if the subspace has other data.
    case none
    /// Fail if the store already exists.
    case errorIfExists
    /// Fail if the store does not exist.
    case errorIfNotExists
    /// Create the store if the subspace is empty; fail if it has data but no header (default).
    case errorIfNoInfoAndNotEmpty
}

/// The primary entry point for storing, retrieving, and querying records — the Swift
/// counterpart of the Java Record Layer's `FDBRecordStore`, with the same on-disk layout.
///
/// A store is bound to one ``FDBRecordContext`` (transaction), a ``Subspace`` to occupy, and
/// a ``RecordMetaData`` schema. Key layout under the store's subspace `S` (Java's
/// `FDBRecordStoreKeyspace`):
/// - `S / 0` — store header (``DataStoreInfo``)
/// - `S / 1 / <primaryKey...> / <suffix>` — records, wrapped in the record union; suffix `0`
///   for an unsplit record, `1, 2, ...` for the chunks of a split record, `-1` for its version
/// - `S / 2 / <indexSubspaceKey> / ...` — index entries
/// - `S / 3 / <indexSubspaceKey> / ...` — secondary index data (rank indexes' ranked sets)
/// - `S / 5 / <indexName>` — index state, absent when readable
/// - `S / 6 / <indexSubspaceKey>` — built ranges of an index being built (a ``RangeSet``)
/// - `S / 7 / <indexSubspaceKey> / <value...> / <primaryKey...>` — uniqueness violations
/// - `S / 9 / <indexSubspaceKey> / ...` — index build metadata (type stamp, ...)
///
/// A store is `Sendable`, but read-modify-write calls on the *same* primary key from concurrent
/// tasks sharing one transaction can still interleave; keep such work on disjoint records.
public final class FDBRecordStore: Sendable {
    /// The transaction context the store operates in.
    public let context: FDBRecordContext
    /// The subspace the store occupies.
    public let subspace: Subspace
    /// The schema describing record types and indexes.
    public let metaData: RecordMetaData

    let recordsSubspace: Subspace
    let indexesSubspace: Subspace
    let indexSecondarySpace: Subspace
    let indexStateSpace: Subspace
    let indexRangeSpace: Subspace
    let indexUniquenessViolationsSpace: Subspace
    let indexBuildSpace: Subspace

    var transaction: any TransactionProtocol { context.transaction }

    /// The store header key, `S / 0`.
    var storeInfoKey: FDB.Bytes { subspace.pack(Tuple(RecordStoreKeyspace.storeInfo.rawValue)) }

    /// The pre-Java-layout Swift layer kept its header as separate keys under `S / 0 / ...`.
    /// Their presence identifies such a store; the format-version key doubles as the fence that
    /// keeps old clients out once migration starts (see ``LegacyStoreMigration``).
    var legacyFormatVersionKey: FDB.Bytes { subspace.child(Int64(0)).pack("format_version") }

    private struct MutableState: Sendable {
        var header = DataStoreInfo()
        /// Non-readable index states; a missing name is readable.
        var indexStates: [String: IndexState] = [:]
        /// Index names whose state key has been added as a read conflict.
        var stateConflicts: Set<String> = []
    }

    private let state = Mutex(MutableState())

    init(context: FDBRecordContext, subspace: Subspace, metaData: RecordMetaData) {
        self.context = context
        self.subspace = subspace
        self.metaData = metaData
        self.recordsSubspace = subspace.child(RecordStoreKeyspace.record.rawValue)
        self.indexesSubspace = subspace.child(RecordStoreKeyspace.index.rawValue)
        self.indexSecondarySpace = subspace.child(RecordStoreKeyspace.indexSecondarySpace.rawValue)
        self.indexStateSpace = subspace.child(RecordStoreKeyspace.indexStateSpace.rawValue)
        self.indexRangeSpace = subspace.child(RecordStoreKeyspace.indexRangeSpace.rawValue)
        self.indexUniquenessViolationsSpace = subspace.child(RecordStoreKeyspace.indexUniquenessViolationsSpace.rawValue)
        self.indexBuildSpace = subspace.child(RecordStoreKeyspace.indexBuildSpace.rawValue)
    }

    // MARK: - Per-index subspaces

    func indexSubspace(_ index: ErasedIndex) -> Subspace { indexesSubspace.subspace(index.subspaceTupleKey) }
    func indexSecondarySubspace(_ index: ErasedIndex) -> Subspace { indexSecondarySpace.subspace(index.subspaceTupleKey) }
    func indexRangeSubspace(_ index: ErasedIndex) -> Subspace { indexRangeSpace.subspace(index.subspaceTupleKey) }
    func indexUniquenessViolationsSubspace(_ index: ErasedIndex) -> Subspace {
        indexUniquenessViolationsSpace.subspace(index.subspaceTupleKey)
    }
    func indexBuildSubspace(_ index: ErasedIndex) -> Subspace { indexBuildSpace.subspace(index.subspaceTupleKey) }
    func indexStateKey(_ name: String) -> FDB.Bytes { indexStateSpace.pack(name) }
    /// The built-ranges set of an index (Java's `IndexingRangeSet.forIndexBuild`).
    func indexRangeSet(_ index: ErasedIndex) -> RangeSet { RangeSet(subspace: indexRangeSubspace(index)) }
    /// `S / 9 / <key> / 2`: how the index is being built (Java's `INDEX_BUILD_TYPE_VERSION`).
    func indexingTypeStampKey(_ index: ErasedIndex) -> FDB.Bytes { indexBuildSubspace(index).pack(Tuple(Int64(2))) }
    /// `S / 9 / <key> / 0`: the indexing session lock, which ``clearIndexData(_:)`` preserves.
    func indexBuildLockSubspace(_ index: ErasedIndex) -> Subspace { indexBuildSubspace(index).child(Int64(0)) }

    // MARK: - Opening

    /// Opens (creating if necessary) the record store at `subspace` — Java's
    /// `FDBRecordStore.Builder.createOrOpen()` followed by `checkVersion`.
    ///
    /// Opening validates the header (format version, lock state), refuses metadata older than
    /// the store's (``RecordStoreError/staleMetaData(stored:local:)``), and upgrades the store
    /// when the metadata is newer: removed indexes are cleared, and new or changed indexes are
    /// marked readable when the store is empty (or their record types are new) and
    /// ``IndexState/disabled`` otherwise, to be built by an ``OnlineIndexer``.
    ///
    /// - Parameters:
    ///   - existenceCheck: what to require about the store's prior existence.
    ///   - userVersion: an application-defined version recorded in the header; opening with a
    ///     version older than the stored one fails (Java's `UserVersionChecker`).
    ///   - bypassFullStoreLockReason: opens a store under a ``DataStoreInfo/LockState/fullStore``
    ///     lock whose reason matches.
    public static func open(
        context: FDBRecordContext, subspace: Subspace, metaData: RecordMetaData,
        existenceCheck: StoreExistenceCheck = .errorIfNoInfoAndNotEmpty,
        userVersion: Int? = nil,
        bypassFullStoreLockReason: String? = nil,
        stateCache: RecordStoreStateCache? = nil
    ) async throws -> FDBRecordStore {
        let store = FDBRecordStore(context: context, subspace: subspace, metaData: metaData)
        if let stateCache, try await store.openFromCache(
            stateCache, existenceCheck: existenceCheck, userVersion: userVersion,
            bypassFullStoreLockReason: bypassFullStoreLockReason) {
            return store
        }
        let stamp = stateCache == nil ? nil : try await context.metaDataVersionStamp()
        try await store.checkVersion(
            existenceCheck: existenceCheck, userVersion: userVersion,
            bypassFullStoreLockReason: bypassFullStoreLockReason)
        if let stateCache {
            let snapshot = store.state.withLock { ($0.header, $0.indexStates) }
            stateCache.record(subspace: subspace, stamp: stamp, header: snapshot.0, indexStates: snapshot.1,
                              dirty: context.hasDirtyStoreState)
        }
        return store
    }

    /// Java's `MetaDataVersionStampStoreStateCache.get`: reuse a cached header and index states
    /// when the cluster's meta-data version stamp hasn't moved and nothing needs upgrading.
    private func openFromCache(
        _ cache: RecordStoreStateCache, existenceCheck: StoreExistenceCheck, userVersion: Int?,
        bypassFullStoreLockReason: String?
    ) async throws -> Bool {
        guard !context.hasDirtyStoreState, let entry = cache.entry(for: subspace) else { return false }
        guard let stamp = try await context.metaDataVersionStamp(), stamp == entry.stamp else { return false }
        let info = entry.header
        guard info.formatVersion == FormatVersion.current.rawValue, info.metaDataVersion == metaData.version,
              userVersion == nil || userVersion == info.userVersion else { return false }
        // Conflict on the header exactly as if it had been read (Java's `handleCachedState`).
        try transaction.addConflictRange(beginKey: storeInfoKey, endKey: storeInfoKey + [0x00], type: .read)
        if existenceCheck == .errorIfExists { throw RecordStoreError.storeAlreadyExists }
        try Self.validateHeader(info, bypassFullStoreLockReason: bypassFullStoreLockReason)
        state.withLock {
            $0.header = info
            $0.indexStates = entry.indexStates
        }
        return true
    }

    /// Opens (creating if necessary) the record store at the subspace named by `path`.
    public static func open(
        context: FDBRecordContext, path: KeySpacePath, metaData: RecordMetaData,
        existenceCheck: StoreExistenceCheck = .errorIfNoInfoAndNotEmpty,
        userVersion: Int? = nil,
        bypassFullStoreLockReason: String? = nil,
        stateCache: RecordStoreStateCache? = nil
    ) async throws -> FDBRecordStore {
        try await open(
            context: context, subspace: path.toSubspace(), metaData: metaData,
            existenceCheck: existenceCheck, userVersion: userVersion,
            bypassFullStoreLockReason: bypassFullStoreLockReason, stateCache: stateCache)
    }

    /// Opens a store without checking or upgrading its header or metadata version — Java's
    /// `uncheckedOpen`. Index states are still loaded. Used internally by migration.
    static func uncheckedOpen(
        context: FDBRecordContext, subspace: Subspace, metaData: RecordMetaData
    ) async throws -> FDBRecordStore {
        let store = FDBRecordStore(context: context, subspace: subspace, metaData: metaData)
        if let bytes = try await store.transaction.getValue(for: store.storeInfoKey) {
            let header = try DataStoreInfo(decoding: bytes)
            store.state.withLock { $0.header = header }
        }
        try await store.loadIndexStates()
        return store
    }

    /// The store header as of this transaction.
    public var header: DataStoreInfo { state.withLock { $0.header } }

    private func checkVersion(
        existenceCheck: StoreExistenceCheck, userVersion: Int?, bypassFullStoreLockReason: String?
    ) async throws {
        // Non-snapshot: any concurrent header change (format/metadata upgrade, lock, migration
        // fence) makes this transaction conflict.
        let headerBytes = try await transaction.getValue(for: storeInfoKey)
        var info: DataStoreInfo
        if let headerBytes {
            info = try DataStoreInfo(decoding: headerBytes)
            if existenceCheck == .errorIfExists { throw RecordStoreError.storeAlreadyExists }
            try Self.validateHeader(info, bypassFullStoreLockReason: bypassFullStoreLockReason)
        } else {
            // No Java header. A pre-Java-layout Swift store keeps its header elsewhere.
            if let legacy = try await transaction.getValue(for: legacyFormatVersionKey) {
                throw RecordStoreError.legacyStoreNeedsMigration(
                    formatVersion: Int(LegacyStoreMigration.decodeLegacyInt(legacy) ?? -1))
            }
            if existenceCheck == .errorIfNotExists { throw RecordStoreError.storeDoesNotExist }
            if existenceCheck != .none {
                let (begin, end) = subspace.range
                let first = try await transaction.getRangeNative(
                    beginSelector: .firstGreaterOrEqual(begin), endSelector: .firstGreaterOrEqual(end),
                    limit: 1, snapshot: true)
                if !first.records.isEmpty { throw RecordStoreError.storeHasNoHeaderButIsNotEmpty }
            }
            info = DataStoreInfo()
        }
        state.withLock { $0.header = info }
        try await loadIndexStates()

        var dirty = false
        let newStore = info.formatVersion == 0

        if let userVersion {
            let old = newStore ? -1 : info.userVersion
            if old > userVersion { throw RecordStoreError.staleUserVersion(stored: old, local: userVersion) }
            if old != userVersion {
                info.userVersion = userVersion
                dirty = true
            }
        }

        let oldFormat = info.formatVersion
        let newFormat = max(oldFormat, FormatVersion.current.rawValue)
        let oldMetaDataVersion = newStore ? -1 : info.metaDataVersion
        if oldMetaDataVersion > metaData.version {
            throw RecordStoreError.staleMetaData(stored: oldMetaDataVersion, local: metaData.version)
        }
        if oldFormat != newFormat || oldMetaDataVersion != metaData.version {
            dirty = true
            info.formatVersion = newFormat
            if oldMetaDataVersion != metaData.version {
                info.metaDataVersion = metaData.version
                try await rebuildIndexesSince(oldMetaDataVersion, newStore: newStore)
            }
        }
        try await handleNoLongerUniqueIndexes(changedSince: oldMetaDataVersion)
        if oldMetaDataVersion != metaData.version || newStore {
            let before = info.recordCountKey
            try await rebuildRecordCountsIfNeeded(&info, newStore: newStore)
            if before != info.recordCountKey { dirty = true }
            try await removeReplacedIndexes()
        }

        if dirty {
            info.lastUpdateTime = UInt64(Date().timeIntervalSince1970 * 1000)
            try saveHeader(info)
        }
    }

    static func validateHeader(_ info: DataStoreInfo, bypassFullStoreLockReason: String?) throws {
        let format = info.formatVersion
        guard format <= FormatVersion.current.rawValue else {
            throw RecordStoreError.incompatibleFormatVersion(found: format, expected: FormatVersion.current.rawValue)
        }
        guard format >= FormatVersion.minimumSupported.rawValue else {
            throw RecordStoreError.incompatibleFormatVersion(found: format, expected: FormatVersion.current.rawValue)
        }
        if info.omitUnsplitRecordSuffix {
            throw RecordStoreError.unsupportedStoreFeature("omit_unsplit_record_suffix")
        }
        if let lock = info.storeLockState {
            if lock.state == .fullStore {
                if bypassFullStoreLockReason == nil || bypassFullStoreLockReason != lock.reason {
                    throw RecordStoreError.storeIsLocked(state: .fullStore, reason: lock.reason)
                }
            } else if lock.state == .unspecified, format >= FormatVersion.fullStoreLock.rawValue {
                throw RecordStoreError.storeIsLocked(state: .unspecified, reason: lock.reason)
            }
        }
    }

    func saveHeader(_ info: DataStoreInfo) throws {
        let wasCacheable = header.cacheable
        transaction.setValue(info.encode(), for: storeInfoKey)
        state.withLock { $0.header = info }
        if wasCacheable || info.cacheable { storeStateChanged() }
    }

    /// Java's `setDirtyStoreState` + `setMetaDataVersionStamp` for cacheable stores.
    private func storeStateChanged() {
        context.markStoreStateDirty()
        if header.cacheable { context.setMetaDataVersionStamp() }
    }

    /// Makes the store's header and index states cacheable across transactions via a
    /// ``RecordStoreStateCache`` (Java's `setStateCacheabilityAsync`). Every later state change
    /// bumps the cluster-wide meta-data version stamp, invalidating all caches — so only mark a
    /// few hot stores cacheable.
    public func setStateCacheability(_ cacheable: Bool) async throws {
        guard header.cacheable != cacheable else { return }
        try await updateHeader { $0.cacheable = cacheable }
        context.setMetaDataVersionStamp()
    }

    /// Mutates and persists the header (Java's `updateStoreHeaderAsync`).
    func updateHeader(_ body: (inout DataStoreInfo) -> Void) async throws {
        // Re-read with conflict so concurrent header updates serialize.
        guard let bytes = try await transaction.getValue(for: storeInfoKey) else {
            throw RecordStoreError.storeDoesNotExist
        }
        var info = try DataStoreInfo(decoding: bytes)
        body(&info)
        info.lastUpdateTime = UInt64(Date().timeIntervalSince1970 * 1000)
        try saveHeader(info)
    }

    /// Java's `checkRebuildIndexes`: clears removed indexes and decides the state of every index
    /// whose definition is newer than the store's recorded metadata version.
    private func rebuildIndexesSince(_ oldMetaDataVersion: Int, newStore: Bool) async throws {
        for former in metaData.formerIndexes where former.removedVersion > oldMetaDataVersion {
            let key = Tuple(former.subspaceKey)
            for space in [indexesSubspace, indexSecondarySpace, indexRangeSpace,
                          indexUniquenessViolationsSpace, indexBuildSpace] {
                let (b, e) = space.subspace(key).range
                transaction.clearRange(beginKey: b, endKey: e)
            }
            if let name = former.formerName {
                transaction.clear(key: indexStateKey(name))
                state.withLock { _ = $0.indexStates.removeValue(forKey: name) }
            }
        }

        let changed = metaData.allIndexes.filter { $0.lastModifiedVersion > oldMetaDataVersion }
        guard !changed.isEmpty else { return }
        if newStore {
            // A brand-new store gets every index for free.
            for index in changed { try await setIndexState(index.name, .readable) }
            return
        }
        // Without a record-count index Java asks "is the store empty?" (one-row scan) and treats
        // any record as too many to rebuild inline.
        let (begin, end) = recordsSubspace.range
        let firstRecord = try await transaction.getRangeNative(
            beginSelector: .firstGreaterOrEqual(begin), endSelector: .firstGreaterOrEqual(end),
            limit: 1, snapshot: true)
        let storeIsEmpty = firstRecord.records.isEmpty
        if storeIsEmpty {
            // Conflict on emptiness: a concurrent insert must not slip in under a readable index.
            try transaction.addConflictRange(beginKey: begin, endKey: end, type: .read)
        }
        for index in changed {
            let onNewType = index.syntheticTypeName == nil && index.recordTypeNames.allSatisfy { name in
                (metaData.recordType(named: name)?.sinceVersion ?? Int.min) > oldMetaDataVersion
            }
            // The definition changed (or the index is new): drop any stale data first.
            clearIndexData(index)
            if !index.replacedByIndexNames.isEmpty {
                try await setIndexState(index.name, .disabled)
            } else if onNewType || storeIsEmpty {
                try await setIndexState(index.name, .readable)
            } else {
                try await setIndexState(index.name, .disabled)
            }
        }
    }

    /// Java's `handleNoLongerUniqueIndex`: an index that stopped being unique without a version
    /// bump drops its violations and leaves `readableUniquePending`.
    private func handleNoLongerUniqueIndexes(changedSince oldMetaDataVersion: Int) async throws {
        for index in metaData.allIndexes where !index.unique && index.lastModifiedVersion <= oldMetaDataVersion {
            let current = state.withLock { $0.indexStates[index.name] } ?? .readable
            guard current == .readableUniquePending || current == .writeOnly else { continue }
            let (b, e) = indexUniquenessViolationsSubspace(index).range
            transaction.clearRange(beginKey: b, endKey: e)
            if current == .readableUniquePending {
                try await setIndexState(index.name, .readable)
            }
        }
    }

    // MARK: - Index states

    private func loadIndexStates() async throws {
        // Snapshot read of the whole state space; a conflict is added per index when its state
        // is actually used (Java's `addIndexStateReadConflict`).
        var states: [String: IndexState] = [:]
        let (begin, end) = indexStateSpace.range
        for try await (key, value) in transaction.getRange(beginKey: begin, endKey: end, snapshot: true) {
            guard let name = try indexStateSpace.unpack(key).first as? String,
                  let code = Self.decodeTupleInt(value),
                  let indexState = IndexState(rawValue: Int(code)) else {
                throw RecordStoreError.corruptHeader
            }
            states[name] = indexState
        }
        state.withLock { $0.indexStates = states }
    }

    private func addIndexStateReadConflict(_ name: String) {
        let first = state.withLock { $0.stateConflicts.insert(name).inserted }
        guard first else { return }
        let key = indexStateKey(name)
        try? transaction.addConflictRange(beginKey: key, endKey: key + [0x00], type: .read)
    }

    /// The build state of the named index. Reading it adds the index's state key as a read
    /// conflict, so a concurrent state change fails this transaction (as in Java).
    public func indexState(named name: String) -> IndexState {
        addIndexStateReadConflict(name)
        return state.withLock { $0.indexStates[name] } ?? .readable
    }

    /// Whether queries may use the named index.
    public func isIndexScannable(_ name: String) -> Bool { indexState(named: name).isScannable }

    /// The names of indexes currently usable by queries.
    func readableIndexNames(for recordType: ErasedRecordType) -> Set<String> {
        Set(recordType.indexes.map(\.name).filter { indexState(named: $0).isScannable })
    }

    /// Writes an index state (Java's `updateIndexState`): readable clears the key.
    private func setIndexState(_ name: String, _ newState: IndexState) async throws {
        addIndexStateReadConflict(name)
        let key = indexStateKey(name)
        if newState == .readable {
            transaction.clear(key: key)
        } else {
            transaction.setValue(Tuple(Int64(newState.rawValue)).encode(), for: key)
        }
        state.withLock { state in
            if newState == .readable { state.indexStates.removeValue(forKey: name) } else { state.indexStates[name] = newState }
        }
        storeStateChanged()
    }

    func erasedIndexOrThrow(_ name: String) throws -> ErasedIndex {
        guard let found = metaData.index(named: name) else { throw RecordStoreError.unknownIndex(name) }
        return found
    }

    /// Java's `markIndexNotReadable`: moves an index to a non-readable state. When leaving the
    /// readable state, a fully-built marker is put in the (cleared) range set so writes keep
    /// maintaining the whole index.
    private func markIndexNotReadable(_ name: String, _ newState: IndexState) async throws -> Bool {
        let index = try erasedIndexOrThrow(name)
        addIndexStateReadConflict(name)
        let previous = try await transaction.getValue(for: indexStateKey(name))
        if previous == nil {
            let rangeSet = indexRangeSet(index)
            if try await rangeSet.isEmpty(transaction) {
                _ = try await rangeSet.insertRange(transaction, begin: nil, end: nil)
            }
            try await setIndexState(name, newState)
            return true
        }
        if Self.decodeTupleInt(previous!).map({ Int($0) }) != newState.rawValue {
            try await setIndexState(name, newState)
            return true
        }
        return false
    }

    /// Marks an index write-only: maintained on writes, ignored by queries. Returns whether the
    /// state changed. Does not clear existing data (see ``clearAndMarkIndexWriteOnly(_:)``).
    @discardableResult
    public func markIndexWriteOnly(_ name: String) async throws -> Bool {
        try await markIndexNotReadable(name, .writeOnly)
    }

    /// Marks an index disabled (not maintained) and clears its data. Returns whether the state
    /// changed.
    @discardableResult
    public func markIndexDisabled(_ name: String) async throws -> Bool {
        let changed = try await markIndexNotReadable(name, .disabled)
        if changed { clearIndexData(try erasedIndexOrThrow(name)) }
        return changed
    }

    /// Clears an index's data and marks it write-only, ready for a fresh build.
    public func clearAndMarkIndexWriteOnly(_ name: String) async throws {
        let index = try erasedIndexOrThrow(name)
        // Mark first, then clear (as Java does): marking a readable index write-only records it
        // as fully built, and the clear must wipe that marker too.
        _ = try await markIndexNotReadable(name, .writeOnly)
        clearIndexData(index)
    }

    /// Marks an index readable — Java's `markIndexReadable`. Fails with
    /// ``RecordStoreError/indexNotBuilt(_:)`` if any range is unbuilt, and for a unique index with
    /// recorded violations fails with ``RecordStoreError/uniquenessViolation(index:)`` unless
    /// `allowUniquePending`, in which case the index becomes ``IndexState/readableUniquePending``.
    @discardableResult
    public func markIndexReadable(_ name: String, allowUniquePending: Bool = false) async throws -> Bool {
        let index = try erasedIndexOrThrow(name)
        if indexState(named: name) == .readable { return false }
        if try await firstUnbuiltRange(index) != nil {
            throw RecordStoreError.indexNotBuilt(name)
        }
        if index.unique, try await hasUniquenessViolations(index) {
            guard allowUniquePending else { throw RecordStoreError.uniquenessViolation(index: name) }
            if indexState(named: name) == .readableUniquePending { return false }
            try await setIndexState(name, .readableUniquePending)
            return true
        }
        try await setIndexState(name, .readable)
        clearReadableIndexBuildData(index)
        try await removeReplacedIndexes()
        return true
    }

    /// The first primary-key range not yet covered by the index's built-range set.
    func firstUnbuiltRange(_ index: ErasedIndex) async throws -> (begin: FDB.Bytes, end: FDB.Bytes)? {
        try await indexRangeSet(index).missingRanges(transaction, begin: nil, end: nil, limit: 1).first
    }

    /// Clears everything an index stores (entries, secondary data, built ranges, uniqueness
    /// violations, build metadata except the session lock) — Java's `clearIndexData`.
    func clearIndexData(_ index: ErasedIndex) {
        for space in [indexSubspace(index), indexSecondarySubspace(index), indexRangeSubspace(index),
                      indexUniquenessViolationsSubspace(index)] {
            let (b, e) = space.range
            transaction.clearRange(beginKey: b, endKey: e)
        }
        clearIndexBuildDataButTheLock(index)
    }

    private func clearIndexBuildDataButTheLock(_ index: ErasedIndex) {
        let build = indexBuildSubspace(index)
        let lock = indexBuildLockSubspace(index)
        let (b, e) = build.range
        transaction.clearRange(beginKey: b, endKey: lock.range.begin)
        transaction.clearRange(beginKey: lock.range.end, endKey: e)
    }

    /// Java's `clearReadableIndexBuildData` + `eraseAllIndexingDataButTheLockAndRangeSet`.
    private func clearReadableIndexBuildData(_ index: ErasedIndex) {
        let (b, e) = indexRangeSubspace(index).range
        transaction.clearRange(beginKey: b, endKey: e)
        clearIndexBuildDataButTheLock(index)
    }

    /// Removes all data for an index and marks it disabled, so it is neither maintained nor
    /// used until rebuilt. To retire an index permanently, drop it from the metadata and list it
    /// in ``RecordMetaData/formerIndexes``.
    public func clearIndex(named name: String) async throws {
        _ = try await markIndexDisabled(name)
        clearIndexData(try erasedIndexOrThrow(name))
    }

    // MARK: - Record counts (Java's record count key)

    /// `S / 4`: per-key record counts maintained when the metadata has a record count key.
    var recordCountSpace: Subspace { subspace.child(RecordStoreKeyspace.recordCount.rawValue) }

    /// Java's `addRecordCount`: +1 on insert, -1 on delete (an update that changes the key's
    /// value is not re-counted, exactly as in Java).
    private func addRecordCount(_ record: IndexableRecord, delta: Int64) {
        guard let countKey = metaData.recordCountKey, header.recordCountState != .disabled else { return }
        let key = countKey.evaluate(record.message).first.map {
            record.recordType.resolveColumns($0, version: record.version?.versionstamp)
        } ?? []
        transaction.atomicOp(
            key: recordCountSpace.pack(Tuple(key)), param: IndexMaintainer.littleEndian(delta), mutationType: .add)
    }

    /// The number of records counted under `key` (a prefix of the record count key's columns;
    /// empty for all) — Java's `getSnapshotRecordCount`. Requires a record count key whose
    /// state is readable.
    public func snapshotRecordCount(key: Tuple = Tuple()) async throws -> Int64 {
        guard metaData.recordCountKey != nil, (header.recordCountState ?? .readable) == .readable else {
            throw RecordStoreError.unsupportedStoreFeature("no readable record count key")
        }
        let (begin, end) = recordCountSpace.range(key)
        var total: Int64 = 0
        for try await (_, value) in transaction.getRange(beginKey: begin, endKey: end, snapshot: true) {
            total &+= IndexMaintainer.decodeLittleEndian(value)
        }
        if let exact = try await transaction.getValue(for: recordCountSpace.pack(key), snapshot: true) {
            total &+= IndexMaintainer.decodeLittleEndian(exact)
        }
        return total
    }

    /// Java's `checkPossiblyRebuildRecordCounts`: when the record count key changed since the
    /// header recorded it, recount every record in this transaction (Java has no cross-
    /// transaction rebuild for counts either).
    private func rebuildRecordCountsIfNeeded(_ info: inout DataStoreInfo, newStore: Bool) async throws {
        let wanted = metaData.recordCountKey.map { RecordCountKeyCodec.encode($0, metaData: metaData) }
        guard wanted != info.recordCountKey else { return }
        let (b, e) = recordCountSpace.range
        transaction.clearRange(beginKey: b, endKey: e)
        transaction.clear(key: recordCountSpace.prefix)
        info.recordCountKey = wanted
        guard metaData.recordCountKey != nil else { info.recordCountState = nil; return }
        info.recordCountState = .readable
        state.withLock { $0.header = info }
        if newStore { return }
        for try await record in scanRecords() { addRecordCount(record, delta: 1) }
    }

    /// Sets whether the record count is maintained/queryable (Java's `RecordCountState`).
    public func setRecordCountState(_ newState: DataStoreInfo.RecordCountState) async throws {
        try await updateHeader { $0.recordCountState = newState }
    }

    // MARK: - Replaced indexes

    /// Java's `removeReplacedIndexes`: an index whose `replacedBy` indexes are all readable is
    /// disabled (and its data cleared).
    func removeReplacedIndexes() async throws {
        for index in metaData.allIndexes where !index.replacedByIndexNames.isEmpty {
            guard indexState(named: index.name) != .disabled else { continue }
            let replacements = index.replacedByIndexNames
            guard replacements.allSatisfy({ metaData.index(named: $0) != nil && indexState(named: $0) == .readable })
            else { continue }
            _ = try await markIndexDisabled(index.name)
        }
    }

    // MARK: - Store locks and header fields

    /// Sets the store lock (Java's `setStoreLockStateAsync`). A ``DataStoreInfo/LockState/fullStore``
    /// lock prevents any client from opening the store without the matching reason.
    public func setStoreLockState(_ lockState: DataStoreInfo.LockState, reason: String) async throws {
        try await updateHeader {
            $0.storeLockState = DataStoreInfo.StoreLockState(
                state: lockState, reason: reason, timestamp: Int64(Date().timeIntervalSince1970 * 1000))
        }
    }

    /// Clears the store lock.
    public func clearStoreLockState() async throws {
        try await updateHeader { $0.storeLockState = nil }
    }

    /// Reads a header user field.
    public func headerUserField(_ key: String) -> FDB.Bytes? { header.userFields[key] }

    /// Sets (or with `nil`, clears) a header user field.
    public func setHeaderUserField(_ key: String, _ value: FDB.Bytes?) async throws {
        try await updateHeader { $0.userFields[key] = value }
    }

    /// Increments the store's incarnation (Java's `updateIncarnation`), e.g. after moving the
    /// store to another cluster.
    public func incrementIncarnation() async throws {
        try await updateHeader { $0.incarnation += 1 }
    }

    private func checkRecordUpdatesAllowed() throws {
        if let lock = header.storeLockState, lock.state == .forbidRecordUpdate {
            throw RecordStoreError.storeIsLocked(state: .forbidRecordUpdate, reason: lock.reason)
        }
    }

    // MARK: - Save / load / delete

    /// Saves `record`, replacing any existing record with the same primary key and updating
    /// every index.
    @discardableResult
    public func save<M: SwiftProtobuf.Message & Sendable>(_ record: M) async throws -> FDBStoredRecord<M> {
        guard let recordType = metaData.recordType(for: M.self) else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }
        try checkRecordUpdatesAllowed()
        let primaryKey = recordType.primaryKey(record)
        let old = try await loadExisting(primaryKey)
        let pendingSynthetic = try await prepareSyntheticUpdate(old: old?.indexable, typeName: recordType.recordName)

        let serialized = try RecordUnion.wrap(record, field: recordType.unionFieldNumber)
        let version: FDBRecordVersion? = metaData.storeRecordVersions
            ? FDBRecordVersion.incomplete(localVersion: try context.claimLocalVersion())
            : nil
        try SplitHelper.saveWithSplit(
            transaction, subspace: recordsSubspace, key: primaryKey, serialized: serialized,
            version: version, splitLongRecords: metaData.splitLongRecords,
            clearBasedOnPreviousSizeInfo: true, previousSizeInfo: old?.raw, versionCache: context)

        let newRecord = IndexableRecord(recordType: recordType, primaryKey: primaryKey, message: record, version: version)
        if old == nil { addRecordCount(newRecord, delta: 1) }
        try await updateSecondaryIndexes(old: old?.indexable, new: newRecord)
        try await applySyntheticUpdate(pendingSynthetic, old: old?.indexable, new: newRecord)
        return FDBStoredRecord(recordType: recordType.recordName, primaryKey: primaryKey, record: record, version: version)
    }

    /// Saves `record` only if the stored version equals `expected` (an optimistic-concurrency
    /// "if unchanged" save). Pass `nil` to require that no record currently exists.
    ///
    /// Throws ``RecordStoreError/versionMismatch`` — not retryable — when the versions differ.
    @discardableResult
    public func save<M: SwiftProtobuf.Message & Sendable>(
        _ record: M, ifVersionMatches expected: FDBRecordVersion?
    ) async throws -> FDBStoredRecord<M> {
        guard let recordType = metaData.recordType(for: M.self) else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }
        guard metaData.storeRecordVersions else {
            throw RecordStoreError.recordVersioningDisabled(M.protoMessageName)
        }
        let current = try await loadExisting(recordType.primaryKey(record))?.indexable.version
        guard current == expected else { throw RecordStoreError.versionMismatch }
        return try await save(record)
    }

    /// Saves `record` only if no record with its primary key exists, else throws
    /// ``RecordStoreError/recordAlreadyExists(_:)`` (not retryable).
    @discardableResult
    public func insert<M: SwiftProtobuf.Message & Sendable>(_ record: M) async throws -> FDBStoredRecord<M> {
        guard let recordType = metaData.recordType(for: M.self) else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }
        if try await loadExisting(recordType.primaryKey(record)) != nil {
            throw RecordStoreError.recordAlreadyExists(M.protoMessageName)
        }
        return try await save(record)
    }

    /// Saves `record` only if a record with its primary key already exists, else throws
    /// ``RecordStoreError/recordDoesNotExist(_:)`` (not retryable).
    @discardableResult
    public func update<M: SwiftProtobuf.Message & Sendable>(_ record: M) async throws -> FDBStoredRecord<M> {
        guard let recordType = metaData.recordType(for: M.self) else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }
        if try await loadExisting(recordType.primaryKey(record)) == nil {
            throw RecordStoreError.recordDoesNotExist(M.protoMessageName)
        }
        return try await save(record)
    }

    /// Loads the record of type `M` with the given primary key, or `nil` if none exists.
    /// Throws ``RecordStoreError/recordTypeMismatch(expected:found:)`` if the key holds a record
    /// of another type.
    public func load<M: SwiftProtobuf.Message & Sendable>(
        _ type: M.Type, primaryKey: Tuple
    ) async throws -> FDBStoredRecord<M>? {
        guard let recordType = metaData.recordType(for: M.self) else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }
        guard let existing = try await loadExisting(primaryKey) else { return nil }
        guard existing.indexable.recordType.recordName == recordType.recordName,
              let message = existing.indexable.message as? M else {
            throw RecordStoreError.recordTypeMismatch(
                expected: recordType.recordName, found: existing.indexable.recordType.recordName)
        }
        return FDBStoredRecord(
            recordType: recordType.recordName, primaryKey: primaryKey, record: message,
            version: existing.indexable.version)
    }

    /// Convenience: load by primary-key elements, e.g. `load(Order.self, 42)`.
    public func load<M: SwiftProtobuf.Message & Sendable>(
        _ type: M.Type, _ primaryKey: any TupleElement...
    ) async throws -> FDBStoredRecord<M>? {
        try await load(type, primaryKey: Tuple(primaryKey))
    }

    /// Deletes the record of type `M` with the given primary key and its index entries.
    /// Returns `true` if a record was deleted.
    @discardableResult
    public func delete<M: SwiftProtobuf.Message & Sendable>(
        _ type: M.Type, primaryKey: Tuple
    ) async throws -> Bool {
        guard metaData.recordType(for: M.self) != nil else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }
        return try await deleteRecord(primaryKey: primaryKey)
    }

    /// Deletes whatever record is stored under `primaryKey` (Java's untyped `deleteRecord`).
    @discardableResult
    public func deleteRecord(primaryKey: Tuple) async throws -> Bool {
        try checkRecordUpdatesAllowed()
        guard let old = try await loadExisting(primaryKey) else { return false }
        let pendingSynthetic = try await prepareSyntheticUpdate(
            old: old.indexable, typeName: old.indexable.recordType.recordName)
        try SplitHelper.deleteSplit(
            transaction, subspace: recordsSubspace, key: primaryKey,
            splitLongRecords: metaData.splitLongRecords,
            clearBasedOnPreviousSizeInfo: true, previousSizeInfo: old.raw, versionCache: context)
        addRecordCount(old.indexable, delta: -1)
        if old.indexable.version?.isComplete == false {
            context.removeLocalVersion(key: recordsSubspace.subspace(primaryKey).pack(Tuple(SplitHelper.recordVersion)))
        }
        try await updateSecondaryIndexes(old: old.indexable, new: nil)
        try await applySyntheticUpdate(pendingSynthetic, old: old.indexable, new: nil)
        return true
    }

    /// Deletes the record only if its stored version equals `expected` (optimistic concurrency).
    @discardableResult
    public func delete<M: SwiftProtobuf.Message & Sendable>(
        _ type: M.Type, primaryKey: Tuple, ifVersionMatches expected: FDBRecordVersion?
    ) async throws -> Bool {
        guard metaData.recordType(for: M.self) != nil else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }
        guard metaData.storeRecordVersions else {
            throw RecordStoreError.recordVersioningDisabled(M.protoMessageName)
        }
        let current = try await loadExisting(primaryKey)?.indexable.version
        guard current == expected else { throw RecordStoreError.versionMismatch }
        return try await delete(type, primaryKey: primaryKey)
    }

    /// Removes every record and index entry in the store, keeping the header and index states
    /// (Java's `deleteAllRecords`).
    public func deleteAllRecords() async throws {
        try checkRecordUpdatesAllowed()
        for space in [recordsSubspace, indexesSubspace, indexSecondarySpace,
                      indexUniquenessViolationsSpace, recordCountSpace,
                      subspace.child(RecordStoreKeyspace.recordVersionSpace.rawValue)] {
            let (b, e) = space.range
            transaction.clearRange(beginKey: b, endKey: e)
        }
    }

    /// Deletes the whole store, header included (Java's `FDBRecordStore.deleteStore`).
    public static func deleteStore(context: FDBRecordContext, subspace: Subspace) {
        let (b, e) = subspace.range
        context.transaction.clearRange(beginKey: b, endKey: e)
        context.transaction.clear(key: subspace.prefix)
    }

    /// A previously stored record, as both raw split data and an indexable record.
    struct ExistingRecord {
        let raw: FDBRawRecord
        let indexable: IndexableRecord
    }

    /// Loads and decodes the record under `primaryKey`, whatever its type.
    func loadExisting(_ primaryKey: Tuple) async throws -> ExistingRecord? {
        guard let raw = try await SplitHelper.loadWithSplit(
            transaction, subspace: recordsSubspace, key: primaryKey,
            splitLongRecords: metaData.splitLongRecords, versionCache: context)
        else { return nil }
        return ExistingRecord(raw: raw, indexable: try decode(raw))
    }

    /// Decodes a raw record into its typed message.
    func decode(_ raw: FDBRawRecord) throws -> IndexableRecord {
        let (field, payload) = try RecordUnion.unwrap(raw.rawRecord)
        guard let recordType = metaData.recordType(unionField: field) else {
            throw RecordStoreError.unknownRecordType("union field \(field)")
        }
        return IndexableRecord(
            recordType: recordType, primaryKey: raw.primaryKey,
            message: try recordType.deserialize(payload), version: raw.version)
    }

    // MARK: - Scanning

    /// Scans raw records whose primary keys lie in `[begin, end)` (tuple-encoded bounds relative
    /// to the records subspace; `nil` = unbounded), decoding each.
    func scanRecords(
        begin: FDB.Bytes? = nil, end: FDB.Bytes? = nil, reverse: Bool = false, snapshot: Bool = false
    ) -> RecordStream {
        let raw = SplitHelper.scanRecords(
            transaction, subspace: recordsSubspace,
            range: (begin.map { recordsSubspace.prefix + $0 } ?? recordsSubspace.range.begin,
                    end.map { recordsSubspace.prefix + $0 } ?? recordsSubspace.range.end),
            reverse: reverse, snapshot: snapshot, versionCache: context)
        return raw.map { try self.decode($0.record) }
    }

    typealias RecordStream = AsyncThrowingMapSequence<SplitHelper.KeyValueUnsplitter<FDB.AsyncKVSequence>, IndexableRecord>

    /// The primary-key range (relative to the records subspace) holding records of `recordType`:
    /// its type-key prefix when the primary key starts with `recordType()`, else everything.
    func recordTypeRange(_ recordType: ErasedRecordType) -> (begin: FDB.Bytes?, end: FDB.Bytes?) {
        guard recordType.primaryKeyStartsWithRecordType else { return (nil, nil) }
        let prefix = Tuple(recordType.recordTypePrefix).encode()
        return (prefix, prefix + [0xFF])
    }

    /// A cursor over every record of type `M`, ordered by primary key.
    public func scan<M: SwiftProtobuf.Message & Sendable>(_ type: M.Type) throws -> RecordCursor<M> {
        guard let recordType = metaData.recordType(for: M.self) else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }
        let range = recordTypeRange(recordType)
        return typedCursor(scanRecords(begin: range.begin, end: range.end), recordType: recordType, filter: nil)
    }

    /// Adapts a stream of decoded records to a typed cursor, skipping other types.
    func typedCursor<M: SwiftProtobuf.Message & Sendable>(
        _ stream: RecordStream, recordType: ErasedRecordType,
        filter: QueryComponent<M>?
    ) -> RecordCursor<M> {
        let name = recordType.recordName
        return RecordCursor {
            var iterator = stream.makeAsyncIterator()
            return {
                while let next = try await iterator.next() {
                    guard next.recordType.recordName == name, let message = next.message as? M else { continue }
                    if let filter, !filter.eval(message) { continue }
                    return FDBStoredRecord(recordType: name, primaryKey: next.primaryKey, record: message, version: next.version)
                }
                return nil
            }
        }
    }

    /// All raw index-entry keys currently stored, across every index. Intended for tests.
    func allIndexKeys() async throws -> [FDB.Bytes] {
        let (begin, end) = indexesSubspace.range
        var keys: [FDB.Bytes] = []
        for try await (key, _) in transaction.getRange(beginKey: begin, endKey: end) {
            keys.append(key)
        }
        return keys
    }

    // MARK: - Helpers

    /// Returns the erased index of the given name on `M`, or throws if absent.
    func erasedIndex<M: SwiftProtobuf.Message>(_ type: M.Type, named name: String) throws -> ErasedIndex {
        guard let recordType = metaData.recordType(for: M.self) else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }
        guard let index = recordType.indexes.first(where: { $0.name == name }) else {
            throw RecordStoreError.unknownIndex(name)
        }
        return index
    }

    /// Like ``erasedIndex(_:named:)`` but also requires the index to be scannable — every index
    /// read goes through this, so no query sees a partially built index.
    func scannableIndex<M: SwiftProtobuf.Message>(_ type: M.Type, named name: String) throws -> ErasedIndex {
        let index = try erasedIndex(type, named: name)
        guard indexState(named: name).isScannable else { throw RecordStoreError.indexNotBuilt(name) }
        return index
    }

    static func encodeInt(_ value: Int) -> FDB.Bytes { Tuple(Int64(value)).encode() }

    /// Decodes a one-element integer tuple (index state codes, legacy header ints).
    static func decodeTupleInt(_ bytes: FDB.Bytes) -> Int64? {
        guard let first = (try? Tuple.decode(from: bytes))?.first else { return nil }
        if let value = first as? Int64 { return value }
        if let value = first as? Int { return Int64(value) }
        return nil
    }
}

/// Caches record stores' headers and index states across transactions, validated by the
/// cluster's meta-data version stamp — Java's `MetaDataVersionStampStoreStateCache`. Only stores
/// marked cacheable (``FDBRecordStore/setStateCacheability(_:)``) are cached. Share one instance
/// per database and pass it to ``FDBRecordStore/open(context:subspace:metaData:existenceCheck:userVersion:bypassFullStoreLockReason:stateCache:)``.
public final class RecordStoreStateCache: Sendable {
    struct Entry: Sendable {
        let stamp: FDB.Bytes?
        let header: DataStoreInfo
        let indexStates: [String: IndexState]
    }

    private let entries = Mutex<[FDB.Bytes: Entry]>([:])

    public init() {}

    func entry(for subspace: Subspace) -> Entry? { entries.withLock { $0[subspace.prefix] } }

    func record(subspace: Subspace, stamp: FDB.Bytes?, header: DataStoreInfo,
                indexStates: [String: IndexState], dirty: Bool) {
        entries.withLock { entries in
            guard let stamp, !dirty, header.cacheable else {
                entries.removeValue(forKey: subspace.prefix)
                return
            }
            if let existing = entries[subspace.prefix]?.stamp,
               !existing.lexicographicallyPrecedes(stamp), existing != stamp { return }
            entries[subspace.prefix] = Entry(stamp: stamp, header: header, indexStates: indexStates)
        }
    }

    /// Drops every cached state.
    public func clear() { entries.withLock { $0.removeAll() } }
}

/// A record as seen by index maintenance (Java's `FDBIndexableRecord`).
struct IndexableRecord: Sendable {
    let recordType: ErasedRecordType
    let primaryKey: Tuple
    let message: any SwiftProtobuf.Message & Sendable
    let version: FDBRecordVersion?

    /// For synthetic records: computes entries from the synthetic structure instead.
    let entriesOverride: (@Sendable (ErasedIndex) -> [[any TupleElement]])?

    /// The key an index build's range set tracks this record under (its own primary key, or for
    /// a synthetic record its first constituent's).
    let buildRangeKey: Tuple?

    init(recordType: ErasedRecordType, primaryKey: Tuple, message: any SwiftProtobuf.Message, version: FDBRecordVersion?,
         entriesOverride: (@Sendable (ErasedIndex) -> [[any TupleElement]])? = nil, buildRangeKey: Tuple? = nil) {
        self.buildRangeKey = buildRangeKey
        self.recordType = recordType
        self.primaryKey = primaryKey
        // Generated swift-protobuf messages are Sendable; the erased deserializer loses that.
        self.message = message as! any SwiftProtobuf.Message & Sendable
        self.version = version
        self.entriesOverride = entriesOverride
    }

    /// Index entries for `index`, with `version()` columns resolved to this record's version.
    func entries(for index: ErasedIndex) -> [[any TupleElement]] {
        if let entriesOverride { return entriesOverride(index) }
        return recordType.indexEntries(index, message, version: version?.versionstamp)
    }
}

/// Wraps records in the store's record union (Java's `RecordTypeUnion`): a message with one
/// length-delimited field per record type, so the stored bytes identify their own type.
enum RecordUnion {
    static func wrap(_ record: any SwiftProtobuf.Message, field: Int) throws -> FDB.Bytes {
        let payload: FDB.Bytes = try record.serializedBytes()
        var union = ProtoFields()
        union.setBytes(field, payload)
        return union.encode()
    }

    static func unwrap(_ bytes: FDB.Bytes) throws -> (field: Int, payload: FDB.Bytes) {
        guard let fields = try? ProtoFields(decoding: bytes),
              let last = fields.fields.last(where: { $0.wireType == .lengthDelimited }) else {
            throw RecordStoreError.corruptRecord
        }
        return (last.number, last.payload)
    }
}
#endif
