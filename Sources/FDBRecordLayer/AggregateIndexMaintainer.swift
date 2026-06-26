/*
 * AggregateIndexMaintainer.swift
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

/// Little-endian 8-byte encoding helpers for FDB atomic integer mutations.
enum LittleEndianInt {
    static func bytes(_ value: Int64) -> FDB.Bytes {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    static func value(_ bytes: FDB.Bytes) -> Int64 {
        var result: Int64 = 0
        for (offset, byte) in bytes.prefix(8).enumerated() {
            result |= Int64(byte) << (8 * offset)
        }
        return result
    }

    /// Reads an integer from a tuple element produced by ``IndexableValue``.
    static func from(_ element: any TupleElement) -> Int64? {
        if let v = element as? Int64 { return v }
        if let v = element as? UInt64, v <= UInt64(Int64.max) { return Int64(v) }
        return nil
    }
}

/// Maintains `count` and `sum` aggregate indexes using FDB atomic addition.
///
/// Entries are grouped by the index expression's columns:
/// - **count**: groups by *all* columns; each entry adds ±1 to its group's key.
/// - **sum**: the *last* column is the summed integer; the preceding columns form the group.
///
/// Because `add` is commutative, an update is applied as a subtraction of the old entries
/// followed by an addition of the new ones — no read needed.
struct AggregateIndexMaintainer: IndexMaintainer {
    let kind: IndexType

    func update(
        transaction: any TransactionProtocol,
        indexSubspace: Subspace,
        oldEntries: [[any TupleElement]],
        newEntries: [[any TupleElement]],
        primaryKeyEncoded: FDB.Bytes
    ) async throws {
        switch kind {
        case .count:
            for entry in oldEntries { addCount(transaction, indexSubspace, group: entry, delta: -1) }
            for entry in newEntries { addCount(transaction, indexSubspace, group: entry, delta: 1) }
        case .sum:
            for entry in oldEntries { addSum(transaction, indexSubspace, entry: entry, sign: -1) }
            for entry in newEntries { addSum(transaction, indexSubspace, entry: entry, sign: 1) }
        default:
            break
        }
    }

    private func addCount(
        _ transaction: any TransactionProtocol, _ indexSubspace: Subspace,
        group: [any TupleElement], delta: Int64
    ) {
        let key = indexSubspace.prefix + Tuple(group).encode()
        transaction.atomicOp(key: key, param: LittleEndianInt.bytes(delta), mutationType: .add)
    }

    private func addSum(
        _ transaction: any TransactionProtocol, _ indexSubspace: Subspace,
        entry: [any TupleElement], sign: Int64
    ) {
        guard let last = entry.last, let value = LittleEndianInt.from(last) else { return }
        let group = Array(entry.dropLast())
        let key = indexSubspace.prefix + Tuple(group).encode()
        transaction.atomicOp(key: key, param: LittleEndianInt.bytes(sign * value), mutationType: .add)
    }
}

/// Maintains a version index, ordering records by the transaction commit versionstamp.
///
/// Layout under the index subspace `I`:
/// - `I / 0 / <10-byte versionstamp> / <primaryKey...>` → ∅  (the ordered entries)
/// - `I / 1 / <primaryKey...>` → `<10-byte versionstamp>`   (reverse map, for update/delete)
///
/// The versionstamp is filled in atomically at commit via `setVersionstampedKey` /
/// `setVersionstampedValue`. The reverse map lets a later transaction find and clear the
/// previous entry when a record is updated or deleted (the versionstamp isn't known until the
/// original transaction committed, so it can't be derived locally).
struct VersionIndexMaintainer: IndexMaintainer {
    private static let versionstampLength = 10

    func update(
        transaction: any TransactionProtocol,
        indexSubspace: Subspace,
        oldEntries: [[any TupleElement]],
        newEntries: [[any TupleElement]],
        primaryKeyEncoded: FDB.Bytes
    ) async throws {
        let entriesSubspace = indexSubspace.child(Int64(0))
        let refSubspace = indexSubspace.child(Int64(1))
        let refKey = refSubspace.prefix + primaryKeyEncoded

        let oldExisted = !oldEntries.isEmpty
        let newExists = !newEntries.isEmpty

        // Remove any previous entry for this record (its versionstamp is in the reverse map).
        if oldExisted, let previousStamp = try await transaction.getValue(for: refKey) {
            let staleEntry = entriesSubspace.prefix + previousStamp + primaryKeyEncoded
            transaction.clear(key: staleEntry)
        }

        guard newExists else {
            // Delete: also drop the reverse-map entry.
            transaction.clear(key: refKey)
            return
        }

        // Write the new versionstamped entry: prefix + <stamp placeholder> + pk + offsetLE.
        let placeholder = FDB.Bytes(repeating: 0, count: Self.versionstampLength)
        let entryKeyPrefix = entriesSubspace.prefix
        var stampedKey = entryKeyPrefix + placeholder + primaryKeyEncoded
        stampedKey += littleEndian32(UInt32(entryKeyPrefix.count))
        transaction.atomicOp(key: stampedKey, param: [], mutationType: .setVersionstampedKey)

        // Write/refresh the reverse map: refKey -> versionstamp (offset 0 within the value).
        var stampedValue = placeholder
        stampedValue += littleEndian32(0)
        transaction.atomicOp(key: refKey, param: stampedValue, mutationType: .setVersionstampedValue)
    }

    private func littleEndian32(_ value: UInt32) -> FDB.Bytes {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }
}
#endif
