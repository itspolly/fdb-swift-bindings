/*
 * AdvancedIndexQueries.swift
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

/// Java's `RankedSetIndexHelper`: keeps a rank index's per-group ranked sets in step with its
/// value entries.
enum RankedSetIndexHelper {
    /// Adds a score to, or removes it from, a group's ranked set. Without duplicate counting, a
    /// score is only removed once no other record in the group still has it — the caller has
    /// already cleared this record's value entry, so any remaining entry under the value belongs
    /// to another record.
    static func updateRankedSet(
        _ tr: any TransactionProtocol, rankedSet: RankedSet, score: FDB.Bytes, remove: Bool,
        valueRange: (begin: FDB.Bytes, end: FDB.Bytes), config: RankedSet.Config
    ) async throws {
        if try await rankedSet.initNeeded(tr, snapshot: true) {
            try await rankedSet.`init`(tr)
        }
        if remove {
            if config.countDuplicates {
                _ = try await rankedSet.remove(tr, key: score)
            } else {
                let others = try await tr.getRangeNative(
                    beginSelector: .firstGreaterOrEqual(valueRange.begin),
                    endSelector: .firstGreaterOrEqual(valueRange.end), limit: 1, snapshot: false)
                if others.records.isEmpty { _ = try await rankedSet.remove(tr, key: score) }
            }
        } else {
            _ = try await rankedSet.add(tr, key: score)
        }
    }
}

extension FDBRecordStore {
    // MARK: - Aggregate (atomic) indexes

    /// Reads a `count`, `count_updates`, `count_not_null`, `sum`, `min_ever_long` or
    /// `max_ever_long` aggregate for one group (empty tuple = the ungrouped total). The index must
    /// be scannable.
    public func aggregate<M: SwiftProtobuf.Message>(
        _ type: M.Type, indexNamed name: String, group: Tuple = Tuple()
    ) async throws -> Int64 {
        let index = try scannableIndex(type, named: name)
        guard let bytes = try await transaction.getValue(for: indexSubspace(index).pack(group)) else { return 0 }
        return IndexMaintainer.decodeLittleEndian(bytes)
    }

    /// Reads a `min_ever_tuple`, `max_ever_tuple` or `max_ever_version` aggregate for a group.
    public func aggregateTuple<M: SwiftProtobuf.Message>(
        _ type: M.Type, indexNamed name: String, group: Tuple = Tuple()
    ) async throws -> Tuple? {
        let index = try scannableIndex(type, named: name)
        guard let bytes = try await transaction.getValue(for: indexSubspace(index).pack(group)) else { return nil }
        return Tuple(try Tuple.decode(from: bytes))
    }

    /// Sums a long-valued aggregate over every group, reading at most `groupLimit` groups so the
    /// read stays inside one transaction's limits. Returns the total and whether every group
    /// was read.
    public func aggregateTotal<M: SwiftProtobuf.Message>(
        _ type: M.Type, indexNamed name: String, groupLimit: Int = 10_000
    ) async throws -> (total: Int64, complete: Bool) {
        let index = try scannableIndex(type, named: name)
        let (begin, end) = indexSubspace(index).range
        let result = try await transaction.getRangeNative(
            beginSelector: .firstGreaterOrEqual(begin), endSelector: .firstGreaterOrEqual(end),
            limit: groupLimit + 1, snapshot: false)
        var total: Int64 = 0
        for (_, value) in result.records.prefix(groupLimit) {
            total &+= IndexMaintainer.decodeLittleEndian(value)
        }
        return (total, result.records.count <= groupLimit && !result.more)
    }

    // MARK: - Min / max (value-index backed)

    /// The minimum value-column value for a group of a `min` index, or `nil` if the group is
    /// empty — one key read (the first entry of the group's range).
    public func minimum<M: SwiftProtobuf.Message>(
        _ type: M.Type, indexNamed name: String, group: Tuple = Tuple()
    ) async throws -> (any TupleElement)? {
        try await extremum(type, indexNamed: name, group: group, wantMaximum: false)
    }

    /// The maximum value-column value for a group of a `max` index, or `nil` if empty.
    public func maximum<M: SwiftProtobuf.Message>(
        _ type: M.Type, indexNamed name: String, group: Tuple = Tuple()
    ) async throws -> (any TupleElement)? {
        try await extremum(type, indexNamed: name, group: group, wantMaximum: true)
    }

    private func extremum<M: SwiftProtobuf.Message>(
        _ type: M.Type, indexNamed name: String, group: Tuple, wantMaximum: Bool
    ) async throws -> (any TupleElement)? {
        let index = try scannableIndex(type, named: name)
        let space = indexSubspace(index)
        let groupPrefix = space.prefix + group.encode()
        let result = try await transaction.getRangeNative(
            beginSelector: .firstGreaterOrEqual(groupPrefix), endSelector: .firstGreaterOrEqual(groupPrefix + [0xFF]),
            limit: 1, snapshot: false, reverse: wantMaximum)
        guard let (key, _) = result.records.first else { return nil }
        let elements = try space.unpack(key)
        return elements.count > group.count ? elements[group.count] : nil
    }

    // MARK: - Rank indexes

    /// The rank (0-based count of entries ordered before `value`) within a group of a `rank`
    /// index, answered from the group's ranked set in O(log n) reads.
    public func rank<M: SwiftProtobuf.Message, V: IndexableValue>(
        _ type: M.Type, indexNamed name: String, lessThan value: V, group: Tuple = Tuple()
    ) async throws -> Int {
        let index = try scannableIndex(type, named: name)
        let rankedSet = RankedSet(subspace: indexSecondarySubspace(index).subspace(group),
                                  config: indexMaintainer(for: index).rankConfig)
        if try await rankedSet.initNeeded(transaction, snapshot: true) { return 0 }
        let score = Tuple(value.asTupleElement()).encode()
        return Int(try await rankedSet.rank(transaction, key: score, nullIfMissing: false) ?? 0)
    }

    /// The score at `rank` within a group of a `rank` index, or `nil` if out of range.
    public func scoreAt<M: SwiftProtobuf.Message>(
        _ type: M.Type, indexNamed name: String, rank: Int, group: Tuple = Tuple()
    ) async throws -> Tuple? {
        let index = try scannableIndex(type, named: name)
        let rankedSet = RankedSet(subspace: indexSecondarySubspace(index).subspace(group),
                                  config: indexMaintainer(for: index).rankConfig)
        if try await rankedSet.initNeeded(transaction, snapshot: true) { return nil }
        guard let bytes = try await rankedSet.getNth(transaction, rank: Int64(rank)) else { return nil }
        return Tuple(try Tuple.decode(from: bytes))
    }

    // MARK: - Version indexes

    /// Scans records in version order via a `version` index whose expression is `version()`
    /// (optionally after grouping columns, fixed by `group`).
    public func scanByVersion<M: SwiftProtobuf.Message & Sendable>(
        _ type: M.Type, indexNamed name: String, group: Tuple = Tuple()
    ) throws -> RecordCursor<M> {
        guard let recordType = metaData.recordType(for: M.self) else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }
        let index = try scannableIndex(type, named: name)
        let space = indexSubspace(index)
        let (begin, end) = space.range(group)
        let primaryKeyCount = recordType.primaryKeyColumnCount
        let tx = transaction
        return RecordCursor {
            var iterator = tx.getRange(beginKey: begin, endKey: end).makeAsyncIterator()
            return {
                while let (key, _) = try await iterator.next() {
                    let elements = try space.unpack(key)
                    guard elements.count >= primaryKeyCount else { continue }
                    let primaryKey = Tuple(Array(elements.suffix(primaryKeyCount)))
                    if let record: FDBStoredRecord<M> = try await self.loadTyped(primaryKey, recordType: recordType, filter: nil) {
                        return record
                    }
                }
                return nil
            }
        }
    }
}
#endif
