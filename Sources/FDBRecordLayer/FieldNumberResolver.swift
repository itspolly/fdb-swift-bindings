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

/// Resolves a (possibly nested) scalar field's protobuf field-number path from a writable key
/// path.
///
/// A fresh message is stamped with the type's ``IndexableValue/probeValue`` through the key
/// path, then traversed: since every other field is still at its proto default (and thus not
/// visited), the single stamped field reveals the path. A nested key path stamps a sub-message
/// field, so the traversal recurses into it and prepends the parent field number, yielding e.g.
/// `[4, 2]` for `customer.name`. Returns `nil` if there isn't exactly one stamped leaf.
///
/// This is what lets a `KeyPath` query select an index that was declared with proto
/// annotations (which only know field numbers).
enum FieldNumberResolver {
    static func resolve<M: SwiftProtobuf.Message, V: IndexableValue>(
        _ keyPath: WritableKeyPath<M, V>
    ) -> [Int]? {
        var message = M()
        message[keyPath: keyPath] = V.probeValue
        return uniqueFieldPath(of: message)
    }

    static func resolve<M: SwiftProtobuf.Message, V: IndexableValue>(
        _ keyPath: WritableKeyPath<M, V?>
    ) -> [Int]? {
        var message = M()
        message[keyPath: keyPath] = V.probeValue
        return uniqueFieldPath(of: message)
    }

    static func resolve<M: SwiftProtobuf.Message, V: IndexableValue>(
        _ keyPath: WritableKeyPath<M, [V]>
    ) -> [Int]? {
        var message = M()
        message[keyPath: keyPath] = [V.probeValue]
        return uniqueFieldPath(of: message)
    }

    /// The single stamped field path within `message`, or `nil` if not exactly one.
    static func uniqueFieldPath(of message: any SwiftProtobuf.Message) -> [Int]? {
        var visitor = SingleFieldPathVisitor()
        try? message.traverse(visitor: &visitor)
        return visitor.paths.count == 1 ? visitor.paths.first : nil
    }
}

/// Records the field-number path(s) of stamped fields. Scalar leaves record `[fieldNumber]`;
/// a stamped sub-message recurses and records `[fieldNumber] + subPath`, so a message with
/// exactly one stamped (non-default) field reveals its full path.
private struct SingleFieldPathVisitor: SwiftProtobuf.Visitor {
    var paths: [[Int]] = []

    mutating func visitSingularDoubleField(value: Double, fieldNumber: Int) throws { paths.append([fieldNumber]) }
    mutating func visitSingularInt64Field(value: Int64, fieldNumber: Int) throws { paths.append([fieldNumber]) }
    mutating func visitSingularUInt64Field(value: UInt64, fieldNumber: Int) throws { paths.append([fieldNumber]) }
    mutating func visitSingularBoolField(value: Bool, fieldNumber: Int) throws { paths.append([fieldNumber]) }
    mutating func visitSingularStringField(value: String, fieldNumber: Int) throws { paths.append([fieldNumber]) }
    mutating func visitSingularBytesField(value: Data, fieldNumber: Int) throws { paths.append([fieldNumber]) }
    mutating func visitSingularEnumField<E: SwiftProtobuf.Enum>(value: E, fieldNumber: Int) throws { paths.append([fieldNumber]) }
    mutating func visitSingularMessageField<M: SwiftProtobuf.Message>(value: M, fieldNumber: Int) throws {
        if let subPath = FieldNumberResolver.uniqueFieldPath(of: value) {
            paths.append([fieldNumber] + subPath)
        }
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
