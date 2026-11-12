/*
 * KeyExpression.swift
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

/// How a repeated (`repeated`) field contributes to a key.
public enum FanType: Sendable, Hashable {
    /// Produce one key per element of the repeated field (the default).
    ///
    /// A record with values `[a, b]` yields two index entries, `[a]` and `[b]`.
    case fanOut
    /// Produce a single key whose column is a nested tuple of all elements.
    case concatenate
}

/// A `Sendable`, `Hashable` identity for a record field.
///
/// The query planner uses these to match a query predicate to an index whose key expression
/// covers the same field. Identities come from typed `KeyPath`s (the Swift DSL) or, for the
/// proto-annotation path, from protobuf field numbers.
public struct FieldID: Sendable, Hashable {
    /// The key-path identity, if known (Swift DSL).
    ///
    /// Key-path *types* are not `Sendable`, but key-path *literals* are (SE-0418), so this is
    /// the `& Sendable`-refined existential to stay checked-`Sendable`.
    let keyPath: (any AnyKeyPath & Sendable)?
    /// The protobuf field-number path, if known (proto annotations, or resolved from a key
    /// path). A top-level field is a single-element path `[n]`; a nested field carries the
    /// chain of field numbers, e.g. `[4, 2]` for `customer.name`.
    let fieldPath: [Int]?

    init(keyPath: (any AnyKeyPath & Sendable)? = nil, fieldPath: [Int]? = nil) {
        self.keyPath = keyPath
        self.fieldPath = fieldPath
    }

    /// An identity derived from a key path.
    public static func keyPath(_ keyPath: any AnyKeyPath & Sendable) -> FieldID {
        FieldID(keyPath: keyPath)
    }

    /// An identity derived from a top-level protobuf field number.
    public static func fieldNumber(_ number: Int) -> FieldID {
        FieldID(fieldPath: [number])
    }

    /// An identity derived from a (possibly nested) protobuf field-number path.
    public static func fieldPath(_ path: [Int]) -> FieldID {
        FieldID(fieldPath: path)
    }

    /// Whether two identities refer to the same field by *either* shared identity.
    ///
    /// This bridges the Swift DSL and proto-annotation styles: a query whose field identity
    /// carries both a key path and a resolved field-number path matches an index declared with
    /// only one of them.
    func matches(_ other: FieldID) -> Bool {
        if let a = keyPath, let b = other.keyPath, a == b { return true }
        if let a = fieldPath, let b = other.fieldPath, a == b { return true }
        return false
    }
}

/// A tuple element representing SQL `NULL` (a missing field).
///
/// Encodes to the tuple `null` type code (`0x00`), matching FoundationDB's other bindings.
public struct NullValue: TupleElement {
    public init() {}
    public func encodeTuple() -> FDB.Bytes { [0x00] }
    public static func decodeTuple(from _: FDB.Bytes, at _: inout Int) throws -> NullValue {
        NullValue()
    }
}

/// Defines how a key (primary key or index key) is computed from a record.
///
/// A key expression evaluates a record into **one or more keys**, where each key is an
/// ordered list of column values (``TupleElement``s). Most expressions yield exactly one
/// key; a ``FanType/fanOut`` over a repeated field yields one key per element.
///
/// Expressions are built from typed `KeyPath`s, which keeps extraction type-safe and lets
/// the query planner match a filter to an index by ``FieldID`` identity:
///
/// ```swift
/// KeyExpression<Order>.field(\.price)                       // single column
/// KeyExpression<Order>.field(\.customer.name)               // nested via appended KeyPath
/// KeyExpression<Order>.field(\.tags, .fanOut)               // one entry per tag
/// KeyExpression.concat(.field(\.flower), .field(\.price))   // composite key
/// ```
public struct KeyExpression<M>: Sendable {
    /// Evaluates a record into its key(s). Each inner array is one key's ordered columns.
    public let evaluate: @Sendable (M) -> [[any TupleElement]]

    /// Per-column identities (in order) used by the planner to match queries to indexes.
    ///
    /// An entry is `nil` for a column the planner cannot match directly (e.g. a
    /// ``FanType/concatenate`` column).
    public let columnIdentities: [FieldID?]

    /// `true` if evaluation can produce more than one key (a fan-out is present).
    public let producesMultipleKeys: Bool

    /// The number of columns each produced key contains.
    public var columnCount: Int { columnIdentities.count }

    /// The expression's structure (Java's `KeyExpression` tree), or ``KeyExpressionNode/opaque``
    /// for expressions built from closures that can't be described.
    public let node: KeyExpressionNode

    init(
        evaluate: @escaping @Sendable (M) -> [[any TupleElement]],
        columnIdentities: [FieldID?],
        producesMultipleKeys: Bool,
        node: KeyExpressionNode = .opaque
    ) {
        self.evaluate = evaluate
        self.columnIdentities = columnIdentities
        self.producesMultipleKeys = producesMultipleKeys
        self.node = node
    }
}

// MARK: - Builders

extension KeyExpression {
    /// A single-column expression over a (possibly nested) scalar field.
    public static func field<V: IndexableValue>(_ keyPath: KeyPath<M, V> & Sendable) -> KeyExpression<M> {
        KeyExpression(
            evaluate: { record in [[record[keyPath: keyPath].asTupleElement()]] },
            columnIdentities: [.keyPath(keyPath)],
            producesMultipleKeys: false,
            node: fieldNode(keyPath, fanType: nil)
        )
    }

    /// A single-column expression over an optional field; a missing value indexes as `NULL`.
    public static func field<V: IndexableValue>(_ keyPath: KeyPath<M, V?> & Sendable) -> KeyExpression<M> {
        KeyExpression(
            evaluate: { record in
                let value = record[keyPath: keyPath]
                return [[value?.asTupleElement() ?? NullValue()]]
            },
            columnIdentities: [.keyPath(keyPath)],
            producesMultipleKeys: false,
            node: fieldNode(keyPath, fanType: nil)
        )
    }

    /// An expression over a repeated field.
    ///
    /// With ``FanType/fanOut`` (the default) an empty field produces **no** keys (the record
    /// is simply absent from that index). With ``FanType/concatenate`` it always produces a
    /// single key holding a nested tuple of the elements.
    public static func field<V: IndexableValue>(
        _ keyPath: KeyPath<M, [V]> & Sendable,
        _ fanType: FanType = .fanOut
    ) -> KeyExpression<M> {
        switch fanType {
        case .fanOut:
            return KeyExpression(
                evaluate: { record in
                    record[keyPath: keyPath].map { [$0.asTupleElement()] }
                },
                columnIdentities: [.keyPath(keyPath)],
                producesMultipleKeys: true,
                node: fieldNode(keyPath, fanType: .fanOut)
            )
        case .concatenate:
            return KeyExpression(
                evaluate: { record in
                    let nested = Tuple(record[keyPath: keyPath].map { $0.asTupleElement() })
                    return [[nested]]
                },
                columnIdentities: [nil],
                producesMultipleKeys: false,
                node: fieldNode(keyPath, fanType: .concatenate)
            )
        }
    }

    /// A composite expression concatenating the columns of `expressions`.
    ///
    /// When sub-expressions fan out, the result is their cartesian product (so two fan-outs
    /// of sizes 2 and 3 yield 6 keys). If any sub-expression produces no keys, the whole
    /// expression produces none.
    public static func concat(_ expressions: [KeyExpression<M>]) -> KeyExpression<M> {
        KeyExpression(
            evaluate: { record in
                crossProduct(expressions.map { $0.evaluate(record) })
            },
            columnIdentities: expressions.flatMap { $0.columnIdentities },
            producesMultipleKeys: expressions.contains { $0.producesMultipleKeys },
            node: expressions.contains { $0.node == .opaque } ? .opaque : .then(expressions.map(\.node))
        )
    }

    /// Variadic convenience for ``concat(_:)``.
    public static func concat(_ expressions: KeyExpression<M>...) -> KeyExpression<M> {
        concat(expressions)
    }

    /// The record's version — Java's `version()` key expression.
    ///
    /// Produces a single column holding the record's ``FDBRecordVersion`` as a tuple
    /// `Versionstamp` (12 bytes: commit versionstamp + local version). For a record saved in the
    /// current transaction the version is still incomplete; the store writes such entries with a
    /// versionstamped-key mutation at commit, exactly as the Java layer does.
    public static func version() -> KeyExpression<M> {
        KeyExpression(
            evaluate: { _ in [[RecordVersionPlaceholder()]] },
            columnIdentities: [nil],
            producesMultipleKeys: false,
            node: .version
        )
    }

    /// The record's type key — Java's `recordType()` key expression.
    ///
    /// Leading a primary key with it (`.concat(.recordType(), .field(\.id))`) clusters each
    /// type's records under their own key prefix, so scans of one type touch only that type's
    /// records and primary keys of different types can't collide.
    public static func recordType() -> KeyExpression<M> {
        KeyExpression(
            evaluate: { _ in [[RecordTypeKeyPlaceholder()]] },
            columnIdentities: [nil],
            producesMultipleKeys: false,
            node: .recordType
        )
    }

    /// An expression with no columns (Java's `empty()`), e.g. the group of an ungrouped count.
    public static func empty() -> KeyExpression<M> {
        KeyExpression(evaluate: { _ in [[]] }, columnIdentities: [], producesMultipleKeys: false, node: .empty)
    }

    /// An expression evaluated by field number from its structure, e.g. one loaded from Java
    /// metadata or shared by several record types.
    public static func structured(_ node: KeyExpressionNode) -> KeyExpression<M> {
        node.keyExpression()
    }
}

/// The node for a field reached by `keyPath`, resolved to its protobuf field-number path by
/// stamping a probe message (``FieldNumberResolver``); `.opaque` if it can't be resolved.
private func fieldNode<M, V: IndexableValue>(_ keyPath: KeyPath<M, V>, fanType: FanType?) -> KeyExpressionNode {
    guard let writable = keyPath as? WritableKeyPath<M, V>,
          let path = resolvePath(writable) else { return .opaque }
    return .path(path, fanType: fanType)
}

private func fieldNode<M, V: IndexableValue>(_ keyPath: KeyPath<M, V?>, fanType: FanType?) -> KeyExpressionNode {
    guard let writable = keyPath as? WritableKeyPath<M, V?>,
          let path = resolveOptionalPath(writable) else { return .opaque }
    return .path(path, fanType: fanType)
}

private func fieldNode<M, V: IndexableValue>(_ keyPath: KeyPath<M, [V]>, fanType: FanType?) -> KeyExpressionNode {
    guard let writable = keyPath as? WritableKeyPath<M, [V]>,
          let path = resolveRepeatedPath(writable) else { return .opaque }
    return .path(path, fanType: fanType)
}

private func resolvePath<M, V: IndexableValue>(_ keyPath: WritableKeyPath<M, V>) -> [Int]? {
    func open<T: SwiftProtobuf.Message>(_: T.Type) -> [Int]? {
        FieldNumberResolver.resolve(keyPath as! WritableKeyPath<T, V>)
    }
    guard let type = M.self as? any SwiftProtobuf.Message.Type else { return nil }
    return open(type)
}

private func resolveOptionalPath<M, V: IndexableValue>(_ keyPath: WritableKeyPath<M, V?>) -> [Int]? {
    func open<T: SwiftProtobuf.Message>(_: T.Type) -> [Int]? {
        FieldNumberResolver.resolve(keyPath as! WritableKeyPath<T, V?>)
    }
    guard let type = M.self as? any SwiftProtobuf.Message.Type else { return nil }
    return open(type)
}

private func resolveRepeatedPath<M, V: IndexableValue>(_ keyPath: WritableKeyPath<M, [V]>) -> [Int]? {
    func open<T: SwiftProtobuf.Message>(_: T.Type) -> [Int]? {
        FieldNumberResolver.resolve(keyPath as! WritableKeyPath<T, [V]>)
    }
    guard let type = M.self as? any SwiftProtobuf.Message.Type else { return nil }
    return open(type)
}

/// Stand-in column produced by ``KeyExpression/version()``; the store replaces it with the
/// record's version before writing. Never persisted.
struct RecordVersionPlaceholder: TupleElement {
    func encodeTuple() -> FDB.Bytes { preconditionFailure("record version placeholder must be resolved before encoding") }
    static func decodeTuple(from _: FDB.Bytes, at _: inout Int) throws -> RecordVersionPlaceholder { RecordVersionPlaceholder() }
}

/// Stand-in column produced by ``KeyExpression/recordType()``; replaced with the record type's
/// key when the expression is evaluated for a concrete record type. Never persisted.
struct RecordTypeKeyPlaceholder: TupleElement {
    func encodeTuple() -> FDB.Bytes { preconditionFailure("record type key placeholder must be resolved before encoding") }
    static func decodeTuple(from _: FDB.Bytes, at _: inout Int) throws -> RecordTypeKeyPlaceholder { RecordTypeKeyPlaceholder() }
}

/// Cartesian product of per-group keys, concatenating columns.
///
/// Each element of `groups` is the set of keys produced by one sub-expression. The result is
/// every combination, with one key chosen from each group, columns concatenated in order.
private func crossProduct(_ groups: [[[any TupleElement]]]) -> [[any TupleElement]] {
    var result: [[any TupleElement]] = [[]]
    for group in groups {
        var next: [[any TupleElement]] = []
        next.reserveCapacity(result.count * group.count)
        for prefix in result {
            for key in group {
                next.append(prefix + key)
            }
        }
        result = next
    }
    return result
}
#endif
