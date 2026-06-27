/*
 * QueryComponent.swift
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

/// A comparison operator used in a query predicate.
public enum ComparisonKind: Sendable, Hashable {
    case equals
    case notEquals
    case lessThan
    case lessThanOrEquals
    case greaterThan
    case greaterThanOrEquals
    case startsWith
    case isNull
    case notNull

    /// Whether this comparison can be satisfied by a contiguous index range scan.
    var isIndexable: Bool {
        switch self {
        case .equals, .lessThan, .lessThanOrEquals, .greaterThan, .greaterThanOrEquals:
            return true
        case .notEquals, .startsWith, .isNull, .notNull:
            return false
        }
    }
}

/// A single comparison the planner may be able to satisfy with an index.
struct IndexableAtom: Sendable {
    let fieldID: FieldID
    let kind: ComparisonKind
    /// The comparison value as a tuple element, for building the index range.
    let bound: any TupleElement
}

/// The logical structure of a predicate, used by the planner (the parallel `eval` closure on
/// ``QueryComponent`` handles residual, in-memory filtering).
indirect enum PredicateNode: Sendable {
    /// An index-eligible comparison.
    case comparison(IndexableAtom)
    /// A leaf the planner cannot satisfy with a range (notEquals/startsWith/isNull/notNull).
    case unindexable
    case and([PredicateNode])
    case or([PredicateNode])
    case not(PredicateNode)

    /// The conjunction's index-eligible comparisons, flattening nested `and`s. Empty for
    /// `or`/`not`/`unindexable` (so a single comparison or an AND-of-comparisons yields atoms).
    var conjunctionAtoms: [IndexableAtom] {
        switch self {
        case .comparison(let atom): return [atom]
        case .and(let children): return children.flatMap { $0.conjunctionAtoms }
        case .or, .not, .unindexable: return []
        }
    }
}

/// A query predicate over records of type `M`.
///
/// Components are built with the fluent ``Query`` API and combined with `and`/`or`/`not`:
///
/// ```swift
/// Query.and(
///     Query.field(\Order.price).lessThan(50),
///     Query.field(\Order.flower).equals("rose")
/// )
/// ```
///
/// Each component carries an in-memory `eval` for residual filtering and a set of
/// ``IndexableAtom``s the planner can use to choose an index.
public struct QueryComponent<M>: Sendable {
    /// Evaluates the predicate against a record (used for residual, in-memory filtering).
    let eval: @Sendable (M) -> Bool
    /// The predicate's logical structure, used by the planner.
    let node: PredicateNode

    /// The top-level conjunction's index-eligible comparisons.
    var atoms: [IndexableAtom] { node.conjunctionAtoms }

    init(eval: @escaping @Sendable (M) -> Bool, node: PredicateNode) {
        self.eval = eval
        self.node = node
    }
}

/// The entry point for building query predicates.
public enum Query {
    /// Begins a comparison against a scalar (possibly nested) field.
    ///
    /// The field identity carries both the key path and (when it is a top-level scalar) the
    /// resolved protobuf field number, so the predicate can match indexes declared either via
    /// the Swift DSL or via proto annotations.
    public static func field<M: SwiftProtobuf.Message, V: IndexableValue>(
        _ keyPath: WritableKeyPath<M, V> & Sendable
    ) -> FieldComparison<M, V> {
        FieldComparison(
            keyPath: keyPath,
            fieldID: FieldID(keyPath: keyPath, fieldPath: FieldNumberResolver.resolve(keyPath))
        )
    }

    /// Begins a comparison against an optional field (supports null predicates).
    public static func field<M: SwiftProtobuf.Message, V: IndexableValue>(
        _ keyPath: WritableKeyPath<M, V?> & Sendable
    ) -> OptionalFieldComparison<M, V> {
        OptionalFieldComparison(
            keyPath: keyPath,
            fieldID: FieldID(keyPath: keyPath, fieldPath: FieldNumberResolver.resolve(keyPath))
        )
    }

    /// Begins a membership comparison against a repeated field ("one of them").
    public static func any<M: SwiftProtobuf.Message, V: IndexableValue>(
        _ keyPath: WritableKeyPath<M, [V]> & Sendable
    ) -> RepeatedFieldComparison<M, V> {
        RepeatedFieldComparison(
            keyPath: keyPath,
            fieldID: FieldID(keyPath: keyPath, fieldPath: FieldNumberResolver.resolve(keyPath))
        )
    }

    /// True when every component matches.
    public static func and<M>(_ components: [QueryComponent<M>]) -> QueryComponent<M> {
        QueryComponent(
            eval: { record in components.allSatisfy { $0.eval(record) } },
            node: .and(components.map { $0.node })
        )
    }

    /// True when every component matches.
    public static func and<M>(_ components: QueryComponent<M>...) -> QueryComponent<M> {
        and(components)
    }

    /// True when any component matches. The planner satisfies this via an index union when
    /// every branch is independently index-able, else a full scan.
    public static func or<M>(_ components: [QueryComponent<M>]) -> QueryComponent<M> {
        QueryComponent(
            eval: { record in components.contains { $0.eval(record) } },
            node: .or(components.map { $0.node })
        )
    }

    /// True when any component matches.
    public static func or<M>(_ components: QueryComponent<M>...) -> QueryComponent<M> {
        or(components)
    }

    /// Negates a component. Not index-eligible (evaluated in memory).
    public static func not<M>(_ component: QueryComponent<M>) -> QueryComponent<M> {
        QueryComponent(eval: { record in !component.eval(record) }, node: .not(component.node))
    }
}

/// Fluent comparisons for a scalar field, produced by ``Query/field(_:)-(KeyPath<M,V>&Sendable)``.
///
/// `equals`/`notEquals` are available for any `Equatable` field; the ordering comparisons require
/// the field be `Comparable` (so e.g. `Bool` and enums support equality but not `lessThan`).
public struct FieldComparison<M, V: IndexableValue> {
    let keyPath: KeyPath<M, V> & Sendable
    let fieldID: FieldID

    fileprivate func make(
        _ kind: ComparisonKind, _ value: V, _ test: @escaping @Sendable (V) -> Bool
    ) -> QueryComponent<M> {
        let keyPath = self.keyPath
        let node: PredicateNode = kind.isIndexable
            ? .comparison(IndexableAtom(fieldID: fieldID, kind: kind, bound: value.asTupleElement()))
            : .unindexable
        return QueryComponent(eval: { test($0[keyPath: keyPath]) }, node: node)
    }
}

extension FieldComparison where V: Equatable {
    public func equals(_ value: V) -> QueryComponent<M> { make(.equals, value) { $0 == value } }
    public func notEquals(_ value: V) -> QueryComponent<M> { make(.notEquals, value) { $0 != value } }
}

extension FieldComparison where V: Comparable {
    public func lessThan(_ value: V) -> QueryComponent<M> { make(.lessThan, value) { $0 < value } }
    public func lessThanOrEquals(_ value: V) -> QueryComponent<M> { make(.lessThanOrEquals, value) { $0 <= value } }
    public func greaterThan(_ value: V) -> QueryComponent<M> { make(.greaterThan, value) { $0 > value } }
    public func greaterThanOrEquals(_ value: V) -> QueryComponent<M> { make(.greaterThanOrEquals, value) { $0 >= value } }
}

extension FieldComparison where V == String {
    /// String prefix match. Evaluated in memory (not index-eligible in this version).
    public func startsWith(_ prefix: String) -> QueryComponent<M> {
        let keyPath = self.keyPath
        return QueryComponent(eval: { $0[keyPath: keyPath].hasPrefix(prefix) }, node: .unindexable)
    }
}

/// Fluent comparisons for an optional field.
public struct OptionalFieldComparison<M, V: IndexableValue> {
    let keyPath: KeyPath<M, V?> & Sendable
    let fieldID: FieldID

    /// Matches records where the field is absent.
    public func isNull() -> QueryComponent<M> {
        let keyPath = self.keyPath
        return QueryComponent(eval: { $0[keyPath: keyPath] == nil }, node: .unindexable)
    }

    /// Matches records where the field is present.
    public func notNull() -> QueryComponent<M> {
        let keyPath = self.keyPath
        return QueryComponent(eval: { $0[keyPath: keyPath] != nil }, node: .unindexable)
    }

    fileprivate func make(
        _ kind: ComparisonKind, _ value: V, _ test: @escaping @Sendable (V) -> Bool
    ) -> QueryComponent<M> {
        let keyPath = self.keyPath
        let node: PredicateNode = kind.isIndexable
            ? .comparison(IndexableAtom(fieldID: fieldID, kind: kind, bound: value.asTupleElement()))
            : .unindexable
        return QueryComponent(
            eval: { record in record[keyPath: keyPath].map(test) ?? false },
            node: node
        )
    }
}

extension OptionalFieldComparison where V: Equatable {
    public func equals(_ value: V) -> QueryComponent<M> { make(.equals, value) { $0 == value } }
}

extension OptionalFieldComparison where V: Comparable {
    public func lessThan(_ value: V) -> QueryComponent<M> { make(.lessThan, value) { $0 < value } }
    public func greaterThan(_ value: V) -> QueryComponent<M> { make(.greaterThan, value) { $0 > value } }
}

/// Fluent membership comparisons for a repeated field.
public struct RepeatedFieldComparison<M, V: IndexableValue> {
    let keyPath: KeyPath<M, [V]> & Sendable
    let fieldID: FieldID
}

extension RepeatedFieldComparison where V: Equatable {
    /// Matches records where some element of the field equals `value`.
    public func equals(_ value: V) -> QueryComponent<M> {
        let keyPath = self.keyPath
        return QueryComponent(
            eval: { $0[keyPath: keyPath].contains(value) },
            node: .comparison(IndexableAtom(fieldID: fieldID, kind: .equals, bound: value.asTupleElement()))
        )
    }
}
#endif
