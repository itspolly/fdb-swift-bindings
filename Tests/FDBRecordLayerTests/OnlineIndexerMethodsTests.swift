/*
 * OnlineIndexerMethodsTests.swift
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

/// The Java Record Layer's other indexing methods: BY_INDEX, MULTI_TARGET_BY_RECORDS,
/// MUTUAL_BY_RECORDS, and the `IndexingPolicy` rules for previous partial builds.
@Suite("Online indexer methods (integration)", .serialized)
struct OnlineIndexerMethodsTests {
    private func database() async throws -> FDBDatabase {
        try await FDBBootstrap.shared.ensureInitialized()
        return try FDBClient.openDatabase()
    }

    private func freshSubspace() -> Subspace { Subspace(Tuple("fdbrl-indexer", UUID().uuidString)) }

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

    // MARK: Fixtures

    /// v1: items with a readable value index on quantity (the source).
    private let base = RecordMetaData {
        RecordType(Fdb_Test_Item.self, primaryKey: \.sku)
            .index("byQty", on: \.quantity)
    }

    /// v2 adds a count, a sum and a value index (to be built), plus a non-VALUE index that can't
    /// serve as a source.
    private let withIndexes = RecordMetaData(version: 2) {
        RecordType(Fdb_Test_Item.self, primaryKey: \.sku)
            .index("byQty", on: \.quantity)
            .index("cnt", on: .field(\.category), type: .count, addedVersion: 2)
            .index("qty", on: .concat(.field(\.category), .field(\.quantity)), type: .sum, addedVersion: 2)
            .index("byCat", on: \.category, addedVersion: 2)
    }

    private static func item(_ i: Int, category: String? = nil, quantity: Int64? = nil) -> Fdb_Test_Item {
        Fdb_Test_Item.sample(sku: String(format: "s%02d", i), quantity: quantity ?? Int64((i * 7) % 23),
                             category: category ?? (i % 3 == 0 ? "a" : "b"))
    }

    private func seed(_ db: FDBDatabase, _ subspace: Subspace, count: Int = 40) async throws {
        try await run(db, subspace, base) { store in
            for i in 0..<count { try await store.save(Self.item(i)) }
        }
    }

    private func config(limit: Int, stopAfter: Int? = nil) -> OnlineIndexer.Config {
        var config = OnlineIndexer.Config()
        config.maxLimit = limit
        config.recordsPerSecond = nil
        config.stopAfterBatches = stopAfter
        return config
    }

    private func indexer(_ db: FDBDatabase, _ subspace: Subspace, _ targets: [String], source: String? = nil,
                         policy: OnlineIndexer.IndexingPolicy = .init(), limit: Int = 5,
                         stopAfter: Int? = nil) -> OnlineIndexer {
        OnlineIndexer(source: db, subspace: subspace, metaData: withIndexes, targetIndexes: targets,
                      sourceIndex: source, policy: policy, config: config(limit: limit, stopAfter: stopAfter))
    }

    /// Runs an indexer that stops after `batches` batches, as if the process died.
    private func interrupted(_ indexer: OnlineIndexer) async throws {
        await #expect(throws: CancellationError.self) { try await indexer.buildIndex() }
    }

    private func stampBytes(_ db: FDBDatabase, _ subspace: Subspace, _ index: String) async throws -> [UInt8]? {
        try await run(db, subspace, withIndexes) { store in
            try await store.transaction.getValue(for: store.indexingTypeStampKey(try store.erasedIndexOrThrow(index)))
        }
    }

    private func stamp(_ db: FDBDatabase, _ subspace: Subspace, _ index: String) async throws -> IndexBuildIndexingStamp? {
        try await stampBytes(db, subspace, index).map { try IndexBuildIndexingStamp(decoding: $0) }
    }

    /// Checks every built index against the records actually stored: per-category counts and
    /// sums, and the exact set of `byCat` value entries.
    private func verifyIndexes(_ db: FDBDatabase, _ subspace: Subspace,
                               _ names: Set<String> = ["cnt", "qty", "byCat"]) async throws {
        try await run(db, subspace, withIndexes) { store in
            var records: [Fdb_Test_Item] = []
            for try await record in try store.scan(Fdb_Test_Item.self) { records.append(record.record) }
            let categories = Set(records.map(\.category)).union(["a", "b", "c"])
            for category in categories {
                let matching = records.filter { $0.category == category }
                if names.contains("cnt") {
                    #expect(store.indexState(named: "cnt") == .readable)
                    let count = try await store.aggregate(Fdb_Test_Item.self, indexNamed: "cnt", group: Tuple(category))
                    #expect(count == Int64(matching.count), "count for \(category)")
                }
                if names.contains("qty") {
                    let sum = try await store.aggregate(Fdb_Test_Item.self, indexNamed: "qty", group: Tuple(category))
                    #expect(sum == matching.map(\.quantity).reduce(0, +), "sum for \(category)")
                }
            }
            if names.contains("byCat") {
                #expect(store.indexState(named: "byCat") == .readable)
                let space = store.indexSubspace(try store.erasedIndexOrThrow("byCat"))
                let (b, e) = space.range
                var entries = Set<[UInt8]>()
                for try await (key, _) in store.transaction.getRange(beginKey: b, endKey: e) { entries.insert(key) }
                let expected = Set(records.map { space.pack(Tuple($0.category, $0.sku)) })
                #expect(entries == expected)
            }
        }
    }

    /// Concurrent writes that change categories, quantities (so source-index entries move),
    /// insert and delete records.
    private func concurrentWrites(_ db: FDBDatabase, _ subspace: Subspace, rounds: Int) async throws {
        for round in 0..<rounds {
            try await run(db, subspace, withIndexes) { store in
                let i = (round * 13) % 40
                switch round % 4 {
                case 0: try await store.save(Self.item(i, category: "c", quantity: Int64(round)))
                case 1: try await store.save(Self.item(100 + round, category: "a", quantity: 50 + Int64(round)))
                case 2: _ = try await store.delete(Fdb_Test_Item.self, primaryKey: Tuple(String(format: "s%02d", i)))
                default: try await store.save(Self.item(i, quantity: 99 - Int64(round)))
                }
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    // MARK: - BY_INDEX

    @Test("by-index build stays exact under concurrent writes")
    func byIndexWithConcurrentWrites() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        try await seed(db, subspace)
        var policy = OnlineIndexer.IndexingPolicy()
        policy.forbidRecordScan = true   // must really build by index
        for target in ["cnt", "qty", "byCat"] {
            let build = indexer(db, subspace, [target], source: "byQty", policy: policy, limit: 3)
            async let built: Void = build.buildIndex()
            try await concurrentWrites(db, subspace, rounds: 24)
            try await built
        }
        try await verifyIndexes(db, subspace)
        try await cleanup(db, subspace)
    }

    @Test("an interrupted by-index build leaves Java's stamp and source-keyed ranges, and resumes")
    func byIndexInterruptedAndResumed() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        try await seed(db, subspace)
        try await interrupted(indexer(db, subspace, ["cnt"], source: "byQty", limit: 5, stopAfter: 2))

        // BY_INDEX(2), source_index_subspace_key = Tuple("byQty").pack(), last-modified version 0.
        let expectedStamp: [UInt8] = [0x08, 0x02, 0x12, 0x07, 0x02] + Array("byQty".utf8) + [0x00, 0x18, 0x00]
        #expect(try await stampBytes(db, subspace, "cnt") == expectedStamp)

        // The range set holds source-index entry keys: [start, 11th (quantity, sku) entry).
        let (built, eleventh) = try await run(db, subspace, withIndexes) { store in
            let cnt = try store.erasedIndexOrThrow("cnt")
            let missing = try await store.indexRangeSet(cnt).missingRanges(store.transaction)
            let space = store.indexSubspace(try store.erasedIndexOrThrow("byQty"))
            let (b, e) = space.range
            var keys: [[UInt8]] = []
            for try await (key, _) in store.transaction.getRange(beginKey: b, endKey: e) {
                keys.append(Array(key.dropFirst(space.prefix.count)))
            }
            return (missing, keys[10])
        }
        #expect(built.count == 1)
        #expect(built.first?.begin == eleventh)
        #expect(built.first?.end == RangeSet.finalKey)
        #expect(try await run(db, subspace, withIndexes) { $0.indexState(named: "cnt") } == .writeOnly)

        // Writes land on both sides of the built boundary before resuming.
        try await concurrentWrites(db, subspace, rounds: 12)
        try await indexer(db, subspace, ["cnt"], source: "byQty").buildIndex()
        try await verifyIndexes(db, subspace, ["cnt"])
        try await cleanup(db, subspace)
    }

    @Test("write-only maintenance during a by-index build is gated by source entry keys")
    func byIndexWriteOnlyGating() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        // A non-empty store, so the new index starts disabled (not readable) after the upgrade.
        try await run(db, subspace, base) { try await $0.save(Self.item(90, category: "z")) }
        try await run(db, subspace, withIndexes) { store in
            try await store.clearAndMarkIndexWriteOnly("cnt")
            let cnt = try store.erasedIndexOrThrow("cnt")
            let source = try store.erasedIndexOrThrow("byQty")
            store.transaction.setValue(
                IndexBuildIndexingStamp(method: .byIndex, sourceIndexSubspaceKey: source.subspaceTupleKey.encode(),
                                        sourceIndexLastModifiedVersion: 0).encode(),
                for: store.indexingTypeStampKey(cnt))
            // Pretend the build covered source entries with quantity < 10.
            _ = try await store.indexRangeSet(cnt).insertRange(store.transaction, begin: nil, end: Tuple(Int64(10)).encode())
        }
        func count(_ category: String) async throws -> Int64 {
            try await db.withTransaction { tx in
                try await tx.getValue(for: subspace.pack(Tuple(Int64(2), "cnt", category)))
            }.map(IndexMaintainer.decodeLittleEndian) ?? 0
        }
        try await run(db, subspace, withIndexes) { store in
            try await store.save(Self.item(1, category: "a", quantity: 3))    // built → counted
            try await store.save(Self.item(2, category: "a", quantity: 30))   // unbuilt → left to the build
        }
        #expect(try await count("a") == 1)
        // Moving s01 out of the built range removes it; moving s02 in adds it.
        try await run(db, subspace, withIndexes) { store in
            try await store.save(Self.item(1, category: "a", quantity: 31))
            try await store.save(Self.item(2, category: "a", quantity: 4))
        }
        #expect(try await count("a") == 1)
        // Same source entry, category change: both sides apply.
        try await run(db, subspace, withIndexes) { store in
            try await store.save(Self.item(2, category: "b", quantity: 4))
        }
        #expect(try await count("a") == 0)
        #expect(try await count("b") == 1)
        try await cleanup(db, subspace)
    }

    @Test("an unusable source index falls back to a records scan unless forbidden")
    func unusableSourceFallsBack() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        try await seed(db, subspace)
        var forbid = OnlineIndexer.IndexingPolicy()
        forbid.forbidRecordScan = true
        // "cnt" is not a VALUE index (and not readable): not a usable source.
        await #expect {
            try await indexer(db, subspace, ["qty"], source: "cnt", policy: forbid).buildIndex()
        } throws: { error in
            if case OnlineIndexerError.unusableSourceIndex = error { return true }
            return false
        }
        try await indexer(db, subspace, ["qty"], source: "cnt").buildIndex()
        try await verifyIndexes(db, subspace, ["qty"])
        try await cleanup(db, subspace)
    }

    // MARK: - MULTI_TARGET_BY_RECORDS

    @Test("multi-target build: one scan, Java's stamp, identical range sets, all readable")
    func multiTargetBuild() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        try await seed(db, subspace)
        try await interrupted(indexer(db, subspace, ["qty", "cnt", "byCat", "cnt"], limit: 4, stopAfter: 3))

        // MULTI_TARGET_BY_RECORDS(4), targetIndex = the sorted names, in each target's stamp.
        var expected: [UInt8] = [0x08, 0x04]
        for name in ["byCat", "cnt", "qty"] { expected += [0x22, UInt8(name.utf8.count)] + Array(name.utf8) }
        for name in ["byCat", "cnt", "qty"] {
            #expect(try await stampBytes(db, subspace, name) == expected)
        }
        let rangeSets = try await run(db, subspace, withIndexes) { store in
            try await ["byCat", "cnt", "qty"].asyncMap { name in
                try await store.indexRangeSet(try store.erasedIndexOrThrow(name)).rep(store.transaction)
            }
        }
        #expect(Set(rangeSets).count == 1)
        #expect(rangeSets[0].split(separator: "\n").count == 1)   // one consolidated range, as Java writes

        async let built: Void = indexer(db, subspace, ["cnt", "qty", "byCat"], limit: 3).buildIndex()
        try await concurrentWrites(db, subspace, rounds: 24)
        try await built
        try await verifyIndexes(db, subspace)
        try await cleanup(db, subspace)
    }

    @Test("a single target keeps the BY_RECORDS stamp")
    func singleTargetLegacyStamp() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        try await seed(db, subspace)
        try await interrupted(indexer(db, subspace, ["cnt"], limit: 4, stopAfter: 1))
        #expect(try await stampBytes(db, subspace, "cnt") == [0x08, 0x01])
        try await indexer(db, subspace, ["cnt"]).buildIndex()
        try await verifyIndexes(db, subspace, ["cnt"])
        try await cleanup(db, subspace)
    }

    @Test("multi-target follower states must match the primary")
    func multiTargetStateMismatch() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        try await seed(db, subspace)
        try await indexer(db, subspace, ["cnt"]).buildIndex()   // cnt readable, qty disabled
        // The primary (cnt) is readable, so nothing is built even though qty is disabled.
        try await indexer(db, subspace, ["cnt", "qty"]).buildIndex()
        #expect(try await run(db, subspace, withIndexes) { $0.indexState(named: "qty") } == .disabled)

        // A write-only primary with a disabled follower can't be continued.
        try await interrupted(indexer(db, subspace, ["byCat"], limit: 4, stopAfter: 1))
        await #expect {
            try await indexer(db, subspace, ["byCat", "qty"]).buildIndex()
        } throws: { error in
            if case OnlineIndexerError.validation = error { return true }
            return false
        }
        try await cleanup(db, subspace)
    }

    // MARK: - IndexingPolicy

    @Test("a by-index request continues a partial by-records build by records (default policy)")
    func mismatchContinuesPreviousMethod() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        try await seed(db, subspace)
        try await interrupted(indexer(db, subspace, ["cnt"], limit: 4, stopAfter: 2))
        try await indexer(db, subspace, ["cnt"], source: "byQty").buildIndex(markReadable: false)
        #expect(try await stamp(db, subspace, "cnt")?.method == .byRecords)
        try await indexer(db, subspace, ["cnt"]).buildIndex()
        try await verifyIndexes(db, subspace, ["cnt"])

        // And the reverse: a by-records request continues a partial by-index build by index.
        try await interrupted(indexer(db, subspace, ["qty"], source: "byQty", limit: 4, stopAfter: 2))
        try await indexer(db, subspace, ["qty"]).buildIndex(markReadable: false)
        #expect(try await stamp(db, subspace, "qty")?.method == .byIndex)
        try await indexer(db, subspace, ["qty"]).buildIndex()
        try await verifyIndexes(db, subspace, ["qty"])
        try await cleanup(db, subspace)
    }

    @Test("ifMismatchPrevious: error reports the conflict, rebuild starts over by the new method")
    func mismatchErrorAndRebuild() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        try await seed(db, subspace)
        try await interrupted(indexer(db, subspace, ["cnt"], limit: 4, stopAfter: 2))

        var error = OnlineIndexer.IndexingPolicy()
        error.ifMismatchPrevious = .error
        await #expect {
            try await indexer(db, subspace, ["cnt"], source: "byQty", policy: error).buildIndex()
        } throws: { error in
            guard case OnlineIndexerError.partlyBuilt(let info) = error else { return false }
            return info.indexName == "cnt" && info.savedMethod == "BY_RECORDS" && info.expectedMethod == "BY_INDEX"
        }

        var rebuild = OnlineIndexer.IndexingPolicy()
        rebuild.ifMismatchPrevious = .rebuild
        try await indexer(db, subspace, ["cnt"], source: "byQty", policy: rebuild).buildIndex(markReadable: false)
        #expect(try await stamp(db, subspace, "cnt")?.method == .byIndex)
        try await indexer(db, subspace, ["cnt"], source: "byQty").buildIndex()
        try await verifyIndexes(db, subspace, ["cnt"])
        try await cleanup(db, subspace)
    }

    @Test("a partial multi-target build continues as a single target only if the takeover is allowed")
    func multiTargetToSingleTakeover() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        try await seed(db, subspace)
        try await interrupted(indexer(db, subspace, ["cnt", "qty"], limit: 4, stopAfter: 2))
        await #expect {
            try await indexer(db, subspace, ["cnt"]).buildIndex()
        } throws: { error in
            guard case OnlineIndexerError.partlyBuilt(let info) = error else { return false }
            return info.savedMethod == "MULTI_TARGET_BY_RECORDS"
        }
        var takeover = OnlineIndexer.IndexingPolicy()
        takeover.allowedTakeovers = [.multiTargetToSingle]
        try await indexer(db, subspace, ["cnt"], policy: takeover).buildIndex()
        try await indexer(db, subspace, ["qty"], policy: takeover).buildIndex()
        try await verifyIndexes(db, subspace, ["cnt", "qty"])
        try await cleanup(db, subspace)
    }

    @Test("index state actions: readable → error / rebuild / nothing; write-only → rebuild")
    func stateActions() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        try await seed(db, subspace)
        try await indexer(db, subspace, ["cnt"]).buildIndex()

        var error = OnlineIndexer.IndexingPolicy()
        error.ifReadable = .error
        await #expect(throws: OnlineIndexerError.self) {
            try await indexer(db, subspace, ["cnt"], policy: error).buildIndex()
        }
        // Rebuilding a readable count clears it first: nothing is counted twice.
        var rebuild = OnlineIndexer.IndexingPolicy()
        rebuild.ifReadable = .rebuild
        try await indexer(db, subspace, ["cnt"], source: "byQty", policy: rebuild).buildIndex()
        try await indexer(db, subspace, ["cnt"]).buildIndex()   // readable: nothing to do
        try await verifyIndexes(db, subspace, ["cnt"])

        var rebuildWriteOnly = OnlineIndexer.IndexingPolicy()
        rebuildWriteOnly.ifWriteOnly = .rebuild
        try await interrupted(indexer(db, subspace, ["qty"], limit: 4, stopAfter: 2))
        try await indexer(db, subspace, ["qty"], source: "byQty", policy: rebuildWriteOnly).buildIndex()
        try await verifyIndexes(db, subspace, ["qty"])

        var errorDisabled = OnlineIndexer.IndexingPolicy()
        errorDisabled.ifDisabled = .error
        await #expect(throws: OnlineIndexerError.self) {
            try await indexer(db, subspace, ["byCat"], policy: errorDisabled).buildIndex()
        }
        try await cleanup(db, subspace)
    }

    @Test("a blocked stamp stops the build unless unblocking is allowed")
    func blockedStamp() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        try await seed(db, subspace)
        try await interrupted(indexer(db, subspace, ["cnt"], limit: 4, stopAfter: 1))
        try await run(db, subspace, withIndexes) { store in
            let cnt = try store.erasedIndexOrThrow("cnt")
            var stamp = IndexBuildIndexingStamp(method: .byRecords)
            stamp.block = true
            stamp.blockID = "maintenance"
            store.transaction.setValue(stamp.encode(), for: store.indexingTypeStampKey(cnt))
        }
        await #expect {
            try await indexer(db, subspace, ["cnt"]).buildIndex()
        } throws: { error in
            if case RecordStoreError.indexBuildBlocked("cnt") = error { return true }
            return false
        }
        var wrongID = OnlineIndexer.IndexingPolicy()
        wrongID.allowUnblock = true
        wrongID.allowUnblockID = "other"
        await #expect(throws: RecordStoreError.self) {
            try await indexer(db, subspace, ["cnt"], policy: wrongID).buildIndex()
        }
        var unblock = OnlineIndexer.IndexingPolicy()
        unblock.allowUnblock = true
        unblock.allowUnblockID = "maintenance"
        try await indexer(db, subspace, ["cnt"], policy: unblock).buildIndex()
        try await verifyIndexes(db, subspace, ["cnt"])
        try await cleanup(db, subspace)
    }

    @Test("stamp codec round-trips Java's fields")
    func stampCodec() throws {
        var stamp = IndexBuildIndexingStamp(method: .byIndex, sourceIndexSubspaceKey: Tuple(Int64(7)).encode(),
                                            sourceIndexLastModifiedVersion: 3)
        stamp.block = true
        stamp.blockExpireEpochMilliSeconds = 1
        stamp.blockID = "x"
        let decoded = try IndexBuildIndexingStamp(decoding: stamp.encode())
        #expect(decoded == stamp)
        #expect(decoded.sourceIndexSubspaceKey == [0x15, 0x07])
        #expect(decoded.sourceIndexLastModifiedVersion == 3)
        #expect(decoded.blockExpireEpochMilliSeconds == 1)
        #expect(!decoded.isBlocked())   // expired
        #expect(decoded.blockless == IndexBuildIndexingStamp(method: .byIndex, sourceIndexSubspaceKey: [0x15, 0x07],
                                                             sourceIndexLastModifiedVersion: 3))
        #expect(stamp.encode() == [0x08, 0x02, 0x12, 0x02, 0x15, 0x07, 0x18, 0x03, 0x28, 0x01, 0x30, 0x01, 0x3A, 0x01, 0x78])
        let multi = IndexBuildIndexingStamp(method: .multiTargetByRecords, targetIndexes: ["a", "b"])
        #expect(try IndexBuildIndexingStamp(decoding: multi.encode()).targetIndexes == ["a", "b"])
    }

    // MARK: - MUTUAL_BY_RECORDS

    @Test("mutual indexers build the same targets concurrently")
    func mutualIndexing() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        try await seed(db, subspace)
        var mutual = OnlineIndexer.IndexingPolicy()
        mutual.mutualIndexing = true
        mutual.mutualIndexingBoundaries = ["s08", "s16", "s24", "s32"].map { Tuple($0) }

        try await interrupted(indexer(db, subspace, ["cnt", "qty"], policy: mutual, limit: 3, stopAfter: 1))
        var expected: [UInt8] = [0x08, 0x05]
        for name in ["cnt", "qty"] { expected += [0x22, UInt8(name.utf8.count)] + Array(name.utf8) }
        #expect(try await stampBytes(db, subspace, "cnt") == expected)

        let first = indexer(db, subspace, ["cnt", "qty"], policy: mutual, limit: 3)
        let second = indexer(db, subspace, ["cnt", "qty"], policy: mutual, limit: 3)
        async let a: Void = first.buildIndex()
        async let b: Void = second.buildIndex()
        try await concurrentWrites(db, subspace, rounds: 16)
        _ = try await (a, b)
        try await verifyIndexes(db, subspace, ["cnt", "qty"])
        try await cleanup(db, subspace)
    }

    @Test("mutual fragment selection matches Java")
    func mutualFragments() {
        let missing: [RangeSet.Range] = [([0x00], [0x10]), ([0x20], [0x30])]
        #expect(OnlineIndexer.fullyUnbuilt(missing, ([0x02], [0x05]))! == ([0x02], [0x05]))
        #expect(OnlineIndexer.fullyUnbuilt(missing, ([0x05], [0x25])) == nil)
        #expect(OnlineIndexer.partlyUnbuilt(missing, ([0x05], [0x25]))! == ([0x05], [0x10]))
        #expect(OnlineIndexer.partlyUnbuilt(missing, ([0x11], [0x1F])) == nil)
        for size in 1...40 {
            let step = OnlineIndexer.primeStep(size)
            #expect(step == 1 || size % step != 0)
        }
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
#endif
