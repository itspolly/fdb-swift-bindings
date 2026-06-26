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
    public init(
        version: Int = 1,
        descriptorSetData: Data,
        recordTypes: [any SwiftProtobuf.Message.Type]
    ) throws {
        let set = try Google_Protobuf_FileDescriptorSet(
            serializedBytes: descriptorSetData,
            extensions: Com_Apple_Foundationdb_Record_RecordMetadataOptions_Extensions
        )

        var infoByName: [String: ProtoTypeInfo] = [:]
        for file in set.file {
            for message in file.messageType {
                let fullName = file.package.isEmpty ? message.name : "\(file.package).\(message.name)"
                infoByName[fullName] = ProtoTypeInfo(message)
            }
        }

        var erased: [ErasedRecordType] = []
        for type in recordTypes {
            let name = type.protoMessageName
            guard let info = infoByName[name] else {
                throw ProtoMetaDataError.recordTypeNotInDescriptor(name)
            }
            guard !info.primaryKeyFields.isEmpty else {
                throw ProtoMetaDataError.missingPrimaryKey(name)
            }
            erased.append(makeErasedRecordType(type, info: info))
        }

        self.init(version: version, erasedTypes: erased)
    }
}

/// Parsed annotation info for one message in a descriptor.
private struct ProtoTypeInfo {
    var primaryKeyFields: [Int] = []
    var indexes: [IndexFieldInfo] = []

    init(_ message: Google_Protobuf_DescriptorProto) {
        for field in message.field {
            guard field.hasOptions else { continue }
            let options = field.options
            guard options.hasCom_Apple_Foundationdb_Record_field else { continue }
            let annotation = options.Com_Apple_Foundationdb_Record_field
            if annotation.primaryKey {
                primaryKeyFields.append(Int(field.number))
            }
            if annotation.hasIndex {
                indexes.append(IndexFieldInfo(
                    name: "\(message.name).\(field.name)",
                    number: Int(field.number),
                    repeated: field.label == .repeated,
                    type: IndexType(protoString: annotation.index.type)
                ))
            }
        }
    }
}

private struct IndexFieldInfo: Sendable {
    let name: String
    let number: Int
    let repeated: Bool
    let type: IndexType
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
                    producesMultipleKeys: info.repeated,
                    columnIdentities: [.fieldNumber(info.number)],
                    entries: { message in
                        let values = extractFieldValues(message, fieldNumber: info.number)
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

/// A ``SwiftProtobuf/Visitor`` that captures the value(s) of a single field by number.
///
/// Only the base visit methods (the ones swift-protobuf does not default) are implemented;
/// everything else funnels into them via the library's default implementations.
private struct FieldValueVisitor: SwiftProtobuf.Visitor {
    let target: Int
    var collected: [any TupleElement] = []

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
        // Nested messages are not directly indexable as scalar key columns.
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
