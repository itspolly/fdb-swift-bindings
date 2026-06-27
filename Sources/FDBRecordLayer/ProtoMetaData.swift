/*
 * ProtoMetaData.swift
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

/// Errors from building metadata out of a protobuf descriptor.
public enum ProtoMetaDataError: Error, Sendable {
    /// A registered record type was not found in the descriptor set.
    case recordTypeNotInDescriptor(String)
    /// A record type's descriptor had no field marked as a primary key.
    case missingPrimaryKey(String)
}

extension RecordMetaData {
    /// Builds metadata from a protobuf `FileDescriptorSet` carrying FoundationDB's
    /// `(com.apple.foundationdb.record.field).*` annotations.
    ///
    /// Generate the descriptor set with:
    /// `protoc --include_imports --descriptor_set_out=schema.desc -I <protos> your.proto`
    ///
    /// Pass the compiled swift-protobuf message types so the store can serialize/deserialize
    /// them; primary keys and indexes are derived from the field annotations and extracted at
    /// runtime by field number (via the message visitor), so no key paths are required.
    ///
    /// - Parameters:
    ///   - descriptorSetData: the serialized `FileDescriptorSet` bytes.
    ///   - recordTypes: the generated message types to register (matched by message name).
    ///
    /// - Note: record types and indexes built this way currently take **positional** storage
    ///   keys (by the order of `recordTypes` and of fields in the descriptor), so that order
    ///   must stay stable for an existing store — append only, like the keyless Swift DSL.
    ///   Use the Swift DSL with explicit `key:` values when you need order-independent evolution.
    public init(
        version: Int = 1,
        descriptorSetData: Data,
        recordTypes: [any SwiftProtobuf.Message.Type]
    ) throws {
        let set = try Google_Protobuf_FileDescriptorSet(
            serializedBytes: descriptorSetData,
            extensions: Com_Apple_Foundationdb_Record_RecordMetadataOptions_Extensions
        )

        // Index every message by fully-qualified name so nested message fields can be resolved.
        var messagesByName: [String: Google_Protobuf_DescriptorProto] = [:]
        for file in set.file {
            for message in file.messageType {
                let fullName = file.package.isEmpty ? message.name : "\(file.package).\(message.name)"
                messagesByName[fullName] = message
            }
        }

        var erased: [ErasedRecordType] = []
        for type in recordTypes {
            let name = type.protoMessageName
            guard let message = messagesByName[name] else {
                throw ProtoMetaDataError.recordTypeNotInDescriptor(name)
            }
            let info = ProtoTypeInfo(message, messages: messagesByName)
            guard !info.primaryKeyFields.isEmpty else {
                throw ProtoMetaDataError.missingPrimaryKey(name)
            }
            erased.append(makeErasedRecordType(type, info: info))
        }

        self.init(version: version, erasedTypes: erased)
    }
}

/// Parsed annotation info for one record type in a descriptor.
private struct ProtoTypeInfo {
    /// Top-level field numbers marked as primary key (nested primary keys are not supported).
    var primaryKeyFields: [Int] = []
    /// Indexes, including ones nested inside singular message fields.
    var indexes: [IndexFieldInfo] = []

    init(_ message: Google_Protobuf_DescriptorProto, messages: [String: Google_Protobuf_DescriptorProto]) {
        for field in message.field where field.hasOptions {
            let annotation = field.options.Com_Apple_Foundationdb_Record_field
            if field.options.hasCom_Apple_Foundationdb_Record_field, annotation.primaryKey {
                primaryKeyFields.append(Int(field.number))
            }
        }
        Self.collectIndexes(
            message, path: [], namePrefix: "\(message.name).",
            messages: messages, visited: [], into: &indexes
        )
    }

    /// Recursively gathers annotated index fields, descending into singular message fields and
    /// building each index's field-number path. `visited` guards against recursive types.
    private static func collectIndexes(
        _ message: Google_Protobuf_DescriptorProto,
        path: [Int],
        namePrefix: String,
        messages: [String: Google_Protobuf_DescriptorProto],
        visited: Set<String>,
        into indexes: inout [IndexFieldInfo]
    ) {
        for field in message.field {
            let fieldPath = path + [Int(field.number)]
            if field.hasOptions, field.options.hasCom_Apple_Foundationdb_Record_field {
                let annotation = field.options.Com_Apple_Foundationdb_Record_field
                if annotation.hasIndex {
                    indexes.append(IndexFieldInfo(
                        name: "\(namePrefix)\(field.name)",
                        path: fieldPath,
                        repeated: field.label == .repeated,
                        type: IndexType(protoString: annotation.index.type),
                        unique: annotation.index.unique
                    ))
                }
            }
            // Descend into singular message-typed fields to find nested indexes.
            if field.type == .message, field.label != .repeated {
                let typeName = field.typeName.hasPrefix(".") ? String(field.typeName.dropFirst()) : field.typeName
                if let sub = messages[typeName], !visited.contains(typeName) {
                    collectIndexes(
                        sub, path: fieldPath, namePrefix: "\(namePrefix)\(field.name).",
                        messages: messages, visited: visited.union([typeName]), into: &indexes
                    )
                }
            }
        }
    }
}

private struct IndexFieldInfo: Sendable {
    let name: String
    /// Field-number path to the indexed field (one element for a top-level field).
    let path: [Int]
    let repeated: Bool
    let type: IndexType
    let unique: Bool
}

extension IndexType {
    init(protoString: String) {
        switch protoString {
        case "count": self = .count
        case "sum": self = .sum
        case "rank": self = .rank
        case "version": self = .version
        case "min": self = .min
        case "max": self = .max
        default: self = .value
        }
    }
}

/// Builds an erased record type whose extraction is by protobuf field number.
///
/// The existential metatype is implicitly opened into the generic `M`, giving a concrete
/// deserializer while keeping field extraction reflection-based.
private func makeErasedRecordType(
    _ type: any SwiftProtobuf.Message.Type, info: ProtoTypeInfo
) -> ErasedRecordType {
    func build<M: SwiftProtobuf.Message>(_ messageType: M.Type) -> ErasedRecordType {
        let primaryKeyFields = info.primaryKeyFields
        let indexInfos = info.indexes
        return ErasedRecordType(
            recordName: M.protoMessageName,
            typeKey: -1,
            explicitKey: nil,
            storesVersions: false,
            primaryKeyColumns: { message in
                primaryKeyFields.map { extractFieldValues(message, fieldNumber: $0).first ?? NullValue() }
            },
            primaryKeyIdentities: primaryKeyFields.map { FieldID.fieldNumber($0) },
            deserialize: { bytes in try M(serializedBytes: bytes) },
            indexes: indexInfos.map { info in
                ErasedIndex(
                    name: info.name,
                    type: info.type,
                    subspaceKey: -1,
                    explicitKey: nil,
                    unique: info.unique,
                    producesMultipleKeys: info.repeated,
                    columnIdentities: [.fieldPath(info.path)],
                    entries: { message in
                        let values = extractFieldValues(message, fieldPath: info.path)
                        if info.repeated { return values.map { [$0] } }
                        return [[values.first ?? NullValue()]]
                    }
                )
            }
        )
    }
    return build(type)
}

/// Extracts the value(s) of the field with `fieldNumber` from a message.
///
/// Returns one element for a singular field and one per element for a repeated field (the
/// visitor's default repeated→singular iteration accumulates them). Empty if the field is
/// unset (proto3 default values are treated as unset).
func extractFieldValues(_ message: any SwiftProtobuf.Message, fieldNumber: Int) -> [any TupleElement] {
    var visitor = FieldValueVisitor(target: fieldNumber)
    try? message.traverse(visitor: &visitor)
    return visitor.collected
}

/// Extracts the value(s) at a (possibly nested) field-number path, descending through singular
/// message fields. A single-element path is the top-level case above.
func extractFieldValues(_ message: any SwiftProtobuf.Message, fieldPath: [Int]) -> [any TupleElement] {
    guard let head = fieldPath.first else { return [] }
    if fieldPath.count == 1 {
        return extractFieldValues(message, fieldNumber: head)
    }
    var visitor = FieldValueVisitor(target: head)
    try? message.traverse(visitor: &visitor)
    guard let sub = visitor.capturedMessage else { return [] }
    return extractFieldValues(sub, fieldPath: Array(fieldPath.dropFirst()))
}

/// A ``SwiftProtobuf/Visitor`` that captures the value(s) of a single field by number.
///
/// Only the base visit methods (the ones swift-protobuf does not default) are implemented;
/// everything else funnels into them via the library's default implementations.
private struct FieldValueVisitor: SwiftProtobuf.Visitor {
    let target: Int
    var collected: [any TupleElement] = []
    /// The sub-message at `target`, if the target field is a singular message (for nested paths).
    var capturedMessage: (any SwiftProtobuf.Message)?

    mutating func visitSingularDoubleField(value: Double, fieldNumber: Int) throws {
        if fieldNumber == target { collected.append(value) }
    }
    mutating func visitSingularInt64Field(value: Int64, fieldNumber: Int) throws {
        if fieldNumber == target { collected.append(value) }
    }
    mutating func visitSingularUInt64Field(value: UInt64, fieldNumber: Int) throws {
        if fieldNumber == target { collected.append(value) }
    }
    mutating func visitSingularBoolField(value: Bool, fieldNumber: Int) throws {
        if fieldNumber == target { collected.append(value) }
    }
    mutating func visitSingularStringField(value: String, fieldNumber: Int) throws {
        if fieldNumber == target { collected.append(value) }
    }
    mutating func visitSingularBytesField(value: Data, fieldNumber: Int) throws {
        if fieldNumber == target { collected.append(FDB.Bytes(value)) }
    }
    mutating func visitSingularEnumField<E: SwiftProtobuf.Enum>(value: E, fieldNumber: Int) throws {
        if fieldNumber == target { collected.append(Int64(value.rawValue)) }
    }
    mutating func visitSingularMessageField<M: SwiftProtobuf.Message>(value: M, fieldNumber: Int) throws {
        if fieldNumber == target { capturedMessage = value }
    }
    mutating func visitUnknown(bytes: Data) throws {}
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
}
#endif
