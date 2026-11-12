/*
 * OnlineIndexScrubber.swift
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

/// Finds — and optionally repairs — inconsistencies between a readable index and the records it
/// indexes: the Java Record Layer's `OnlineIndexScrubber` (with `IndexScrubbing` and the value
/// index scrubbing tools).
///
/// - ``scrubDanglingIndexEntries()`` walks the index entries (`S / 2 / <index>`) and reports
///   entries that no record backs; with ``Config/allowRepair`` they are deleted.
/// - ``scrubMissingIndexEntries()`` walks the records (`S / 1`) and reports records whose expected
///   index entries are absent; with ``Config/allowRepair`` the record is re-indexed.
///
/// Each walk runs in batches of at most ``Config/maxLimit`` items per transaction, adapting the
/// limit on too-large/too-old errors exactly like ``OnlineIndexer``. Progress is kept in Java's
/// scrubbed-ranges range sets, so a walk stopped by ``Config/entriesScanLimit`` (or a failure)
/// resumes where it stopped — from any process, Swift or Java:
///
/// | walk     | range id 0               | range id `n`                    |
/// |----------|--------------------------|---------------------------------|
/// | dangling | `S / 9 / <index> / 3`    | `S / 9 / <index> / 6 / n`       |
/// | missing  | `S / 9 / <index> / 4`    | `S / 9 / <index> / 5 / n`       |
///
/// Range keys are the tuple-packed index keys (dangling) or primary keys (missing), relative to
/// their subspace. Once a walk covers everything its range set is cleared, so the next call
/// starts over. As in Java, the scrubber's `SCRUB_REPAIR` indexing stamp is never written: the
/// index must be (and stay) readable, which every batch checks.
///
/// Supported index types are those Java scrubs — value indexes (here also ``IndexType/min`` and
/// ``IndexType/max``, which are value indexes in Java) and version indexes; others fail with
/// ``RecordStoreError/unsupportedIndexType(_:)``.
public struct OnlineIndexScrubber: Sendable {
    /// What a scrub looks for (Java's `IndexScrubbingTools.ScrubbingType`).
    public enum ScrubbingType: Sendable, Hashable {
        /// Index entries without a record that produces them.
        case dangling
        /// Records whose index entries are absent.
        case missing
    }

    /// Tuning and policy knobs: Java's `OnlineIndexOperationConfig` limits plus its
    /// `OnlineIndexScrubber.ScrubbingPolicy`.
    public struct Config: Sendable {
        /// Maximum items (index entries or records) scanned per transaction (Java's scrubber
        /// builder default, 2000).
        public var maxLimit: Int = 2000
        /// Items per transaction to start with (defaults to `maxLimit`).
        public var initialLimit: Int? = nil
        /// Give up after this many consecutive failed attempts of one batch (Java default 100).
        public var maxRetries: Int = 100
        /// Successful batches before the limit is raised again; `nil` never raises it.
        public var increaseLimitAfter: Int? = nil
        /// Throttle to this many items per second (Java default 10,000); `nil` disables.
        public var recordsPerSecond: Int? = 10_000

        /// Fix what is found: delete dangling entries / re-index records with missing entries
        /// (Java's `ScrubbingPolicy.allowRepair`, default `true`).
        public var allowRepair: Bool = true
        /// Stop a call after scanning at least this many items, leaving the rest for the next
        /// call; `0` scans everything (Java's `entriesScanLimit`). Checked between transactions.
        public var entriesScanLimit: Int = 0
        /// Selects an independent set of scrubbed ranges, so separate scrubbing sessions don't
        /// share progress (Java's `scrubbingRangeId`; 0 is the pre-range-id location).
        public var rangeId: Int = 0
        /// Forget earlier progress and start this call from the beginning (Java's
        /// `scrubbingRangeReset`).
        public var rangeReset: Bool = false
        /// Also treat an entry as dangling when its record exists but no longer produces it.
        /// Java's value scrubber only checks that the record exists; set `false` for Java's
        /// exact counts.
        public var detectStaleEntries: Bool = false

        public init() {}

        var indexerConfig: OnlineIndexer.Config {
            var config = OnlineIndexer.Config()
            config.maxLimit = maxLimit
            config.initialLimit = initialLimit
            config.maxRetries = maxRetries
            config.increaseLimitAfter = increaseLimitAfter
            config.recordsPerSecond = recordsPerSecond
            return config
        }
    }

    let source: any RecordTransactionSource
    let subspace: Subspace
    let metaData: RecordMetaData
    let indexName: String
    let config: Config

    public init(source: any RecordTransactionSource, subspace: Subspace, metaData: RecordMetaData,
                indexName: String, config: Config = Config()) {
        self.source = source
        self.subspace = subspace
        self.metaData = metaData
        self.indexName = indexName
        self.config = config
    }

    /// Scans index entries for ones whose record is gone (or, with
    /// ``Config/detectStaleEntries``, no longer produces them). Returns how many were found;
    /// with ``Config/allowRepair`` they have been deleted.
    @discardableResult
    public func scrubDanglingIndexEntries() async throws -> Int {
        try await scrub(.dangling)
    }

    /// Scans records for ones whose index entries are absent. Returns how many such records were
    /// found; with ``Config/allowRepair`` they have been re-indexed.
    @discardableResult
    public func scrubMissingIndexEntries() async throws -> Int {
        try await scrub(.missing)
    }

    /// Forgets all scrubbing progress for the index, every range id and both walks — Java's
    /// `eraseAllIndexingScrubbingData`. Runs within `store`'s transaction.
    public func eraseAllIndexingScrubbingData(_ store: FDBRecordStore) throws {
        let index = try store.erasedIndexOrThrow(indexName)
        for key in [ScrubSubspaceKey.indexRangesZero, .indexRanges, .recordRangesZero, .recordRanges] {
            let prefix = store.indexBuildSubspace(index).pack(Tuple(key.rawValue))
            store.transaction.clearRange(beginKey: prefix, endKey: prefix + [0xFF])
        }
    }

    // MARK: - The walk

    /// Java's `IndexScrubbing.buildIndexAsync` / `iterateAllRanges`.
    private func scrub(_ type: ScrubbingType) async throws -> Int {
        let index = try validateIndex()
        try await run { store in try await self.prepare(store, type) }

        var throttle = OnlineIndexer.Throttle(config: config.indexerConfig)
        var issues = 0
        var scanned = 0
        while true {
            let started = Date()
            let outcome: BatchOutcome
            do {
                let limit = throttle.limit
                outcome = try await run { store in try await self.scrubBatch(store, index: index, type, limit: limit) }
            } catch let error as FDBError where OnlineIndexer.Throttle.lessensWork(error) {
                try throttle.failed(error)
                continue
            }
            // Issues count only once their transaction committed.
            issues += outcome.issues
            scanned += outcome.scanned
            throttle.succeeded(scanned: outcome.scanned)
            if outcome.done { break }
            if config.entriesScanLimit > 0, scanned >= config.entriesScanLimit { break }
            try await throttle.pace(scanned: outcome.scanned, since: started)
        }
        return issues
    }

    /// Fails for indexes Java can't scrub (`getIndexScrubbingTools` returning nothing).
    private func validateIndex() throws -> ErasedIndex {
        guard let index = metaData.index(named: indexName) else { throw RecordStoreError.unknownIndex(indexName) }
        switch index.type {
        case .value, .min, .max, .version:
            break
        default:
            throw RecordStoreError.unsupportedIndexType(index.type)
        }
        if index.syntheticTypeName != nil {
            throw RecordStoreError.unsupportedStoreFeature("scrubbing an index on a synthetic record type")
        }
        return index
    }

    /// Java's `handleStateAndDoBuildIndexAsync` (scrubber branch) + `setScrubberTypeOrThrow`.
    private func prepare(_ store: FDBRecordStore, _ type: ScrubbingType) async throws {
        let index = try store.erasedIndexOrThrow(indexName)
        guard store.indexState(named: indexName).isScannable else { throw RecordStoreError.indexNotBuilt(indexName) }
        let rangeSet = store.scrubbedRangeSet(index, type, rangeId: config.rangeId)
        if config.rangeReset {
            rangeSet.clear(store.transaction)
        } else if try await rangeSet.missingRanges(store.transaction, limit: 1).first == nil {
            // A finished earlier session: start afresh.
            rangeSet.clear(store.transaction)
        }
    }

    private struct BatchOutcome: Sendable {
        let done: Bool
        let scanned: Int
        let issues: Int
    }

    /// One transaction of Java's `IndexScrubbing.indexScrubRangeOnly`: scrubs up to `limit` items
    /// from the first unscrubbed range and records the covered range.
    private func scrubBatch(_ store: FDBRecordStore, index: ErasedIndex, _ type: ScrubbingType, limit: Int) async throws -> BatchOutcome {
        guard store.indexState(named: indexName).isScannable else { throw RecordStoreError.indexNotBuilt(indexName) }
        let rangeSet = store.scrubbedRangeSet(index, type, rangeId: config.rangeId)
        guard let range = try await rangeSet.missingRanges(store.transaction, limit: 1).first else {
            rangeSet.clear(store.transaction)
            return BatchOutcome(done: true, scanned: 0, issues: 0)
        }
        let rangeStart = RangeSet.nullIfFirst(range.begin)
        let rangeEnd = RangeSet.nullIfFinal(range.end)

        let pass: (scanned: Int, issues: Int, continuation: FDB.Bytes?)
        switch type {
        case .dangling:
            pass = try await scrubDangling(store, index, begin: rangeStart, end: rangeEnd, limit: limit)
        case .missing:
            pass = try await scrubMissing(store, index, begin: rangeStart, end: rangeEnd, limit: limit)
        }

        // Java's `updateRangeAndCheckIfExhausted`.
        if pass.continuation == nil, rangeEnd == nil {
            rangeSet.clear(store.transaction)
            return BatchOutcome(done: true, scanned: pass.scanned, issues: pass.issues)
        }
        try await rangeSet.insertRange(store.transaction, begin: rangeStart, end: pass.continuation ?? rangeEnd, requireEmpty: true)
        return BatchOutcome(done: false, scanned: pass.scanned, issues: pass.issues)
    }

    /// Java's `ValueIndexScrubbingToolsDangling`: scans index entries (snapshot) in
    /// `[begin, end)` (tuple-packed, relative to the index subspace). Returns the key of the first
    /// unscanned entry if the limit stopped the scan.
    private func scrubDangling(
        _ store: FDBRecordStore, _ index: ErasedIndex, begin: FDB.Bytes?, end: FDB.Bytes?, limit: Int
    ) async throws -> (scanned: Int, issues: Int, continuation: FDB.Bytes?) {
        let indexSubspace = store.indexSubspace(index)
        let beginKey = begin.map { indexSubspace.prefix + $0 } ?? indexSubspace.range.begin
        let endKey = end.map { indexSubspace.prefix + $0 } ?? indexSubspace.range.end
        let pkCount = index.primaryKeyColumnCount
        var scanned = 0
        var issues = 0
        for try await (key, _) in store.transaction.getRange(beginKey: beginKey, endKey: endKey, snapshot: true) {
            if scanned == limit {
                return (scanned, issues, Array(key.dropFirst(indexSubspace.prefix.count)))
            }
            scanned += 1
            let elements = try indexSubspace.unpack(key)
            guard elements.count >= pkCount else { continue }
            let primaryKey = Tuple(Array(elements.suffix(pkCount)))
            if try await isDangling(store, index, key: key, primaryKey: primaryKey) {
                issues += 1
                if config.allowRepair {
                    // The record's absence can't be a conflict key, so conflict on its range.
                    let (b, e) = store.recordsSubspace.subspace(primaryKey).range
                    try store.transaction.addConflictRange(beginKey: b, endKey: e, type: .read)
                    store.transaction.clear(key: key)
                }
            }
        }
        return (scanned, issues, nil)
    }

    private func isDangling(_ store: FDBRecordStore, _ index: ErasedIndex, key: FDB.Bytes, primaryKey: Tuple) async throws -> Bool {
        guard let record = try await store.loadExisting(primaryKey)?.indexable else { return true }
        guard config.detectStaleEntries else { return false }
        guard record.recordType.indexes.contains(where: { $0.name == index.name }) else { return true }
        let prefix = store.indexSubspace(index).prefix
        let pk = record.primaryKey.encode()
        return !record.entries(for: index).contains { prefix + Tuple($0).encode() + pk == key }
    }

    /// Java's `ValueIndexScrubbingToolsMissing`: scans records (snapshot) in `[begin, end)`
    /// (tuple-packed primary keys). Returns the primary key of the first unscanned record if the
    /// limit stopped the scan.
    private func scrubMissing(
        _ store: FDBRecordStore, _ index: ErasedIndex, begin: FDB.Bytes?, end: FDB.Bytes?, limit: Int
    ) async throws -> (scanned: Int, issues: Int, continuation: FDB.Bytes?) {
        let maintainer = store.indexMaintainer(for: index)
        let indexPrefix = store.indexSubspace(index).prefix
        var scanned = 0
        var issues = 0
        for try await record in store.scanRecords(begin: begin, end: end, snapshot: true) {
            if scanned == limit {
                return (scanned, issues, record.primaryKey.encode())
            }
            scanned += 1
            guard record.recordType.indexes.contains(where: { $0.name == index.name }) else { continue }
            let pk = record.primaryKey.encode()
            var missing = false
            for entry in record.entries(for: index) {
                // Serializable: a concurrent fix or removal of this entry conflicts.
                if try await store.transaction.getValue(for: indexPrefix + Tuple(entry).encode() + pk) == nil {
                    missing = true
                }
            }
            guard missing else { continue }
            issues += 1
            if config.allowRepair {
                // Java's `updateMaintainerBuilder` for a snapshot scan: conflict on the record.
                let (b, e) = store.recordsSubspace.subspace(record.primaryKey).range
                try store.transaction.addConflictRange(beginKey: b, endKey: e, type: .read)
                try await maintainer.update(old: nil, new: record)
            }
        }
        return (scanned, issues, nil)
    }

    /// Runs `body` in a fresh transaction with a checked-open store, committing on success (as
    /// ``OnlineIndexer``'s runner: lessen-work errors propagate to the throttle).
    private func run<T: Sendable>(_ body: @Sendable (FDBRecordStore) async throws -> T) async throws -> T {
        var attempts = 0
        while true {
            let transaction = try source.createRecordTransaction()
            do {
                let context = FDBRecordContext(transaction: transaction)
                let store = try await FDBRecordStore.open(context: context, subspace: subspace, metaData: metaData)
                let result = try await body(store)
                try await context.commit()
                return result
            } catch let error as FDBError {
                if OnlineIndexer.Throttle.lessensWork(error) { throw error }
                attempts += 1
                guard error.isRetryable, attempts < config.maxRetries else { throw error }
                try await transaction.onError(error)
            }
        }
    }
}

// MARK: - Scrubbed-range subspaces

/// Keys under `S / 9 / <index>` holding scrubbing progress (Java's `IndexingSubspaces`).
enum ScrubSubspaceKey: Int64 {
    /// Scrubbed index-entry ranges for range id 0 (`INDEX_SCRUBBED_INDEX_RANGES_ZERO`).
    case indexRangesZero = 3
    /// Scrubbed record ranges for range id 0 (`INDEX_SCRUBBED_RECORDS_RANGES_ZERO`).
    case recordRangesZero = 4
    /// Scrubbed record ranges, followed by the range id (`INDEX_SCRUBBED_RECORDS_RANGES`).
    case recordRanges = 5
    /// Scrubbed index-entry ranges, followed by the range id (`INDEX_SCRUBBED_INDEX_RANGES`).
    case indexRanges = 6
}

extension FDBRecordStore {
    /// Java's `IndexingSubspaces.indexScrubIndexRangeSubspace`.
    func indexScrubIndexRangeSubspace(_ index: ErasedIndex, rangeId: Int) -> Subspace {
        let build = indexBuildSubspace(index)
        return rangeId == 0
            ? build.child(ScrubSubspaceKey.indexRangesZero.rawValue)
            : build.child(ScrubSubspaceKey.indexRanges.rawValue, Int64(rangeId))
    }

    /// Java's `IndexingSubspaces.indexScrubRecordsRangeSubspace`.
    func indexScrubRecordsRangeSubspace(_ index: ErasedIndex, rangeId: Int) -> Subspace {
        let build = indexBuildSubspace(index)
        return rangeId == 0
            ? build.child(ScrubSubspaceKey.recordRangesZero.rawValue)
            : build.child(ScrubSubspaceKey.recordRanges.rawValue, Int64(rangeId))
    }

    /// Java's `IndexingRangeSet.forScrubbingIndex` / `forScrubbingRecords`.
    func scrubbedRangeSet(_ index: ErasedIndex, _ type: OnlineIndexScrubber.ScrubbingType, rangeId: Int) -> RangeSet {
        switch type {
        case .dangling: return RangeSet(subspace: indexScrubIndexRangeSubspace(index, rangeId: rangeId))
        case .missing: return RangeSet(subspace: indexScrubRecordsRangeSubspace(index, rangeId: rangeId))
        }
    }
}

extension DatabaseProtocol where Self: RecordTransactionSource {
    /// A scrubber for an index of the store at `subspace`. See ``OnlineIndexScrubber``.
    public func indexScrubber(
        subspace: Subspace, metaData: RecordMetaData, indexName: String,
        config: OnlineIndexScrubber.Config = OnlineIndexScrubber.Config()
    ) -> OnlineIndexScrubber {
        OnlineIndexScrubber(source: self, subspace: subspace, metaData: metaData, indexName: indexName, config: config)
    }
}
#endif
