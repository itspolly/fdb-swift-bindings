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

/// Errors raised by ``FDBRecordStore``.
public enum RecordStoreError: Error, Sendable {
    /// A record of a type not present in the metadata was saved/loaded.
    case unknownRecordType(String)
    /// The store on disk was written by an incompatible Record Layer format version.
    case incompatibleFormatVersion(found: Int, expected: Int)
    /// The store header could not be decoded.
    case corruptHeader
    /// An index type whose maintainer is not yet implemented was encountered.
    case unsupportedIndexType(IndexType)
    /// A query referenced an index name not present on the record type.
    case unknownIndex(String)
    /// A covering query's filter is not fully satisfiable by the named index alone.
    case queryNotCovered(String)
    /// A save would violate a unique index (another record already has the same key).
    case uniquenessViolation(index: String)
    /// A conditional save's expected version did not match the stored version. Not retryable —
    /// the caller should re-read and decide.
    case versionMismatch
    /// `save(_:ifVersionMatches:)` was used on a type that does not opt into record versions.
    case recordVersioningDisabled(String)
}

/// The primary entry point for storing, retrieving, and querying records.
///
/// A store is bound to one ``FDBRecordContext`` (transaction), a ``Subspace`` to occupy, and
/// a ``RecordMetaData`` schema. Open one with ``open(context:subspace:metaData:)`` (or the
/// ``KeySpacePath`` overload), which validates/initializes the store header.
///
/// Key layout, all under the store's subspace `S`:
/// - `S / 0 / ...` — store header (format + metadata versions)
/// - `S / 1 / <typeKey> / <primaryKey...>` → serialized record bytes
/// - `S / 2 / <indexKey> / <indexColumns...> / <primaryKey...>` → index entry
public final class FDBRecordStore {
    /// The transaction context the store operates in.
    public let context: FDBRecordContext
    /// The subspace the store occupies.
    public let subspace: Subspace
    /// The schema describing record types and indexes.
    public let metaData: RecordMetaData

    let storeInfoSubspace: Subspace
    let recordsSubspace: Subspace
    let indexesSubspace: Subspace
    let versionsSubspace: Subspace

    var transaction: any TransactionProtocol { context.transaction }

    /// Per-index build state, resolved when the store is opened.
    private var indexStates: [String: IndexState] = [:]

    private var formatVersionKey: FDB.Bytes { storeInfoSubspace.pack("format_version") }
    private var metaDataVersionKey: FDB.Bytes { storeInfoSubspace.pack("metadata_version") }
    private func indexStateKey(_ name: String) -> FDB.Bytes { storeInfoSubspace.pack("index_state", name) }
    private func buildProgressKey(_ name: String) -> FDB.Bytes { storeInfoSubspace.pack("index_build", name) }

    /// The build state of the named index (defaults to `.readable` for unknown names).
    public func indexState(named name: String) -> IndexState {
        indexStates[name] ?? .readable
    }

    /// The names of indexes currently usable by queries (readable).
    func readableIndexNames(for recordType: ErasedRecordType) -> Set<String> {
        Set(recordType.indexes.map { $0.name }.filter { indexState(named: $0) == .readable })
    }

    init(context: FDBRecordContext, subspace: Subspace, metaData: RecordMetaData) {
        self.context = context
        self.subspace = subspace
        self.metaData = metaData
        self.storeInfoSubspace = subspace.child(Int64(0))
        self.recordsSubspace = subspace.child(Int64(1))
        self.indexesSubspace = subspace.child(Int64(2))
        self.versionsSubspace = subspace.child(Int64(3))
    }

    // MARK: - Opening

    /// Opens (creating if necessary) the record store at `subspace`.
    public static func open(
        context: FDBRecordContext, subspace: Subspace, metaData: RecordMetaData
    ) async throws -> FDBRecordStore {
        let store = FDBRecordStore(context: context, subspace: subspace, metaData: metaData)
        try await store.checkOrInitializeHeader()
        return store
    }

    /// Opens (creating if necessary) the record store at the subspace named by `path`.
    public static func open(
        context: FDBRecordContext, path: KeySpacePath, metaData: RecordMetaData
    ) async throws -> FDBRecordStore {
        try await open(context: context, subspace: path.toSubspace(), metaData: metaData)
    }

    private func checkOrInitializeHeader() async throws {
        if let existing = try await transaction.getValue(for: formatVersionKey) {
            guard let format = Self.decodeInt(existing) else { throw RecordStoreError.corruptHeader }
            guard Int(format) == recordLayerFormatVersion else {
                throw RecordStoreError.incompatibleFormatVersion(
                    found: Int(format), expected: recordLayerFormatVersion)
            }
            // Advance the stored metadata version if this metadata is newer.
            if let mvBytes = try await transaction.getValue(for: metaDataVersionKey),
               let mv = Self.decodeInt(mvBytes), Int(mv) < metaData.version {
                transaction.setValue(Self.encodeInt(metaData.version), for: metaDataVersionKey)
            }
        } else {
            transaction.setValue(Self.encodeInt(recordLayerFormatVersion), for: formatVersionKey)
            transaction.setValue(Self.encodeInt(metaData.version), for: metaDataVersionKey)
        }
        try await resolveIndexStates()
    }

