/*
 * JavaParityExtrasTests.swift
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
import Testing

@testable import FDBRecordLayer
import FoundationDB

/// Record counts, replaced-by indexes, store-state caching, multi-type indexes and synthetic
/// (joined / unnested) record types.
@Suite("Java parity extras (integration)", .serialized)
struct JavaParityExtrasTests {
    private func database() async throws -> FDBDatabase {
        try await FDBBootstrap.shared.ensureInitialized()
        return try FDBClient.openDatabase()
    }

    private func run<T: Sendable>(_ db: FDBDatabase, _ subspace: Subspace, _ meta: RecordMetaData,
                                  cache: RecordStoreStateCache? = nil,
                                  _ body: (FDBRecordStore) async throws -> T) async throws -> T {
        try await db.withRecordContext { context in
            let store = try await FDBRecordStore.open(context: context, subspace: subspace, metaData: meta, stateCache: cache)
            return try await body(store)
        }
    }

    private func entries(_ db: FDBDatabase, _ subspace: Subspace, index: String) async throws -> [[any TupleElement]] {
        try await db.withTransaction { tx in
            let space = subspace.child(Int64(2), index)
            let (b, e) = space.range
            return try await tx.getRangeNative(beginKey: b, endKey: e, limit: 0, snapshot: false).records.map {
                try space.unpack($0.0)
            }
        }
    }

    private func cleanup(_ db: FDBDatabase, _ subspace: Subspace) async throws {
        try await db.withRecordContext { FDBRecordStore.deleteStore(context: $0, subspace: subspace) }
    }

    private func fresh() -> Subspace { Subspace(Tuple("fdbrl-extras", UUID().uuidString)) }

    @Test("record count key counts inserts and deletes per key")
    func recordCounts() async throws {
        let db = try await database()
        let subspace = fresh()
        let meta = RecordMetaData(recordCountKey: .field(number: 4, fanType: nil)) {
            RecordType(Fdb_Test_Item.self, primaryKey: \.sku)
        }
        try await run(db, subspace, meta) { store in
            for (sku, category) in [("a", "x"), ("b", "x"), ("c", "y")] {
                _ = try await store.save(Fdb_Test_Item.sample(sku: sku, category: category))
            }
            _ = try await store.save(Fdb_Test_Item.sample(sku: "a", category: "x")) // update: not recounted
        }
        try await run(db, subspace, meta) { _ = try await $0.delete(Fdb_Test_Item.self, primaryKey: Tuple("c")) }
        let (all, x, y) = try await run(db, subspace, meta) { store in
            (try await store.snapshotRecordCount(),
             try await store.snapshotRecordCount(key: Tuple("x")),
             try await store.snapshotRecordCount(key: Tuple("y")))
        }
        #expect(all == 2)
        #expect(x == 2)
        #expect(y == 0)
        try await cleanup(db, subspace)
    }

    @Test("an index replaced by readable indexes is disabled")
    func replacedByIndex() async throws {
        let db = try await database()
        let subspace = fresh()
        let v1 = RecordMetaData {
            RecordType(Fdb_Test_Item.self, primaryKey: \.sku).index("old", on: \.category)
        }
        let v2 = RecordMetaData(version: 2) {
            RecordType(Fdb_Test_Item.self, primaryKey: \.sku)
                .index("old", on: .field(\.category), options: ["replacedBy1": "new"])
                .index("new", on: .concat(.field(\.category), .field(\.name)), addedVersion: 2)
        }
        try await run(db, subspace, v1) { _ = try await $0.save(Fdb_Test_Item.sample(sku: "a")) }
        #expect(try await run(db, subspace, v2) { $0.indexState(named: "old") } == .readable)
        try await db.buildIndex(subspace: subspace, metaData: v2, indexName: "new")
        let states = try await run(db, subspace, v2) { ($0.indexState(named: "old"), $0.indexState(named: "new")) }
        #expect(states.0 == .disabled)
        #expect(states.1 == .readable)
        try await cleanup(db, subspace)
    }

    @Test("cacheable stores reuse cached state until another client changes it")
    func storeStateCache() async throws {
        let db = try await database()
        let subspace = fresh()
        let meta = RecordMetaData {
            RecordType(Fdb_Test_Item.self, primaryKey: \.sku).index("cat", on: \.category)
        }
        let cache = RecordStoreStateCache()
        try await run(db, subspace, meta) { try await $0.setStateCacheability(true) }
        try await run(db, subspace, meta, cache: cache) { _ = try await $0.save(Fdb_Test_Item.sample(sku: "a")) }
        #expect(cache.entry(for: subspace) != nil)
        // A state change made elsewhere bumps the meta-data version stamp, so the cache misses.
        try await run(db, subspace, meta) { _ = try await $0.markIndexWriteOnly("cat") }
        let state = try await run(db, subspace, meta, cache: cache) { $0.indexState(named: "cat") }
        #expect(state == .writeOnly)
        try await cleanup(db, subspace)
    }

    @Test("multi-type indexes cover several record types with one expression")
    func multiTypeIndex() async throws {
        let db = try await database()
        let subspace = fresh()
        // Field 2 is Order.flower and Item.name: both strings.
        let meta = RecordMetaData(multiTypeIndexes: [
            MultiTypeIndex("byField2", on: .field(number: 2, fanType: nil),
                           recordTypes: [Fdb_Test_Order.self, Fdb_Test_Item.self])
        ]) {
            RecordType(Fdb_Test_Order.self, primaryKey: .concat(.recordType(), .field(\.orderID)))
            RecordType(Fdb_Test_Item.self, primaryKey: .concat(.recordType(), .field(\.sku)))
        }
        try await run(db, subspace, meta) { store in
            _ = try await store.save(Fdb_Test_Order.sample(id: 1, flower: "rose"))
            _ = try await store.save(Fdb_Test_Item.sample(sku: "a", name: "rose"))
            _ = try await store.save(Fdb_Test_Item.sample(sku: "b", name: "tulip"))
        }
        let keys = try await entries(db, subspace, index: "byField2")
        #expect(keys.count == 3)
        #expect(keys.filter { ($0.first as? String) == "rose" }.count == 2)
        try await cleanup(db, subspace)
    }

    @Test("joined record type indexes follow changes to either constituent")
    func joinedRecordType() async throws {
        let db = try await database()
        let subspace = fresh()
        // order.flower (field 2) == item.category (field 4); index (order.price, item.sku).
        let joined = JoinedRecordType(
            "OrderItem",
            constituents: [.init("order", Fdb_Test_Order.self), .init("item", Fdb_Test_Item.self)],
            joins: [.init("order", .field(number: 2, fanType: nil), "item", .field(number: 4, fanType: nil))],
            indexes: [SyntheticIndex("orderItem.priceSku", on: .then([
                .nest(number: 1, fanType: nil, child: .field(number: 3, fanType: nil)),
                .nest(number: 2, fanType: nil, child: .field(number: 1, fanType: nil)),
            ]))])
        let meta = RecordMetaData(joinedRecordTypes: [joined]) {
            RecordType(Fdb_Test_Order.self, primaryKey: \.orderID)
            RecordType(Fdb_Test_Item.self, primaryKey: \.sku).index("item.category", on: \.category)
        }
        try await run(db, subspace, meta) { store in
            _ = try await store.save(Fdb_Test_Item.sample(sku: "a", category: "rose"))
            _ = try await store.save(Fdb_Test_Item.sample(sku: "b", category: "tulip"))
            _ = try await store.save(Fdb_Test_Order.sample(id: 1, flower: "rose", price: 10))
        }
        var keys = try await entries(db, subspace, index: "orderItem.priceSku")
        #expect(keys.count == 1)
        #expect((keys.first?[0] as? Int64) == 10 && (keys.first?[1] as? String) == "a")
        #expect((keys.first?[2] as? Int64) == -1) // synthetic type key

        // Changing the item breaks the join; a new order joins both tulip items.
        try await run(db, subspace, meta) { store in
            _ = try await store.save(Fdb_Test_Item.sample(sku: "a", category: "tulip"))
            _ = try await store.save(Fdb_Test_Order.sample(id: 2, flower: "tulip", price: 20))
        }
        keys = try await entries(db, subspace, index: "orderItem.priceSku")
        #expect(keys.map { "\($0[0] as! Int64)/\($0[1] as! String)" }.sorted() == ["20/a", "20/b"])

        try await run(db, subspace, meta) { _ = try await $0.delete(Fdb_Test_Order.self, primaryKey: Tuple(Int64(2))) }
        #expect(try await entries(db, subspace, index: "orderItem.priceSku").isEmpty)
        try await cleanup(db, subspace)
    }

    @Test("a synthetic index added to a populated store is built online without duplicates")
    func syntheticIndexBuild() async throws {
        let db = try await database()
        let subspace = fresh()
        let base = RecordMetaData {
            RecordType(Fdb_Test_Order.self, primaryKey: \.orderID)
            RecordType(Fdb_Test_Item.self, primaryKey: \.sku)
        }
        let joined = JoinedRecordType(
            "OrderItem",
            constituents: [.init("order", Fdb_Test_Order.self), .init("item", Fdb_Test_Item.self)],
            joins: [.init("order", .field(number: 2, fanType: nil), "item", .field(number: 4, fanType: nil))],
            indexes: [SyntheticIndex("orderItem.sku", on: .nest(number: 2, fanType: nil, child: .field(number: 1, fanType: nil)),
                                     addedVersion: 2)])
        let withIndex = RecordMetaData(version: 2, joinedRecordTypes: [joined]) {
            RecordType(Fdb_Test_Order.self, primaryKey: \.orderID)
            RecordType(Fdb_Test_Item.self, primaryKey: \.sku)
        }
        try await run(db, subspace, base) { store in
            for sku in ["a", "b", "c"] { _ = try await store.save(Fdb_Test_Item.sample(sku: sku, category: "rose")) }
            for id in Int64(1)...2 { _ = try await store.save(Fdb_Test_Order.sample(id: id, flower: "rose")) }
        }
        #expect(try await run(db, subspace, withIndex) { $0.indexState(named: "orderItem.sku") } == .disabled)
        var config = OnlineIndexer.Config()
        config.maxLimit = 2
        try await db.buildIndex(subspace: subspace, metaData: withIndex, indexName: "orderItem.sku", config: config)
        let keys = try await entries(db, subspace, index: "orderItem.sku")
        #expect(keys.count == 6) // 2 orders x 3 items
        try await cleanup(db, subspace)
    }

    @Test("unnested record type indexes nested messages")
    func unnestedRecordType() async throws {
        let db = try await database()
        let subspace = fresh()
        let unnested = UnnestedRecordType(
            "OrderCustomer", parentName: "order", parentType: Fdb_Test_Order.self,
            nested: [.init("customer", parent: "order", typeName: "fdb.test.Customer",
                           nestingExpression: .field(number: 4, fanType: nil))],
            indexes: [SyntheticIndex("orderCustomer.name", on: .nest(number: 2, fanType: nil, child: .field(number: 2, fanType: nil)))])
        let meta = RecordMetaData(unnestedRecordTypes: [unnested]) {
            RecordType(Fdb_Test_Order.self, primaryKey: \.orderID)
        }
        try await run(db, subspace, meta) { _ = try await $0.save(Fdb_Test_Order.sample(id: 7, customer: "zoe")) }
        let keys = try await entries(db, subspace, index: "orderCustomer.name")
        #expect(keys.count == 1)
        #expect((keys.first?[0] as? String) == "zoe")
        // Primary key: (type key, (parent pk), (position)).
        #expect((keys.first?[2] as? Tuple) == Tuple(Int64(7)))
        #expect((keys.first?[3] as? Tuple) == Tuple(Int64(0)))
        try await cleanup(db, subspace)
    }
}
#endif
