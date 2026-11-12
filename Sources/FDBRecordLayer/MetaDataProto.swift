/*
 * MetaDataProto.swift
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

// Serialization of ``RecordMetaData`` to and from the Java Record Layer's `MetaData` message
// (`record_metadata.proto`) and of ``KeyExpressionNode`` to and from its `KeyExpression`
// message (`record_key_expression.proto`).
//
// The messages are written by hand with the minimal wire codec in `StoreHeader.swift`, in field
// number order — the order protobuf-java serializes in — so the bytes match what
// `RecordMetaData.toProto()` / `KeyExpression.toKeyExpression()` produce for the same metadata
// (modulo the iteration order of Java's hash maps, see ``RecordMetaData/toProto(descriptorSet:)``).

/// Errors from converting metadata to or from Java's `MetaData` proto.
public enum MetaDataProtoError: Error, Sendable, Equatable {
    /// The bytes are not a well-formed message of the expected type.
    case malformed(String)
    /// A message type named by the metadata is not in the descriptors.
    case unknownMessageType(String)
    /// A key expression names a field the message does not have (by name or by number).
    case unknownField(message: String, field: String)
    /// A key expression nests into a field that is not a message.
    case notAMessageField(message: String, field: String)
    /// A key expression (or index) has no structural description, e.g. one built from closures.
    case unserializable(String)
    /// The proto uses a Java feature the Swift layer does not implement.
    case unsupported(String)
    /// A record type in the proto has no matching Swift message type, or vice versa.
    case unknownRecordType(String)
    /// The metadata is internally inconsistent (the checks `RecordMetaData` would otherwise trap on).
    case invalid(String)
}

// MARK: - Field names

/// Maps a key expression's protobuf field numbers to and from field names (Java's `Field` uses
/// names), using message descriptors. Nesting resolves through message-typed fields.
public enum KeyExpressionProto {
    /// The field namespace one level of a key expression is evaluated in: a protobuf message type,
    /// or a synthetic record type whose "fields" are its constituents (field number `i`, 1-based,
    /// is the `i`-th constituent, named by the constituent name — see ``SyntheticIndex``).
    public struct FieldNames: Sendable {
        enum Storage: Sendable {
            case message(DescriptorPool, String)
            case synthetic([Constituent])
        }

        struct Constituent: Sendable {
            let name: String
            let fields: FieldNames
        }

        let storage: Storage

        /// The field names of message `messageName` (fully qualified, e.g. `"fdb.test.Order"`) in a
        /// serialized `google.protobuf.FileDescriptorSet`.
        public init(descriptorSet: Data, messageName: String) throws {
            let set: Google_Protobuf_FileDescriptorSet
            do {
                set = try Google_Protobuf_FileDescriptorSet(serializedBytes: descriptorSet)
            } catch {
                throw MetaDataProtoError.malformed("FileDescriptorSet: \(error)")
            }
            try self.init(files: set.file, messageName: messageName)
        }

        /// The field names of message `messageName` among `files`.
        public init(files: [Google_Protobuf_FileDescriptorProto], messageName: String) throws {
            try self.init(pool: DescriptorPool(files), messageName: messageName)
        }

        init(pool: DescriptorPool, messageName: String) throws {
            let name = DescriptorPool.stripDot(messageName)
            guard pool.messages[name] != nil else { throw MetaDataProtoError.unknownMessageType(name) }
            storage = .message(pool, name)
        }

        /// A synthetic record type's namespace: its constituents, in order, with each one's fields.
        public static func synthetic(constituents: [(name: String, fields: FieldNames)]) -> FieldNames {
            FieldNames(storage: .synthetic(constituents.map { Constituent(name: $0.name, fields: $0.fields) }))
        }

        private init(storage: Storage) { self.storage = storage }

        var displayName: String {
            switch storage {
            case .message(_, let name): return name
            case .synthetic(let constituents): return "synthetic(\(constituents.map(\.name).joined(separator: ",")))"
            }
        }

        func name(of number: Int) throws -> String {
            switch storage {
            case .message(let pool, let message):
                guard let field = pool.messages[message]?.field.first(where: { Int($0.number) == number }) else {
                    throw MetaDataProtoError.unknownField(message: message, field: "#\(number)")
                }
                return field.name
            case .synthetic(let constituents):
                guard number >= 1, number <= constituents.count else {
                    throw MetaDataProtoError.unknownField(message: displayName, field: "#\(number)")
                }
                return constituents[number - 1].name
            }
        }

        func number(of name: String) throws -> Int {
            switch storage {
            case .message(let pool, let message):
                guard let field = pool.messages[message]?.field.first(where: { $0.name == name }) else {
                    throw MetaDataProtoError.unknownField(message: message, field: name)
                }
                return Int(field.number)
            case .synthetic(let constituents):
                guard let index = constituents.firstIndex(where: { $0.name == name }) else {
                    throw MetaDataProtoError.unknownField(message: displayName, field: name)
                }
                return index + 1
            }
        }

        /// The namespace inside message-typed field `number`.
        func nested(_ number: Int) throws -> FieldNames {
            switch storage {
            case .message(let pool, let message):
                guard let descriptor = pool.messages[message],
                      let field = descriptor.field.first(where: { Int($0.number) == number }) else {
                    throw MetaDataProtoError.unknownField(message: message, field: "#\(number)")
                }
                guard field.type == .message || field.type == .group,
                      let typeName = pool.resolve(field.typeName, from: message) else {
                    throw MetaDataProtoError.notAMessageField(message: message, field: field.name)
                }
                return FieldNames(storage: .message(pool, typeName))
            case .synthetic(let constituents):
                guard number >= 1, number <= constituents.count else {
                    throw MetaDataProtoError.unknownField(message: displayName, field: "#\(number)")
                }
                return constituents[number - 1].fields
            }
        }
    }

    // MARK: Encoding

    /// Java's `KeyExpression.toKeyExpression().toByteArray()` for `node`, with field numbers
    /// mapped to names through `fieldNames`. Nested `then`s are flattened, as Java's `concat`
    /// does; a one-child `then` is its child and an empty one is `empty()`.
    public static func encode(_ node: KeyExpressionNode, fieldNames: FieldNames) throws -> FDB.Bytes {
        var out = ProtoWriter()
        switch node {
        case .field(let number, let fanType):
            out.message(3, try fieldMessage(name: fieldNames.name(of: number), fanType: fanType))
        case .nest(let number, let fanType, let child):
            var nesting = ProtoWriter()
            nesting.message(1, try fieldMessage(name: fieldNames.name(of: number), fanType: fanType))
            nesting.message(2, try encode(child, fieldNames: fieldNames.nested(number)))
            out.message(2, nesting.bytes)
        case .then(let children):
            let flat = flattenThen(children)
            if flat.isEmpty { return try encode(.empty, fieldNames: fieldNames) }
            if flat.count == 1 { return try encode(flat[0], fieldNames: fieldNames) }
            var then = ProtoWriter()
            for child in flat { then.message(1, try encode(child, fieldNames: fieldNames)) }
            out.message(1, then.bytes)
        case .grouping(let whole, let groupedCount):
            var grouping = ProtoWriter()
            grouping.message(1, try encode(whole, fieldNames: fieldNames))
            grouping.int32(3, groupedCount)
            out.message(4, grouping.bytes)
        case .empty:
            out.message(5, [])
        case .version:
            out.message(7, [])
        case .recordType:
            out.message(11, [])
        case .opaque:
            throw MetaDataProtoError.unserializable("key expression built from closures")
        }
        return out.bytes
    }

    /// The `KeyExpression` bytes for a record-wide expression such as `DataStoreInfo.record_count_key`
    /// or `MetaData.record_count_key`, which Java evaluates against records of every type: the
    /// expression must resolve to the same field names in each of `recordDescriptors`.
    public static func encodeForHeader(_ node: KeyExpressionNode, recordDescriptors: [FieldNames]) throws -> FDB.Bytes {
        guard let first = recordDescriptors.first else {
            return try encode(node, fieldNames: .synthetic(constituents: []))
        }
        let bytes = try encode(node, fieldNames: first)
        for other in recordDescriptors.dropFirst() where try encode(node, fieldNames: other) != bytes {
            throw MetaDataProtoError.invalid("expression resolves to different field names in \(first.displayName) and \(other.displayName)")
        }
        return bytes
    }

    /// Single-type convenience for ``encodeForHeader(_:recordDescriptors:)``.
    public static func encodeForHeader(_ node: KeyExpressionNode, recordDescriptor: FieldNames) throws -> FDB.Bytes {
        try encodeForHeader(node, recordDescriptors: [recordDescriptor])
    }

    private static func flattenThen(_ children: [KeyExpressionNode]) -> [KeyExpressionNode] {
        children.flatMap { child -> [KeyExpressionNode] in
            if case .then(let grandchildren) = child { return flattenThen(grandchildren) }
            return [child]
        }
    }

    /// Java's `Field`: name, fan type, and the `NOT_UNIQUE` null interpretation Java always writes.
    private static func fieldMessage(name: String, fanType: FanType?) -> FDB.Bytes {
        var field = ProtoWriter()
        field.string(1, name)
        field.varint(2, fanTypeCode(fanType))
        field.varint(3, 1) // NullInterpretation.NOT_UNIQUE
        return field.bytes
    }

    private static func fanTypeCode(_ fanType: FanType?) -> UInt64 {
        switch fanType {
        case nil: return 1           // SCALAR
        case .fanOut?: return 2      // FAN_OUT
        case .concatenate?: return 3 // CONCATENATE
        }
    }

    // MARK: Decoding

    /// The node for a serialized Java `KeyExpression`, with field names mapped to numbers through
    /// `fieldNames`. Only the expression kinds ``KeyExpressionNode`` models are accepted.
    public static func decode(_ bytes: FDB.Bytes, fieldNames: FieldNames) throws -> KeyExpressionNode {
        let message = try ProtoReader(bytes, "KeyExpression")
        let kinds = [1: "then", 2: "nesting", 3: "field", 4: "grouping", 5: "empty", 6: "split", 7: "version",
                     8: "value", 9: "function", 10: "key_with_value", 11: "record_type_key", 12: "list",
                     13: "dimensions"]
        let present = kinds.keys.filter { message.has($0) }
        guard present.count == 1, let kind = present.first else {
            throw MetaDataProtoError.malformed("KeyExpression must set exactly one expression (found \(present.count))")
        }
        switch kind {
        case 1:
            let then = try ProtoReader(message.bytes(1) ?? [], "Then")
            let children = try then.repeatedBytes(1).map { try decode($0, fieldNames: fieldNames) }
            let flat = flattenThen(children)
            guard flat.count >= 2 else { throw MetaDataProtoError.malformed("Then must have at least 2 children") }
            return .then(flat)
        case 2:
            let nesting = try ProtoReader(message.bytes(2) ?? [], "Nesting")
            guard let parentBytes = nesting.bytes(1) else { throw MetaDataProtoError.malformed("Nesting is missing parent") }
            let (number, fanType) = try decodeField(parentBytes, fieldNames: fieldNames)
            let child = try decode(nesting.bytes(2) ?? [], fieldNames: fieldNames.nested(number))
            return .nest(number: number, fanType: fanType, child: child)
        case 3:
            let (number, fanType) = try decodeField(message.bytes(3) ?? [], fieldNames: fieldNames)
            return .field(number: number, fanType: fanType)
        case 4:
            let grouping = try ProtoReader(message.bytes(4) ?? [], "Grouping")
            guard let whole = grouping.bytes(1) else { throw MetaDataProtoError.malformed("Grouping is missing whole_key") }
            let groupedCount = Int(grouping.int32(3) ?? 1)
            return .grouping(try decode(whole, fieldNames: fieldNames), groupedCount: groupedCount)
        case 5: return .empty
        case 7: return .version
        case 11: return .recordType
        default:
            throw MetaDataProtoError.unsupported("\(kinds[kind]!) key expression")
        }
    }

    private static func decodeField(_ bytes: FDB.Bytes, fieldNames: FieldNames) throws -> (Int, FanType?) {
        let field = try ProtoReader(bytes, "Field")
        guard let name = field.string(1) else { throw MetaDataProtoError.malformed("Field is missing field_name") }
        guard let code = field.varint(2) else { throw MetaDataProtoError.malformed("Field \(name) is missing fan_type") }
        let fanType: FanType?
        switch code {
        case 1: fanType = nil
        case 2: fanType = .fanOut
        case 3: fanType = .concatenate
        default: throw MetaDataProtoError.malformed("Field \(name) has unknown fan_type \(code)")
        }
        // UNIQUE / NOT_NULL change how missing values are keyed, which the Swift evaluator doesn't model.
        if let nulls = field.varint(3), nulls != 1 {
            throw MetaDataProtoError.unsupported("Field \(name) null_interpretation \(nulls)")
        }
        return (try fieldNames.number(of: name), fanType)
    }

    // MARK: Index root expressions

    /// Index types whose maintainers read a `Grouping` root (Java wraps them; ``KeyExpressionNode``
    /// models the grouping as ``ErasedIndex/groupedCount`` instead).
    static func usesGrouping(_ type: IndexType, root: KeyExpressionNode, groupedCount: Int) -> Bool {
        if type.isAtomic || type == .rank || type == .timeWindowLeaderboard { return true }
        // A text index is grouped only when columns precede the text column.
        if type == .text { return root.columnCount > groupedCount }
        return false
    }

    static func encodeIndexRoot(_ root: KeyExpressionNode, type: IndexType, groupedCount: Int,
                                fieldNames: FieldNames) throws -> FDB.Bytes {
        if case .grouping = root { return try encode(root, fieldNames: fieldNames) }
        if usesGrouping(type, root: root, groupedCount: groupedCount) {
            return try encode(.grouping(root, groupedCount: groupedCount), fieldNames: fieldNames)
        }
        return try encode(root, fieldNames: fieldNames)
    }

    /// Unwraps a Java index root into the root node and grouped count. Ungrouped roots of the
    /// types Java auto-wraps (`Index(proto)`) get Java's grouped count; others the Swift default.
    static func decodeIndexRoot(_ bytes: FDB.Bytes, type: IndexType,
                                fieldNames: FieldNames) throws -> (KeyExpressionNode, Int) {
        let node = try decode(bytes, fieldNames: fieldNames)
        if case .grouping(let whole, let groupedCount) = node { return (whole, groupedCount) }
        switch type {
        case .count: return (node, node.columnCount)
        case .rank, .sum, .minEverTuple, .maxEverTuple: return (node, 1)
        default: return (node, type.defaultGroupedCount)
        }
    }
}

// MARK: - Descriptor pool

/// Message descriptors by fully-qualified name (no leading dot), including nested messages.
final class DescriptorPool: Sendable {
    let files: [Google_Protobuf_FileDescriptorProto]
    let messages: [String: Google_Protobuf_DescriptorProto]
    /// The file each message is declared in.
    let fileOfMessage: [String: String]

    init(_ files: [Google_Protobuf_FileDescriptorProto]) {
        var messages: [String: Google_Protobuf_DescriptorProto] = [:]
        var fileOf: [String: String] = [:]
        func add(_ message: Google_Protobuf_DescriptorProto, prefix: String, file: String) {
            let name = prefix.isEmpty ? message.name : "\(prefix).\(message.name)"
            messages[name] = message
            fileOf[name] = file
            for nested in message.nestedType { add(nested, prefix: name, file: file) }
        }
        for file in files {
            for message in file.messageType { add(message, prefix: file.package, file: file.name) }
        }
        self.files = files
        self.messages = messages
        self.fileOfMessage = fileOf
    }

    static func stripDot(_ name: String) -> String { name.hasPrefix(".") ? String(name.dropFirst()) : name }

    /// Resolves a field's `type_name` (fully qualified with a leading dot, as protoc writes it, or
    /// relative to the referring message's scope).
    func resolve(_ typeName: String, from scope: String) -> String? {
        if typeName.hasPrefix(".") { return messages[String(typeName.dropFirst())] != nil ? String(typeName.dropFirst()) : nil }
        var parts = scope.split(separator: ".").map(String.init)
        while true {
            let candidate = (parts + [typeName]).joined(separator: ".")
            if messages[candidate] != nil { return candidate }
            if parts.isEmpty { return nil }
            parts.removeLast()
        }
    }

    func file(named name: String) -> Google_Protobuf_FileDescriptorProto? { files.first { $0.name == name } }
}

// MARK: - Wire helpers

/// Appends protobuf fields in call order (callers write them in field-number order, as
/// protobuf-java does).
struct ProtoWriter {
    var bytes: FDB.Bytes = []

    mutating func tag(_ number: Int, _ wireType: ProtoFields.WireType) {
        ProtoFields.writeVarint(UInt64(number << 3) | UInt64(wireType.rawValue), into: &bytes)
    }
    mutating func message(_ number: Int, _ payload: FDB.Bytes) {
        tag(number, .lengthDelimited)
        ProtoFields.writeVarint(UInt64(payload.count), into: &bytes)
        bytes += payload
    }
    mutating func string(_ number: Int, _ value: String) { message(number, Array(value.utf8)) }
    mutating func varint(_ number: Int, _ value: UInt64) {
        tag(number, .varint)
        ProtoFields.writeVarint(value, into: &bytes)
    }
    mutating func int32(_ number: Int, _ value: Int) { varint(number, ProtoFields.raw(Int32(truncatingIfNeeded: value))) }
    mutating func int64(_ number: Int, _ value: Int64) { varint(number, UInt64(bitPattern: value)) }
    mutating func bool(_ number: Int, _ value: Bool) { varint(number, value ? 1 : 0) }
}

/// Read access to a message's fields, with decode failures reported as ``MetaDataProtoError``.
struct ProtoReader {
    let fields: ProtoFields

    init(_ bytes: FDB.Bytes, _ what: String) throws {
        do { fields = try ProtoFields(decoding: bytes) } catch {
            throw MetaDataProtoError.malformed("\(what) is not a valid protobuf message")
        }
    }

    func has(_ number: Int) -> Bool { fields.has(number) }
    func bytes(_ number: Int) -> FDB.Bytes? { fields.bytes(number) }
    func repeatedBytes(_ number: Int) -> [FDB.Bytes] { fields.repeatedBytes(number) }
    func string(_ number: Int) -> String? { bytes(number).map { String(decoding: $0, as: UTF8.self) } }
    func repeatedStrings(_ number: Int) -> [String] { repeatedBytes(number).map { String(decoding: $0, as: UTF8.self) } }
    func varint(_ number: Int) -> UInt64? { fields.varint(number) }
    func int32(_ number: Int) -> Int32? { ProtoFields.int32(varint(number)) }
    func bool(_ number: Int) -> Bool? { varint(number).map { $0 != 0 } }
}

/// Java's `LiteralKeyExpression.toProtoValue` for an integer record type key (a `Long`).
private func valueProto(_ key: Int64) -> FDB.Bytes {
    var value = ProtoWriter()
    value.int64(3, key)
    return value.bytes
}

/// An integer from Java's `Value` (`long_value` or `int_value`); other kinds are unsupported here.
private func integerValue(_ bytes: FDB.Bytes, _ what: String) throws -> Int64 {
    let value = try ProtoReader(bytes, "Value")
    if let long = value.varint(3) { return Int64(bitPattern: long) }
    if let int = value.int32(7) { return Int64(int) }
    throw MetaDataProtoError.unsupported("non-integer \(what)")
}

/// The proto `subspace_key` (a packed one-element tuple).
private func decodeSubspaceKey(_ bytes: FDB.Bytes, _ what: String) throws -> any TupleElement {
    guard let elements = try? Tuple.decode(from: bytes), elements.count == 1 else {
        throw MetaDataProtoError.malformed("subspace_key of \(what) is not a one-element tuple")
    }
    switch elements[0] {
    case let value as Int: return Int64(value)
    default: return elements[0]
    }
}

/// Java's default-excluded `MetaData.dependencies` (`RecordMetaData.defaultExcludedProtoDependencies`).
private let excludedDependencyNames: Set<String> = ["record_metadata.proto", "record_metadata_options.proto", "tuple_fields.proto"]

private let defaultUnionName = "RecordTypeUnion"

/// Whether a message is marked `(com.apple.foundationdb.record.record).usage = UNION` (message
/// option 1233, `RecordTypeOptions.usage` = 2). Read from unknown fields, since only the field
/// options extension is generated here.
private func isUnionMessage(_ message: Google_Protobuf_DescriptorProto) -> Bool {
    guard message.hasOptions,
          let options = try? ProtoFields(decoding: FDB.Bytes(message.options.unknownFields.data)),
          let record = options.bytes(1233),
          let usage = (try? ProtoFields(decoding: record))?.varint(1) else { return false }
    return usage == 2
}

private func shortName(_ fullName: String) -> String {
    String(fullName.split(separator: ".").last ?? Substring(fullName))
}

// MARK: - RecordMetaData → MetaData

extension RecordMetaData {
    /// Serializes the metadata as Java's `RecordMetaDataProto.MetaData`, loadable by Java's
    /// `RecordMetaData.build(MetaData)` (and by ``init(metaDataProto:recordTypes:)``).
    ///
    /// - Parameter descriptorSet: a serialized `google.protobuf.FileDescriptorSet` containing the
    ///   record message types and their imports (`protoc --include_imports --descriptor_set_out`).
    ///
    /// The records file is the file declaring the record types with a `RecordTypeUnion` message
    /// appended whose fields (`_<Type> = <union field>`) are the record types' union fields; if
    /// the file already has a union (`RecordTypeUnion` or `usage = UNION`), it must agree. When the
    /// types span several files, a new `record_type_union.proto` importing them holds the union.
    /// Record types are written in declaration order and indexes sorted by name (Java's order).
    ///
    /// Java's `record_type` names are message names without the package, so record types must
    /// have distinct short names. Index versions of 0 (the Swift default) are written as 1 when
    /// the metadata version is at least 1 (and a zero added version as the last-modified one),
    /// since Java treats a missing or zero `last_modified_version` as "new index" and assigns it
    /// a fresh version on load.
    public func toProto(descriptorSet: Data) throws -> Data {
        let set: Google_Protobuf_FileDescriptorSet
        do { set = try Google_Protobuf_FileDescriptorSet(serializedBytes: descriptorSet) } catch {
            throw MetaDataProtoError.malformed("FileDescriptorSet: \(error)")
        }
        let pool = DescriptorPool(set.file)

        // Record types, their files, and Java names.
        var javaName: [String: String] = [:]
        var seenShort: [String: String] = [:]
        for type in recordTypes {
            guard pool.messages[type.recordName] != nil else { throw MetaDataProtoError.unknownMessageType(type.recordName) }
            let short = shortName(type.recordName)
            if let other = seenShort[short] {
                throw MetaDataProtoError.invalid("record types \(other) and \(type.recordName) have the same Java name \(short)")
            }
            seenShort[short] = type.recordName
            javaName[type.recordName] = short
        }
        func fields(_ messageName: String) throws -> KeyExpressionProto.FieldNames {
            try KeyExpressionProto.FieldNames(pool: pool, messageName: messageName)
        }
        func java(_ recordName: String) throws -> String {
            guard let name = javaName[recordName] else { throw MetaDataProtoError.unknownRecordType(recordName) }
            return name
        }

        let records = try recordsFile(pool: pool)
        let dependencies = try dependencyFiles(of: records, pool: pool)

        var out = ProtoWriter()
        // 1: records
        out.message(1, try records.serializedBytes())

        // 2: indexes, sorted by name.
        for index in allIndexes.sorted(by: { $0.name < $1.name }) {
            let names: KeyExpressionProto.FieldNames
            var typeNames: [String]
            if let synthetic = index.syntheticTypeName {
                guard let type = syntheticType(named: synthetic) else { throw MetaDataProtoError.unknownRecordType(synthetic) }
                names = try syntheticFieldNames(type, fields: fields)
                typeNames = [synthetic]
            } else {
                let covered = recordTypes.filter { index.recordTypeNames.contains($0.recordName) }
                guard let first = covered.first else { throw MetaDataProtoError.invalid("index \(index.name) covers no record types") }
                names = try fields(first.recordName)
                // A multi-type index must name the same fields in every type it covers.
                let bytes = try KeyExpressionProto.encodeIndexRoot(index.rootNode, type: index.type,
                                                                   groupedCount: index.groupedCount, fieldNames: names)
                for other in covered.dropFirst() {
                    let otherBytes = try KeyExpressionProto.encodeIndexRoot(index.rootNode, type: index.type,
                                                                            groupedCount: index.groupedCount,
                                                                            fieldNames: fields(other.recordName))
                    guard otherBytes == bytes else {
                        throw MetaDataProtoError.invalid("index \(index.name) resolves to different field names in \(first.recordName) and \(other.recordName)")
                    }
                }
                typeNames = index.isUniversal ? [] : try covered.map { try java($0.recordName) }
            }
            if case .opaque = index.rootNode { throw MetaDataProtoError.unserializable("index \(index.name)") }
            out.message(2, try indexProto(index, recordTypes: typeNames, fieldNames: names))
        }

        // 3: record_types, in declaration order.
        for type in recordTypes {
            var proto = ProtoWriter()
            proto.string(1, try java(type.recordName))
            if case .opaque = type.primaryKeyNode {
                throw MetaDataProtoError.unserializable("primary key of \(type.recordName)")
            }
            proto.message(2, try KeyExpressionProto.encode(type.primaryKeyNode, fieldNames: fields(type.recordName)))
            if let since = type.sinceVersion { proto.int32(3, since) }
            if let key = type.explicitKey { proto.message(4, valueProto(Int64(key))) }
            out.message(3, proto.bytes)
        }

        // 4: split_long_records, 5: version
        out.bool(4, splitLongRecords)
        out.int32(5, version)

        // 6: former_indexes
        for former in formerIndexes {
            var proto = ProtoWriter()
            if let name = former.formerName { proto.string(3, name) }
            proto.message(5, Tuple(former.subspaceKey).encode())
            if former.removedVersion > 0 { proto.int32(6, former.removedVersion) }
            if former.addedVersion > 0 { proto.int32(10, former.addedVersion) }
            out.message(6, proto.bytes)
        }

        // 7: record_count_key
        if let countKey = recordCountKey {
            out.message(7, try KeyExpressionProto.encodeForHeader(
                countKey, recordDescriptors: recordTypes.map { try fields($0.recordName) }))
        }

        // 8: store_record_versions, 9: dependencies
        out.bool(8, storeRecordVersions)
        for dependency in dependencies { out.message(9, try dependency.serializedBytes()) }

        // 12: joined_record_types
        for type in syntheticTypes {
            guard case .joined(let joined) = type.kind else { continue }
            var proto = ProtoWriter()
            proto.string(1, joined.name)
            proto.message(4, valueProto(type.recordTypeKey))
            for constituent in joined.constituents {
                var c = ProtoWriter()
                c.string(1, constituent.name)
                c.string(2, try java(constituent.recordType))
                if constituent.outerJoined { c.bool(3, true) }
                proto.message(10, c.bytes)
            }
            func constituentFields(_ name: String) throws -> KeyExpressionProto.FieldNames {
                guard let constituent = joined.constituents.first(where: { $0.name == name }) else {
                    throw MetaDataProtoError.invalid("join in \(joined.name) names unknown constituent \(name)")
                }
                return try fields(constituent.recordType)
            }
            for join in joined.joins {
                var j = ProtoWriter()
                j.string(1, join.left)
                j.message(2, try KeyExpressionProto.encode(join.leftExpression, fieldNames: constituentFields(join.left)))
                j.string(3, join.right)
                j.message(4, try KeyExpressionProto.encode(join.rightExpression, fieldNames: constituentFields(join.right)))
                proto.message(11, j.bytes)
            }
            out.message(12, proto.bytes)
        }

        // 13: unnested_record_types
        for type in syntheticTypes {
            guard case .unnested(let unnested) = type.kind else { continue }
            var proto = ProtoWriter()
            proto.string(1, unnested.name)
            proto.message(2, valueProto(type.recordTypeKey))
            var parent = ProtoWriter()
            parent.string(1, unnested.parentName)
            parent.string(3, try java(unnested.parentType))
            proto.message(3, parent.bytes)
            for nested in unnested.nested {
                var n = ProtoWriter()
                n.string(1, nested.name)
                n.string(2, nested.parent)
                n.string(3, DescriptorPool.stripDot(nested.typeName))
                let parentFields = try unnestedConstituentFields(unnested, nested.parent, fields: fields)
                n.message(4, try KeyExpressionProto.encode(nested.nestingExpression, fieldNames: parentFields))
                proto.message(3, n.bytes)
            }
            out.message(13, proto.bytes)
        }
        return Data(out.bytes)
    }

    private func indexProto(_ index: ErasedIndex, recordTypes typeNames: [String],
                            fieldNames: KeyExpressionProto.FieldNames) throws -> FDB.Bytes {
        var proto = ProtoWriter()
        for name in typeNames { proto.string(1, name) }
        proto.string(3, index.name)
        proto.message(4, try KeyExpressionProto.encodeIndexRoot(index.rootNode, type: index.type,
                                                                groupedCount: index.groupedCount, fieldNames: fieldNames))
        proto.message(5, index.subspaceTupleKey.encode())
        // Java gives an index with no (or a zero) last_modified_version a fresh version on load.
        let lastModified = index.lastModifiedVersion > 0 ? index.lastModifiedVersion : (version >= 1 ? 1 : 0)
        if lastModified > 0 { proto.int32(6, lastModified) }
        proto.string(8, index.type.javaName)
        for (key, value) in index.options.sorted(by: { $0.key < $1.key }) {
            var option = ProtoWriter()
            option.string(1, key)
            option.string(2, value)
            proto.message(9, option.bytes)
        }
        // Java sets a missing added version to the last-modified one (`addIndexCommon`).
        let added = index.addedVersion > 0 ? index.addedVersion : lastModified
        if added > 0 { proto.int32(10, added) }
        return proto.bytes
    }

    private func syntheticFieldNames(
        _ type: ErasedSyntheticType, fields: (String) throws -> KeyExpressionProto.FieldNames
    ) throws -> KeyExpressionProto.FieldNames {
        switch type.kind {
        case .joined(let joined):
            return .synthetic(constituents: try joined.constituents.map { ($0.name, try fields($0.recordType)) })
        case .unnested(let unnested):
            return .synthetic(constituents: try unnested.constituentNames.map {
                ($0, try unnestedConstituentFields(unnested, $0, fields: fields))
            })
        }
    }

    private func unnestedConstituentFields(
        _ unnested: UnnestedRecordType, _ name: String, fields: (String) throws -> KeyExpressionProto.FieldNames
    ) throws -> KeyExpressionProto.FieldNames {
        if name == unnested.parentName { return try fields(unnested.parentType) }
        guard let nested = unnested.nested.first(where: { $0.name == name }) else {
            throw MetaDataProtoError.invalid("unnested type \(unnested.name) names unknown constituent \(name)")
        }
        return try fields(nested.typeName)
    }

    /// The records file: the file declaring the record types, with the union added.
    private func recordsFile(pool: DescriptorPool) throws -> Google_Protobuf_FileDescriptorProto {
        let unionTypes = recordTypes.sorted { $0.unionFieldNumber < $1.unionFieldNumber }
        let fileNames = Set(recordTypes.compactMap { pool.fileOfMessage[$0.recordName] })
        if fileNames.count == 1, let name = fileNames.first, var file = pool.file(named: name) {
            let unions = file.messageType.filter { $0.name == defaultUnionName || isUnionMessage($0) }
            if unions.count > 1 { throw MetaDataProtoError.invalid("\(name) declares more than one union message") }
            if let existing = unions.first {
                // An existing union must already map each type to its union field.
                let prefix = file.package.isEmpty ? "" : file.package + "."
                for type in recordTypes {
                    guard existing.field.contains(where: {
                        Int($0.number) == type.unionFieldNumber
                            && pool.resolve($0.typeName, from: prefix + existing.name) == type.recordName
                    }) else {
                        throw MetaDataProtoError.invalid("existing union \(existing.name) has no field \(type.unionFieldNumber) of type \(type.recordName)")
                    }
                }
                return file
            }
            file.messageType.append(unionMessage(unionTypes))
            return file
        }
        // Types spread over several files: a new file holding just the union.
        var file = Google_Protobuf_FileDescriptorProto()
        file.name = "record_type_union.proto"
        if let first = recordTypes.first, let fileName = pool.fileOfMessage[first.recordName] {
            file.package = pool.file(named: fileName)?.package ?? ""
        }
        file.dependency = fileNames.sorted()
        file.messageType = [unionMessage(unionTypes)]
        return file
    }

    private func unionMessage(_ types: [ErasedRecordType]) -> Google_Protobuf_DescriptorProto {
        var union = Google_Protobuf_DescriptorProto()
        union.name = defaultUnionName
        union.field = types.map { type in
            var field = Google_Protobuf_FieldDescriptorProto()
            field.name = "_" + shortName(type.recordName)
            field.number = Int32(type.unionFieldNumber)
            field.label = .optional
            field.type = .message
            field.typeName = "." + type.recordName
            return field
        }
        return union
    }

    /// Transitive imports of the records file, minus Java's bundled protos, sorted by name.
    private func dependencyFiles(of records: Google_Protobuf_FileDescriptorProto,
                                 pool: DescriptorPool) throws -> [Google_Protobuf_FileDescriptorProto] {
        var found: [String: Google_Protobuf_FileDescriptorProto] = [:]
        func visit(_ file: Google_Protobuf_FileDescriptorProto) throws {
            for name in file.dependency where !excludedDependencyNames.contains(name) && found[name] == nil {
                guard let dependency = pool.file(named: name) else {
                    throw MetaDataProtoError.malformed("descriptor set is missing import \(name) (use --include_imports)")
                }
                found[name] = dependency
                try visit(dependency)
            }
        }
        try visit(records)
        return found.keys.sorted().map { found[$0]! }
    }
}

// MARK: - MetaData → RecordMetaData

extension FormerIndex {
    /// A former index with an arbitrary subspace key (as loaded from Java metadata).
    init(subspaceKey: any TupleElement, formerName: String?, addedVersion: Int, removedVersion: Int) {
        self.subspaceKey = subspaceKey
        self.formerName = formerName
        self.addedVersion = addedVersion
        self.removedVersion = removedVersion
    }
}

extension RecordMetaData {
    /// Loads metadata serialized as Java's `RecordMetaDataProto.MetaData` (Java's
    /// `RecordMetaData.toProto()`, or ``toProto(descriptorSet:)``).
    ///
    /// - Parameter recordTypes: the generated message types, matched to the records file's union
    ///   by full message name. Every union record type must be given, and only those.
    ///
    /// Expressions are evaluated structurally (by field number, see ``KeyExpressionNode``). Java
    /// features the Swift layer doesn't implement — index predicates, `value_expression`, key
    /// expressions other than field / nesting / then / grouping / empty / version / record type
    /// key, non-integer record type keys, `UNIQUE`/`NOT_NULL` null interpretations, index types
    /// without a Swift ``IndexType`` — are rejected with ``MetaDataProtoError/unsupported(_:)``.
    public init(metaDataProto: Data, recordTypes swiftTypes: [any SwiftProtobuf.Message.Type]) throws {
        let proto = try ProtoReader(FDB.Bytes(metaDataProto), "MetaData")
        guard let recordsBytes = proto.bytes(1) else { throw MetaDataProtoError.malformed("MetaData has no records file") }
        let records: Google_Protobuf_FileDescriptorProto
        var dependencies: [Google_Protobuf_FileDescriptorProto] = []
        do {
            records = try Google_Protobuf_FileDescriptorProto(serializedBytes: recordsBytes)
            for bytes in proto.repeatedBytes(9) { dependencies.append(try Google_Protobuf_FileDescriptorProto(serializedBytes: bytes)) }
        } catch {
            throw MetaDataProtoError.malformed("MetaData file descriptors: \(error)")
        }
        let pool = DescriptorPool([records] + dependencies)
        func fields(_ messageName: String) throws -> KeyExpressionProto.FieldNames {
            try KeyExpressionProto.FieldNames(pool: pool, messageName: messageName)
        }

        // The union: record types and their union fields (Java's fetchUnionDescriptor / fillUnionFields).
        let unions = records.messageType.filter { isUnionMessage($0) || $0.name == defaultUnionName }
        guard unions.count == 1, let union = unions.first else {
            throw MetaDataProtoError.malformed(unions.isEmpty ? "records file has no union descriptor" : "records file has several union descriptors")
        }
        let unionScope = records.package.isEmpty ? union.name : "\(records.package).\(union.name)"
        var unionOrder: [String] = []
        var unionField: [String: Google_Protobuf_FieldDescriptorProto] = [:]
        for field in union.field {
            guard field.type == .message, let typeName = pool.resolve(field.typeName, from: unionScope) else {
                throw MetaDataProtoError.malformed("union field \(field.name) is not a message")
            }
            if let current = unionField[typeName] {
                // Java prefers the field named "_<Type>", else the larger field number.
                let canonical = "_" + shortName(typeName)
                if field.name == canonical || (current.name != canonical && field.number > current.number) {
                    unionField[typeName] = field
                }
            } else {
                unionOrder.append(typeName)
                unionField[typeName] = field
            }
        }
        var fullName: [String: String] = [:] // Java (short) name → full name
        for name in unionOrder {
            if fullName[shortName(name)] != nil { throw MetaDataProtoError.invalid("duplicate record type name \(shortName(name))") }
            fullName[shortName(name)] = name
        }
        func recordName(_ java: String) throws -> String {
            guard let name = fullName[java] else { throw MetaDataProtoError.unknownRecordType(java) }
            return name
        }
        var swiftByName: [String: any SwiftProtobuf.Message.Type] = [:]
        for type in swiftTypes {
            guard unionField[type.protoMessageName] != nil else { throw MetaDataProtoError.unknownRecordType(type.protoMessageName) }
            swiftByName[type.protoMessageName] = type
        }
        for name in unionOrder where swiftByName[name] == nil {
            throw MetaDataProtoError.unknownRecordType(name)
        }

        let version = Int(proto.int32(5) ?? 0)
        let storeVersions = proto.bool(8) ?? false

        // Record type protos.
        var typeProtos: [String: ProtoReader] = [:]
        for bytes in proto.repeatedBytes(3) {
            let typeProto = try ProtoReader(bytes, "RecordType")
            guard let name = typeProto.string(1) else { throw MetaDataProtoError.malformed("RecordType has no name") }
            typeProtos[try recordName(name)] = typeProto
        }

        // Synthetic types (before indexes, which may be on them).
        var joinedTypes: [JoinedRecordType] = []
        var unnestedTypes: [UnnestedRecordType] = []
        var syntheticFields: [String: KeyExpressionProto.FieldNames] = [:]
        for bytes in proto.repeatedBytes(12) {
            let joined = try ProtoReader(bytes, "JoinedRecordType")
            let name = joined.string(1) ?? ""
            var constituents: [JoinedRecordType.Constituent] = []
            for c in joined.repeatedBytes(10) {
                let constituent = try ProtoReader(c, "JoinConstituent")
                constituents.append(.init(constituent.string(1) ?? "", recordTypeName: try recordName(constituent.string(2) ?? ""),
                                          outerJoined: constituent.bool(3) ?? false))
            }
            func constituentFields(_ constituent: String) throws -> KeyExpressionProto.FieldNames {
                guard let match = constituents.first(where: { $0.name == constituent }) else {
                    throw MetaDataProtoError.invalid("join in \(name) names unknown constituent \(constituent)")
                }
                return try fields(match.recordType)
            }
            var joins: [JoinedRecordType.Join] = []
            for j in joined.repeatedBytes(11) {
                let join = try ProtoReader(j, "Join")
                let left = join.string(1) ?? "", right = join.string(3) ?? ""
                joins.append(.init(left, try KeyExpressionProto.decode(join.bytes(2) ?? [], fieldNames: constituentFields(left)),
                                   right, try KeyExpressionProto.decode(join.bytes(4) ?? [], fieldNames: constituentFields(right))))
            }
            let key = try joined.bytes(4).map { try integerValue($0, "record type key of \(name)") }
            joinedTypes.append(JoinedRecordType(name, recordTypeKey: key, constituents: constituents, joins: joins))
            syntheticFields[name] = .synthetic(constituents: try constituents.map { ($0.name, try fields($0.recordType)) })
        }
        for bytes in proto.repeatedBytes(13) {
            let unnested = try ProtoReader(bytes, "UnnestedRecordType")
            let name = unnested.string(1) ?? ""
            var parent: (name: String, type: String)?
            var nested: [UnnestedRecordType.NestedConstituent] = []
            var constituentFields: [(name: String, fields: KeyExpressionProto.FieldNames)] = []
            for c in unnested.repeatedBytes(3) {
                let constituent = try ProtoReader(c, "NestedConstituent")
                let constituentName = constituent.string(1) ?? ""
                let parentName = constituent.string(2) ?? ""
                if parentName.isEmpty {
                    guard parent == nil else { throw MetaDataProtoError.invalid("unnested type \(name) has several parents") }
                    let type = try recordName(constituent.string(3) ?? "")
                    parent = (constituentName, type)
                    constituentFields.insert((constituentName, try fields(type)), at: 0)
                } else {
                    guard let parentFields = constituentFields.first(where: { $0.name == parentName })?.fields else {
                        throw MetaDataProtoError.invalid("unnested type \(name): constituent \(constituentName) precedes its parent \(parentName)")
                    }
                    let typeName = DescriptorPool.stripDot(constituent.string(3) ?? "")
                    let expression = try KeyExpressionProto.decode(constituent.bytes(4) ?? [], fieldNames: parentFields)
                    nested.append(.init(constituentName, parent: parentName, typeName: typeName, nestingExpression: expression))
                    constituentFields.append((constituentName, try fields(typeName)))
                }
            }
            guard let parent else { throw MetaDataProtoError.invalid("unnested type \(name) has no parent constituent") }
            let key = try unnested.bytes(2).map { try integerValue($0, "record type key of \(name)") }
            unnestedTypes.append(UnnestedRecordType(name, recordTypeKey: key, parentName: parent.name,
                                                    parentTypeName: parent.type, nested: nested))
            syntheticFields[name] = .synthetic(constituents: constituentFields)
        }

        // Indexes.
        var typeIndexes: [String: [ErasedIndex]] = [:]
        var multiTypeIndexes: [MultiTypeIndex] = []
        var syntheticIndexes: [String: [SyntheticIndex]] = [:]
        var seenIndexNames = Set<String>()
        var seenSubspaceKeys = Set<FDB.Bytes>()
        for bytes in proto.repeatedBytes(2) {
            let index = try ProtoReader(bytes, "Index")
            guard let name = index.string(3) else { throw MetaDataProtoError.malformed("Index has no name") }
            if index.has(11) { throw MetaDataProtoError.unsupported("index \(name) has a predicate") }
            if index.has(7) { throw MetaDataProtoError.unsupported("index \(name) has a value_expression") }
            var options: [String: String] = [:]
            for o in index.repeatedBytes(9) {
                let option = try ProtoReader(o, "Index.Option")
                options[option.string(1) ?? ""] = option.string(2) ?? ""
            }
            let typeName: String
            if let legacy = index.varint(2) {
                // Deprecated Index.Type (Java's indexTypeToType / indexTypeToOptions).
                switch legacy {
                case 1: typeName = "value"
                case 2: typeName = "value"; options[IndexOptions.unique] = "true"
                case 3: typeName = "rank"
                case 4: typeName = "rank"; options[IndexOptions.unique] = "true"
                default: throw MetaDataProtoError.malformed("index \(name) has unknown index_type \(legacy)")
                }
            } else {
                typeName = index.string(8) ?? "value"
            }
            guard let type = IndexType(javaName: typeName) else { throw MetaDataProtoError.unsupported("index type \(typeName) (index \(name))") }
            let subspaceKey = try index.bytes(5).map { try decodeSubspaceKey($0, "index \(name)") } ?? name
            let lastModified = Int(index.int32(6) ?? 0)
            let added = index.int32(10).map(Int.init) ?? min(1, lastModified)
            let unique = options[IndexOptions.unique] == "true"
            let root = index.bytes(4) ?? []

            guard seenIndexNames.insert(name).inserted else { throw MetaDataProtoError.invalid("duplicate index name \(name)") }
            guard seenSubspaceKeys.insert(Tuple(subspaceKey).encode()).inserted else {
                throw MetaDataProtoError.invalid("duplicate index subspace key for index \(name)")
            }
            guard lastModified <= version else { throw MetaDataProtoError.invalid("index \(name) is newer than the metadata version") }
            guard added <= lastModified else { throw MetaDataProtoError.invalid("index \(name) addedVersion exceeds lastModifiedVersion") }
            guard !unique || type == .value else { throw MetaDataProtoError.unsupported("unique \(typeName) index \(name)") }

            // Multi-type and synthetic indexes take an integer key or the name.
            func intKey() throws -> Int? {
                if let key = subspaceKey as? Int64 { return Int(key) }
                if let key = subspaceKey as? String, key == name { return nil }
                throw MetaDataProtoError.unsupported("subspace key \(subspaceKey) of index \(name)")
            }

            let javaTypes = index.repeatedStrings(1)
            let synthetic = javaTypes.filter { syntheticFields[$0] != nil }
            if !synthetic.isEmpty {
                guard javaTypes.count == 1, let typeName = synthetic.first, let names = syntheticFields[typeName] else {
                    throw MetaDataProtoError.unsupported("index \(name) on several synthetic types")
                }
                let (node, grouped) = try KeyExpressionProto.decodeIndexRoot(root, type: type, fieldNames: names)
                syntheticIndexes[typeName, default: []].append(SyntheticIndex(
                    name, on: node, type: type, key: try intKey(), addedVersion: added, lastModifiedVersion: lastModified,
                    groupedCount: grouped, options: options))
            } else if javaTypes.count == 1 {
                let recordName = try recordName(javaTypes[0])
                let (node, grouped) = try KeyExpressionProto.decodeIndexRoot(root, type: type, fieldNames: fields(recordName))
                typeIndexes[recordName, default: []].append(ErasedIndex(
                    name: name, type: type, subspaceKey: subspaceKey, explicitKey: (subspaceKey as? Int64).map { Int($0) },
                    unique: unique, producesMultipleKeys: node.producesMultipleKeys,
                    columnIdentities: node.columnIdentities(prefix: []),
                    addedVersion: added, lastModifiedVersion: lastModified, groupedCount: grouped,
                    clearWhenZero: options[IndexOptions.clearWhenZero] == "true",
                    rawEntries: { node.evaluate($0) }, options: options, rootNode: node))
            } else {
                // Several types, or none (a universal index): the expression must mean the same in each.
                let covered = javaTypes.isEmpty ? unionOrder : try javaTypes.map(recordName)
                var decoded: (KeyExpressionNode, Int)?
                for recordName in covered {
                    let result = try KeyExpressionProto.decodeIndexRoot(root, type: type, fieldNames: fields(recordName))
                    if let decoded, decoded != result {
                        throw MetaDataProtoError.invalid("index \(name) resolves to different fields in \(recordName)")
                    }
                    decoded = result
                }
                guard let (node, grouped) = decoded else { throw MetaDataProtoError.invalid("index \(name) covers no record types") }
                // (Primary-key widths are checked below, once primary keys are decoded.)
                multiTypeIndexes.append(MultiTypeIndex(
                    name, on: node, type: type, recordTypes: javaTypes.isEmpty ? [] : covered.map { swiftByName[$0]! },
                    key: try intKey(), addedVersion: added, lastModifiedVersion: lastModified, groupedCount: grouped,
                    options: options))
            }
        }

        // Record types, in union order.
        var erased: [ErasedRecordType] = []
        var recordTypeKeys: [Int64: String] = [:]
        for name in unionOrder {
            guard let typeProto = typeProtos[name], let pkBytes = typeProto.bytes(2) else {
                throw MetaDataProtoError.invalid("record type \(name) has no primary key")
            }
            let primaryKey = try KeyExpressionProto.decode(pkBytes, fieldNames: fields(name))
            let field = Int(unionField[name]!.number)
            guard field > 0 && field < 19000 || field > 19999 && field <= 536_870_911 else {
                throw MetaDataProtoError.invalid("union field \(field) is not a valid field number")
            }
            let explicitKey = try typeProto.bytes(4).map { Int(try integerValue($0, "record type key of \(name)")) }
            let recordTypeKey = Int64(explicitKey ?? field)
            if let other = recordTypeKeys[recordTypeKey] {
                throw MetaDataProtoError.invalid("record types \(other) and \(name) have the same record type key")
            }
            recordTypeKeys[recordTypeKey] = name
            erased.append(Self.loadedRecordType(
                swiftByName[name]!, primaryKey: primaryKey, explicitKey: explicitKey, unionField: field,
                sinceVersion: typeProto.int32(3).map(Int.init), storesVersions: storeVersions,
                indexes: typeIndexes[name] ?? []))
        }
        for multi in multiTypeIndexes {
            let covered = multi.recordTypes.isEmpty ? erased : erased.filter { multi.recordTypes.contains($0.recordName) }
            guard Set(covered.map(\.primaryKeyColumnCount)).count == 1 else {
                throw MetaDataProtoError.invalid("multi-type index \(multi.name) spans types with different primary key widths")
            }
        }

        // Former indexes.
        var formerIndexes: [FormerIndex] = []
        for bytes in proto.repeatedBytes(6) {
            let former = try ProtoReader(bytes, "FormerIndex")
            let name = former.string(3)
            let key = try former.bytes(5).map { try decodeSubspaceKey($0, "former index \(name ?? "")") }
            guard let key else { throw MetaDataProtoError.malformed("FormerIndex has no subspace_key") }
            let removed = Int(former.int32(6) ?? 0)
            guard !seenSubspaceKeys.contains(Tuple(key).encode()) else {
                throw MetaDataProtoError.invalid("former index subspace key \(key) is reused by a current index")
            }
            guard removed <= version else { throw MetaDataProtoError.invalid("former index removedVersion exceeds metadata version") }
            formerIndexes.append(FormerIndex(subspaceKey: key, formerName: name,
                                             addedVersion: Int(former.int32(10) ?? 0), removedVersion: removed))
        }

        // Record count key: must mean the same for every record type.
        var recordCountKey: KeyExpressionNode?
        if let countBytes = proto.bytes(7) {
            for name in unionOrder {
                let node = try KeyExpressionProto.decode(countBytes, fieldNames: fields(name))
                if let recordCountKey, recordCountKey != node {
                    throw MetaDataProtoError.invalid("record_count_key resolves to different fields in \(name)")
                }
                recordCountKey = node
            }
        }

        let joined = joinedTypes.map {
            JoinedRecordType($0.name, recordTypeKey: $0.recordTypeKey, constituents: $0.constituents, joins: $0.joins,
                             indexes: syntheticIndexes[$0.name] ?? [])
        }
        let unnested = unnestedTypes.map {
            UnnestedRecordType($0.name, recordTypeKey: $0.recordTypeKey, parentName: $0.parentName,
                               parentTypeName: $0.parentType, nested: $0.nested, indexes: syntheticIndexes[$0.name] ?? [])
        }
        self.init(version: version, splitLongRecords: proto.bool(4) ?? false, formerIndexes: formerIndexes,
                  multiTypeIndexes: multiTypeIndexes, recordCountKey: recordCountKey,
                  joinedRecordTypes: joined, unnestedRecordTypes: unnested, erasedTypes: erased)
        var set = Google_Protobuf_FileDescriptorSet()
        set.file = [records] + dependencies
        self = self.withDescriptorSet(try set.serializedData())
    }

    /// An erased record type for a message type whose keys are evaluated structurally.
    private static func loadedRecordType(
        _ type: any SwiftProtobuf.Message.Type, primaryKey: KeyExpressionNode, explicitKey: Int?, unionField: Int,
        sinceVersion: Int?, storesVersions: Bool, indexes: [ErasedIndex]
    ) -> ErasedRecordType {
        func build<M: SwiftProtobuf.Message>(_: M.Type) -> ErasedRecordType {
            let probe = primaryKey.evaluate(M()).first ?? []
            return ErasedRecordType(
                recordName: M.protoMessageName, explicitKey: explicitKey, explicitUnionField: unionField,
                sinceVersion: sinceVersion, storesVersions: storesVersions,
                primaryKeyStartsWithRecordType: probe.first is RecordTypeKeyPlaceholder,
                rawPrimaryKey: { primaryKey.evaluate($0).first ?? [] },
                primaryKeyColumnIdentities: primaryKey.columnIdentities(prefix: []),
                deserialize: { try M(serializedBytes: $0) },
                indexes: indexes, primaryKeyNode: primaryKey)
        }
        return build(type)
    }
}
#endif
