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

/// A projected index entry returned by ``FDBRecordStore/executeCoveringQuery(_:using:)``:
/// the index's column values plus the record's primary key, without loading the record.
public struct CoveredRecord: Sendable {
    public let primaryKey: Tuple
    public let columns: [any TupleElement]
}

extension FDBRecordStore {
    /// Executes `query`, returning a cursor over the matching records.
    ///
    /// The planner chooses a full scan, a (possibly multi-column) index scan, or a union of
    /// index scans for `OR`; the query's filter is always applied as a residual, so results
    /// are exact regardless of the plan. A sort materializes and orders the results.
    public func executeQuery<M: SwiftProtobuf.Message & Sendable>(
        _ query: RecordQuery<M>
    ) async throws -> RecordCursor<M> {
        guard let recordType = metaData.recordType(for: M.self) else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }

        let plan = QueryPlanner.plan(recordType: recordType, node: query.filter?.node)
        let needsDistinct = query.requiresDistinct || plan.requiresDistinct
        let filter = query.filter

        let base: RecordCursor<M>
        switch plan.source {
        case .fullScan:
            base = Self.filtered(try scan(M.self), by: filter)
        case .indexScan(let scan):
            let primaryKeys = try await collectPrimaryKeys([scan], recordType: recordType, distinct: needsDistinct)
            base = recordCursor(primaryKeys: primaryKeys, recordType: recordType, filter: filter)
        case .union(let scans):
            let primaryKeys = try await collectPrimaryKeys(scans, recordType: recordType, distinct: true)
            base = recordCursor(primaryKeys: primaryKeys, recordType: recordType, filter: filter)
        }

        guard let sort = query.sort else { return base }

