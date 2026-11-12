/*
 * LegacyStoreMigration.swift
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

/// Errors specific to migrating a store written by the pre-Java-layout Swift record layer.
public enum LegacyMigrationError: Error, Sendable {
    /// A legacy record's type key matches no record type in the metadata.
    case unknownLegacyRecordType(Int64)
    /// Two legacy records map to the same Java-layout primary key (records of different types
    /// sharing a primary key). Give the colliding types a `recordType()`-prefixed primary key.
    case primaryKeyCollision(Tuple)
    /// The legacy header names a format this migration doesn't know.
    case unknownLegacyFormat(Int64)
}

/// Migrates a record store from the pre-Java-layout Swift layer (legacy format versions 1–2) to
/// the Java Record Layer layout, in batches, without ever letting an old or new client write a
/// half-migrated store.
///
/// Legacy layout under `S`: header keys `S/0/("format_version")`, `S/0/("metadata_version")`,
/// `S/0/("index_state", name)`, `S/0/("index_build", name)`; records at `S/1/<typeKey>/<pk>` (raw
/// message bytes); index entries at `S/2/<positional key>/...`; versions at `S/3/<typeKey>/<pk>`.
///
/// Steps, each resumable:
/// 1. **Fence and lock** (one transaction). The legacy format key is overwritten with
///    ``fenceValue``: legacy clients read it (non-snapshot) on every open and accept only their
///    own exact version, so in-flight legacy transactions conflict and later ones fail with
///    `incompatibleFormatVersion`. The key is never deleted — a legacy client that found it
///    missing would treat the store as new. A Java header is written with a
///    ``DataStoreInfo/LockState/fullStore`` lock, so new-layout clients (Swift or Java) refuse to
///    open the store until migration finishes. Legacy index data and index state are cleared and
///    every index is marked disabled.
/// 2. **Stage**: legacy record keys are moved, unchanged, from `S/1` to a staging area under
///    `S/0/("swift_legacy_migration", 1)`. (Legacy and Java record keys share `S/1` and can collide
///    byte-for-byte, so records can't be rewritten in place.)
/// 3. **Convert**: staged records are re-keyed by their primary key, wrapped in the record union,
///    split if large, and written to `S/1` with their legacy version (from `S/3`) inline.
/// 4. **Unlock**: staging and the legacy version space are cleared and the lock is released.
/// 5. **Build**: every index is built with an ``OnlineIndexer``.
struct LegacyStoreMigration: Sendable {
    /// Written over the legacy format-version key to fence out legacy clients. Legacy clients
    /// accept only 1 or 2.
    static let fenceValue: Int64 = 1_000_000
    /// The full-store lock reason held during migration.
    static let lockReason = "swift-legacy-layout-migration"

    let source: any RecordTransactionSource
    let subspace: Subspace
    let metaData: RecordMetaData
    var batchKeyLimit = 500
    var batchByteLimit = 2_000_000

    private var legacyHeader: Subspace { subspace.child(Int64(0)) }
    private var legacyFormatKey: FDB.Bytes { legacyHeader.pack("format_version") }
    private var legacyMetaDataKey: FDB.Bytes { legacyHeader.pack("metadata_version") }
    private var staging: Subspace { legacyHeader.child("swift_legacy_migration", Int64(1)) }
    private var phaseKey: FDB.Bytes { legacyHeader.pack("swift_legacy_migration", Int64(0)) }
    private var records: Subspace { subspace.child(RecordStoreKeyspace.record.rawValue) }
    private var legacyVersions: Subspace { subspace.child(Int64(3)) }
    private var storeInfoKey: FDB.Bytes { subspace.pack(Tuple(RecordStoreKeyspace.storeInfo.rawValue)) }

    enum Phase: Int64 { case stage = 1, convert = 2, unlock = 3, build = 4 }

    static func decodeLegacyInt(_ bytes: FDB.Bytes) -> Int64? { FDBRecordStore.decodeTupleInt(bytes) }

    /// Runs (or resumes) the migration. Returns `false` if the store is not a legacy store.
    func run() async throws -> Bool {
        guard let start = try await transact({ try await self.begin($0) }) else { return false }
        var phase = start
        while phase == .stage {
            phase = try await transact { try await self.stageBatch($0) } ?? .stage
        }
        while phase == .convert {
            phase = try await transact { try await self.convertBatch($0) } ?? .convert
        }
        if phase == .unlock {
            _ = try await transact { try await self.unlock($0) }
            phase = .build
        }
        for index in metaData.allIndexes {
            try await OnlineIndexer(source: source, subspace: subspace, metaData: metaData, indexName: index.name)
                .buildIndex()
        }
        _ = try await transact { context -> Phase? in
            context.transaction.clear(key: self.phaseKey)
            return nil
        }
        return true
    }

    /// Step 1, or detection of where a previous run stopped.
    private func begin(_ context: FDBRecordContext) async throws -> Phase? {
        let tx = context.transaction
        if let phaseBytes = try await tx.getValue(for: phaseKey) {
            return Phase(rawValue: Self.decodeLegacyInt(phaseBytes) ?? 0) ?? .build
        }
        guard let legacy = try await tx.getValue(for: legacyFormatKey) else { return nil }
        let format = Self.decodeLegacyInt(legacy) ?? -1
        guard format == 1 || format == 2 else {
            if format == Self.fenceValue { return nil } // finished earlier
            throw LegacyMigrationError.unknownLegacyFormat(format)
        }
        if try await tx.getValue(for: storeInfoKey) != nil {
            // A Java header next to an unfenced legacy header: refuse to guess.
            throw RecordStoreError.storeHasNoHeaderButIsNotEmpty
        }
        let legacyMetaDataVersion = try await tx.getValue(for: legacyMetaDataKey)
            .flatMap(Self.decodeLegacyInt).map(Int.init) ?? 0
        if legacyMetaDataVersion > metaData.version {
            throw RecordStoreError.staleMetaData(stored: legacyMetaDataVersion, local: metaData.version)
        }

        // Fence legacy clients (never delete this key).
        tx.setValue(Tuple(Self.fenceValue).encode(), for: legacyFormatKey)
        // Drop legacy index data and state; indexes are rebuilt at the end.
        for prefix in [Tuple("index_state"), Tuple("index_build")] {
            let (b, e) = legacyHeader.range(prefix)
            tx.clearRange(beginKey: b, endKey: e)
        }
        let (ib, ie) = subspace.child(RecordStoreKeyspace.index.rawValue).range
        tx.clearRange(beginKey: ib, endKey: ie)

        // Java header, fully locked.
        var info = DataStoreInfo()
        info.formatVersion = FormatVersion.current.rawValue
        info.metaDataVersion = metaData.version
        info.lastUpdateTime = UInt64(Date().timeIntervalSince1970 * 1000)
        info.storeLockState = DataStoreInfo.StoreLockState(
            state: .fullStore, reason: Self.lockReason, timestamp: Int64(Date().timeIntervalSince1970 * 1000))
        tx.setValue(info.encode(), for: storeInfoKey)
        let stateSpace = subspace.child(RecordStoreKeyspace.indexStateSpace.rawValue)
        for index in metaData.allIndexes {
            tx.setValue(Tuple(Int64(IndexState.disabled.rawValue)).encode(), for: stateSpace.pack(index.name))
        }
        tx.setValue(Tuple(Phase.stage.rawValue).encode(), for: phaseKey)
        return .stage
    }

    /// Step 2: move one batch of legacy record keys into staging.
    private func stageBatch(_ context: FDBRecordContext) async throws -> Phase? {
        let tx = context.transaction
        if let other = try await otherPhase(tx, .stage) { return other }
        let (begin, end) = records.range
        let batch = try await tx.getRangeNative(
            beginSelector: .firstGreaterOrEqual(begin), endSelector: .firstGreaterOrEqual(end),
            limit: batchKeyLimit, snapshot: false)
        var bytes = 0
        var moved = 0
        for (key, value) in batch.records {
            tx.setValue(value, for: staging.prefix + key.dropFirst(records.prefix.count))
            tx.clear(key: key)
            moved += 1
            bytes += key.count + value.count
            if bytes > batchByteLimit { break }
        }
        if moved == 0 {
            tx.setValue(Tuple(Phase.convert.rawValue).encode(), for: phaseKey)
            return .convert
        }
        return nil
    }

    /// Step 3: convert one batch of staged records into the Java layout.
    private func convertBatch(_ context: FDBRecordContext) async throws -> Phase? {
        let tx = context.transaction
        if let other = try await otherPhase(tx, .convert) { return other }
        let store = try await FDBRecordStore.uncheckedOpen(context: context, subspace: subspace, metaData: metaData)
        let (begin, end) = staging.range
        let batch = try await tx.getRangeNative(
            beginSelector: .firstGreaterOrEqual(begin), endSelector: .firstGreaterOrEqual(end),
            limit: batchKeyLimit, snapshot: false)
        if batch.records.isEmpty {
            tx.setValue(Tuple(Phase.unlock.rawValue).encode(), for: phaseKey)
            return .unlock
        }
        var bytes = 0
        for (key, value) in batch.records {
            let elements = try staging.unpack(key)
            guard let typeKey = elements.first.flatMap(IndexMaintainer.integer) else {
                throw RecordStoreError.corruptRecord
            }
            guard let recordType = metaData.recordTypes.first(where: { Int64($0.legacyTypeKey) == typeKey }) else {
                throw LegacyMigrationError.unknownLegacyRecordType(typeKey)
            }
            let legacyPrimaryKey = Array(key.dropFirst(staging.prefix.count + Tuple(typeKey).encode().count))
            let message = try recordType.deserialize(value)
            let primaryKey = recordType.primaryKey(message)

            if try await store.loadExisting(primaryKey) != nil {
                throw LegacyMigrationError.primaryKeyCollision(primaryKey)
            }
            let legacyVersionKey = legacyVersions.prefix + Tuple(typeKey).encode() + legacyPrimaryKey
            var version: FDBRecordVersion?
            if metaData.storeRecordVersions, let raw = try await tx.getValue(for: legacyVersionKey) {
                // Legacy format 1 stored 10 bytes (local version 0); format 2 the full 12.
                version = FDBRecordVersion(bytes: raw.count == 10 ? raw + [0, 0] : raw)
            }
            tx.clear(key: legacyVersionKey)
            let serialized = try RecordUnion.wrap(message, field: recordType.unionFieldNumber)
            try SplitHelper.saveWithSplit(
                tx, subspace: records, key: primaryKey, serialized: serialized, version: version,
                splitLongRecords: metaData.splitLongRecords, versionCache: context)
            tx.clear(key: key)
            bytes += key.count + value.count
            if bytes > batchByteLimit { break }
        }
        return nil
    }

    /// Step 4: clear leftovers and release the lock.
    private func unlock(_ context: FDBRecordContext) async throws -> Phase? {
        let tx = context.transaction
        if let other = try await otherPhase(tx, .unlock) { return other }
        let (sb, se) = staging.range
        tx.clearRange(beginKey: sb, endKey: se)
        let (vb, ve) = legacyVersions.range
        tx.clearRange(beginKey: vb, endKey: ve)
        guard let bytes = try await tx.getValue(for: storeInfoKey) else { throw RecordStoreError.corruptHeader }
        var info = try DataStoreInfo(decoding: bytes)
        info.storeLockState = nil
        info.lastUpdateTime = UInt64(Date().timeIntervalSince1970 * 1000)
        tx.setValue(info.encode(), for: storeInfoKey)
        tx.setValue(Tuple(Phase.build.rawValue).encode(), for: phaseKey)
        return .build
    }

    /// The current phase if another migrator has moved past `expected`, else `nil`.
    private func otherPhase(_ tx: any TransactionProtocol, _ expected: Phase) async throws -> Phase? {
        let current = try await tx.getValue(for: phaseKey).flatMap(Self.decodeLegacyInt)
        if current == expected.rawValue { return nil }
        return current.flatMap(Phase.init(rawValue:)) ?? .build
    }

    /// Runs one migration transaction with FDB retries.
    private func transact<T: Sendable>(_ body: @Sendable (FDBRecordContext) async throws -> T) async throws -> T {
        var attempts = 0
        while true {
            let transaction = try source.createRecordTransaction()
            do {
                let context = FDBRecordContext(transaction: transaction)
                let result = try await body(context)
                try await context.commit()
                return result
            } catch let error as FDBError {
                attempts += 1
                guard error.isRetryable, attempts < 100 else { throw error }
                try await transaction.onError(error)
            }
        }
    }
}

extension DatabaseProtocol where Self: RecordTransactionSource {
    /// Migrates a store written by the pre-Java-layout Swift record layer to the Java Record
    /// Layer layout and builds its indexes. Safe to re-run: resumes an interrupted migration and
    /// returns `false` when the store is not (or no longer) a legacy store.
    ///
    /// Opening a legacy store fails with ``RecordStoreError/legacyStoreNeedsMigration(formatVersion:)``
    /// until this has run; during migration, opens fail with ``RecordStoreError/storeIsLocked(state:reason:)``.
    @discardableResult
    public func migrateLegacyRecordStore(subspace: Subspace, metaData: RecordMetaData) async throws -> Bool {
        try await LegacyStoreMigration(source: self, subspace: subspace, metaData: metaData).run()
    }
}

extension FDBTenant {
    /// Migrates a tenant-scoped legacy store. See ``FoundationDB/DatabaseProtocol/migrateLegacyRecordStore(subspace:metaData:)``.
    @discardableResult
    public func migrateLegacyRecordStore(subspace: Subspace, metaData: RecordMetaData) async throws -> Bool {
        try await LegacyStoreMigration(source: self, subspace: subspace, metaData: metaData).run()
    }
}
#endif
