/*
 * MetaDataProtoTests.swift
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
import Testing

@testable import FDBRecordLayer
import FoundationDB

/// The `FileDescriptorProto` for `Protos/test_records.proto`, built by hand (there is no protoc
/// to emit a descriptor set at test time). Mirrors the `.proto` exactly.
enum TestRecordsDescriptor {
    typealias Field = Google_Protobuf_FieldDescriptorProto

    static func field(_ name: String, _ number: Int32, _ type: Field.TypeEnum,
                      typeName: String? = nil, repeated: Bool = false) -> Field {
        var field = Field()
        field.name = name
        field.number = number
        field.type = type
        field.label = repeated ? .repeated : .optional
        if let typeName { field.typeName = typeName }
        return field
    }

    static func message(_ name: String, _ fields: [Field]) -> Google_Protobuf_DescriptorProto {
        var message = Google_Protobuf_DescriptorProto()
        message.name = name
        message.field = fields
        return message
    }

    static var file: Google_Protobuf_FileDescriptorProto {
        var file = Google_Protobuf_FileDescriptorProto()
        file.name = "test_records.proto"
        file.package = "fdb.test"
        file.syntax = "proto3"
        file.messageType = [
            message("Customer", [field("id", 1, .int64), field("name", 2, .string), field("city", 3, .string)]),
            message("Order", [
                field("order_id", 1, .int64), field("flower", 2, .string), field("price", 3, .int64),
                field("customer", 4, .message, typeName: ".fdb.test.Customer"),
                field("tags", 5, .string, repeated: true),
                field("color", 6, .enum, typeName: ".fdb.test.Color"), field("fulfilled", 7, .bool),
            ]),
            message("Item", [field("sku", 1, .string), field("name", 2, .string),
                             field("quantity", 3, .int64), field("category", 4, .string)]),
        ]
        var color = Google_Protobuf_EnumDescriptorProto()
        color.name = "Color"
        color.value = [("COLOR_UNSPECIFIED", 0), ("RED", 1), ("BLUE", 2)].map { name, number in
            var value = Google_Protobuf_EnumValueDescriptorProto()
            value.name = name
            value.number = Int32(number)
            return value
        }
        file.enumType = [color]
        return file
    }

    static var set: Data {
        var set = Google_Protobuf_FileDescriptorSet()
        set.file = [file]
        return try! set.serializedData()
    }

    static func fields(_ message: String) throws -> KeyExpressionProto.FieldNames {
        try KeyExpressionProto.FieldNames(descriptorSet: set, messageName: message)
    }
}

/// `[UInt8]` from a mix of byte literals and ASCII strings, for writing expected protobuf bytes.
private func bytes(_ parts: Any...) -> [UInt8] {
    parts.flatMap { part -> [UInt8] in
        switch part {
        case let s as String: return Array(s.utf8)
        case let b as Int: return [UInt8(b)]
        case let a as [UInt8]: return a
        default: fatalError("unsupported part \(part)")
        }
    }
}

@Suite("MetaData proto (Java interop)")
struct MetaDataProtoTests {
    // MARK: - Key expressions: exact bytes

    /// Bytes derived by hand from `record_key_expression.proto` and Java's `toProto()`:
    /// `Field` always carries fan_type and null_interpretation (NOT_UNIQUE = 1).
    @Test("key expressions encode to Java's KeyExpression bytes")
    func keyExpressionBytes() throws {
        let order = try TestRecordsDescriptor.fields("fdb.test.Order")
        // field("price"): KeyExpression{field(3): Field{"price", SCALAR, NOT_UNIQUE}}
        let price = bytes(0x1a, 0x0b, 0x0a, 0x05, "price", 0x10, 0x01, 0x18, 0x01)
        #expect(try KeyExpressionProto.encode(KeyExpression<Fdb_Test_Order>.field(\.price).node, fieldNames: order) == price)

        // concat(field("flower"), field("price")): KeyExpression{then(1): Then{child, child}}
        let flowerPrice = bytes(0x0a, 0x1f,
                                0x0a, 0x0e, 0x1a, 0x0c, 0x0a, 0x06, "flower", 0x10, 0x01, 0x18, 0x01,
                                0x0a, 0x0d, price)
        let concat = KeyExpression<Fdb_Test_Order>.concat(.field(\.flower), .field(\.price)).node
        #expect(try KeyExpressionProto.encode(concat, fieldNames: order) == flowerPrice)
        // Nested thens flatten like Java's concat.
        #expect(try KeyExpressionProto.encode(.then([.then([.field(number: 2, fanType: nil)]), .field(number: 3, fanType: nil)]),
                                              fieldNames: order) == flowerPrice)

        // field("customer").nest("name"): KeyExpression{nesting(2): Nesting{parent Field, child}}
        let customerName = bytes(0x12, 0x1e,
                                 0x0a, 0x0e, 0x0a, 0x08, "customer", 0x10, 0x01, 0x18, 0x01,
                                 0x12, 0x0c, 0x1a, 0x0a, 0x0a, 0x04, "name", 0x10, 0x01, 0x18, 0x01)
        #expect(try KeyExpressionProto.encode(KeyExpression<Fdb_Test_Order>.field(\.customer.name).node,
                                              fieldNames: order) == customerName)

        // field("tags", FAN_OUT) and field("tags", CONCATENATE)
        #expect(try KeyExpressionProto.encode(KeyExpression<Fdb_Test_Order>.field(\.tags, .fanOut).node, fieldNames: order)
                == bytes(0x1a, 0x0a, 0x0a, 0x04, "tags", 0x10, 0x02, 0x18, 0x01))
        #expect(try KeyExpressionProto.encode(KeyExpression<Fdb_Test_Order>.field(\.tags, .concatenate).node, fieldNames: order)
                == bytes(0x1a, 0x0a, 0x0a, 0x04, "tags", 0x10, 0x03, 0x18, 0x01))

        // version() / recordType() / empty(): empty sub-messages at fields 7 / 11 / 5.
        #expect(try KeyExpressionProto.encode(.version, fieldNames: order) == [0x3a, 0x00])
        #expect(try KeyExpressionProto.encode(.recordType, fieldNames: order) == [0x5a, 0x00])
        #expect(try KeyExpressionProto.encode(.empty, fieldNames: order) == [0x2a, 0x00])

        // field("price").groupBy(field("flower")) = Grouping(concat(flower, price), 1)
        let grouped = KeyExpressionNode.grouping(concat, groupedCount: 1)
        #expect(try KeyExpressionProto.encode(grouped, fieldNames: order)
                == bytes(0x22, 0x25, 0x0a, 0x21, flowerPrice, 0x18, 0x01))

        // Every encoding decodes back to the same node.
        for node in [KeyExpression<Fdb_Test_Order>.field(\.price).node, concat, grouped,
                     KeyExpression<Fdb_Test_Order>.field(\.customer.name).node,
                     .then([.recordType, .field(number: 5, fanType: .fanOut), .version]), .empty] {
            #expect(try KeyExpressionProto.decode(KeyExpressionProto.encode(node, fieldNames: order), fieldNames: order) == node)
        }
    }

    @Test("decoding rejects unknown fields and unsupported expressions")
    func keyExpressionDecodeErrors() throws {
        let order = try TestRecordsDescriptor.fields("fdb.test.Order")
        let unknown = bytes(0x1a, 0x09, 0x0a, 0x03, "zzz", 0x10, 0x01, 0x18, 0x01)
        #expect(throws: MetaDataProtoError.unknownField(message: "fdb.test.Order", field: "zzz")) {
            try KeyExpressionProto.decode(unknown, fieldNames: order)
        }
        // A Function key expression (field 9).
        #expect(throws: MetaDataProtoError.unsupported("function key expression")) {
            try KeyExpressionProto.decode(bytes(0x4a, 0x00), fieldNames: order)
        }
        // NOT_NULL null interpretation.
        #expect(throws: MetaDataProtoError.unsupported("Field price null_interpretation 3")) {
            try KeyExpressionProto.decode(bytes(0x1a, 0x0b, 0x0a, 0x05, "price", 0x10, 0x01, 0x18, 0x03), fieldNames: order)
        }
        #expect(throws: MetaDataProtoError.unserializable("key expression built from closures")) {
            try KeyExpressionProto.encode(.opaque, fieldNames: order)
        }
    }

    // MARK: - Indexes: exact bytes

    @Test("indexes encode to Java's Index bytes")
    func indexBytes() throws {
        let meta = RecordMetaData(version: 3) {
            RecordType(Fdb_Test_Order.self, primaryKey: \.orderID)
                .index("order.price", on: \.price)
            RecordType(Fdb_Test_Item.self, primaryKey: \.sku)
                .index("item.count", on: .field(\.category), type: .count, key: 7,
                       addedVersion: 2, lastModifiedVersion: 3, clearWhenZero: true)
        }
        let proto = try ProtoReader(FDB.Bytes(meta.toProto(descriptorSet: TestRecordsDescriptor.set)), "MetaData")
        let indexes = proto.repeatedBytes(2)
        try #require(indexes.count == 2)

        // Sorted by name: "item.count" first.
        // count index: root wrapped in Grouping(field("category"), 0); subspace key Tuple(7).
        #expect(indexes[0] == bytes(
            0x0a, 0x04, "Item",                                     // record_type
            0x1a, 0x0a, "item.count",                               // name
            0x22, 0x16, 0x22, 0x14,                                 // root_expression: KeyExpression{grouping}
            0x0a, 0x10, 0x1a, 0x0e, 0x0a, 0x08, "category", 0x10, 0x01, 0x18, 0x01, //   whole_key
            0x18, 0x00,                                             //   grouped_count = 0
            0x2a, 0x02, 0x15, 0x07,                                 // subspace_key = Tuple(7)
            0x30, 0x03,                                             // last_modified_version
            0x42, 0x05, "count",                                    // type
            0x4a, 0x15, 0x0a, 0x0d, "clearWhenZero", 0x12, 0x04, "true", // options
            0x50, 0x02))                                            // added_version

        // value index with the Swift default versions (0), written as 1 for Java.
        #expect(indexes[1] == bytes(
            0x0a, 0x05, "Order",
            0x1a, 0x0b, "order.price",
            0x22, 0x0d, 0x1a, 0x0b, 0x0a, 0x05, "price", 0x10, 0x01, 0x18, 0x01,
            0x2a, 0x0d, 0x02, "order.price", 0x00,                  // subspace_key = Tuple("order.price")
            0x30, 0x01,
            0x42, 0x05, "value",
            0x50, 0x01))

        // Record types: name, primary key; then split_long_records, version, store_record_versions.
        #expect(proto.repeatedBytes(3) == [
            bytes(0x0a, 0x05, "Order", 0x12, 0x10, 0x1a, 0x0e, 0x0a, 0x08, "order_id", 0x10, 0x01, 0x18, 0x01),
            bytes(0x0a, 0x04, "Item", 0x12, 0x0b, 0x1a, 0x09, 0x0a, 0x03, "sku", 0x10, 0x01, 0x18, 0x01),
        ])
        #expect(proto.bool(4) == true)
        #expect(proto.int32(5) == 3)
        #expect(proto.bool(8) == false)
        #expect(proto.repeatedBytes(9).isEmpty)

        // The records file is test_records.proto plus RecordTypeUnion { _Order = 1; _Item = 2; }.
        let records = try Google_Protobuf_FileDescriptorProto(serializedBytes: try #require(proto.bytes(1)))
        #expect(records.name == "test_records.proto")
        let union = try #require(records.messageType.first { $0.name == "RecordTypeUnion" })
        #expect(union.field.map { "\($0.name)=\($0.number):\($0.typeName)" }
                == ["_Order=1:.fdb.test.Order", "_Item=2:.fdb.test.Item"])
    }

    // MARK: - Round trip

    /// Metadata touching every serialized feature.
    static func richMetaData() -> RecordMetaData {
        RecordMetaData(
            version: 4,
            formerIndexes: [FormerIndex(name: "old.idx", addedVersion: 1, removedVersion: 2),
                            FormerIndex(name: "old.keyed", explicitKey: 99, removedVersion: 3)],
            multiTypeIndexes: [
                MultiTypeIndex("all.count", on: .empty, type: .count),
                MultiTypeIndex("both.type", on: .recordType,
                               recordTypes: [Fdb_Test_Order.self, Fdb_Test_Item.self], key: 40),
            ],
            recordCountKey: .recordType,
            joinedRecordTypes: [JoinedRecordType(
                "OrderItem",
                constituents: [.init("order", Fdb_Test_Order.self), .init("item", Fdb_Test_Item.self, outerJoined: true)],
                joins: [.init("order", .field(number: 2, fanType: nil), "item", .field(number: 2, fanType: nil))],
                indexes: [SyntheticIndex("joined.priceCategory",
                                         on: .then([.nest(number: 1, fanType: nil, child: .field(number: 3, fanType: nil)),
                                                    .nest(number: 2, fanType: nil, child: .field(number: 4, fanType: nil))]),
                                         addedVersion: 3)])],
            unnestedRecordTypes: [UnnestedRecordType(
                "OrderCustomer", parentName: "parent", parentType: Fdb_Test_Order.self,
                nested: [.init("customer", parent: "parent", typeName: "fdb.test.Customer",
                               nestingExpression: .field(number: 4, fanType: nil))],
                indexes: [SyntheticIndex("unnested.city", on: .nest(number: 2, fanType: nil, child: .field(number: 3, fanType: nil)),
                                         key: 41)])]
        ) {
            RecordType(Fdb_Test_Order.self, primaryKey: .concat(.recordType(), .field(\.orderID)))
                .index("order.price", on: \.price)
                .index("order.byTag", on: \.tags, fanType: .fanOut)
                .index("order.customerName", on: \.customer.name, addedVersion: 2)
                .index("order.flowerPrice", on: .concat(.field(\.flower), .field(\.price)), unique: true)
                .index("order.priceRank", on: \.price, type: .rank)
            RecordType(Fdb_Test_Item.self, key: 7, unionField: 5, sinceVersion: 2,
                       primaryKey: .concat(.recordType(), .field(\.sku)))
                .index("item.sumQty", on: .concat(.field(\.category), .field(\.quantity)), type: .sum)
                .index("item.maxQty", on: .concat(.field(\.category), .field(\.quantity)), type: .maxEverLong, key: 12)
        }
    }

    @Test("metadata → proto → metadata → proto is stable and preserves the model")
    func roundTripStructure() throws {
        let meta = Self.richMetaData()
        let first = try meta.toProto(descriptorSet: TestRecordsDescriptor.set)
        let loaded = try RecordMetaData(metaDataProto: first, recordTypes: [Fdb_Test_Order.self, Fdb_Test_Item.self])
        let second = try loaded.toProto(descriptorSet: TestRecordsDescriptor.set)
        #expect(first == second)

        #expect(loaded.version == 4)
        #expect(loaded.splitLongRecords == meta.splitLongRecords)
        #expect(loaded.recordCountKey == .recordType)
        for type in meta.recordTypes {
            let other = try #require(loaded.recordType(named: type.recordName))
            #expect(other.unionFieldNumber == type.unionFieldNumber)
            #expect(other.recordTypeKey == type.recordTypeKey)
            #expect(other.sinceVersion == type.sinceVersion)
            #expect(other.primaryKeyNode == type.primaryKeyNode)
            #expect(other.primaryKeyStartsWithRecordType == type.primaryKeyStartsWithRecordType)
        }
        #expect(loaded.recordType(named: "fdb.test.Item")?.recordTypeKey == 7)
        #expect(loaded.recordType(named: "fdb.test.Item")?.unionFieldNumber == 5)
        for index in meta.allIndexes {
            let other = try #require(loaded.index(named: index.name))
            #expect(other.type == index.type)
            #expect(other.rootNode == index.rootNode)
            #expect(other.groupedCount == index.groupedCount)
            #expect(other.subspaceTupleKey == index.subspaceTupleKey)
            #expect(other.options == index.options)
            #expect(Set(other.recordTypeNames) == Set(index.recordTypeNames))
            #expect(other.isUniversal == index.isUniversal)
            #expect(other.syntheticTypeName == index.syntheticTypeName)
            #expect(other.lastModifiedVersion == max(index.lastModifiedVersion, 1))
        }
        #expect(loaded.index(named: "all.count")?.isUniversal == true)
        #expect(loaded.formerIndexes.map { Tuple($0.subspaceKey) } == meta.formerIndexes.map { Tuple($0.subspaceKey) })
        #expect(loaded.syntheticTypes.map(\.name) == ["OrderItem", "OrderCustomer"])
        #expect(loaded.syntheticTypes.map(\.recordTypeKey) == meta.syntheticTypes.map(\.recordTypeKey))
    }

    @Test("a store opened with loaded metadata writes the same keys as the DSL metadata")
    func roundTripStoreBehaviour() async throws {
        let meta = RecordMetaData(
            version: 2,
            multiTypeIndexes: [MultiTypeIndex("all.count", on: .empty, type: .count)]
        ) {
            RecordType(Fdb_Test_Order.self, primaryKey: .concat(.recordType(), .field(\.orderID)))
                .index("order.price", on: \.price)
                .index("order.byTag", on: \.tags, fanType: .fanOut)
                .index("order.customerName", on: \.customer.name)
                .index("order.flowerPrice", on: .concat(.field(\.flower), .field(\.price)), unique: true)
                .index("order.tagsConcat", on: \.tags, fanType: .concatenate, key: 3)
                .index("order.priceRank", on: \.price, type: .rank)
            RecordType(Fdb_Test_Item.self, key: 9, unionField: 4, primaryKey: .concat(.recordType(), .field(\.sku)))
                .index("item.countByCategory", on: .field(\.category), type: .count, addedVersion: 2)
                .index("item.sumQty", on: .concat(.field(\.category), .field(\.quantity)), type: .sum)
                .index("item.maxQty", on: .concat(.field(\.category), .field(\.quantity)), type: .maxEverLong)
        }
        let loaded = try RecordMetaData(metaDataProto: meta.toProto(descriptorSet: TestRecordsDescriptor.set),
                                        recordTypes: [Fdb_Test_Order.self, Fdb_Test_Item.self])

        try await FDBBootstrap.shared.ensureInitialized()
        let db = try FDBClient.openDatabase()
        let run = UUID().uuidString
        let a = Subspace(Tuple("fdbrl-mdproto", run, "dsl"))
        let b = Subspace(Tuple("fdbrl-mdproto", run, "loaded"))
        for (subspace, metaData) in [(a, meta), (b, loaded)] {
            try await db.withRecordContext { context in
                let store = try await FDBRecordStore.open(context: context, subspace: subspace, metaData: metaData)
                _ = try await store.save(Fdb_Test_Order.sample(id: 1, flower: "rose", price: 10, customer: "alice", tags: ["a", "b"]))
                _ = try await store.save(Fdb_Test_Order.sample(id: 2, flower: "tulip", price: 7, customer: "bob", tags: ["b"]))
                _ = try await store.save(Fdb_Test_Item.sample(sku: "x", quantity: 3, category: "tools"))
                _ = try await store.save(Fdb_Test_Item.sample(sku: "y", quantity: 5, category: "tools"))
            }
            try await db.withRecordContext { context in
                let store = try await FDBRecordStore.open(context: context, subspace: subspace, metaData: metaData)
                _ = try await store.save(Fdb_Test_Order.sample(id: 2, flower: "tulip", price: 8, customer: "bob", tags: ["c"]))
                _ = try await store.delete(Fdb_Test_Item.self, primaryKey: Tuple(Int64(9), "x"))
            }
        }

        func contents(_ subspace: Subspace) async throws -> [(FDB.Bytes, FDB.Bytes)] {
            try await db.withTransaction { tx in
                let (begin, end) = subspace.range
                let header = subspace.pack(Tuple(Int64(0)))
                return try await tx.getRangeNative(beginKey: begin, endKey: end, limit: 0, snapshot: false).records
                    .filter { $0.0 != header } // the header carries a timestamp
                    .map { (Array($0.0.dropFirst(subspace.prefix.count)), $0.1) }
            }
        }
        let dsl = try await contents(a)
        let fromProto = try await contents(b)
        #expect(dsl.count > 20)
        #expect(dsl.map(\.0) == fromProto.map(\.0))
        #expect(dsl.map(\.1) == fromProto.map(\.1))

        try await db.withRecordContext { context in
            FDBRecordStore.deleteStore(context: context, subspace: a)
            FDBRecordStore.deleteStore(context: context, subspace: b)
        }
    }

    // MARK: - Loading Java-written metadata

    /// A `MetaData` assembled field by field as Java's `RecordMetaData.toProto()` writes it for:
    ///
    /// ```java
    /// builder.getRecordType("Order").setPrimaryKey(concat(recordType(), field("order_id")));
    /// builder.getRecordType("Item").setPrimaryKey(concat(recordType(), field("sku")));
    /// builder.getRecordType("Item").setRecordTypeKey(100L);
    /// builder.addIndex("Order", new Index("price", field("price"))) /* subspace key 12L */;
    /// builder.addIndex("Item", new Index("sumQty", field("quantity").groupBy(field("category")), SUM));
    /// builder.addUniversalIndex(new Index("globalCount", new GroupingKeyExpression(empty(), 0), COUNT));
    /// builder.addFormerIndex(new FormerIndex(99L, 1, 2, "gone"));
    /// ```
    /// with union `RecordTypeUnion { Order _Order = 7; Item _Item = 3; }`.
    static func javaMetaData() throws -> Data {
        var records = TestRecordsDescriptor.file
        var union = Google_Protobuf_DescriptorProto()
        union.name = "RecordTypeUnion"
        union.field = [TestRecordsDescriptor.field("_Order", 7, .message, typeName: ".fdb.test.Order"),
                       TestRecordsDescriptor.field("_Item", 3, .message, typeName: ".fdb.test.Item")]
        records.messageType.append(union)

        func field(_ name: String) -> [UInt8] {
            bytes(0x1a, 2 + name.utf8.count + 4, 0x0a, name.utf8.count, name, 0x10, 0x01, 0x18, 0x01)
        }
        func lengthDelimited(_ number: Int, _ payload: [UInt8]) -> [UInt8] {
            var w = ProtoWriter()
            w.message(number, payload)
            return w.bytes
        }
        var out = ProtoWriter()
        out.message(1, try records.serializedBytes())
        // indexes, sorted by name
        out.message(2, bytes(0x1a, 0x0b, "globalCount",
                             lengthDelimited(4, lengthDelimited(4, bytes(0x0a, 0x02, 0x2a, 0x00, 0x18, 0x00))),
                             0x2a, 0x0d, 0x02, "globalCount", 0x00, 0x30, 0x01, 0x42, 0x05, "count", 0x50, 0x01))
        out.message(2, bytes(0x0a, 0x05, "Order", 0x1a, 0x05, "price", lengthDelimited(4, field("price")),
                             0x2a, 0x02, 0x15, 0x0c, 0x30, 0x02, 0x42, 0x05, "value", 0x50, 0x02))
        let categoryQuantity = lengthDelimited(1, lengthDelimited(1, field("category")) + lengthDelimited(1, field("quantity")))
        out.message(2, bytes(0x0a, 0x04, "Item", 0x1a, 0x06, "sumQty",
                             lengthDelimited(4, lengthDelimited(4, lengthDelimited(1, categoryQuantity) + [0x18, 0x01])),
                             0x2a, 0x08, 0x02, "sumQty", 0x00, 0x30, 0x03, 0x42, 0x03, "sum", 0x50, 0x03))
        // record_types
        out.message(3, bytes(0x0a, 0x05, "Order",
                             lengthDelimited(2, lengthDelimited(1, lengthDelimited(1, [0x5a, 0x00]) + lengthDelimited(1, field("order_id"))))))
        out.message(3, bytes(0x0a, 0x04, "Item",
                             lengthDelimited(2, lengthDelimited(1, lengthDelimited(1, [0x5a, 0x00]) + lengthDelimited(1, field("sku")))),
                             lengthDelimited(4, [0x18, 0x64])))   // explicit_key: Value{long_value: 100}
        out.bool(4, true)       // split_long_records
        out.int32(5, 3)         // version
        out.message(6, bytes(0x1a, 0x04, "gone", 0x2a, 0x02, 0x15, 0x63, 0x30, 0x02, 0x50, 0x01))
        out.bool(8, false)      // store_record_versions
        return Data(out.bytes)
    }

    @Test("loads Java-written metadata and stores records with its keys")
    func loadJavaMetaData() async throws {
        let meta = try RecordMetaData(metaDataProto: Self.javaMetaData(),
                                      recordTypes: [Fdb_Test_Order.self, Fdb_Test_Item.self])
        #expect(meta.version == 3)
        #expect(meta.recordType(named: "fdb.test.Order")?.unionFieldNumber == 7)
        #expect(meta.recordType(named: "fdb.test.Item")?.unionFieldNumber == 3)
        #expect(meta.recordType(named: "fdb.test.Item")?.recordTypeKey == 100)
        #expect(meta.index(named: "sumQty")?.groupedCount == 1)
        #expect(meta.index(named: "globalCount")?.isUniversal == true)
        #expect(meta.index(named: "globalCount")?.groupedCount == 0)
        #expect(meta.formerIndexes.first?.formerName == "gone")

        try await FDBBootstrap.shared.ensureInitialized()
        let db = try FDBClient.openDatabase()
        let subspace = Subspace(Tuple("fdbrl-mdproto", UUID().uuidString))
        try await db.withRecordContext { context in
            let store = try await FDBRecordStore.open(context: context, subspace: subspace, metaData: meta)
            _ = try await store.save(Fdb_Test_Order.sample(id: 5, price: 42))
            _ = try await store.save(Fdb_Test_Item.sample(sku: "a", quantity: 4, category: "x"))
            _ = try await store.save(Fdb_Test_Item.sample(sku: "b", quantity: 6, category: "x"))
        }
        try await db.withTransaction { tx in
            // Records are wrapped in their Java union fields: _Order = 7 (tag 0x3a), _Item = 3 (tag 0x1a).
            // Order's record type key is its union field (7).
            let order = try #require(try await tx.getValue(for: subspace.pack(Tuple(Int64(1), Int64(7), Int64(5), Int64(0)))))
            #expect(order.first == 0x3a)
            let item = try #require(try await tx.getValue(for: subspace.pack(Tuple(Int64(1), Int64(100), "a", Int64(0)))))
            #expect(item.first == 0x1a)
            // "price" lives under its integer subspace key 12.
            #expect(try await tx.getValue(for: subspace.pack(Tuple(Int64(2), Int64(12), Int64(42), Int64(7), Int64(5)))) == [])
            // sum grouped by category, and the universal count.
            let sum = try #require(try await tx.getValue(for: subspace.pack(Tuple(Int64(2), "sumQty", "x"))))
            #expect(IndexMaintainer.decodeLittleEndian(sum) == 10)
            let count = try #require(try await tx.getValue(for: subspace.pack(Tuple(Int64(2), "globalCount"))))
            #expect(IndexMaintainer.decodeLittleEndian(count) == 3)
        }
        try await db.withRecordContext { FDBRecordStore.deleteStore(context: $0, subspace: subspace) }
    }

    @Test("rejects Java features the Swift layer does not implement")
    func loadRejectsUnsupported() throws {
        var proto = try ProtoFields(decoding: FDB.Bytes(Self.javaMetaData()))
        var indexes = proto.repeatedBytes(2)
        // Give "price" a predicate (Index field 11).
        indexes[1] += [0x5a, 0x00]
        proto.setRepeatedBytes(2, indexes)
        #expect(throws: MetaDataProtoError.unsupported("index price has a predicate")) {
            try RecordMetaData(metaDataProto: Data(proto.encode()), recordTypes: [Fdb_Test_Order.self, Fdb_Test_Item.self])
        }
        #expect(throws: MetaDataProtoError.unknownRecordType("fdb.test.Item")) {
            try RecordMetaData(metaDataProto: Self.javaMetaData(), recordTypes: [Fdb_Test_Order.self])
        }
    }

    @Test("record count key encodes against every record type")
    func recordCountKeyForHeader() throws {
        let order = try TestRecordsDescriptor.fields("fdb.test.Order")
        let item = try TestRecordsDescriptor.fields("fdb.test.Item")
        #expect(try KeyExpressionProto.encodeForHeader(.recordType, recordDescriptors: [order, item]) == [0x5a, 0x00])
        // Field 2 is "flower" in Order but "name" in Item.
        #expect(throws: MetaDataProtoError.self) {
            try KeyExpressionProto.encodeForHeader(.field(number: 2, fanType: nil), recordDescriptors: [order, item])
        }
    }
}
#endif
