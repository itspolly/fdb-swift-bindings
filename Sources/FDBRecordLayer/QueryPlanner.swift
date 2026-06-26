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

/// How the planner decided to produce candidate records for a query.
struct QueryPlan {
    enum Source {
        /// Scan every record of the type and filter in memory.
        case fullScan
        /// Scan a value index over a derived range, then load matching records.
        case indexScan(index: ErasedIndex, atom: IndexableAtom)
    }

    let source: Source
    /// Whether the chosen source can surface a record more than once (fan-out index).
    let requiresDistinct: Bool

    /// The name of the chosen index, or `nil` for a full scan. Exposed for tests/inspection.
    var indexName: String? {
        if case .indexScan(let index, _) = source { return index.name }
        return nil
    }
}

/// A small rule-based planner that picks a value index for a query when one applies.
///
/// The rule: among the filter's indexable conjuncts (``IndexableAtom``s), find one whose
/// field matches the *leading* column of a value index. Prefer an equality match; otherwise
/// take the first range match. If none apply, fall back to a full scan. The full filter is
/// always re-applied as a residual during execution, so the plan only needs to produce a
/// superset — it never has to be exact.
enum QueryPlanner {
    static func plan(recordType: ErasedRecordType, atoms: [IndexableAtom]) -> QueryPlan {
        var equalsChoice: (ErasedIndex, IndexableAtom)?
        var rangeChoice: (ErasedIndex, IndexableAtom)?

        for atom in atoms where atom.kind.isIndexable {
            for index in recordType.indexes where index.type == .value {
                guard let leading = index.columnIdentities.first, let identity = leading,
                      identity.matches(atom.fieldID) else { continue }
                if atom.kind == .equals {
                    if equalsChoice == nil { equalsChoice = (index, atom) }
                } else if rangeChoice == nil {
                    rangeChoice = (index, atom)
                }
            }
        }

        if let (index, atom) = equalsChoice ?? rangeChoice {
            return QueryPlan(
                source: .indexScan(index: index, atom: atom),
                requiresDistinct: index.producesMultipleKeys
            )
        }
        return QueryPlan(source: .fullScan, requiresDistinct: false)
    }
}
#endif
