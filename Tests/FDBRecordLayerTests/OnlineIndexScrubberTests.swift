/*
 * OnlineIndexScrubberTests.swift
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

/// The index scrubber (Java's `OnlineIndexScrubber`): indexes are corrupted with raw writes, then
/// scrubbed for dangling and missing entries, with and without repair, in small resumable batches.
@Suite("Online index scrubber (integration)", .serialized)
struct OnlineIndexScrubberTests {
    private func database() async throws -> FDBDatabase {
        try await FDBBootstrap.shared.ensureInitialized()
        return try FDBClient.openDatabase()
    }

    private func freshSubspace() -> Subspace { Subspace(Tuple("fdbrl-scrub", UUID().uuidString)) }

    private func valueMeta() -> RecordMetaData {
        RecordMetaData { RecordType(Fdb_Test_Order.self, primaryKey: \.orderID).index("price", on: \.price) }
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

    /// Saves orders 1...n with price `10 * id`.
    private func populate(_ db: FDBDatabase, _ subspace: Subspace, _ meta: RecordMetaData, count: Int64) async throws {
        try await run(db, subspace, meta) { store in
            for id in Int64(1)...count { _ = try await store.save(Fdb_Test_Order.sample(id: id, price: id * 10)) }
        }
    }

    /// `S / 2 / "price" / price / id`.
    private func entryKey(_ subspace: Subspace, price: Int64, id: Int64) -> FDB.Bytes {
        subspace.pack(Tuple(Int64(2), "price", price, id))
    }

    private func rawKeys(_ db: FDBDatabase, _ space: Subspace) async throws -> [FDB.Bytes] {
        try await db.withTransaction { tx in
            let (b, e) = space.range
            return try await tx.getRangeNative(beginKey: b, endKey: e, limit: 0, snapshot: false).records.map(\.0)
        }
    }

    private func rawPairs(_ db: FDBDatabase, _ space: Subspace) async throws -> [(FDB.Bytes, FDB.Bytes)] {
        try await db.withTransaction { tx in
            let (b, e) = space.range
            return try await tx.getRangeNative(beginKey: b, endKey: e, limit: 0, snapshot: false).records.map { ($0.0, $0.1) }
        }
    }

    private func scrubber(_ db: FDBDatabase, _ subspace: Subspace, _ meta: RecordMetaData, index: String = "price",
                          _ configure: (inout OnlineIndexScrubber.Config) -> Void = { _ in }) -> OnlineIndexScrubber {
        var config = OnlineIndexScrubber.Config()
        config.recordsPerSecond = nil
        // These tests also cover the stricter stale-entry check (off by default, as in Java);
        // the "Java check" case turns it back off.
        config.detectStaleEntries = true
        configure(&config)
        return db.indexScrubber(subspace: subspace, metaData: meta, indexName: index, config: config)
    }

    // MARK: - Missing entries

    @Test("missing entries are counted, left alone without repair, and re-added with repair")
    func missingEntries() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let meta = valueMeta()
        try await populate(db, subspace, meta, count: 20)
        let indexSpace = subspace.child(Int64(2), "price")
        let healthy = try await rawKeys(db, indexSpace)
        #expect(healthy.count == 20)

        try await db.withTransaction { tx in
            for id: Int64 in [2, 7, 8, 15, 20] { tx.clear(key: entryKey(subspace, price: id * 10, id: id)) }
        }

        let noRepair = scrubber(db, subspace, meta) { $0.allowRepair = false; $0.maxLimit = 4 }
        #expect(try await noRepair.scrubMissingIndexEntries() == 5)
        #expect(try await noRepair.scrubMissingIndexEntries() == 5) // still there; a finished walk restarts
        #expect(try await noRepair.scrubDanglingIndexEntries() == 0)
        #expect(try await rawKeys(db, indexSpace).count == 15)

        let repair = scrubber(db, subspace, meta) { $0.maxLimit = 4 }
        #expect(try await repair.scrubMissingIndexEntries() == 5)
        #expect(try await rawKeys(db, indexSpace) == healthy)
        #expect(try await repair.scrubMissingIndexEntries() == 0)

        // The repaired index answers queries again.
        let ids = try await run(db, subspace, meta) { store in
            try await store.executeCoveringQuery(
                RecordQuery(Fdb_Test_Order.self).where(Query.field(\.price).equals(70)), using: "price").map(\.primaryKey)
        }
        #expect(ids == [Tuple(Int64(7))])
        try await cleanup(db, subspace)
    }

    // MARK: - Dangling entries

    @Test("dangling entries (record gone, or record no longer produces them) are counted and deleted")
    func danglingEntries() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let meta = valueMeta()
        try await populate(db, subspace, meta, count: 10)
        let indexSpace = subspace.child(Int64(2), "price")
        let healthy = try await rawKeys(db, indexSpace)

        try await db.withTransaction { tx in
            // No such records.
            tx.setValue([], for: entryKey(subspace, price: 5, id: 100))
            tx.setValue([], for: entryKey(subspace, price: 55, id: 101))
            tx.setValue([], for: entryKey(subspace, price: 999, id: 102))
            // Records 3 and 4 exist but have other prices.
            tx.setValue([], for: entryKey(subspace, price: 31, id: 3))
            tx.setValue([], for: entryKey(subspace, price: 1, id: 4))
        }

        // Java's check (record existence only) sees the three orphans.
        let javaCheck = scrubber(db, subspace, meta) { $0.allowRepair = false; $0.detectStaleEntries = false; $0.maxLimit = 3 }
        #expect(try await javaCheck.scrubDanglingIndexEntries() == 3)

        let noRepair = scrubber(db, subspace, meta) { $0.allowRepair = false; $0.maxLimit = 3 }
        #expect(try await noRepair.scrubDanglingIndexEntries() == 5)
        #expect(try await noRepair.scrubMissingIndexEntries() == 0)
        #expect(try await rawKeys(db, indexSpace).count == 15)

        let repair = scrubber(db, subspace, meta) { $0.maxLimit = 3 }
        #expect(try await repair.scrubDanglingIndexEntries() == 5)
        #expect(try await rawKeys(db, indexSpace) == healthy)
        #expect(try await repair.scrubDanglingIndexEntries() == 0)
        try await cleanup(db, subspace)
    }

    // MARK: - Resumption and on-disk progress

    @Test("missing-entries progress is a Java RangeSet at S/9/<index>/4, resumed by the next call")
    func missingResumesFromRecordRanges() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let meta = valueMeta()
        try await populate(db, subspace, meta, count: 12)
        try await db.withTransaction { tx in
            tx.clear(key: entryKey(subspace, price: 20, id: 2))
            tx.clear(key: entryKey(subspace, price: 100, id: 10))
        }

        // Batches of 3, stopping once 4 records were scanned: two batches, records 1–6.
        let partial = scrubber(db, subspace, meta) { $0.allowRepair = false; $0.maxLimit = 3; $0.entriesScanLimit = 4 }
        #expect(try await partial.scrubMissingIndexEntries() == 1) // record 2

        // The two inserted ranges [∅, (4)) and [(4), (7)) are consolidated (requireEmpty) into one
        // entry: key = pack(bytes \x00) → value = Tuple(7).
        let recordRanges = subspace.child(Int64(9), "price", Int64(4))
        let pairs = try await rawPairs(db, recordRanges)
        #expect(pairs.count == 1)
        #expect(pairs.first?.0 == recordRanges.prefix + [0x01, 0x00, 0xFF, 0x00])
        #expect(pairs.first?.1 == [0x15, 0x07])
        #expect(pairs.first?.1 == Tuple(Int64(7)).encode())
        #expect(try await rawKeys(db, subspace.child(Int64(9), "price", Int64(3))).isEmpty) // dangling walk untouched

        // The next call picks up at record 7, finds record 10 and finishes (clearing progress).
        let rest = scrubber(db, subspace, meta) { $0.allowRepair = false; $0.maxLimit = 3 }
        #expect(try await rest.scrubMissingIndexEntries() == 1)
        #expect(try await rawKeys(db, recordRanges).isEmpty)

        // A finished walk starts over: both again.
        #expect(try await rest.scrubMissingIndexEntries() == 2)
        try await cleanup(db, subspace)
    }

    @Test("dangling-entries progress is a Java RangeSet at S/9/<index>/3 keyed by index keys")
    func danglingResumesFromIndexRanges() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let meta = valueMeta()
        try await populate(db, subspace, meta, count: 9)
        try await db.withTransaction { tx in
            tx.setValue([], for: entryKey(subspace, price: 15, id: 50))  // sorts among the first entries
            tx.setValue([], for: entryKey(subspace, price: 85, id: 51))  // sorts near the end
        }

        let partial = scrubber(db, subspace, meta) { $0.maxLimit = 3; $0.entriesScanLimit = 3 }
        // One batch: entries (10,1), (15,50), (20,2); the scan stops before (30,3).
        #expect(try await partial.scrubDanglingIndexEntries() == 1)
        let indexRanges = subspace.child(Int64(9), "price", Int64(3))
        let pairs = try await rawPairs(db, indexRanges)
        #expect(pairs.count == 1)
        #expect(pairs.first?.0 == indexRanges.prefix + [0x01, 0x00, 0xFF, 0x00])
        #expect(pairs.first?.1 == Tuple(Int64(30), Int64(3)).encode())
        #expect(pairs.first?.1 == [0x15, 0x1E, 0x15, 0x03])

        // The repaired orphan is gone, the later one still there.
        let indexSpace = subspace.child(Int64(2), "price")
        let keys = try await rawKeys(db, indexSpace)
        #expect(!keys.contains(entryKey(subspace, price: 15, id: 50)))
        #expect(keys.contains(entryKey(subspace, price: 85, id: 51)))

        // Resetting the ranges restarts from the beginning (and, everything being repairable,
        // finds only the remaining orphan).
        let reset = scrubber(db, subspace, meta) { $0.maxLimit = 3; $0.rangeReset = true }
        #expect(try await reset.scrubDanglingIndexEntries() == 1)
        #expect(try await rawKeys(db, indexRanges).isEmpty)
        #expect(try await rawKeys(db, indexSpace).count == 9)
        try await cleanup(db, subspace)
    }

    @Test("non-zero range ids keep progress at S/9/<index>/6/<id> and S/9/<index>/5/<id>")
    func rangeIdSubspaces() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let meta = valueMeta()
        try await populate(db, subspace, meta, count: 8)
        let build = subspace.child(Int64(9), "price")

        let partial = scrubber(db, subspace, meta) { $0.maxLimit = 2; $0.entriesScanLimit = 2; $0.rangeId = 7 }
        #expect(try await partial.scrubDanglingIndexEntries() == 0)
        #expect(try await partial.scrubMissingIndexEntries() == 0)

        let danglingPairs = try await rawPairs(db, build.child(Int64(6), Int64(7)))
        #expect(danglingPairs.map(\.0) == [build.child(Int64(6), Int64(7)).prefix + [0x01, 0x00, 0xFF, 0x00]])
        #expect(danglingPairs.map(\.1) == [Tuple(Int64(30), Int64(3)).encode()])
        let missingPairs = try await rawPairs(db, build.child(Int64(5), Int64(7)))
        #expect(missingPairs.map(\.1) == [Tuple(Int64(3)).encode()])
        // Range id 0's locations are untouched.
        #expect(try await rawKeys(db, build.child(Int64(3))).isEmpty)
        #expect(try await rawKeys(db, build.child(Int64(4))).isEmpty)

        // Another range id has its own progress; erasing forgets every session's.
        let other = scrubber(db, subspace, meta) { $0.maxLimit = 2; $0.entriesScanLimit = 2; $0.rangeId = 8 }
        #expect(try await other.scrubMissingIndexEntries() == 0)
        #expect(try await rawKeys(db, build.child(Int64(5), Int64(8))).count == 1)
        try await run(db, subspace, meta) { try partial.eraseAllIndexingScrubbingData($0) }
        #expect(try await rawKeys(db, build).isEmpty)
        try await cleanup(db, subspace)
    }

    @Test("a complete scrub clears both range-set subspaces", arguments: [0, 1, 10_000])
    func completeScrubClearsRanges(rangeId: Int) async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let meta = valueMeta()
        try await populate(db, subspace, meta, count: 11)
        let s = scrubber(db, subspace, meta) { $0.maxLimit = 3; $0.rangeId = rangeId }
        #expect(try await s.scrubMissingIndexEntries() == 0)
        #expect(try await s.scrubDanglingIndexEntries() == 0)
        #expect(try await rawKeys(db, subspace.child(Int64(9), "price")).isEmpty)
        try await cleanup(db, subspace)
    }

    // MARK: - Index types and states

    @Test("version index entries are scrubbed and repaired byte-for-byte")
    func versionIndex() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let meta = RecordMetaData {
            RecordType(Fdb_Test_Order.self, primaryKey: \.orderID).index("order.version", on: .version(), type: .version)
        }
        try await run(db, subspace, meta) { store in
            for id in Int64(1)...6 { _ = try await store.save(Fdb_Test_Order.sample(id: id)) }
        }
        let space = subspace.child(Int64(2), "order.version")
        let healthy = try await rawKeys(db, space)
        #expect(healthy.count == 6)

        let s = scrubber(db, subspace, meta, index: "order.version") { $0.maxLimit = 2 }
        #expect(try await s.scrubDanglingIndexEntries() == 0)
        #expect(try await s.scrubMissingIndexEntries() == 0)

        try await db.withTransaction { tx in tx.clear(key: healthy[3]) }
        #expect(try await s.scrubMissingIndexEntries() == 1)
        #expect(try await rawKeys(db, space) == healthy)

        // An entry with another version for an existing record is stale.
        let bogus = space.pack(Tuple(Versionstamp(transactionVersion: [UInt8](repeating: 1, count: 10), userVersion: 0), Int64(2)))
        try await db.withTransaction { tx in tx.setValue([], for: bogus) }
        #expect(try await s.scrubDanglingIndexEntries() == 1)
        #expect(try await rawKeys(db, space) == healthy)
        try await cleanup(db, subspace)
    }

    @Test("only readable value/version indexes can be scrubbed")
    func refusesUnsupported() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let meta = RecordMetaData {
            RecordType(Fdb_Test_Order.self, primaryKey: \.orderID)
                .index("price", on: \.price)
                .index("priceRank", on: \.price, type: .rank)
            RecordType(Fdb_Test_Item.self, primaryKey: \.sku)
                .index("countByCategory", on: .field(\.category), type: .count)
        }
        try await populate(db, subspace, meta, count: 3)

        for name in ["priceRank", "countByCategory"] {
            for type in [OnlineIndexScrubber.ScrubbingType.dangling, .missing] {
                do {
                    let s = scrubber(db, subspace, meta, index: name)
                    _ = type == .dangling ? try await s.scrubDanglingIndexEntries() : try await s.scrubMissingIndexEntries()
                    Issue.record("scrubbing \(name) should fail")
                } catch RecordStoreError.unsupportedIndexType {
                }
            }
        }

        try await run(db, subspace, meta) { _ = try await $0.markIndexWriteOnly("price") }
        for type in [OnlineIndexScrubber.ScrubbingType.dangling, .missing] {
            do {
                let s = scrubber(db, subspace, meta)
                _ = type == .dangling ? try await s.scrubDanglingIndexEntries() : try await s.scrubMissingIndexEntries()
                Issue.record("scrubbing a write-only index should fail")
            } catch RecordStoreError.indexNotBuilt(let name) {
                #expect(name == "price")
            }
        }
        // Nothing was recorded for the refused scrubs.
        #expect(try await rawKeys(db, subspace.child(Int64(9), "price", Int64(3))).isEmpty)
        try await cleanup(db, subspace)
    }
}
#endif
