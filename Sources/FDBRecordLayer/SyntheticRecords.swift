/*
 * SyntheticRecords.swift
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

/// A synthetic record (Java's `FDBSyntheticRecord`): one combination of constituents of a joined
/// or unnested record type. Never stored; it exists to compute index entries.
struct SyntheticRecord: Sendable {
    let type: ErasedSyntheticType
    /// Constituent messages in synthetic-field order (`nil` for a missing outer-joined one).
    let constituents: [(any SwiftProtobuf.Message & Sendable)?]
    /// Java's synthetic primary key: the type key, then one nested tuple per constituent (its
    /// primary key for joined types; for unnested types the parent's primary key, then each
    /// nested constituent's position).
    let primaryKey: Tuple

    /// Evaluates an index expression over the synthetic record: field `i` is constituent `i`.
    func evaluate(_ node: KeyExpressionNode) -> [[any TupleElement]] {
        switch node {
        case .nest(let number, _, let child):
            guard number >= 1, number <= constituents.count, let message = constituents[number - 1] else {
                return [Array(repeating: NullValue(), count: child.columnCount)]
            }
            return child.evaluate(message)
        case .then(let children):
            var result: [[any TupleElement]] = [[]]
            for child in children {
                let keys = evaluate(child)
                result = result.flatMap { prefix in keys.map { prefix + $0 } }
            }
            return result
        case .grouping(let whole, _):
            return evaluate(whole)
        case .recordType:
            return [[type.recordTypeKey]]
        case .empty:
            return [[]]
        case .field, .version, .opaque:
            return [[NullValue()]]
        }
    }

    /// The record as index maintenance sees it.
    func indexable(anchor: IndexableRecord) -> IndexableRecord {
        let record = self
        // Builds of synthetic indexes track progress by the first constituent's primary key
        // (the stored record that starts each synthetic record), so write-only gating uses it.
        let firstConstituentKey = primaryKey[1] as? Tuple
        return IndexableRecord(
            recordType: anchor.recordType, primaryKey: primaryKey, message: anchor.message, version: nil,
            entriesOverride: { index in record.evaluate(index.rootNode) },
            buildRangeKey: firstConstituentKey)
    }
}

extension FDBRecordStore {
    /// Synthetic records the old version of a record took part in, computed *before* the new
    /// version is written so lookups can't see it.
    struct PendingSyntheticUpdate {
        let old: [(type: ErasedSyntheticType, records: [SyntheticRecord])]
    }

    func prepareSyntheticUpdate(old: IndexableRecord?, typeName: String) async throws -> PendingSyntheticUpdate {
        var result: [(ErasedSyntheticType, [SyntheticRecord])] = []
        for synthetic in metaData.syntheticTypes(involving: typeName)
            where synthetic.indexes.contains(where: { indexState(named: $0.name) != .disabled }) {
            var records: [SyntheticRecord] = []
            if let old { records = try await syntheticRecords(synthetic, containing: old) }
            result.append((synthetic, records))
        }
        return PendingSyntheticUpdate(old: result)
    }

    /// Java's `updateSyntheticIndexes`: every synthetic record the changed record takes part in
    /// is removed (as computed from the old record) and re-added (from the new), updating each
    /// synthetic type's indexes by state like stored indexes.
    func applySyntheticUpdate(_ pending: PendingSyntheticUpdate, old: IndexableRecord?, new: IndexableRecord?) async throws {
        for (synthetic, oldRecords) in pending.old {
            var newRecords: [SyntheticRecord] = []
            if let new { newRecords = try await syntheticRecords(synthetic, containing: new) }
            for index in synthetic.indexes {
                let state = indexState(named: index.name)
                if state == .disabled { continue }
                let maintainer = indexMaintainer(for: index)
                for record in oldRecords {
                    let indexable = record.indexable(anchor: old!)
                    if state == .writeOnly { try await maintainer.updateWhileWriteOnly(old: indexable, new: nil) }
                    else { try await maintainer.update(old: indexable, new: nil) }
                }
                for record in newRecords {
                    let indexable = record.indexable(anchor: new!)
                    if state == .writeOnly { try await maintainer.updateWhileWriteOnly(old: nil, new: indexable) }
                    else { try await maintainer.update(old: nil, new: indexable) }
                }
            }
        }
    }

    /// Every synthetic record of `type` that includes `record` as a constituent (Java's
    /// `SyntheticRecordPlanner.fromStoredType`). With `asFirstConstituentOnly`, only those where it
    /// is the first constituent of its type — used to build an index without duplicates.
    func syntheticRecords(
        _ type: ErasedSyntheticType, containing record: IndexableRecord, asFirstConstituentOnly: Bool = false
    ) async throws -> [SyntheticRecord] {
        switch type.kind {
        case .unnested(let unnested):
            guard record.recordType.recordName == unnested.parentType else { return [] }
            return unnestedRecords(type, unnested, parent: record)
        case .joined(let joined):
            var result: [SyntheticRecord] = []
            var seen = Set<FDB.Bytes>()
            let positions = joined.constituents.indices.filter {
                joined.constituents[$0].recordType == record.recordType.recordName
            }
            for position in asFirstConstituentOnly ? positions.filter({ $0 == 0 }) : positions {
                for combination in try await joinCombinations(joined, start: position, record: record) {
                    let synthetic = SyntheticRecord(
                        type: type,
                        constituents: combination.map { $0?.message },
                        primaryKey: Tuple([type.recordTypeKey] + combination.map { $0.map { $0.primaryKey as any TupleElement } ?? NullValue() }))
                    if seen.insert(synthetic.primaryKey.encode()).inserted { result.append(synthetic) }
                }
            }
            return result
        }
    }

    private func unnestedRecords(_ type: ErasedSyntheticType, _ unnested: UnnestedRecordType,
                                 parent: IndexableRecord) -> [SyntheticRecord] {
        // Each partial combination: messages by constituent name, positions in order.
        var combinations: [([String: any SwiftProtobuf.Message], [Int])] = [([unnested.parentName: parent.message], [])]
        for nested in unnested.nested {
            combinations = combinations.flatMap { messages, positions -> [([String: any SwiftProtobuf.Message], [Int])] in
                guard let parentMessage = messages[nested.parent] else { return [] }
                let children = Self.nestedMessages(nested.nestingExpression, in: parentMessage)
                return children.enumerated().map { offset, child in
                    var next = messages
                    next[nested.name] = child
                    return (next, positions + [offset])
                }
            }
        }
        return combinations.map { messages, positions in
            SyntheticRecord(
                type: type,
                constituents: unnested.constituentNames.map { messages[$0] as? (any SwiftProtobuf.Message & Sendable) },
                primaryKey: Tuple([type.recordTypeKey, parent.primaryKey] + positions.map { Tuple(Int64($0)) as any TupleElement }))
        }
    }

    /// The messages a nesting expression selects (a repeated or singular message field).
    static func nestedMessages(_ node: KeyExpressionNode, in message: any SwiftProtobuf.Message) -> [any SwiftProtobuf.Message] {
        switch node {
        case .field(let number, _):
            return extractMessages(message, fieldNumber: number)
        case .nest(let number, _, let child):
            return extractMessages(message, fieldNumber: number).flatMap { nestedMessages(child, in: $0) }
        default:
            return []
        }
    }

    /// All constituent combinations for a joined type, starting from `record` at `start`
    /// and following join conditions outward (inner joins drop combinations without a match;
    /// outer-joined constituents become `nil`).
    private func joinCombinations(_ joined: JoinedRecordType, start: Int, record: IndexableRecord) async throws -> [[IndexableRecord?]] {
        let names = joined.constituents.map(\.name)
        var combinations: [[IndexableRecord?]] = [Array(repeating: nil, count: names.count)]
        combinations[0][start] = record
        var bound: Set<Int> = [start]
        while bound.count < names.count {
            // A join edge from a bound constituent to an unbound one.
            guard let (join, from, to, fromExpr, toExpr) = joined.joins.lazy.compactMap({ join -> (JoinedRecordType.Join, Int, Int, KeyExpressionNode, KeyExpressionNode)? in
                guard let l = names.firstIndex(of: join.left), let r = names.firstIndex(of: join.right) else { return nil }
                if bound.contains(l) && !bound.contains(r) { return (join, l, r, join.leftExpression, join.rightExpression) }
                if bound.contains(r) && !bound.contains(l) { return (join, r, l, join.rightExpression, join.leftExpression) }
                return nil
            }).first else {
                // Disconnected constituent: Java requires a connected join graph.
                throw RecordStoreError.unsupportedStoreFeature("joined type \(joined.name) has an unconnected constituent")
            }
            _ = join
            let target = joined.constituents[to]
            var next: [[IndexableRecord?]] = []
            for combination in combinations {
                guard let fromRecord = combination[from] else {
                    if target.outerJoined { next.append(combination) }
                    continue
                }
                let values = fromExpr.evaluate(fromRecord.message).map {
                    Tuple(fromRecord.recordType.resolveColumns($0, version: nil))
                }
                var matches: [IndexableRecord] = []
                for value in values where !value.elements.contains(where: { $0 is NullValue }) {
                    matches += try await findRecords(ofType: target.recordType, where: toExpr, equals: value)
                }
                if matches.isEmpty {
                    if target.outerJoined { next.append(combination) }
                } else {
                    for match in matches {
                        var extended = combination
                        extended[to] = match
                        next.append(extended)
                    }
                }
            }
            combinations = next
            bound.insert(to)
        }
        return combinations
    }

    /// Records of `typeName` whose `expression` evaluates to `value`, via a readable value index
    /// starting with that expression when there is one, else by scanning the type.
    private func findRecords(ofType typeName: String, where expression: KeyExpressionNode,
                             equals value: Tuple) async throws -> [IndexableRecord] {
        guard let recordType = metaData.recordType(named: typeName) else { return [] }
        let leading: (KeyExpressionNode) -> KeyExpressionNode? = { node in
            if case .then(let children) = node { return children.first }
            return node
        }
        if let index = recordType.indexes.first(where: {
            $0.type == .value && !$0.isMultiType && leading($0.rootNode) == expression
                && $0.rootNode.columnCount >= value.count && indexState(named: $0.name).isScannable
        }) {
            let prefix = indexSubspace(index).prefix + value.encode()
            var result: [IndexableRecord] = []
            var seen = Set<FDB.Bytes>()
            for try await (key, _) in transaction.getRange(beginKey: prefix, endKey: prefix + [0xFF]) {
                let elements = try indexSubspace(index).unpack(key)
                let pk = Tuple(Array(elements.suffix(index.primaryKeyColumnCount)))
                guard seen.insert(pk.encode()).inserted, let existing = try await loadExisting(pk),
                      existing.indexable.recordType.recordName == typeName else { continue }
                result.append(existing.indexable)
            }
            return result
        }
        var result: [IndexableRecord] = []
        let range = recordTypeRange(recordType)
        for try await record in scanRecords(begin: range.begin, end: range.end)
            where record.recordType.recordName == typeName {
            let keys = expression.evaluate(record.message).map { Tuple(record.recordType.resolveColumns($0, version: nil)) }
            if keys.contains(where: { $0.encode() == value.encode() }) { result.append(record) }
        }
        return result
    }
}
#endif
