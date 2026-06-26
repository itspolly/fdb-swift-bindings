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

/// One page of a paged query: the records plus an opaque continuation token. A `nil`
/// continuation means the result set is exhausted.
public struct QueryPage<M: SwiftProtobuf.Message & Sendable>: Sendable {
    public let records: [FDBStoredRecord<M>]
    public let continuation: FDB.Bytes?
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

        let plan = QueryPlanner.plan(
            recordType: recordType, node: query.filter?.node,
            readableIndexNames: readableIndexNames(for: recordType))
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

        let plan = QueryPlanner.plan(
            recordType: recordType, node: node, readableIndexNames: readableIndexNames(for: recordType))
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
        guard indexState(named: indexName) == .readable,
              index.type == .value || index.type == .rank,
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

    // MARK: - Paged execution

    /// Executes one page of `query`, resuming from `continuation` (pass `nil` for the first
    /// page). Set `query.limit` to bound the page size; the returned `continuation` is `nil`
    /// once results are exhausted. Streaming plans resume efficiently by key; sorted and
    /// `OR`-union plans page over the materialized result set by offset.
    public func executeQuery<M: SwiftProtobuf.Message & Sendable>(
        _ query: RecordQuery<M>, continuation: FDB.Bytes?
    ) async throws -> QueryPage<M> {
        guard let recordType = metaData.recordType(for: M.self) else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }
        guard let limit = query.limit else {
            return QueryPage(records: try await executeQuery(query).collect(), continuation: nil)
        }

        let plan = QueryPlanner.plan(
            recordType: recordType, node: query.filter?.node,
            readableIndexNames: readableIndexNames(for: recordType))

        // Sorted or union plans page over the materialized, ordered/de-duplicated result.
        if query.sort != nil {
            return try await offsetPage(query, limit: limit, continuation: continuation)
        }
        switch plan.source {
        case .union:
            return try await offsetPage(query, limit: limit, continuation: continuation)
        case .fullScan:
            let typeSubspace = recordsSubspace.child(Int64(recordType.typeKey))
            return try await keyBasedPage(
                range: typeSubspace.range, prefixLength: typeSubspace.prefix.count,
                isIndexScan: false, recordType: recordType, filter: query.filter,
                limit: limit, continuation: continuation)
        case .indexScan(let scan):
            let indexSubspace = indexesSubspace.child(Int64(scan.index.subspaceKey))
            return try await keyBasedPage(
                range: Self.indexRange(indexSubspace, scan), prefixLength: indexSubspace.prefix.count,
                isIndexScan: true, recordType: recordType, filter: query.filter,
                limit: limit, continuation: continuation)
        }
    }

    /// Offset-based paging: re-materialize the ordered result and slice it.
    private func offsetPage<M: SwiftProtobuf.Message & Sendable>(
        _ query: RecordQuery<M>, limit: Int, continuation: FDB.Bytes?
    ) async throws -> QueryPage<M> {
        let offset = continuation.flatMap(Self.decodeOffset) ?? 0
        let all = try await executeQuery(query).collect()
        guard offset < all.count else { return QueryPage(records: [], continuation: nil) }
        let endIndex = Swift.min(offset + limit, all.count)
        let next = endIndex < all.count ? Self.encodeOffset(endIndex) : nil
        return QueryPage(records: Array(all[offset..<endIndex]), continuation: next)
    }

    /// Key-based paging for a streaming plan: resume the KV scan after the continuation key,
    /// collect up to `limit` post-filter records, and emit the last key as the continuation.
    private func keyBasedPage<M: SwiftProtobuf.Message & Sendable>(
        range: (begin: FDB.Bytes, end: FDB.Bytes), prefixLength: Int, isIndexScan: Bool,
        recordType: ErasedRecordType, filter: QueryComponent<M>?, limit: Int, continuation: FDB.Bytes?
    ) async throws -> QueryPage<M> {
        let begin = Self.decodeKey(continuation).map { $0 + [0x00] } ?? range.begin
        let typeSubspace = recordsSubspace.child(Int64(recordType.typeKey))
        let primaryKeyCount = recordType.primaryKeyIdentities.count
        let name = recordType.recordName

        var records: [FDBStoredRecord<M>] = []
        var lastScanKey: FDB.Bytes?
        var iterator = transaction.getRange(beginKey: begin, endKey: range.end).makeAsyncIterator()
        while records.count < limit, let (key, value) = try await iterator.next() {
            let record: FDBStoredRecord<M>?
            if isIndexScan {
                let elements = try Tuple.decode(from: Array(key.dropFirst(prefixLength)))
                guard elements.count >= primaryKeyCount else { continue }
                let primaryKey = Tuple(Array(elements.suffix(primaryKeyCount)))
                guard let bytes = try await transaction.getValue(
                    for: typeSubspace.prefix + primaryKey.encode()) else { continue }
                let message = try M(serializedBytes: bytes)
                record = (filter?.eval(message) ?? true)
                    ? FDBStoredRecord(recordType: name, primaryKey: primaryKey, record: message) : nil
            } else {
                let primaryKey = Tuple(try Tuple.decode(from: Array(key.dropFirst(prefixLength))))
                let message = try M(serializedBytes: value)
                record = (filter?.eval(message) ?? true)
                    ? FDBStoredRecord(recordType: name, primaryKey: primaryKey, record: message) : nil
            }
            if let record {
                records.append(record)
                lastScanKey = key
            }
        }
        let next = records.count == limit ? lastScanKey.map(Self.encodeKey) : nil
        return QueryPage(records: records, continuation: next)
    }

    // Continuation token codec: tag byte 0x01 = scan key, 0x02 = offset.
    private static func encodeKey(_ key: FDB.Bytes) -> FDB.Bytes { [0x01] + key }
    private static func decodeKey(_ token: FDB.Bytes?) -> FDB.Bytes? {
        guard let token, token.first == 0x01 else { return nil }
        return Array(token.dropFirst())
    }
    private static func encodeOffset(_ offset: Int) -> FDB.Bytes { [0x02] + Tuple(Int64(offset)).encode() }
    private static func decodeOffset(_ token: FDB.Bytes) -> Int? {
        guard token.first == 0x02,
              let value = (try? Tuple.decode(from: Array(token.dropFirst())))?.first as? Int64 else { return nil }
        return Int(value)
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
