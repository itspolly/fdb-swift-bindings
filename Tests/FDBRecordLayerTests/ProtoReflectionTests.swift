/*
 * ProtoReflectionTests.swift
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

/// Descriptors reconstructed from generated Swift types must match protoc's.
@Suite("Descriptor reconstruction")
struct ProtoReflectionTests {
    /// A comparable summary of a message: each field's name, number, type, label, type name.
    private func summary(_ message: Google_Protobuf_DescriptorProto) -> [String] {
        message.field.sorted { $0.number < $1.number }.map {
            "\($0.name)=\($0.number) \($0.type) \($0.label) \($0.typeName)"
        }
    }

    private func find(_ name: String, in set: Google_Protobuf_FileDescriptorSet) -> Google_Protobuf_DescriptorProto? {
        for file in set.file {
            for message in file.messageType where (file.package.isEmpty ? "" : file.package + ".") + message.name == name {
                return message
            }
        }
        return nil
    }

    private func file(of name: String, in set: Google_Protobuf_FileDescriptorSet) -> Google_Protobuf_FileDescriptorProto? {
        set.file.first { f in f.messageType.contains { (f.package.isEmpty ? "" : f.package + ".") + $0.name == name } }
    }

    @Test("name tables are read from generated types")
    func nameTables() {
        let names = ProtoReflection.nameTable(Fdb_Test_Order.self)
        #expect(names == [1: "order_id", 2: "flower", 3: "price", 4: "customer", 5: "tags", 6: "color", 7: "fulfilled"])
        #expect(ProtoReflection.nameTable(Fdb_Test_Color.self) == [0: "COLOR_UNSPECIFIED", 1: "RED", 2: "BLUE"])
    }

    @Test("proto3 messages match the test_records.proto descriptor")
    func proto3MatchesFixture() throws {
        let reflected = try ProtoReflection.fileDescriptorSet(for: [Fdb_Test_Order.self, Fdb_Test_Item.self])
        let expected = try Google_Protobuf_FileDescriptorSet(serializedBytes: TestRecordsDescriptor.set)
        for name in ["fdb.test.Order", "fdb.test.Item", "fdb.test.Customer"] {
            let got = try #require(find(name, in: reflected), "missing \(name)")
            let want = try #require(find(name, in: expected))
            #expect(summary(got) == summary(want), "\(name)")
        }
        #expect(file(of: "fdb.test.Order", in: reflected)?.syntax == "proto3")
        let color = reflected.file.flatMap(\.enumType).first { $0.name == "Color" }
        #expect(color?.value.map(\.name) == ["COLOR_UNSPECIFIED", "RED", "BLUE"])
    }

    @Test("proto2 messages match protoc's descriptor for annotated.proto")
    func proto2MatchesProtoc() throws {
        let reflected = try ProtoReflection.fileDescriptorSet(for: [Fdb_Test_AnnotatedOrder.self])
        let protoc = try Google_Protobuf_FileDescriptorSet(serializedBytes: Data(base64Encoded: AnnotatedDescriptor.base64)!)
        for name in ["fdb.test.AnnotatedOrder", "fdb.test.AnnotatedCustomer"] {
            let got = try #require(find(name, in: reflected), "missing \(name)")
            let want = try #require(find(name, in: protoc))
            #expect(summary(got) == summary(want), "\(name)")
        }
        #expect(file(of: "fdb.test.AnnotatedOrder", in: reflected)?.syntax != "proto3")
    }

    @Test("repeated message fields and every scalar kind in use are recovered")
    func repeatedMessages() throws {
        let reflected = try ProtoReflection.fileDescriptorSet(for: [Fdb_Test_LeaderboardRecord.self])
        let record = try #require(find("fdb.test.LeaderboardRecord", in: reflected))
        #expect(summary(record) == [
            "name=1 string optional ", "game_id=2 string optional ",
            "scores=3 message repeated .fdb.test.LeaderboardEntry",
        ])
        #expect(find("fdb.test.LeaderboardEntry", in: reflected) != nil)
    }

    @Test("toProto works without a descriptor set and round-trips")
    func toProtoWithoutDescriptors() throws {
        // Field 2 is `flower` in Order and `name` in Item, so it can't be a shared count key;
        // count by record type instead.
        let meta = RecordMetaData(recordCountKey: .recordType) {
            RecordType(Fdb_Test_Order.self, primaryKey: \.orderID).index("order.price", on: \.price)
            RecordType(Fdb_Test_Item.self, primaryKey: \.sku).index("item.category", on: \.category)
        }
        #expect(meta.descriptorSet == nil)
        let reflectedProto = try meta.toProto()
        let reloaded = try RecordMetaData(metaDataProto: reflectedProto, recordTypes: [Fdb_Test_Order.self, Fdb_Test_Item.self])
        #expect(try reloaded.toProto() == reflectedProto)
        #expect(reloaded.index(named: "order.price")?.rootNode == .field(number: 3, fanType: nil))
    }

    @Test("the header's record count key is Java's encoding without a descriptor set")
    func recordCountKeyWithoutDescriptors() throws {
        let plain = RecordMetaData(recordCountKey: .field(number: 4, fanType: nil)) {
            RecordType(Fdb_Test_Item.self, primaryKey: \.sku)
        }
        let withDescriptors = plain.withDescriptorSet(TestRecordsDescriptor.set)
        let reflected = RecordCountKeyCodec.encode(.field(number: 4, fanType: nil), metaData: plain)
        let fromProtoc = RecordCountKeyCodec.encode(.field(number: 4, fanType: nil), metaData: withDescriptors)
        #expect(reflected == fromProtoc)
        #expect(!reflected.starts(with: Array("swift:".utf8)))
    }
}
#endif
