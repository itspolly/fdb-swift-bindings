/*
 * JavaParityTests.swift
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

/// Behaviors that must match the Java Record Layer: on-disk layout, store-open checks, index
/// maintenance while an index is being built, version handling, and limits.
@Suite("Java parity (integration)", .serialized)
struct JavaParityTests {
    private func database() async throws -> FDBDatabase {
        try await FDBBootstrap.shared.ensureInitialized()
        return try FDBClient.openDatabase()
    }

    private func freshSubspace() -> Subspace { Subspace(Tuple("fdbrl-parity", UUID().uuidString)) }

    private func open(_ db: FDBDatabase, _ subspace: Subspace, _ meta: RecordMetaData,
                      bypass: String? = nil) async throws -> (FDBRecordContext, FDBRecordStore) {
        let context = FDBRecordContext(transaction: try db.createTransaction())
        let store = try await FDBRecordStore.open(
            context: context, subspace: subspace, metaData: meta, bypassFullStoreLockReason: bypass)
        return (context, store)
    }

    private func run<T: Sendable>(_ db: FDBDatabase, _ subspace: Subspace, _ meta: RecordMetaData,
                                  _ body: (FDBRecordStore) async throws -> T) async throws -> T {
        try await db.withRecordContext { context in
            let store = try await FDBRecordStore.open(context: context, subspace: subspace, metaData: meta)
            return try await body(store)
        }
    }

    private func cleanup(_ db: FDBDatabase, _ subspace: Subspace) async throws {
        try await db.withRecordContext { FDBRecordStore.deleteStore(context: $0, subspace: subspace) }
    }

    // MARK: - On-disk layout

    @Test("header, records, index entries and index state use Java's keys and encodings")
    func onDiskLayout() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let meta = RecordMetaData {
            RecordType(Fdb_Test_Order.self, primaryKey: \.orderID).index("order.price", on: \.price)
        }
        try await run(db, subspace, meta) { _ = try await $0.save(Fdb_Test_Order.sample(id: 7, price: 42)) }

        try await db.withTransaction { tx in
            // S/(0) holds a DataStoreInfo at the current format and metadata version.
            let headerBytes = try #require(try await tx.getValue(for: subspace.pack(Tuple(Int64(0)))))
            let header = try DataStoreInfo(decoding: headerBytes)
            #expect(header.formatVersion == FormatVersion.current.rawValue)
            #expect(header.metaDataVersion == 1)

            // S/1/(7, 0) holds the record wrapped in union field 1 (tag 0x0A).
            let recordKey = subspace.pack(Tuple(Int64(1), Int64(7), Int64(0)))
            let value = try #require(try await tx.getValue(for: recordKey))
            #expect(value.first == 0x0A)
            let (field, payload) = try RecordUnion.unwrap(value)
            #expect(field == 1)
            #expect(try Fdb_Test_Order(serializedBytes: payload).price == 42)

            // S/2/("order.price", 42, 7) is the value index entry (subspace key = index name).
            let entry = subspace.pack(Tuple(Int64(2), "order.price", Int64(42), Int64(7)))
            #expect(try await tx.getValue(for: entry) == [])

            // A readable index has no state key.
            let (b, e) = subspace.child(Int64(5)).range
            #expect(try await tx.getRangeNative(beginKey: b, endKey: e, limit: 0, snapshot: false).records.isEmpty)
        }
        try await cleanup(db, subspace)
    }

    // MARK: - Opening

    @Test("a client with older metadata is refused (stale metadata)")
    func staleMetaDataRefused() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let v1 = RecordMetaData { RecordType(Fdb_Test_Item.self, primaryKey: \.sku) }
        let v2 = RecordMetaData(version: 2) {
            RecordType(Fdb_Test_Item.self, primaryKey: \.sku).index("cat", on: \.category, addedVersion: 2)
        }
        try await run(db, subspace, v2) { _ in }
        await #expect {
            try await run(db, subspace, v1) { try await $0.save(Fdb_Test_Item.sample(sku: "x")) }
        } throws: { error in
            if case RecordStoreError.staleMetaData(stored: 2, local: 1) = error { return true }
            return false
        }
        try await cleanup(db, subspace)
    }

    @Test("store locks: forbid-record-update blocks writes; full-store blocks opens without the reason")
    func storeLocks() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let meta = RecordMetaData { RecordType(Fdb_Test_Item.self, primaryKey: \.sku) }
        try await run(db, subspace, meta) { try await $0.setStoreLockState(.forbidRecordUpdate, reason: "maint") }
        await #expect(throws: RecordStoreError.self) {
            try await run(db, subspace, meta) { try await $0.save(Fdb_Test_Item.sample(sku: "x")) }
        }
        try await run(db, subspace, meta) { try await $0.setStoreLockState(.fullStore, reason: "moving") }
        await #expect(throws: RecordStoreError.self) { try await run(db, subspace, meta) { _ in } }
        try await db.withRecordContext { context in
            let store = try await FDBRecordStore.open(
                context: context, subspace: subspace, metaData: meta, bypassFullStoreLockReason: "moving")
            try await store.clearStoreLockState()
        }
        try await run(db, subspace, meta) { try await $0.save(Fdb_Test_Item.sample(sku: "x")) }
        try await cleanup(db, subspace)
    }

    @Test("removed indexes listed as former indexes are cleared on upgrade")
    func formerIndexCleared() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let v1 = RecordMetaData {
            RecordType(Fdb_Test_Item.self, primaryKey: \.sku).index("cat", on: \.category)
        }
        let v2 = RecordMetaData(version: 2, formerIndexes: [FormerIndex(name: "cat", removedVersion: 2)]) {
            RecordType(Fdb_Test_Item.self, primaryKey: \.sku)
        }
        try await run(db, subspace, v1) { _ = try await $0.save(Fdb_Test_Item.sample(sku: "x")) }
        #expect(try await run(db, subspace, v1) { try await $0.allIndexKeys().count } == 1)
        #expect(try await run(db, subspace, v2) { try await $0.allIndexKeys().count } == 0)
        try await cleanup(db, subspace)
    }

    // MARK: - Index maintenance during a build (review bug 1)

    @Test("count index stays exact when records change while it is being built")
    func countIndexWithConcurrentWritesDuringBuild() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let base = RecordMetaData { RecordType(Fdb_Test_Item.self, primaryKey: \.sku) }
        let withIndex = RecordMetaData(version: 2) {
            RecordType(Fdb_Test_Item.self, primaryKey: \.sku)
                .index("cnt", on: .field(\.category), type: .count, addedVersion: 2)
                .index("qty", on: .concat(.field(\.category), .field(\.quantity)), type: .sum, addedVersion: 2)
        }
        try await run(db, subspace, base) { store in
            for i in 0..<6 { try await store.save(Fdb_Test_Item.sample(sku: "s\(i)", quantity: 1, category: "a")) }
        }
        #expect(try await run(db, subspace, withIndex) { $0.indexState(named: "cnt") } == .disabled)

        // Make the indexes write-only with nothing built yet, then write: move a record between
        // groups, insert, and delete. The pre-fix code counted these and then the build counted
        // the same records again.
        try await run(db, subspace, withIndex) { try await $0.clearAndMarkIndexWriteOnly("cnt") }
        try await run(db, subspace, withIndex) { try await $0.clearAndMarkIndexWriteOnly("qty") }
        try await run(db, subspace, withIndex) { store in
            try await store.save(Fdb_Test_Item.sample(sku: "s4", quantity: 1, category: "b"))
            try await store.save(Fdb_Test_Item.sample(sku: "s9", quantity: 1, category: "a"))
            _ = try await store.delete(Fdb_Test_Item.self, primaryKey: Tuple("s5"))
        }
        var config = OnlineIndexer.Config()
        config.maxLimit = 2
        try await db.buildIndex(subspace: subspace, metaData: withIndex, indexName: "cnt", config: config)
        try await db.buildIndex(subspace: subspace, metaData: withIndex, indexName: "qty", config: config)

        let (a, b, sumA) = try await run(db, subspace, withIndex) { store in
            (try await store.aggregate(Fdb_Test_Item.self, indexNamed: "cnt", group: Tuple("a")),
             try await store.aggregate(Fdb_Test_Item.self, indexNamed: "cnt", group: Tuple("b")),
             try await store.aggregate(Fdb_Test_Item.self, indexNamed: "qty", group: Tuple("a")))
        }
        // a: s0 s1 s2 s3 s9; b: s4
        #expect(a == 5)
        #expect(b == 1)
        #expect(sumA == 5)
        try await cleanup(db, subspace)
    }

    @Test("writes during a build only touch a non-idempotent index inside built ranges")
    func writeOnlyGatingByRangeSet() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let base = RecordMetaData { RecordType(Fdb_Test_Item.self, primaryKey: \.sku) }
        let withIndex = RecordMetaData(version: 2) {
            RecordType(Fdb_Test_Item.self, primaryKey: \.sku)
                .index("cnt", on: .field(\.category), type: .count, addedVersion: 2)
        }
        try await run(db, subspace, base) { try await $0.save(Fdb_Test_Item.sample(sku: "m", category: "a")) }
        try await run(db, subspace, withIndex) { store in
            try await store.clearAndMarkIndexWriteOnly("cnt")
            // Pretend the build covered ["", "m"): records before "m" are built.
            let index = try store.erasedIndexOrThrow("cnt")
            try await store.indexRangeSet(index).insertRange(store.transaction, begin: nil, end: Tuple("m").encode())
        }
        try await run(db, subspace, withIndex) { store in
            try await store.save(Fdb_Test_Item.sample(sku: "c", category: "a"))   // built range → counted
            try await store.save(Fdb_Test_Item.sample(sku: "z", category: "a"))   // unbuilt → left to the build
        }
        let raw = try await db.withTransaction { tx in
            try await tx.getValue(for: subspace.pack(Tuple(Int64(2), "cnt", "a")))
        }
        #expect(raw.map(IndexMaintainer.decodeLittleEndian) == 1)
        try await cleanup(db, subspace)
    }

    @Test("queries refuse indexes that are not built")
    func queriesRequireScannableIndexes() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let base = RecordMetaData { RecordType(Fdb_Test_Item.self, primaryKey: \.sku) }
        let withIndex = RecordMetaData(version: 2) {
            RecordType(Fdb_Test_Item.self, primaryKey: \.sku)
                .index("cnt", on: .field(\.category), type: .count, addedVersion: 2)
        }
        try await run(db, subspace, base) { try await $0.save(Fdb_Test_Item.sample(sku: "a")) }
        await #expect(throws: RecordStoreError.self) {
            try await run(db, subspace, withIndex) {
                try await $0.aggregate(Fdb_Test_Item.self, indexNamed: "cnt", group: Tuple("general"))
            }
        }
        try await cleanup(db, subspace)
    }

    @Test("clearIndex disables the index instead of leaving it looking readable")
    func clearIndexDisables() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let meta = RecordMetaData {
            RecordType(Fdb_Test_Item.self, primaryKey: \.sku).index("cnt", on: .field(\.category), type: .count)
        }
        try await run(db, subspace, meta) { store in
            try await store.save(Fdb_Test_Item.sample(sku: "a"))
            try await store.clearIndex(named: "cnt")
            #expect(store.indexState(named: "cnt") == .disabled)
            await #expect(throws: RecordStoreError.self) {
                _ = try await store.aggregate(Fdb_Test_Item.self, indexNamed: "cnt", group: Tuple("general"))
            }
        }
        try await cleanup(db, subspace)
    }

    // MARK: - Unique indexes during a build

    @Test("a unique index built over duplicates records violations and can become readable-unique-pending")
    func uniqueViolationsDuringBuild() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let base = RecordMetaData { RecordType(Fdb_Test_Item.self, primaryKey: \.sku) }
        let withIndex = RecordMetaData(version: 2) {
            RecordType(Fdb_Test_Item.self, primaryKey: \.sku)
                .index("byName", on: \.name, unique: true, addedVersion: 2)
        }
        try await run(db, subspace, base) { store in
            try await store.save(Fdb_Test_Item.sample(sku: "a", name: "dup"))
            try await store.save(Fdb_Test_Item.sample(sku: "b", name: "dup"))
            try await store.save(Fdb_Test_Item.sample(sku: "c", name: "solo"))
        }
        await #expect {
            try await db.buildIndex(subspace: subspace, metaData: withIndex, indexName: "byName")
        } throws: { error in
            if case RecordStoreError.uniquenessViolation(index: "byName") = error { return true }
            return false
        }
        let violations = try await run(db, subspace, withIndex) {
            try await $0.scanUniquenessViolations(indexNamed: "byName")
        }
        #expect(violations.count == 2)
        try await OnlineIndexer(source: db, subspace: subspace, metaData: withIndex, indexName: "byName")
            .buildIndex(allowUniquePending: true)
        #expect(try await run(db, subspace, withIndex) { $0.indexState(named: "byName") } == .readableUniquePending)

        // Resolving the duplicate clears both violations; the index can then become readable.
        try await run(db, subspace, withIndex) { _ = try await $0.delete(Fdb_Test_Item.self, primaryKey: Tuple("b")) }
        let (violationsAfter, madeReadable) = try await run(db, subspace, withIndex) { store in
            (try await store.scanUniquenessViolations(indexNamed: "byName").count,
             try await store.markIndexReadable("byName"))
        }
        #expect(violationsAfter == 0)
        #expect(madeReadable)
        try await cleanup(db, subspace)
    }

    // MARK: - Versions (review bug 2)

    @Test("a versioned record can be saved twice and reloaded in one transaction")
    func versionedDoubleSave() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let meta = RecordLayerTestCase.advancedMetaData()
        try await run(db, subspace, meta) { _ = try await $0.save(Fdb_Test_Order.sample(id: 1, price: 10)) }
        try await run(db, subspace, meta) { store in
            _ = try await store.save(Fdb_Test_Order.sample(id: 1, price: 20))
            _ = try await store.save(Fdb_Test_Order.sample(id: 1, price: 30))
            let loaded = try #require(try await store.load(Fdb_Test_Order.self, 1))
            #expect(loaded.record.price == 30)
            #expect(loaded.version?.isComplete == false)
        }
        let (ids, version) = try await run(db, subspace, meta) { store in
            var ids: [Int64] = []
            for try await r in try store.scanByVersion(Fdb_Test_Order.self, indexNamed: "order.version") {
                ids.append(r.record.orderID)
            }
            return (ids, try await store.load(Fdb_Test_Order.self, 1)?.version)
        }
        #expect(ids == [1])
        #expect(version?.isComplete == true)
        try await cleanup(db, subspace)
    }

    @Test("version index entries are tuple versionstamps, as in Java")
    func versionIndexEntryFormat() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let meta = RecordLayerTestCase.advancedMetaData()
        try await run(db, subspace, meta) { _ = try await $0.save(Fdb_Test_Order.sample(id: 9)) }
        let entries = try await db.withTransaction { tx in
            let space = subspace.child(Int64(2), "order.version")
            let (b, e) = space.range
            return try await tx.getRangeNative(beginKey: b, endKey: e, limit: 0, snapshot: false).records.map { try space.unpack($0.0) }
        }
        #expect(entries.count == 1)
        #expect(entries.first?.first is Versionstamp)
        #expect((entries.first?.last as? Int64) == 9)
        try await cleanup(db, subspace)
    }

    // MARK: - Sums (review bug 5) and limits

    @Test("sum index handles Int64.min without trapping")
    func sumHandlesInt64Min() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let meta = RecordLayerTestCase.advancedMetaData()
        try await run(db, subspace, meta) { store in
            try await store.save(Fdb_Test_Item.sample(sku: "a", quantity: .min, category: "x"))
            try await store.save(Fdb_Test_Item.sample(sku: "b", quantity: 5, category: "x"))
        }
        try await run(db, subspace, meta) { _ = try await $0.delete(Fdb_Test_Item.self, primaryKey: Tuple("a")) }
        let sum = try await run(db, subspace, meta) {
            try await $0.aggregate(Fdb_Test_Item.self, indexNamed: "item.sumQtyByCategory", group: Tuple("x"))
        }
        #expect(sum == 5)
        try await cleanup(db, subspace)
    }

    @Test("records over 100KB are split and reassembled")
    func largeRecords() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let meta = RecordMetaData { RecordType(Fdb_Test_Item.self, primaryKey: \.sku) }
        let big = String(repeating: "x", count: 250_000)
        try await run(db, subspace, meta) { _ = try await $0.save(Fdb_Test_Item.sample(sku: "big", name: big)) }
        let loaded: String? = try await run(db, subspace, meta) { store in
            try await store.load(Fdb_Test_Item.self, "big")?.record.name
        }
        #expect(loaded == big)
        try await run(db, subspace, meta) { _ = try await $0.save(Fdb_Test_Item.sample(sku: "big", name: "small")) }
        let keys = try await db.withTransaction { tx in
            let (b, e) = subspace.child(Int64(1)).range
            return try await tx.getRangeNative(beginKey: b, endKey: e, limit: 0, snapshot: false).records.count
        }
        #expect(keys == 1) // the chunks were cleared when the record shrank
        try await cleanup(db, subspace)
    }

    @Test("oversized index keys fail with a clear error")
    func oversizedIndexKey() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let meta = RecordMetaData {
            RecordType(Fdb_Test_Item.self, primaryKey: \.sku).index("byName", on: \.name)
        }
        await #expect {
            try await run(db, subspace, meta) {
                try await $0.save(Fdb_Test_Item.sample(sku: "a", name: String(repeating: "n", count: 20_000)))
            }
        } throws: { error in
            if case RecordStoreError.keyTooLarge(index: "byName", _) = error { return true }
            return false
        }
        try await cleanup(db, subspace)
    }

    @Test("indexer limit shrinks on lessen-work errors like Java's IndexingThrottle")
    func throttleAdaptation() throws {
        var config = OnlineIndexer.Config()
        config.maxLimit = 100
        config.increaseLimitAfter = 1
        var throttle = OnlineIndexer.Throttle(config: config)
        try throttle.failed(FDBError(code: 2101))
        #expect(throttle.limit == 90)
        try throttle.failed(FDBError(code: 2101))
        #expect(throttle.limit == 72)
        throttle.succeeded(scanned: 72)
        throttle.succeeded(scanned: 72)
        #expect(throttle.limit > 72)
    }

    // MARK: - Legacy migration (review bug 3 / layout change)

    @Test("a legacy-layout store is fenced, migrated, and fully indexed")
    func legacyMigration() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let meta = RecordMetaData {
            RecordType(Fdb_Test_Order.self, primaryKey: \.orderID)
                .storingVersions()
                .index("order.price", on: \.price)
            RecordType(Fdb_Test_Item.self, primaryKey: \.sku)
                .index("item.count", on: .field(\.category), type: .count)
        }
        // Write a store exactly as the legacy Swift layer laid it out.
        let legacyVersion: FDB.Bytes = [0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 3]
        try await db.withTransaction { tx in
            let header = subspace.child(Int64(0))
            tx.setValue(Tuple(Int64(2)).encode(), for: header.pack("format_version"))
            tx.setValue(Tuple(Int64(1)).encode(), for: header.pack("metadata_version"))
            tx.setValue(Tuple(Int64(0)).encode(), for: header.pack("index_state", "order.price"))
            for id in Int64(1)...3 {
                let order = Fdb_Test_Order.sample(id: id, price: id * 10)
                tx.setValue(try order.serializedBytes(), for: subspace.pack(Tuple(Int64(1), Int64(0), id)))
                tx.setValue(Tuple().encode(), for: subspace.pack(Tuple(Int64(2), Int64(0), id * 10, id)))
            }
            tx.setValue(legacyVersion, for: subspace.pack(Tuple(Int64(3), Int64(0), Int64(2))))
            for (sku, category) in [("a", "x"), ("b", "x"), ("c", "y")] {
                let item = Fdb_Test_Item.sample(sku: sku, category: category)
                tx.setValue(try item.serializedBytes(), for: subspace.pack(Tuple(Int64(1), Int64(1), sku)))
            }
        }

        await #expect {
            try await run(db, subspace, meta) { _ in }
        } throws: { error in
            if case RecordStoreError.legacyStoreNeedsMigration(formatVersion: 2) = error { return true }
            return false
        }

        #expect(try await db.migrateLegacyRecordStore(subspace: subspace, metaData: meta))
        #expect(try await db.migrateLegacyRecordStore(subspace: subspace, metaData: meta) == false)

        // The legacy format key is kept, fenced at a value legacy clients reject.
        let fence = try await db.withTransaction { tx in
            try await tx.getValue(for: subspace.child(Int64(0)).pack("format_version"))
        }
        #expect(fence.flatMap(FDBRecordStore.decodeTupleInt) == LegacyStoreMigration.fenceValue)

        try await run(db, subspace, meta) { store in
            #expect(store.indexState(named: "order.price") == .readable)
            #expect(store.indexState(named: "item.count") == .readable)
            let order = try #require(try await store.load(Fdb_Test_Order.self, Int64(2)))
            #expect(order.record.price == 20)
            #expect(order.version?.bytes == legacyVersion)
            #expect(try await store.load(Fdb_Test_Item.self, "c")?.record.category == "y")
            #expect(try await store.aggregate(Fdb_Test_Item.self, indexNamed: "item.count", group: Tuple("x")) == 2)
            let cheap = try await store.executeQuery(
                RecordQuery(Fdb_Test_Order.self).where(Query.field(\.price).lessThan(25))).collect()
            #expect(cheap.map(\.record.orderID).sorted() == [1, 2])
        }
        // No legacy keys remain outside the fenced header key.
        let leftovers = try await db.withTransaction { tx in
            let (b, e) = subspace.child(Int64(3)).range
            return try await tx.getRangeNative(beginKey: b, endKey: e, limit: 0, snapshot: false).records.count
        }
        #expect(leftovers == 0)
        try await cleanup(db, subspace)
    }
}
#endif
