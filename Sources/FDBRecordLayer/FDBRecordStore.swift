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

    var transaction: any TransactionProtocol { context.transaction }

    private var formatVersionKey: FDB.Bytes { storeInfoSubspace.pack("format_version") }
    private var metaDataVersionKey: FDB.Bytes { storeInfoSubspace.pack("metadata_version") }

    init(context: FDBRecordContext, subspace: Subspace, metaData: RecordMetaData) {
        self.context = context
        self.subspace = subspace
        self.metaData = metaData
        self.storeInfoSubspace = subspace.child(Int64(0))
        self.recordsSubspace = subspace.child(Int64(1))
        self.indexesSubspace = subspace.child(Int64(2))
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

        for index in recordType.indexes {
            let indexSubspace = indexesSubspace.child(Int64(index.subspaceKey))
            let oldEntries = oldMessage.map { index.entries($0) } ?? []
            let newEntries = index.entries(record)
            try await indexMaintainer(for: index.type).update(
                transaction: transaction,
                indexSubspace: indexSubspace,
                oldEntries: oldEntries,
                newEntries: newEntries,
                primaryKeyEncoded: primaryKeyEncoded
            )
        }

        return FDBStoredRecord(recordType: recordType.recordName, primaryKey: Tuple(primaryKeyColumns), record: record)
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
        return FDBStoredRecord(recordType: recordType.recordName, primaryKey: primaryKey, record: message)
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
        for index in recordType.indexes {
            let indexSubspace = indexesSubspace.child(Int64(index.subspaceKey))
            try await indexMaintainer(for: index.type).update(
                transaction: transaction,
                indexSubspace: indexSubspace,
                oldEntries: index.entries(oldMessage),
                newEntries: [],
                primaryKeyEncoded: primaryKeyEncoded
            )
        }
        return true
    }

    /// Removes every record and index entry in the store (but keeps the header).
    public func deleteAllRecords() async throws {
        let records = recordsSubspace.range
        transaction.clearRange(beginKey: records.begin, endKey: records.end)
        let indexes = indexesSubspace.range
        transaction.clearRange(beginKey: indexes.begin, endKey: indexes.end)
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

    // MARK: - Internals

    func indexMaintainer(for type: IndexType) throws -> any IndexMaintainer {
        switch type {
        case .value, .rank, .min, .max:
            // These all store ordered (columns..., primaryKey) entries like a value index.
            // - rank: position is derived by counting entries before a value.
            // - min/max: the extremum is the first/last entry in a group's range, so deletes
            //   are handled correctly (no atomic-accumulator that can't be decremented).
            return ValueIndexMaintainer()
        case .count, .sum:
            return AggregateIndexMaintainer(kind: type)
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

    static func encodeInt(_ value: Int) -> FDB.Bytes {
        Tuple(Int64(value)).encode()
    }

    static func decodeInt(_ bytes: FDB.Bytes) -> Int64? {
        (try? Tuple.decode(from: bytes))?.first as? Int64
    }
}
#endif
