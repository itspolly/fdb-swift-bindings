/*
 * FieldNumberResolver.swift
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
import SwiftProtobuf

/// Resolves a top-level scalar field's protobuf field number from a writable key path.
///
/// A fresh message is stamped with the type's ``IndexableValue/probeValue`` through the key
/// path, then traversed: since every other field is still at its proto default (and thus not
/// visited), the single visited scalar field reveals the number. Returns `nil` for nested or
/// non-scalar key paths (no single top-level scalar is visited) — callers then fall back to
/// key-path identity matching.
///
/// This is what lets a `KeyPath` query select an index that was declared with proto
/// annotations (which only know field numbers).
enum FieldNumberResolver {
    static func resolve<M: SwiftProtobuf.Message, V: IndexableValue>(
        _ keyPath: WritableKeyPath<M, V>
    ) -> Int? {
        var message = M()
        message[keyPath: keyPath] = V.probeValue
        return uniqueScalarFieldNumber(of: message)
    }

    static func resolve<M: SwiftProtobuf.Message, V: IndexableValue>(
        _ keyPath: WritableKeyPath<M, V?>
    ) -> Int? {
        var message = M()
        message[keyPath: keyPath] = V.probeValue
        return uniqueScalarFieldNumber(of: message)
    }

    static func resolve<M: SwiftProtobuf.Message, V: IndexableValue>(
        _ keyPath: WritableKeyPath<M, [V]>
    ) -> Int? {
        var message = M()
        message[keyPath: keyPath] = [V.probeValue]
        return uniqueScalarFieldNumber(of: message)
    }

    private static func uniqueScalarFieldNumber(of message: any SwiftProtobuf.Message) -> Int? {
        var visitor = SingleScalarFieldVisitor()
        try? message.traverse(visitor: &visitor)
        return visitor.scalarFieldNumbers.count == 1 ? visitor.scalarFieldNumbers.first : nil
    }
}

/// Records the field numbers of visited scalar fields (ignoring nested messages), so a message
/// with exactly one non-default scalar field reveals that field's number.
private struct SingleScalarFieldVisitor: SwiftProtobuf.Visitor {
    var scalarFieldNumbers: [Int] = []

    mutating func visitSingularDoubleField(value: Double, fieldNumber: Int) throws { scalarFieldNumbers.append(fieldNumber) }
    mutating func visitSingularInt64Field(value: Int64, fieldNumber: Int) throws { scalarFieldNumbers.append(fieldNumber) }
    mutating func visitSingularUInt64Field(value: UInt64, fieldNumber: Int) throws { scalarFieldNumbers.append(fieldNumber) }
    mutating func visitSingularBoolField(value: Bool, fieldNumber: Int) throws { scalarFieldNumbers.append(fieldNumber) }
    mutating func visitSingularStringField(value: String, fieldNumber: Int) throws { scalarFieldNumbers.append(fieldNumber) }
    mutating func visitSingularBytesField(value: Data, fieldNumber: Int) throws { scalarFieldNumbers.append(fieldNumber) }
    mutating func visitSingularEnumField<E: SwiftProtobuf.Enum>(value: E, fieldNumber: Int) throws { scalarFieldNumbers.append(fieldNumber) }
    mutating func visitSingularMessageField<M: SwiftProtobuf.Message>(value: M, fieldNumber: Int) throws {
        // Ignore nested messages: a nested key path stamps a sub-field, surfacing the message
        // field here, which is not a usable top-level scalar identity.
    }
    mutating func visitMapField<KeyType, ValueType: SwiftProtobuf.MapValueType>(
        fieldType: SwiftProtobuf._ProtobufMap<KeyType, ValueType>.Type,
        value: SwiftProtobuf._ProtobufMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int
    ) throws {}
    mutating func visitMapField<KeyType, ValueType>(
        fieldType: SwiftProtobuf._ProtobufEnumMap<KeyType, ValueType>.Type,
        value: SwiftProtobuf._ProtobufEnumMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int
    ) throws where ValueType.RawValue == Int {}
    mutating func visitMapField<KeyType, ValueType>(
        fieldType: SwiftProtobuf._ProtobufMessageMap<KeyType, ValueType>.Type,
        value: SwiftProtobuf._ProtobufMessageMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int
    ) throws {}
    mutating func visitUnknown(bytes: Data) throws {}
}
#endif