    /// Loads each index's persisted state, or resolves a new index: `readable` when its record
    /// type is empty (nothing to backfill), otherwise `writeOnly` (maintained on writes, hidden
    /// from queries until built).
    private func resolveIndexStates() async throws {
        for recordType in metaData.recordTypes {
            for index in recordType.indexes {
                if let stored = try await transaction.getValue(for: indexStateKey(index.name)),
                   let raw = Self.decodeInt(stored), let state = IndexState(rawValue: Int(raw)) {
                    indexStates[index.name] = state
                    continue
                }
                let (begin, end) = recordsSubspace.child(Int64(recordType.typeKey)).range
                let firstBatch = try await transaction.getRangeNative(
                    beginSelector: .firstGreaterOrEqual(begin), endSelector: .firstGreaterOrEqual(end),
                    limit: 1, snapshot: false)
                let state: IndexState = firstBatch.records.isEmpty ? .readable : .writeOnly
                transaction.setValue(Self.encodeInt(state.rawValue), for: indexStateKey(index.name))
                indexStates[index.name] = state
            }
        }
    }

    // MARK: - Save / load / delete

    /// Saves `record`, replacing any existing record with the same primary key and updating
    /// every index of its type.
    @discardableResult
    public func save<M: SwiftProtobuf.Message & Sendable>(_ record: M) async throws -> FDBStoredRecord<M> {
        guard let recordType = metaData.recordType(for: M.self) else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }

        let primaryKeyColumns = recordType.primaryKeyColumns(record)
        let primaryKeyEncoded = Tuple(primaryKeyColumns).encode()
        let typeSubspace = recordsSubspace.child(Int64(recordType.typeKey))
        let recordKey = typeSubspace.prefix + primaryKeyEncoded

        // Read the prior version (if any) so indexes can be diffed precisely.
        let oldBytes = try await transaction.getValue(for: recordKey)
        let oldMessage = try oldBytes.map { try recordType.deserialize($0) }

        let serialized: [UInt8] = try record.serializedBytes()
        transaction.setValue(serialized, for: recordKey)

        for index in recordType.indexes where indexState(named: index.name) != .disabled {
            let indexSubspace = indexesSubspace.child(Int64(index.subspaceKey))
            let oldEntries = oldMessage.map { index.entries($0) } ?? []
            let newEntries = index.entries(record)
            try await indexMaintainer(for: index).update(
                transaction: transaction,
                indexSubspace: indexSubspace,
                oldEntries: oldEntries,
                newEntries: newEntries,
                primaryKeyEncoded: primaryKeyEncoded
            )
        }

        if recordType.storesVersions {
            stampVersion(recordType: recordType, primaryKeyEncoded: primaryKeyEncoded)
        }

