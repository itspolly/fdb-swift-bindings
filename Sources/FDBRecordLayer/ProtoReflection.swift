/*
 * ProtoReflection.swift
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

/// Errors from reconstructing descriptors from generated message types.
public enum ProtoReflectionError: Error, Sendable {
    /// A field's type couldn't be determined by probing (named in the payload).
    case undeterminedField(message: String, field: String)
    /// A feature reconstruction doesn't support (map fields, required fields); supply a
    /// descriptor set with ``RecordMetaData/withDescriptorSet(_:)`` instead.
    case unsupported(String)
}

/// Rebuilds protobuf descriptors from swift-protobuf generated types, which don't embed them.
///
/// Field numbers and proto names come from each type's generated name table (read by
/// reflection). Field types are found by decoding small probe buffers — one field, one wire
/// type, a chosen value — and seeing how the message accepts and re-encodes them: a varint `1`
/// that comes back as JSON `true` is a `bool`, as `"1"` a 64-bit integer, as `-1` a `sint32`, and
/// so on; a length-delimited `"a"` that comes back as `"a"` is a `string`, as `"YQ=="` `bytes`,
/// and an empty one that yields a sub-message is a message field, whose type is then
/// reconstructed recursively.
///
/// The result is semantically equivalent to protoc's output for the same messages — same full
/// names, field names, numbers, types, labels, presence and type references — which is what the
/// Java Record Layer needs to read records and evaluate key expressions. File names, comments,
/// options, and oneof grouping are not recoverable; map fields and proto2 `required` fields are
/// refused (pass the real descriptors instead).
enum ProtoReflection {
    typealias Field = Google_Protobuf_FieldDescriptorProto

    // MARK: Name tables

    /// Field (or enum value) number → proto name, from a generated `_protobuf_nameMap`.
    static func nameTable(_ type: Any.Type) -> [Int: String] {
        guard let provider = type as? any SwiftProtobuf._ProtoNameProviding.Type else { return [:] }
        let map = provider._protobuf_nameMap
        for child in Mirror(reflecting: map).children where child.label == "numberToNameMap" {
            guard let table = child.value as? [Int: Any] else { return [:] }
            var result: [Int: String] = [:]
            for (number, names) in table {
                guard let proto = Mirror(reflecting: names).children.first(where: { $0.label == "proto" }) else { continue }
                result[number] = String(describing: proto.value)
            }
            return result
        }
        return [:]
    }

    // MARK: Descriptor set

    /// A `FileDescriptorSet` covering `types` and every message and enum they reference, one file
    /// per proto package.
    static func fileDescriptorSet(for types: [any SwiftProtobuf.Message.Type]) throws -> Google_Protobuf_FileDescriptorSet {
        var builder = Builder()
        for type in types { try builder.add(type) }
        return builder.finish()
    }

    /// Whether `type`'s Swift name nests it inside another generated type (`Outer.Inner`).
    private static func swiftNestingDepth(_ type: Any.Type) -> Int {
        // String(reflecting:) is "Module.Outer.Inner"; drop the module.
        String(reflecting: type).split(separator: ".").count - 1
    }

    private struct Builder {
        /// Message full name → (descriptor, Swift nesting depth).
        var messages: [String: (Google_Protobuf_DescriptorProto, Int)] = [:]
        var enums: [String: (Google_Protobuf_EnumDescriptorProto, Int)] = [:]
        /// Package per message/enum full name.
        var packages: [String: String] = [:]
        /// Swift type-name prefix → proto package prefix, learned from message types (e.g.
        /// "Fdb_Test_" → "fdb.test."), used to name enums, which carry no proto name.
        var prefixes: [(swift: String, proto: String)] = []
        /// Syntax per message full name ("proto2" / "proto3").
        var messageSyntax: [String: String] = [:]

        mutating func add(_ type: any SwiftProtobuf.Message.Type) throws {
            let fullName = type.protoMessageName
            if messages[fullName] != nil { return }
            let depth = swiftNestingDepth(type)
            let components = fullName.split(separator: ".").map(String.init)
            let package = components.dropLast(depth).joined(separator: ".")
            learnPrefix(type, fullName: fullName)
            messages[fullName] = (Google_Protobuf_DescriptorProto(), depth) // placeholder against cycles
            packages[fullName] = package

            var descriptor = Google_Protobuf_DescriptorProto()
            descriptor.name = components.last ?? fullName
            let prober = Prober(type)
            guard prober.defaultIsInitialized else {
                throw ProtoReflectionError.unsupported("\(fullName) has required fields")
            }
            var implicitPresence = false
            for (number, name) in nameTable(type).sorted(by: { $0.key < $1.key }) {
                var field = try prober.field(number: number, name: name, builder: &self)
                field.number = Int32(number)
                field.name = name
                field.jsonName = Self.jsonName(name)
                if prober.hasImplicitPresence(field) { implicitPresence = true }
                descriptor.field.append(field)
            }
            // A message whose scalar fields track presence only when set is proto3.
            let isProto3 = implicitPresence
            messageSyntax[fullName] = isProto3 ? "proto3" : "proto2"
            if isProto3 {
                // proto3 `optional` fields are modeled by protoc as synthetic oneofs.
                for i in descriptor.field.indices where descriptor.field[i].label == .optional
                    && prober.hasExplicitPresence(descriptor.field[i]) && descriptor.field[i].type != .message {
                    descriptor.field[i].proto3Optional = true
                    descriptor.field[i].oneofIndex = Int32(descriptor.oneofDecl.count)
                    var oneof = Google_Protobuf_OneofDescriptorProto()
                    oneof.name = "_" + descriptor.field[i].name
                    descriptor.oneofDecl.append(oneof)
                }
            }
            messages[fullName] = (descriptor, depth)
        }

        mutating func addEnum(_ type: any SwiftProtobuf.Enum.Type) -> String {
            let swiftName = String(reflecting: type).split(separator: ".").dropFirst().joined(separator: ".")
            let depth = swiftNestingDepth(type)
            var fullName = swiftName
            for prefix in prefixes where swiftName.hasPrefix(prefix.swift) {
                fullName = prefix.proto + swiftName.dropFirst(prefix.swift.count)
                break
            }
            if enums[fullName] != nil { return fullName }
            var descriptor = Google_Protobuf_EnumDescriptorProto()
            descriptor.name = String(fullName.split(separator: ".").last ?? Substring(fullName))
            for (number, name) in nameTable(type).sorted(by: { $0.key < $1.key }) {
                var value = Google_Protobuf_EnumValueDescriptorProto()
                value.name = name
                value.number = Int32(number)
                descriptor.value.append(value)
            }
            enums[fullName] = (descriptor, depth)
            packages[fullName] = fullName.split(separator: ".").dropLast(depth).joined(separator: ".")
            return fullName
        }

        /// Learns "Swift prefix ↔ proto package prefix" from a message type's two names.
        mutating func learnPrefix(_ type: any SwiftProtobuf.Message.Type, fullName: String) {
            let swiftName = String(reflecting: type).split(separator: ".").dropFirst().joined(separator: ".")
            let depth = swiftNestingDepth(type)
            let protoTail = fullName.split(separator: ".").suffix(depth).joined(separator: ".")
            guard swiftName.hasSuffix(protoTail) else { return }
            let swiftPrefix = String(swiftName.dropLast(protoTail.count))
            let protoPrefix = String(fullName.dropLast(protoTail.count))
            if !prefixes.contains(where: { $0.swift == swiftPrefix }) {
                prefixes.append((swiftPrefix, protoPrefix))
                prefixes.sort { $0.swift.count > $1.swift.count }
            }
        }

        static func jsonName(_ name: String) -> String {
            var result = ""
            var upper = false
            for char in name {
                if char == "_" { upper = true; continue }
                result.append(upper ? Character(char.uppercased()) : char)
                upper = false
            }
            return result
        }

        /// Files are per (package, syntax): a proto2 and a proto3 file can share a package.
        private func fileKey(_ name: String) -> String {
            let package = packages[name] ?? ""
            let root = String(name.split(separator: ".").prefix(package.isEmpty ? 1 : package.split(separator: ".").count + 1)
                .joined(separator: "."))
            // Nested types and enums live in their top-level message's file; top-level enums in
            // the package's proto3 file when there is one (enum syntax rules are compatible).
            if let syntax = messageSyntax[root] { return package + "|" + syntax }
            let hasProto3 = messageSyntax.contains { packages[$0.key] == package && $0.value == "proto3" }
            return package + "|" + (hasProto3 ? "proto3" : "proto2")
        }

        func finish() -> Google_Protobuf_FileDescriptorSet {
            let keys = Set(messages.keys.map(fileKey) + enums.keys.map(fileKey))
            let packagesWithBothSyntaxes = Set(keys.map { String($0.split(separator: "|", omittingEmptySubsequences: false)[0]) })
                .filter { (p: String) in keys.contains(p + "|proto2") && keys.contains(p + "|proto3") }
            var files: [String: Google_Protobuf_FileDescriptorProto] = [:]
            func file(_ key: String) -> Google_Protobuf_FileDescriptorProto {
                if let existing = files[key] { return existing }
                let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                let (package, syntax) = (parts[0], parts[1])
                var file = Google_Protobuf_FileDescriptorProto()
                let base = package.isEmpty ? "reflected" : package.replacingOccurrences(of: ".", with: "/")
                file.name = base + (packagesWithBothSyntaxes.contains(package) ? "." + syntax : "") + ".reflected.proto"
                file.package = package
                if syntax == "proto3" { file.syntax = "proto3" }
                return file
            }
            // Place nested types inside their parents (deepest first so children are ready).
            var nestedMessages: [String: [Google_Protobuf_DescriptorProto]] = [:]
            var nestedEnums: [String: [Google_Protobuf_EnumDescriptorProto]] = [:]
            func parent(_ name: String) -> String { String(name.split(separator: ".").dropLast().joined(separator: ".")) }
            for (name, (descriptor, depth)) in enums where depth > 1 {
                nestedEnums[parent(name), default: []].append(descriptor)
            }
            var topLevel: [String: Google_Protobuf_DescriptorProto] = [:]
            for (name, (descriptor, depth)) in messages.sorted(by: { $0.value.1 > $1.value.1 }) {
                var descriptor = descriptor
                descriptor.nestedType = (nestedMessages[name] ?? []).sorted { $0.name < $1.name }
                descriptor.enumType = (nestedEnums[name] ?? []).sorted { $0.name < $1.name }
                if depth > 1 { nestedMessages[parent(name), default: []].append(descriptor) }
                else { topLevel[name] = descriptor }
            }
            var fileOf: [String: String] = [:] // type full name -> file key
            for (name, descriptor) in topLevel.sorted(by: { $0.key < $1.key }) {
                let key = fileKey(name)
                var f = file(key)
                f.messageType.append(descriptor)
                files[key] = f
            }
            for (name, (descriptor, depth)) in enums.sorted(by: { $0.key < $1.key }) where depth <= 1 {
                let key = fileKey(name)
                var f = file(key)
                f.enumType.append(descriptor)
                files[key] = f
            }
            for name in Array(messages.keys) + Array(enums.keys) { fileOf[name] = fileKey(name) }
            // References to types in other files become imports.
            for (key, var f) in files {
                var refs = Set<String>()
                for message in f.messageType { collectReferences(message, into: &refs) }
                f.dependency = Set(refs.compactMap { ref -> String? in
                    guard let other = fileOf[ref], other != key else { return nil }
                    return files[other]?.name
                }).sorted()
                files[key] = f
            }
            var set = Google_Protobuf_FileDescriptorSet()
            set.file = files.values.sorted { $0.name < $1.name }
            return set
        }

        private func collectReferences(_ message: Google_Protobuf_DescriptorProto, into refs: inout Set<String>) {
            for field in message.field where !field.typeName.isEmpty { refs.insert(String(field.typeName.dropFirst())) }
            for nested in message.nestedType { collectReferences(nested, into: &refs) }
        }
    }

    // MARK: Probing

    /// Decodes probe buffers into one message type.
    private struct Prober {
        let type: any SwiftProtobuf.Message.Type

        init(_ type: any SwiftProtobuf.Message.Type) { self.type = type }

        var defaultIsInitialized: Bool { type.init().isInitialized }

        func decode(_ bytes: FDB.Bytes) -> (any SwiftProtobuf.Message)? {
            guard let message = try? type.init(serializedBytes: bytes), message.unknownFields.data.isEmpty else { return nil }
            return message
        }

        static func json(_ message: any SwiftProtobuf.Message) -> [String: Any] {
            var options = JSONEncodingOptions()
            options.preserveProtoFieldNames = true
            guard let data = try? message.jsonUTF8Data(options: options),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return object
        }

        static func tag(_ number: Int, _ wireType: UInt64) -> FDB.Bytes {
            var out: FDB.Bytes = []
            ProtoFields.writeVarint(UInt64(number) << 3 | wireType, into: &out)
            return out
        }

        static func varint(_ value: UInt64) -> FDB.Bytes {
            var out: FDB.Bytes = []
            ProtoFields.writeVarint(value, into: &out)
            return out
        }

        /// The JSON text of field `name` after decoding `payload` as field `number` (the first
        /// element for a repeated field), e.g. `true`, `1`, `"1"`, `"RED"`, `"YQ=="`.
        func probe(_ number: Int, _ name: String, _ wireType: UInt64, _ payload: FDB.Bytes) -> String? {
            probeWithShape(number, name, wireType, payload)?.value
        }

        /// Like ``probe`` but encodes the field twice, so a repeated field shows as an array.
        func probeWithShape(_ number: Int, _ name: String, _ wireType: UInt64, _ payload: FDB.Bytes) -> (value: String, repeated: Bool)? {
            var one = Self.tag(number, wireType)
            if wireType == 2 { one += Self.varint(UInt64(payload.count)) }
            one += payload
            guard let message = decode(one + one) else { return nil }
            var options = JSONEncodingOptions()
            options.preserveProtoFieldNames = true
            guard let json = try? message.jsonString(options: options) else { return nil }
            // Only this field is set, so the object is {"name":VALUE}.
            let prefix = "{\"\(name)\":"
            guard json.hasPrefix(prefix), json.hasSuffix("}") else { return nil }
            var value = String(json.dropFirst(prefix.count).dropLast())
            let repeated = value.hasPrefix("[") && value.hasSuffix("]")
            if repeated {
                value = String(value.dropFirst().dropLast())
                if let comma = value.firstIndex(of: ",") { value = String(value[..<comma]) }
            }
            return (value, repeated)
        }

        func field(number: Int, name: String, builder: inout Builder) throws -> Field {
            var field = Field()
            field.label = .optional
            // Repeated if a doubled occurrence comes back as an array, under whichever wire
            // type the field accepts. Maps encode as JSON objects keyed by entry key.
            for (wireType, payload) in [(UInt64(0), Self.varint(1)), (5, [0, 0, 0x80, 0x3F]),
                                        (1, [0, 0, 0, 0, 0, 0, 0xF0, 0x3F]), (2, [0x61]), (2, [])] {
                if let shape = probeWithShape(number, name, wireType, payload) {
                    if shape.repeated { field.label = .repeated }
                    if wireType == 2, payload.isEmpty, shape.value.hasPrefix("{"), shape.value != "{}" {
                        throw ProtoReflectionError.unsupported("map field \(type.protoMessageName).\(name)")
                    }
                    break
                }
            }
            func quoted(_ text: String) -> String? {
                guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return nil }
                return String(text.dropFirst().dropLast())
            }

            // Varint family.
            if let one = probe(number, name, 0, Self.varint(1)) {
                if one == "true" {
                    field.type = .bool
                } else if let string = quoted(one), Int64(string) == nil {
                    field.type = .enum
                    guard let message = decode(Self.tag(number, 0) + Self.varint(1)),
                          let enumType = Self.findEnumType(in: message) else {
                        throw ProtoReflectionError.undeterminedField(message: type.protoMessageName, field: name)
                    }
                    field.typeName = "." + builder.addEnum(enumType)
                } else if let string = quoted(one) {
                    // 64-bit integers encode as JSON strings.
                    if string == "-1" { field.type = .sint64 }
                    else { field.type = probe(number, name, 0, Self.varint(UInt64.max)) == "\"-1\"" ? .int64 : .uint64 }
                } else if one == "-1" {
                    field.type = .sint32
                } else {
                    field.type = probe(number, name, 0, Self.varint(0xFFFF_FFFF)) == "-1" ? .int32 : .uint32
                }
                return field
            }
            // Fixed 32-bit family.
            if let value = probe(number, name, 5, [0x00, 0x00, 0x80, 0x3F]) {
                if value == "1" || value == "1.0" { field.type = .float }
                else { field.type = probe(number, name, 5, [0xFF, 0xFF, 0xFF, 0xFF]) == "-1" ? .sfixed32 : .fixed32 }
                return field
            }
            // Fixed 64-bit family.
            if let value = probe(number, name, 1, [0, 0, 0, 0, 0, 0, 0xF0, 0x3F]) {
                if value == "1" || value == "1.0" { field.type = .double }
                else {
                    field.type = probe(number, name, 1, FDB.Bytes(repeating: 0xFF, count: 8)) == "\"-1\"" ? .sfixed64 : .fixed64
                }
                return field
            }
            // Length-delimited: string, bytes, or message.
            if let value = probe(number, name, 2, [0x61]), let text = quoted(value) {
                field.type = text == "a" ? .string : .bytes
                return field
            }
            if let message = decode(Self.tag(number, 2) + [0x00]),
               let sub = extractMessages(message, fieldNumber: number).first {
                let subType = Swift.type(of: sub)
                field.type = .message
                field.typeName = "." + subType.protoMessageName
                try builder.add(subType)
                return field
            }
            throw ProtoReflectionError.undeterminedField(message: type.protoMessageName, field: name)
        }

        /// A scalar field that doesn't record whether its default value was set (proto3 implicit
        /// presence).
        func hasImplicitPresence(_ field: Field) -> Bool {
            field.label == .optional && field.type != .message && !hasExplicitPresence(field)
        }

        /// Whether setting the field to its zero value is remembered (and so re-encoded).
        func hasExplicitPresence(_ field: Field) -> Bool {
            let zero: (UInt64, FDB.Bytes)
            switch field.type {
            case .float, .fixed32, .sfixed32: zero = (5, [0, 0, 0, 0])
            case .double, .fixed64, .sfixed64: zero = (1, FDB.Bytes(repeating: 0, count: 8))
            case .string, .bytes: zero = (2, [])
            case .message, .group: return true
            default: zero = (0, [0])
            }
            var bytes = Self.tag(Int(field.number), zero.0)
            if zero.0 == 2 { bytes += [0] } else { bytes += zero.1 }
            guard let message = decode(bytes) else { return false }
            return Self.json(message)[field.name] != nil
        }

        /// The enum type of the field holding raw value 1 in `message`.
        static func findEnumType(in message: any SwiftProtobuf.Message) -> (any SwiftProtobuf.Enum.Type)? {
            func search(_ value: Any, depth: Int) -> (any SwiftProtobuf.Enum.Type)? {
                if let e = value as? any SwiftProtobuf.Enum, e.rawValue == 1 { return Swift.type(of: e) }
                if let array = value as? [Any] {
                    for element in array { if let found = search(element, depth: depth) { return found } }
                }
                guard depth < 4 else { return nil }
                for child in Mirror(reflecting: value).children where child.label != "unknownFields" {
                    if let found = search(child.value, depth: depth + 1) { return found }
                }
                return nil
            }
            return search(message, depth: 0)
        }
    }
}
#endif
