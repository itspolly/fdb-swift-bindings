/*
 * QueryExecution.swift
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
    /// Executes `query`, returning a cursor over the matching records.
    ///
    /// The planner chooses an index scan or full scan; the query's filter is always applied
    /// as a residual, so results are exact regardless of the plan. If the query requests a
    /// sort, results are materialized, sorted, and (when needed) de-duplicated; otherwise the
    /// cursor streams.
    public func executeQuery<M: SwiftProtobuf.Message & Sendable>(
        _ query: RecordQuery<M>
    ) async throws -> RecordCursor<M> {
        guard let recordType = metaData.recordType(for: M.self) else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }

        let plan = QueryPlanner.plan(recordType: recordType, atoms: query.filter?.atoms ?? [])
        let needsDistinct = query.requiresDistinct || plan.requiresDistinct
        let filter = query.filter

        let base: RecordCursor<M>
        switch plan.source {
        case .fullScan:
            base = try scan(M.self)
        case .indexScan(let index, let atom):
            base = indexScanCursor(M.self, recordType: recordType, index: index, atom: atom, distinctPK: needsDistinct)
        }

        // Streaming path: no sort, apply residual filter lazily.
        guard let sort = query.sort else {
            return Self.filtered(base, by: filter)
        }

        // Sorting requires materialization.
        var records = try await base.collect()
        if let filter { records = records.filter { filter.eval($0.record) } }
        if needsDistinct { records = Self.deduplicate(records) }
        records.sort { lhs, rhs in
            let l = Self.sortKey(sort, lhs.record)
            let r = Self.sortKey(sort, rhs.record)
            return query.sortReversed ? lexicographicallyPrecedes(r, l) : lexicographicallyPrecedes(l, r)
        }
        return RecordCursor.ofBuffer(records)
    }

    // MARK: - Cursors

    private func indexScanCursor<M: SwiftProtobuf.Message & Sendable>(
        _ type: M.Type,
        recordType: ErasedRecordType,
        index: ErasedIndex,
        atom: IndexableAtom,
        distinctPK: Bool
    ) -> RecordCursor<M> {
        let indexSubspace = indexesSubspace.child(Int64(index.subspaceKey))
        let (begin, end) = Self.indexRange(indexSubspace, atom: atom)
        let prefixLength = indexSubspace.prefix.count
        let primaryKeyCount = recordType.primaryKeyIdentities.count
        let typeSubspace = recordsSubspace.child(Int64(recordType.typeKey))
        let tx = transaction
        let name = recordType.recordName

        return RecordCursor {
            var iterator = tx.getRange(beginKey: begin, endKey: end).makeAsyncIterator()
            var seen = Set<FDB.Bytes>()
            return {
                while let (key, _) = try await iterator.next() {
                    let suffix = Array(key.dropFirst(prefixLength))
                    let elements = try Tuple.decode(from: suffix)
                    guard elements.count >= primaryKeyCount else { continue }
                    let primaryKey = Tuple(Array(elements.suffix(primaryKeyCount)))
                    let primaryKeyEncoded = primaryKey.encode()
                    if distinctPK, !seen.insert(primaryKeyEncoded).inserted { continue }

                    let recordKey = typeSubspace.prefix + primaryKeyEncoded
                    guard let bytes = try await tx.getValue(for: recordKey) else { continue }
                    let message = try M(serializedBytes: bytes)
                    return FDBStoredRecord(recordType: name, primaryKey: primaryKey, record: message)
                }
                return nil
            }
        }
    }

    private static func filtered<M: SwiftProtobuf.Message & Sendable>(
        _ base: RecordCursor<M>, by filter: QueryComponent<M>?
    ) -> RecordCursor<M> {
        guard let filter else { return base }
        return RecordCursor {
            var iterator = base.makeAsyncIterator()
            return {
                while let record = try await iterator.next() {
                    if filter.eval(record.record) { return record }
                }
                return nil
            }
        }
    }

    // MARK: - Helpers

    /// Builds the `[begin, end)` byte range over `indexSubspace` that satisfies `atom`.
    static func indexRange(_ indexSubspace: Subspace, atom: IndexableAtom) -> (FDB.Bytes, FDB.Bytes) {
        let low = indexSubspace.prefix + Tuple(atom.bound).encode()
        let (subBegin, subEnd) = indexSubspace.range
        switch atom.kind {
        case .equals:
            return (low, low + [0xFF])
        case .lessThan:
            return (subBegin, low)
        case .lessThanOrEquals:
            return (subBegin, low + [0xFF])
        case .greaterThan:
            return (low + [0xFF], subEnd)
        case .greaterThanOrEquals:
            return (low, subEnd)
        case .notEquals, .startsWith, .isNull, .notNull:
            return (subBegin, subEnd) // not index-eligible; caller filters residually
        }
    }

    private static func sortKey<M>(_ sort: KeyExpression<M>, _ record: M) -> FDB.Bytes {
        sort.evaluate(record).first.map { Tuple($0).encode() } ?? []
    }

    private static func deduplicate<M: SwiftProtobuf.Message & Sendable>(
        _ records: [FDBStoredRecord<M>]
    ) -> [FDBStoredRecord<M>] {
        var seen = Set<FDB.Bytes>()
        return records.filter { seen.insert($0.primaryKey.encode()).inserted }
    }
}

/// Byte-wise lexicographic ordering, matching FoundationDB key ordering.
private func lexicographicallyPrecedes(_ a: FDB.Bytes, _ b: FDB.Bytes) -> Bool {
    a.lexicographicallyPrecedes(b)
}
#endif
