/*
 * KeyExpressionNode.swift
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
import Foundation
import FoundationDB
import SwiftProtobuf

/// The structure of a key expression — the Java Record Layer's `KeyExpression` tree
/// (`record_key_expression.proto`), with fields identified by protobuf field number.
///
/// Every ``KeyExpression`` carries one. It is what lets metadata be serialized to (and loaded
/// from) Java's `MetaData` proto, lets one expression apply to several record types (multi-type
/// and universal indexes), and lets the store evaluate expressions loaded from a proto by
/// reflection.
public indirect enum KeyExpressionNode: Sendable, Hashable {
    /// A field of the record (Java `Field`). `fanType` is `nil` for a non-repeated field
    /// (Java `FanType.None`).
    case field(number: Int, fanType: FanType?)
    /// A field holding a message, with `child` evaluated inside it (Java `Nesting`). A repeated
    /// parent needs a fan type.
    case nest(number: Int, fanType: FanType?, child: KeyExpressionNode)
    /// Concatenation (Java `Then`).
    case then([KeyExpressionNode])
    /// Grouping for aggregate indexes (Java `Grouping`): the last `groupedCount` columns are
    /// aggregated, the rest form the group.
    case grouping(KeyExpressionNode, groupedCount: Int)
    /// The record's version (Java `Version`).
    case version
    /// The record type key (Java `RecordTypeKey`).
    case recordType
    /// No columns (Java `Empty`).
    case empty
    /// An expression built from Swift closures with no structural description; it can be
    /// evaluated but not serialized or applied to other types.
    case opaque

    /// Whether the node (and everything under it) is describable.
    public var isSerializable: Bool {
        switch self {
        case .opaque: return false
        case .field, .version, .recordType, .empty: return true
        case .nest(_, _, let child): return child.isSerializable
        case .grouping(let whole, _): return whole.isSerializable
        case .then(let children): return children.allSatisfy(\.isSerializable)
        }
    }

    /// Number of columns each produced key has.
    public var columnCount: Int {
        switch self {
        case .field, .version, .recordType: return 1
        case .nest(_, _, let child): return child.columnCount
        case .then(let children): return children.reduce(0) { $0 + $1.columnCount }
        case .grouping(let whole, _): return whole.columnCount
        case .empty: return 0
        case .opaque: return 0
        }
    }

    /// Builds the node for a (possibly nested) field-number path.
    static func path(_ path: [Int], fanType: FanType?) -> KeyExpressionNode {
        guard let first = path.first else { return .opaque }
        if path.count == 1 { return .field(number: first, fanType: fanType) }
        return .nest(number: first, fanType: nil, child: .path(Array(path.dropFirst()), fanType: fanType))
    }

    /// Evaluates the expression against a message by reflection, with Java's semantics: an
    /// unset field is null, a repeated field fans out or concatenates, and cross products of
    /// fan-outs multiply keys. `version()` / `recordType()` produce placeholders the store
    /// resolves.
    func evaluate(_ message: any SwiftProtobuf.Message) -> [[any TupleElement]] {
        switch self {
        case .field(let number, let fanType):
            let values = extractFieldValues(message, fieldNumber: number)
            switch fanType {
            case nil: return [[values.first ?? NullValue()]]
            case .fanOut?: return values.map { [$0] }
            case .concatenate?: return [[Tuple(values)]]
            }
        case .nest(let number, let fanType, let child):
            let children = extractMessages(message, fieldNumber: number)
            switch fanType {
            case nil:
                guard let sub = children.first else {
                    // Java evaluates the child against a null message: every column null.
                    return [Array(repeating: NullValue(), count: child.columnCount)]
                }
                return child.evaluate(sub)
            case .fanOut?:
                return children.flatMap { child.evaluate($0) }
            case .concatenate?:
                return [[Tuple(children.flatMap { child.evaluate($0).map { Tuple($0) as any TupleElement } })]]
            }
        case .then(let children):
            var result: [[any TupleElement]] = [[]]
            for child in children {
                let keys = child.evaluate(message)
                result = result.flatMap { prefix in keys.map { prefix + $0 } }
            }
            return result
        case .grouping(let whole, _):
            return whole.evaluate(message)
        case .version:
            return [[RecordVersionPlaceholder()]]
        case .recordType:
            return [[RecordTypeKeyPlaceholder()]]
        case .empty:
            return [[]]
        case .opaque:
            return []
        }
    }

    /// The equivalent typed expression (evaluated by reflection).
    func keyExpression<M>() -> KeyExpression<M> {
        let node = self
        return KeyExpression(
            evaluate: { record in node.evaluate(record as! any SwiftProtobuf.Message) },
            columnIdentities: node.columnIdentities(prefix: []),
            producesMultipleKeys: node.producesMultipleKeys,
            node: node)
    }

    var producesMultipleKeys: Bool {
        switch self {
        case .field(_, let fan): return fan == .fanOut
        case .nest(_, let fan, let child): return fan == .fanOut || child.producesMultipleKeys
        case .then(let children): return children.contains(where: \.producesMultipleKeys)
        case .grouping(let whole, _): return whole.producesMultipleKeys
        case .version, .recordType, .empty, .opaque: return false
        }
    }

    /// Planner identities for each column, by field-number path.
    func columnIdentities(prefix: [Int]) -> [FieldID?] {
        switch self {
        case .field(let number, let fan): return [fan == .concatenate ? nil : .fieldPath(prefix + [number])]
        case .nest(let number, _, let child): return child.columnIdentities(prefix: prefix + [number])
        case .then(let children): return children.flatMap { $0.columnIdentities(prefix: prefix) }
        case .grouping(let whole, _): return whole.columnIdentities(prefix: prefix)
        case .version, .recordType: return [nil]
        case .empty, .opaque: return []
        }
    }
}

/// The sub-message(s) stored in field `fieldNumber` (one for a singular field, each element for
/// a repeated one).
func extractMessages(_ message: any SwiftProtobuf.Message, fieldNumber: Int) -> [any SwiftProtobuf.Message] {
    var visitor = MessageCollector(target: fieldNumber)
    try? message.traverse(visitor: &visitor)
    return visitor.messages
}

private struct MessageCollector: SwiftProtobuf.Visitor {
    let target: Int
    var messages: [any SwiftProtobuf.Message] = []

    mutating func visitSingularMessageField<M: SwiftProtobuf.Message>(value: M, fieldNumber: Int) throws {
        if fieldNumber == target { messages.append(value) }
    }
    mutating func visitRepeatedMessageField<M: SwiftProtobuf.Message>(value: [M], fieldNumber: Int) throws {
        if fieldNumber == target { messages.append(contentsOf: value) }
    }
    mutating func visitSingularDoubleField(value: Double, fieldNumber: Int) throws {}
    mutating func visitSingularInt64Field(value: Int64, fieldNumber: Int) throws {}
    mutating func visitSingularUInt64Field(value: UInt64, fieldNumber: Int) throws {}
    mutating func visitSingularBoolField(value: Bool, fieldNumber: Int) throws {}
    mutating func visitSingularStringField(value: String, fieldNumber: Int) throws {}
    mutating func visitSingularBytesField(value: Data, fieldNumber: Int) throws {}
    mutating func visitSingularEnumField<E: SwiftProtobuf.Enum>(value: E, fieldNumber: Int) throws {}
    mutating func visitUnknown(bytes: Data) throws {}
    mutating func visitMapField<KeyType, ValueType: SwiftProtobuf.MapValueType>(
        fieldType: SwiftProtobuf._ProtobufMap<KeyType, ValueType>.Type,
        value: SwiftProtobuf._ProtobufMap<KeyType, ValueType>.BaseType, fieldNumber: Int) throws {}
    mutating func visitMapField<KeyType, ValueType>(
        fieldType: SwiftProtobuf._ProtobufEnumMap<KeyType, ValueType>.Type,
        value: SwiftProtobuf._ProtobufEnumMap<KeyType, ValueType>.BaseType, fieldNumber: Int
    ) throws where ValueType.RawValue == Int {}
    mutating func visitMapField<KeyType, ValueType>(
        fieldType: SwiftProtobuf._ProtobufMessageMap<KeyType, ValueType>.Type,
        value: SwiftProtobuf._ProtobufMessageMap<KeyType, ValueType>.BaseType, fieldNumber: Int) throws {}
}
#endif
