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

/// Computes and applies the index changes for a single record update.
///
/// A maintainer is given the record's index entries *before* and *after* the change (either
/// of which may be empty for an insert or delete) and is responsible for writing the right
/// keys into the index's subspace within the supplied transaction.
protocol IndexMaintainer {
    func update(
        transaction: any TransactionProtocol,
        indexSubspace: Subspace,
        oldEntries: [[any TupleElement]],
        newEntries: [[any TupleElement]],
        primaryKeyEncoded: FDB.Bytes
    ) async throws
}

/// Maintains a standard value index: `indexSubspace / <entryColumns...> / <primaryKey...>` → ∅.
///
/// Because tuple encoding is a plain concatenation of element encodings, the full entry key is
/// `indexSubspace.prefix + Tuple(entry).encode() + primaryKeyEncoded` — no need to re-decode
/// the primary key into elements. Only the keys that actually changed are written, so a save
/// that leaves an indexed field untouched performs no index writes.
struct ValueIndexMaintainer: IndexMaintainer {
    func update(
        transaction: any TransactionProtocol,
        indexSubspace: Subspace,
        oldEntries: [[any TupleElement]],
        newEntries: [[any TupleElement]],
        primaryKeyEncoded: FDB.Bytes
    ) async throws {
        let oldKeys = Set(oldEntries.map { key(for: $0, in: indexSubspace, primaryKeyEncoded: primaryKeyEncoded) })
        let newKeys = Set(newEntries.map { key(for: $0, in: indexSubspace, primaryKeyEncoded: primaryKeyEncoded) })

        for removed in oldKeys.subtracting(newKeys) {
            transaction.clear(key: removed)
        }
        for added in newKeys.subtracting(oldKeys) {
            transaction.setValue([], for: added)
        }
    }

    private func key(
        for entry: [any TupleElement], in indexSubspace: Subspace, primaryKeyEncoded: FDB.Bytes
    ) -> FDB.Bytes {
        indexSubspace.prefix + Tuple(entry).encode() + primaryKeyEncoded
    }
}

/// A value index that enforces uniqueness: before adding an entry it checks that no *other*
/// primary key already holds the same index key, throwing
/// ``RecordStoreError/uniquenessViolation(index:)`` if so.
///
/// The range read also makes concurrent inserts of the same value conflict in FoundationDB, so
/// two transactions can't both create a duplicate.
struct UniqueValueIndexMaintainer: IndexMaintainer {
    let indexName: String

    func update(
        transaction: any TransactionProtocol,
        indexSubspace: Subspace,
        oldEntries: [[any TupleElement]],
        newEntries: [[any TupleElement]],
        primaryKeyEncoded: FDB.Bytes
    ) async throws {
        let oldKeys = Set(oldEntries.map { indexSubspace.prefix + Tuple($0).encode() + primaryKeyEncoded })
        let newKeys = Set(newEntries.map { indexSubspace.prefix + Tuple($0).encode() + primaryKeyEncoded })

        for removed in oldKeys.subtracting(newKeys) {
            transaction.clear(key: removed)
        }

        for entry in newEntries {
            let entryPrefix = indexSubspace.prefix + Tuple(entry).encode()
            let fullKey = entryPrefix + primaryKeyEncoded
            if oldKeys.contains(fullKey) { continue } // unchanged entry for this record

            // Any existing entry under these columns belongs to a different primary key.
            for try await (existing, _) in transaction.getRange(
                beginKey: entryPrefix + [0x00], endKey: entryPrefix + [0xFF]
            ) where existing != fullKey {
                throw RecordStoreError.uniquenessViolation(index: indexName)
            }
            transaction.setValue([], for: fullKey)
        }
    }
}
#endif