        return FDBStoredRecord(recordType: recordType.recordName, primaryKey: Tuple(primaryKeyColumns), record: record)
    }

    /// Saves `record` only if the stored version equals `expected` (an optimistic-concurrency
    /// "if unchanged" save). Pass `nil` to require that no record currently exists.
    ///
    /// Throws ``RecordStoreError/versionMismatch`` — which is **not** retryable, so the
    /// surrounding `withTransaction`/`withRecordContext` does not silently retry — when the
    /// versions differ. The record type must opt in with ``RecordType/storingVersions(_:)``.
    @discardableResult
    public func save<M: SwiftProtobuf.Message & Sendable>(
        _ record: M, ifVersionMatches expected: FDBRecordVersion?
    ) async throws -> FDBStoredRecord<M> {
        guard let recordType = metaData.recordType(for: M.self) else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }
        guard recordType.storesVersions else {
            throw RecordStoreError.recordVersioningDisabled(M.protoMessageName)
        }
        let primaryKeyEncoded = Tuple(recordType.primaryKeyColumns(record)).encode()
        // Non-snapshot read so a concurrent change to this record's version conflicts.
        let current = try await readVersion(recordType: recordType, primaryKeyEncoded: primaryKeyEncoded)
        guard current == expected else {
            throw RecordStoreError.versionMismatch
        }
        return try await save(record)
    }

    /// Loads the record of type `M` with the given primary key, or `nil` if none exists.
    public func load<M: SwiftProtobuf.Message & Sendable>(
        _ type: M.Type, primaryKey: Tuple
    ) async throws -> FDBStoredRecord<M>? {
        guard let recordType = metaData.recordType(for: M.self) else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }
        let recordKey = recordsSubspace.child(Int64(recordType.typeKey)).prefix + primaryKey.encode()
        guard let bytes = try await transaction.getValue(for: recordKey) else { return nil }
        let message = try M(serializedBytes: bytes)
        let version = recordType.storesVersions
            ? try await readVersion(recordType: recordType, primaryKeyEncoded: primaryKey.encode())
            : nil
        return FDBStoredRecord(
            recordType: recordType.recordName, primaryKey: primaryKey, record: message, version: version)
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
        guard let recordType = metaData.recordType(for: M.self) else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }
        let recordKey = recordsSubspace.child(Int64(recordType.typeKey)).prefix + primaryKey.encode()
        guard let bytes = try await transaction.getValue(for: recordKey) else { return false }
        let oldMessage = try recordType.deserialize(bytes)
        transaction.clear(key: recordKey)

        let primaryKeyEncoded = primaryKey.encode()
        for index in recordType.indexes where indexState(named: index.name) != .disabled {
            let indexSubspace = indexesSubspace.child(Int64(index.subspaceKey))
            try await indexMaintainer(for: index).update(
                transaction: transaction,
                indexSubspace: indexSubspace,
                oldEntries: index.entries(oldMessage),
                newEntries: [],
                primaryKeyEncoded: primaryKeyEncoded
            )
        }
        if recordType.storesVersions {
            transaction.clear(key: versionKey(recordType: recordType, primaryKeyEncoded: primaryKeyEncoded))
        }
        return true
    }

    /// Deletes the record only if its stored version equals `expected` (optimistic concurrency).
    ///
    /// Throws ``RecordStoreError/versionMismatch`` (not retryable) when the versions differ. Pass
    /// `nil` to require that no record currently exists (in which case this is a no-op returning
    /// `false`). The record type must opt in with ``RecordType/storingVersions(_:)``.
    @discardableResult
    public func delete<M: SwiftProtobuf.Message & Sendable>(
        _ type: M.Type, primaryKey: Tuple, ifVersionMatches expected: FDBRecordVersion?
    ) async throws -> Bool {
        guard let recordType = metaData.recordType(for: M.self) else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }
        guard recordType.storesVersions else {
            throw RecordStoreError.recordVersioningDisabled(M.protoMessageName)
        }
        // Non-snapshot read so a concurrent change to this record's version conflicts.
        let current = try await readVersion(recordType: recordType, primaryKeyEncoded: primaryKey.encode())
        guard current == expected else {
            throw RecordStoreError.versionMismatch
        }
        return try await delete(type, primaryKey: primaryKey)
    }

    /// Removes every record and index entry in the store (but keeps the header).
    public func deleteAllRecords() async throws {
        let records = recordsSubspace.range
        transaction.clearRange(beginKey: records.begin, endKey: records.end)
        let indexes = indexesSubspace.range
        transaction.clearRange(beginKey: indexes.begin, endKey: indexes.end)
        let versions = versionsSubspace.range
        transaction.clearRange(beginKey: versions.begin, endKey: versions.end)
    }

    // MARK: - Scanning

    /// A cursor over every record of type `M`, ordered by primary key.
    public func scan<M: SwiftProtobuf.Message & Sendable>(_ type: M.Type) throws -> RecordCursor<M> {
        guard let recordType = metaData.recordType(for: M.self) else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }
        let typeSubspace = recordsSubspace.child(Int64(recordType.typeKey))
        let (begin, end) = typeSubspace.range
        let tx = transaction
        let name = recordType.recordName
        return RecordCursor {
            var iterator = tx.getRange(beginKey: begin, endKey: end).makeAsyncIterator()
            return {
                guard let (key, value) = try await iterator.next() else { return nil }
                let primaryKeyElements = try typeSubspace.unpack(key)
                let message = try M(serializedBytes: value)
                return FDBStoredRecord(recordType: name, primaryKey: Tuple(primaryKeyElements), record: message)
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

    /// Removes all data for an index: its entries plus its persisted state and build progress.
    ///
    /// Use this when retiring an index from the schema: call `clearIndex` while the index is
    /// still declared, then drop it from the metadata and never reuse its key. Because each
    /// index occupies its own key subspace, clearing one never affects another.
    public func clearIndex(named name: String) async throws {
        guard let recordType = metaData.recordType(forIndexNamed: name),
              let index = recordType.indexes.first(where: { $0.name == name }) else {
            throw RecordStoreError.unknownIndex(name)
        }
        let (begin, end) = indexesSubspace.child(Int64(index.subspaceKey)).range
        transaction.clearRange(beginKey: begin, endKey: end)
        transaction.clear(key: indexStateKey(name))
        transaction.clear(key: buildProgressKey(name))
        indexStates.removeValue(forKey: name)
    }

    // MARK: - Index building

    /// Backfills one batch of existing records into the named index within this transaction,
    /// resuming from persisted progress. Returns `true` when the build is complete (state has
    /// been flipped to `readable`). Drive it across transactions via
    /// ``FoundationDB/DatabaseProtocol/buildIndex(subspace:metaData:indexName:batchSize:)``.
    func backfillIndex(named name: String, batchSize: Int) async throws -> Bool {
        guard let recordType = metaData.recordType(forIndexNamed: name),
              let index = recordType.indexes.first(where: { $0.name == name }) else {
            throw RecordStoreError.unknownIndex(name)
        }
        let typeSubspace = recordsSubspace.child(Int64(recordType.typeKey))
        let progress = try await transaction.getValue(for: buildProgressKey(name))
        let begin = progress.map { typeSubspace.prefix + $0 + [0x00] } ?? typeSubspace.range.begin
        let end = typeSubspace.range.end

        let batch = try await transaction.getRangeNative(
            beginSelector: .firstGreaterOrEqual(begin), endSelector: .firstGreaterOrEqual(end),
            limit: batchSize, snapshot: false)

        let indexSubspace = indexesSubspace.child(Int64(index.subspaceKey))
        let maintainer = try indexMaintainer(for: index)
        var lastPrimaryKeyEncoded: FDB.Bytes?
        for (key, value) in batch.records {
            let primaryKeyEncoded = Array(key.dropFirst(typeSubspace.prefix.count))
            let message = try recordType.deserialize(value)
            try await maintainer.update(
                transaction: transaction,
                indexSubspace: indexSubspace,
                oldEntries: [],
                newEntries: index.entries(message),
                primaryKeyEncoded: primaryKeyEncoded
            )
            lastPrimaryKeyEncoded = primaryKeyEncoded
        }
        if let lastPrimaryKeyEncoded {
            transaction.setValue(lastPrimaryKeyEncoded, for: buildProgressKey(name))
        }

        if batch.more {
            return false
        }
        // Done: the index is now fully populated and usable by queries.
        transaction.setValue(Self.encodeInt(IndexState.readable.rawValue), for: indexStateKey(name))
        transaction.clear(key: buildProgressKey(name))
        indexStates[name] = .readable
        return true
    }

    // MARK: - Internals

    func indexMaintainer(for index: ErasedIndex) throws -> any IndexMaintainer {
        switch index.type {
        case .value, .rank, .min, .max:
            // These all store ordered (columns..., primaryKey) entries like a value index.
            // - rank: position is derived by counting entries before a value.
            // - min/max: the extremum is the first/last entry in a group's range, so deletes
            //   are handled correctly (no atomic-accumulator that can't be decremented).
            if index.unique, index.type == .value {
                return UniqueValueIndexMaintainer(indexName: index.name)
            }
            return ValueIndexMaintainer()
        case .count, .sum:
            return AggregateIndexMaintainer(kind: index.type)
        case .version:
            return VersionIndexMaintainer()
        }
    }

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

    // MARK: - Record versions

    private func versionKey(recordType: ErasedRecordType, primaryKeyEncoded: FDB.Bytes) -> FDB.Bytes {
        versionsSubspace.child(Int64(recordType.typeKey)).prefix + primaryKeyEncoded
    }

    /// Reads a record's stored version, or `nil` if it has none.
    private func readVersion(
        recordType: ErasedRecordType, primaryKeyEncoded: FDB.Bytes
    ) async throws -> FDBRecordVersion? {
        guard let bytes = try await transaction.getValue(
            for: versionKey(recordType: recordType, primaryKeyEncoded: primaryKeyEncoded)) else {
            return nil
        }
        return FDBRecordVersion(bytes: bytes)
    }

    /// Stamps the record's version with this transaction's commit versionstamp (resolved at
    /// commit). A 10-byte placeholder plus a little-endian offset of 0 tells FoundationDB to
    /// write the versionstamp as the whole value.
    private func stampVersion(recordType: ErasedRecordType, primaryKeyEncoded: FDB.Bytes) {
        let placeholder = FDB.Bytes(repeating: 0, count: 10)
        let param = placeholder + withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) }
        transaction.atomicOp(
            key: versionKey(recordType: recordType, primaryKeyEncoded: primaryKeyEncoded),
            param: param,
            mutationType: .setVersionstampedValue)
    }

    static func encodeInt(_ value: Int) -> FDB.Bytes {
        Tuple(Int64(value)).encode()
    }

    static func decodeInt(_ bytes: FDB.Bytes) -> Int64? {
        // Tuple decoding yields `Int` for the zero value but `Int64` otherwise; accept both.
        guard let first = (try? Tuple.decode(from: bytes))?.first else { return nil }
        if let value = first as? Int64 { return value }
        if let value = first as? Int { return Int64(value) }
        return nil
    }
}
#endif