        var records = try await base.collect()
        records.sort { lhs, rhs in
            let l = Self.sortKey(sort, lhs.record)
            let r = Self.sortKey(sort, rhs.record)
            return query.sortReversed ? r.lexicographicallyPrecedes(l) : l.lexicographicallyPrecedes(r)
        }
        return RecordCursor.ofBuffer(records)
    }

    /// Counts matching records. When the plan is an index scan/union that fully satisfies the
    /// filter (no residual), counts distinct primary keys by scanning index ranges only —
    /// without loading any records. Otherwise falls back to counting query results.
    public func count<M: SwiftProtobuf.Message & Sendable>(_ query: RecordQuery<M>) async throws -> Int {
        guard let recordType = metaData.recordType(for: M.self) else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }

        // No filter: count record keys directly, no deserialization.
        guard let node = query.filter?.node else {
            let (begin, end) = recordsSubspace.child(Int64(recordType.typeKey)).range
            var total = 0
            for try await _ in transaction.getRange(beginKey: begin, endKey: end) { total += 1 }
            return total
        }

        let plan = QueryPlanner.plan(recordType: recordType, node: node)
        switch plan.source {
        case .indexScan(let scan) where QueryPlanner.isFullyCovered(node, by: scan):
            return try await collectPrimaryKeys([scan], recordType: recordType, distinct: true).count
        case .union(let scans) where Self.unionFullyCovered(node, scans):
            return try await collectPrimaryKeys(scans, recordType: recordType, distinct: true).count
        default:
            return try await executeQuery(query).collect().count
        }
    }

    /// Executes a covering query against `indexName`, returning index entries (columns +
    /// primary key) without loading records.
    ///
    /// The filter must be fully satisfiable by the named index alone, otherwise
    /// ``RecordStoreError/queryNotCovered(_:)`` is thrown.
    public func executeCoveringQuery<M: SwiftProtobuf.Message>(
        _ query: RecordQuery<M>, using indexName: String
    ) async throws -> [CoveredRecord] {
        guard let recordType = metaData.recordType(for: M.self) else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }
        let index = try erasedIndex(M.self, named: indexName)
        let node = query.filter?.node ?? .and([])
        guard index.type == .value || index.type == .rank,
              let scan = QueryPlanner.scan(index: index, atoms: node.conjunctionAtoms),
              QueryPlanner.isFullyCovered(node, by: scan)
        else {
            throw RecordStoreError.queryNotCovered(indexName)
        }

        let indexSubspace = indexesSubspace.child(Int64(index.subspaceKey))
        let (begin, end) = Self.indexRange(indexSubspace, scan)
        let prefixLength = indexSubspace.prefix.count
        let columnCount = index.columnIdentities.count
        let primaryKeyCount = recordType.primaryKeyIdentities.count

        var result: [CoveredRecord] = []
        for try await (key, _) in transaction.getRange(beginKey: begin, endKey: end) {
            let elements = try Tuple.decode(from: Array(key.dropFirst(prefixLength)))
            guard elements.count >= columnCount + primaryKeyCount else { continue }
            let columns = Array(elements.prefix(columnCount))
            let primaryKey = Tuple(Array(elements.suffix(primaryKeyCount)))
            result.append(CoveredRecord(primaryKey: primaryKey, columns: columns))
        }
        return result
    }

    // MARK: - Primary-key collection

    /// Scans the given index ranges and returns the matching primary keys, optionally
    /// de-duplicated (required for fan-out indexes and unions).
    private func collectPrimaryKeys(
        _ scans: [IndexScan], recordType: ErasedRecordType, distinct: Bool
    ) async throws -> [Tuple] {
        let primaryKeyCount = recordType.primaryKeyIdentities.count
        var seen = Set<FDB.Bytes>()
        var primaryKeys: [Tuple] = []
        for scan in scans {
            let indexSubspace = indexesSubspace.child(Int64(scan.index.subspaceKey))
            let (begin, end) = Self.indexRange(indexSubspace, scan)
            let prefixLength = indexSubspace.prefix.count
            for try await (key, _) in transaction.getRange(beginKey: begin, endKey: end) {
                let elements = try Tuple.decode(from: Array(key.dropFirst(prefixLength)))
                guard elements.count >= primaryKeyCount else { continue }
                let primaryKey = Tuple(Array(elements.suffix(primaryKeyCount)))
                if distinct {
                    if seen.insert(primaryKey.encode()).inserted { primaryKeys.append(primaryKey) }
                } else {
                    primaryKeys.append(primaryKey)
                }
            }
        }
        return primaryKeys
    }

    /// A cursor that streams records by loading each primary key and applying the residual filter.
    private func recordCursor<M: SwiftProtobuf.Message & Sendable>(
        primaryKeys: [Tuple], recordType: ErasedRecordType, filter: QueryComponent<M>?
    ) -> RecordCursor<M> {
        let typeSubspace = recordsSubspace.child(Int64(recordType.typeKey))
        let tx = transaction
        let name = recordType.recordName
        return RecordCursor {
            var index = 0
            return {
                while index < primaryKeys.count {
                    let primaryKey = primaryKeys[index]
                    index += 1
                    let recordKey = typeSubspace.prefix + primaryKey.encode()
                    guard let bytes = try await tx.getValue(for: recordKey) else { continue }
                    let message = try M(serializedBytes: bytes)
                    if let filter, !filter.eval(message) { continue }
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

    /// Builds the `[begin, end)` byte range over `indexSubspace` for an index scan: an equality
    /// prefix optionally narrowed by a trailing range comparison.
    static func indexRange(_ indexSubspace: Subspace, _ scan: IndexScan) -> (FDB.Bytes, FDB.Bytes) {
        let base = indexSubspace.prefix + Tuple(scan.equalityBounds).encode()
        guard let trailing = scan.trailing else {
            return (base, base + [0xFF])
        }
        let low = base + Tuple(trailing.bound).encode()
        switch trailing.kind {
        case .lessThan:
            return (base, low)
        case .lessThanOrEquals:
            return (base, low + [0xFF])
        case .greaterThan:
            return (low + [0xFF], base + [0xFF])
        case .greaterThanOrEquals:
            return (low, base + [0xFF])
        case .equals, .notEquals, .startsWith, .isNull, .notNull:
            return (base, base + [0xFF])
        }
    }

    private static func unionFullyCovered(_ node: PredicateNode, _ scans: [IndexScan]) -> Bool {
        guard case .or(let children) = node, children.count == scans.count else { return false }
        return zip(children, scans).allSatisfy { QueryPlanner.isFullyCovered($0, by: $1) }
    }

    private static func sortKey<M>(_ sort: KeyExpression<M>, _ record: M) -> FDB.Bytes {
        sort.evaluate(record).first.map { Tuple($0).encode() } ?? []
    }
}
#endif
