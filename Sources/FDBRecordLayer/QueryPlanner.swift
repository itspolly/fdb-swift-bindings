/*
 * QueryPlanner.swift
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

/// A range comparison applied to the column after an index scan's equality prefix.
struct TrailingComparison {
    let kind: ComparisonKind
    let bound: any TupleElement
}

/// A scan of one value index: an equality prefix over its leading columns plus an optional
/// range on the next column.
struct IndexScan {
    let index: ErasedIndex
    let equalityBounds: [any TupleElement]
    let trailing: TrailingComparison?

    /// Number of leading index columns the scan constrains.
    var prefixLength: Int { equalityBounds.count + (trailing == nil ? 0 : 1) }
}

/// How the planner decided to produce candidate records for a query.
struct QueryPlan {
    enum Source {
        /// Scan every record of the type and filter in memory.
        case fullScan
        /// Scan a value index over a derived range, then load matching records.
        case indexScan(IndexScan)
        /// Union the results of several index scans (one per `OR` branch).
        case union([IndexScan])
    }

    let source: Source
    /// Whether the chosen source can surface a record more than once (fan-out or union).
    let requiresDistinct: Bool

    /// The chosen index's name for a single index scan, else `nil`.
    var indexName: String? {
        if case .indexScan(let scan) = source { return scan.index.name }
        return nil
    }

    /// The branch index names for a union plan, else `nil`.
    var unionIndexNames: [String]? {
        if case .union(let scans) = source { return scans.map { $0.index.name } }
        return nil
    }
}

/// A rule-based planner that selects value-index scans for a query, including multi-column
/// prefixes and `OR` unions, and falls back to a full scan otherwise. The query's filter is
/// always re-applied as a residual during execution, so a plan only needs to produce a
/// superset — except where ``isFullyCovered(_:by:)`` proves no residual is needed.
enum QueryPlanner {
    static func plan(recordType: ErasedRecordType, node: PredicateNode?) -> QueryPlan {
        guard let node else { return QueryPlan(source: .fullScan, requiresDistinct: false) }

        // OR: union of index scans, but only if *every* branch can use an index.
        if case .or(let children) = node {
            var scans: [IndexScan] = []
            for child in children {
                guard let scan = matchIndexScan(recordType: recordType, atoms: child.conjunctionAtoms) else {
                    return QueryPlan(source: .fullScan, requiresDistinct: false)
                }
                scans.append(scan)
            }
            guard !scans.isEmpty else { return QueryPlan(source: .fullScan, requiresDistinct: false) }
            return QueryPlan(source: .union(scans), requiresDistinct: true)
        }

        if let scan = matchIndexScan(recordType: recordType, atoms: node.conjunctionAtoms) {
            return QueryPlan(source: .indexScan(scan), requiresDistinct: scan.index.producesMultipleKeys)
        }
        return QueryPlan(source: .fullScan, requiresDistinct: false)
    }

    /// The best index scan for a conjunction of comparisons, or `nil` if none apply.
    static func matchIndexScan(recordType: ErasedRecordType, atoms: [IndexableAtom]) -> IndexScan? {
        var best: IndexScan?
        for index in recordType.indexes where index.type == .value {
            guard let scan = scan(index: index, atoms: atoms) else { continue }
            if isBetter(scan, than: best) { best = scan }
        }
        return best
    }

    /// Matches an index's leading columns against the atoms: equality columns form the prefix,
    /// then at most one range column, stopping at the first unmatched column.
    static func scan(index: ErasedIndex, atoms: [IndexableAtom]) -> IndexScan? {
        var equalityBounds: [any TupleElement] = []
        var trailing: TrailingComparison?

        for identityOptional in index.columnIdentities {
            guard let identity = identityOptional else { break }
            if let equality = atoms.first(where: { $0.kind == .equals && identity.matches($0.fieldID) }) {
                equalityBounds.append(equality.bound)
                continue
            }
            if let range = atoms.first(where: {
                $0.kind.isIndexable && $0.kind != .equals && identity.matches($0.fieldID)
            }) {
                trailing = TrailingComparison(kind: range.kind, bound: range.bound)
            }
            break // a range column (or a gap) ends the usable prefix
        }

        guard !equalityBounds.isEmpty || trailing != nil else { return nil }
        return IndexScan(index: index, equalityBounds: equalityBounds, trailing: trailing)
    }

    /// Prefer more equality columns, then a longer overall prefix.
    private static func isBetter(_ candidate: IndexScan, than current: IndexScan?) -> Bool {
        guard let current else { return true }
        if candidate.equalityBounds.count != current.equalityBounds.count {
            return candidate.equalityBounds.count > current.equalityBounds.count
        }
        return candidate.prefixLength > current.prefixLength
    }

    /// Whether `node` is fully satisfied by `scan` alone, so no residual filtering is needed.
    /// True only for a pure conjunction of comparisons all consumed by the scan's prefix.
    static func isFullyCovered(_ node: PredicateNode, by scan: IndexScan) -> Bool {
        guard isPureConjunction(node) else { return false }
        let atoms = node.conjunctionAtoms
        guard atoms.count == scan.prefixLength else { return false }
        let scannedColumns = Array(scan.index.columnIdentities.prefix(scan.prefixLength))
        return atoms.allSatisfy { atom in
            scannedColumns.contains { $0?.matches(atom.fieldID) ?? false }
        }
    }

    private static func isPureConjunction(_ node: PredicateNode) -> Bool {
        switch node {
        case .comparison: return true
        case .and(let children): return children.allSatisfy { isPureConjunction($0) }
        case .or, .not, .unindexable: return false
        }
    }
}
#endif
