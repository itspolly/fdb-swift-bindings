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

extension FDBRecordStore {
    // MARK: - Aggregate indexes (count / sum)

    /// Reads a `count` or `sum` aggregate for a single group (empty tuple = the ungrouped total
    /// when the index has no grouping columns).
    public func aggregate<M: SwiftProtobuf.Message>(
        _ type: M.Type, indexNamed name: String, group: Tuple = Tuple()
    ) async throws -> Int64 {
        let index = try erasedIndex(type, named: name)
        let indexSubspace = indexesSubspace.child(Int64(index.subspaceKey))
        let key = indexSubspace.prefix + group.encode()
        guard let bytes = try await transaction.getValue(for: key) else { return 0 }
        return LittleEndianInt.value(bytes)
    }

    /// Sums every group's aggregate value — e.g. the grand total of a grouped `count`/`sum`.
    public func aggregateTotal<M: SwiftProtobuf.Message>(
        _ type: M.Type, indexNamed name: String
    ) async throws -> Int64 {
        let index = try erasedIndex(type, named: name)
        let indexSubspace = indexesSubspace.child(Int64(index.subspaceKey))
        let (begin, end) = indexSubspace.range
        var total: Int64 = 0
        for try await (_, value) in transaction.getRange(beginKey: begin, endKey: end) {
            total += LittleEndianInt.value(value)
        }
        return total
    }

    // MARK: - Min / max indexes

    /// The minimum value-column value for a group of a `min` index, or `nil` if the group is
    /// empty. The index expression is `concat(groupColumns..., valueColumn)`; entries are kept
    /// sorted, so the minimum is the first entry in the group's range.
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
        let index = try erasedIndex(type, named: name)
        let indexSubspace = indexesSubspace.child(Int64(index.subspaceKey))
        // The value column is the last column of the expression; the rest are grouping.
        let valueColumnIndex = max(index.columnIdentities.count - 1, 0)
        let groupPrefix = indexSubspace.prefix + group.encode()

        var first: (any TupleElement)?
        var last: (any TupleElement)?
        for try await (key, _) in transaction.getRange(beginKey: groupPrefix, endKey: groupPrefix + [0xFF]) {
            let elements = try Tuple.decode(from: Array(key.dropFirst(indexSubspace.prefix.count)))
            guard elements.count > valueColumnIndex else { continue }
            let value = elements[valueColumnIndex]
            if first == nil { first = value }
            last = value
        }
        return wantMaximum ? last : first
    }

    // MARK: - Rank indexes

    /// The rank (0-based count of records ordered before `value`) for a `rank` index's field.
    ///
    /// This counts index entries whose leading column is strictly less than `value`.
    public func rank<M: SwiftProtobuf.Message, V: IndexableValue>(
        _ type: M.Type, indexNamed name: String, lessThan value: V
    ) async throws -> Int {
        let index = try erasedIndex(type, named: name)
        let indexSubspace = indexesSubspace.child(Int64(index.subspaceKey))
        let begin = indexSubspace.range.begin
        let end = indexSubspace.prefix + Tuple(value.asTupleElement()).encode()
        var count = 0
        for try await _ in transaction.getRange(beginKey: begin, endKey: end) {
            count += 1
        }
        return count
    }

    // MARK: - Version indexes

    /// Scans records in commit-version order via a `version` index.
    public func scanByVersion<M: SwiftProtobuf.Message & Sendable>(
        _ type: M.Type, indexNamed name: String
    ) throws -> RecordCursor<M> {
        guard let recordType = metaData.recordType(for: M.self) else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }
        let index = try erasedIndex(type, named: name)
        let entriesSubspace = indexesSubspace.child(Int64(index.subspaceKey)).child(Int64(0))
        let (begin, end) = entriesSubspace.range
        // Each entry key is: entriesPrefix + <10-byte versionstamp> + <encoded primary key>.
        let primaryKeyOffset = entriesSubspace.prefix.count + 10
        let typeSubspace = recordsSubspace.child(Int64(recordType.typeKey))
        let tx = transaction
        let recordName = recordType.recordName

        return RecordCursor {
            var iterator = tx.getRange(beginKey: begin, endKey: end).makeAsyncIterator()
            return {
                while let (key, _) = try await iterator.next() {
                    guard key.count > primaryKeyOffset else { continue }
                    let primaryKeyEncoded = Array(key.dropFirst(primaryKeyOffset))
                    let recordKey = typeSubspace.prefix + primaryKeyEncoded
                    guard let bytes = try await tx.getValue(for: recordKey) else { continue }
                    let message = try M(serializedBytes: bytes)
                    let primaryKey = Tuple(try Tuple.decode(from: primaryKeyEncoded))
                    return FDBStoredRecord(recordType: recordName, primaryKey: primaryKey, record: message)
                }
                return nil
            }
        }
    }
}
#endif
