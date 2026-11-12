/*
 * OnlineIndexer.swift
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

/// Something that can start transactions against a record store's cluster or tenant.
public protocol RecordTransactionSource: Sendable {
    func createRecordTransaction() throws -> any TransactionProtocol
}

extension FDBDatabase: RecordTransactionSource {
    public func createRecordTransaction() throws -> any TransactionProtocol { try createTransaction() }
}

extension FDBTenant: RecordTransactionSource {
    public func createRecordTransaction() throws -> any TransactionProtocol { try createTransaction() }
}

/// Errors specific to online index builds (Java's `IndexingBase` exceptions).
public enum OnlineIndexerError: Error, Sendable, CustomStringConvertible {
    /// The request or the indexes' states are not valid for this build (Java's
    /// `IndexingBase.ValidationException`).
    case validation(String)
    /// The index was partly built by another method, or its build is blocked (Java's
    /// `IndexingBase.PartlyBuiltException`). See ``OnlineIndexer/IndexingPolicy/ifMismatchPrevious``.
    case partlyBuilt(PartlyBuiltIndex)
    /// The source index cannot be used to build the target (Java's
    /// `IndexingBase.UnusableSourceIndexException`). Unless the policy forbids it, the indexer
    /// falls back to a by-records build instead of throwing this.
    case unusableSourceIndex(String)

    public var description: String {
        switch self {
        case .validation(let message): return "index build validation failed: \(message)"
        case .partlyBuilt(let info): return info.description
        case .unusableSourceIndex(let message): return "unusable source index: \(message)"
        }
    }
}

/// Details of an ``OnlineIndexerError/partlyBuilt(_:)`` error.
public struct PartlyBuiltIndex: Sendable, CustomStringConvertible {
    /// The index whose saved indexing type stamp conflicts with the requested build.
    public let indexName: String
    public let reason: String
    let saved: IndexBuildIndexingStamp?
    let expected: IndexBuildIndexingStamp

    /// The indexing method the index was partly built with (Java's method names).
    public var savedMethod: String { saved?.method.description ?? "NONE" }
    /// The indexing method this build requested.
    public var expectedMethod: String { expected.method.description }
    /// Whether the saved stamp blocks the build.
    public var isBlocked: Bool { saved?.isBlocked() ?? false }

    public var description: String {
        "\(reason): index \(indexName), saved [\(saved?.summary ?? "none")], expected [\(expected.summary)]"
    }
}

/// Builds indexes over a store's existing records, online and in batches — the Java Record
/// Layer's `OnlineIndexer`, with its BY_RECORDS, MULTI_TARGET_BY_RECORDS, MUTUAL_BY_RECORDS and
/// BY_INDEX methods.
///
/// The build:
/// 1. checks the target indexes' states against the ``IndexingPolicy`` (continue, rebuild, …),
///    moves them to ``IndexState/writeOnly`` (clearing them when rebuilding) and records how they
///    are being built — the indexing type stamp at `S / 9 / <index> / 2`. A previous build by a
///    different method is continued by that method, rebuilt, or reported, per the policy;
/// 2. repeatedly takes the first range missing from the (primary) target's built-range set
///    (`S / 6 / <index>`), indexes up to `limit` records from it in one transaction, and adds
///    the covered range to every target's set in the same transaction;
/// 3. marks every target readable once no range is missing.
///
/// Methods:
/// - **by records** (one target): scans records by primary key; stamp `BY_RECORDS`.
/// - **multi target** (several targets): one record scan updates every target; stamp
///   `MULTI_TARGET_BY_RECORDS` with the sorted target names (the first is the primary, whose range
///   set drives the scan).
/// - **by index** (`sourceIndex`): scans a readable VALUE index over the same single record type
///   (one entry per record), loading and indexing each record; the range set is keyed by
///   source-index entry keys, and the stamp `BY_INDEX` carries the source's subspace key and
///   last-modified version.
/// - **mutual** (``IndexingPolicy/mutualIndexing``): like multi target, but several processes
///   may build the same targets concurrently, each taking fragments of the primary-key space;
///   stamp `MUTUAL_BY_RECORDS`.
///
/// While an index is write-only, saves maintain it — but non-idempotent indexes (counts, sums)
/// only for records inside already-built ranges (by primary key, or by source entry key for a
/// by-index build), and both sides read the range set, so a record is never counted by both the
/// build and a concurrent write. Progress lives in the database, so an interrupted build resumes
/// where it stopped, from any process.
///
/// Transactions that fail with too-large / too-old / timeout errors shrink the batch (Java's
/// `IndexingThrottle`): to 90%, 80%, 70% of the records last attempted, then 50%, then 10%;
/// after `increaseLimitAfter` consecutive successes the limit grows again, up to `maxLimit`.
public struct OnlineIndexer: Sendable {
    /// Tuning knobs, mirroring Java's `OnlineIndexOperationConfig`.
    public struct Config: Sendable {
        /// Maximum records indexed per transaction (Java default 100).
        public var maxLimit: Int = 100
        /// Records per transaction to start with (defaults to `maxLimit`).
        public var initialLimit: Int? = nil
        /// Give up after this many consecutive failed attempts of one batch (Java default 100).
        public var maxRetries: Int = 100
        /// Successful batches before the limit is raised again; `nil` never raises it (Java's
        /// default, `DO_NOT_RE_INCREASE_LIMIT`).
        public var increaseLimitAfter: Int? = nil
        /// Throttle to this many records per second (Java default 10,000); `nil` disables.
        public var recordsPerSecond: Int? = 10_000
        /// Testing hook: stop (throwing `CancellationError`) after this many committed batches,
        /// simulating an interrupted build.
        var stopAfterBatches: Int? = nil

        public init() {}
    }

    /// How to treat existing index states and previous partial builds — Java's
    /// `OnlineIndexer.IndexingPolicy`.
    public struct IndexingPolicy: Sendable {
        /// Java's `IndexingPolicy.DesiredAction`.
        public enum DesiredAction: Sendable, Hashable {
            /// Fail with ``OnlineIndexerError/validation(_:)`` (state) or
            /// ``OnlineIndexerError/partlyBuilt(_:)`` (mismatching previous build).
            case error
            /// Clear the index and build it from scratch.
            case rebuild
            /// Continue the previous build: for a write-only index, from where it stopped (by
            /// the previous method when it differs); for a disabled one, build it; for a
            /// readable one, do nothing.
            case `continue`
            /// Only mark the index readable (used for ``IndexState/readableUniquePending``).
            case markReadable
        }

        /// Java's `IndexingPolicy.TakeoverTypes`: conversions from one method to another that
        /// may continue a partly built index.
        public enum TakeoverType: Sendable, Hashable, CaseIterable {
            /// Continue, as a single target, an index partly built in a multi-target set.
            case multiTargetToSingle
            /// Continue, as a single target, an index partly built mutually.
            case mutualToSingle
            /// Continue mutually an index partly built by records (single or multi target).
            case byRecordsToMutual
        }

        /// Action for a disabled index (Java default ``DesiredAction/rebuild``).
        public var ifDisabled: DesiredAction = .rebuild
        /// Action for a write-only (partly built) index (Java default ``DesiredAction/continue``).
        public var ifWriteOnly: DesiredAction = .continue
        /// Action when the index was partly built by another method (Java default
        /// ``DesiredAction/continue``: continue by the previous method if possible).
        public var ifMismatchPrevious: DesiredAction = .continue
        /// Action for a readable index (Java default ``DesiredAction/continue``: nothing to do).
        public var ifReadable: DesiredAction = .continue
        /// Never fall back to a by-records build when the source index is unusable.
        public var forbidRecordScan: Bool = false
        /// Method conversions allowed when continuing (Java's `allowTakeoverContinue`).
        public var allowedTakeovers: Set<TakeoverType> = []
        /// Mark unique indexes with violations ``IndexState/readableUniquePending``.
        public var allowUniquePending: Bool = false
        /// Continue a build whose stamp is blocked (Java's `allowUnblock`), optionally only if
        /// the block's ID matches `allowUnblockID`.
        public var allowUnblock: Bool = false
        public var allowUnblockID: String? = nil
        /// Build mutually, allowing several processes to build the same targets at once.
        public var mutualIndexing: Bool = false
        /// Primary-key boundaries that split the record space into mutual-indexing fragments
        /// (Java's `setMutualIndexingBoundaries`). `nil` uses one fragment.
        public var mutualIndexingBoundaries: [Tuple]? = nil

        public init() {}

        /// Java's `getStateDesiredAction`.
        public func desiredAction(for state: IndexState) -> DesiredAction {
            switch state {
            case .disabled: return ifDisabled
            case .writeOnly: return ifWriteOnly
            case .readable: return ifReadable
            case .readableUniquePending: return .markReadable
            }
        }

        /// Java's `allowTakeoverContinue(true)`: allow every conversion.
        public mutating func allowTakeoverContinue() { allowedTakeovers = Set(TakeoverType.allCases) }

        /// Java's `shouldAllowTypeConversionContinue`.
        func shouldAllowTypeConversionContinue(new: IndexBuildIndexingStamp, saved: IndexBuildIndexingStamp) -> Bool {
            switch (new.method, saved.method) {
            case (.byRecords, .multiTargetByRecords):
                return allowedTakeovers.contains(.multiTargetToSingle)
            case (.byRecords, .mutualByRecords):
                return allowedTakeovers.contains(.mutualToSingle)
            case (.mutualByRecords, .multiTargetByRecords):
                guard allowedTakeovers.contains(.byRecordsToMutual) else { return false }
                return new.targetIndexes.count == 1 ||
                    (new.targetIndexes.count == saved.targetIndexes.count &&
                     Set(new.targetIndexes).isSuperset(of: saved.targetIndexes))
            case (.mutualByRecords, .byRecords):
                return allowedTakeovers.contains(.byRecordsToMutual) && new.targetIndexes.count == 1
            default:
                return false
            }
        }

        /// Java's `shouldAllowUnblock`.
        func shouldAllowUnblock(_ blockID: String) -> Bool {
            allowUnblock && (allowUnblockID == nil || allowUnblockID!.isEmpty || allowUnblockID == blockID)
        }
    }

    let source: any RecordTransactionSource
    let subspace: Subspace
    let metaData: RecordMetaData
    /// Target index names, deduplicated and sorted (Java sorts by name); the first is the primary.
    let targetIndexNames: [String]
    let sourceIndexName: String?
    let policy: IndexingPolicy
    let config: Config

    /// The primary target index.
    var indexName: String { targetIndexNames[0] }

    /// A by-records build of one index.
    public init(source: any RecordTransactionSource, subspace: Subspace, metaData: RecordMetaData,
                indexName: String, config: Config = Config()) {
        self.init(source: source, subspace: subspace, metaData: metaData, targetIndexes: [indexName], config: config)
    }

    /// A build of one or more target indexes.
    ///
    /// - Parameters:
    ///   - targetIndexes: the indexes to build; several are built in one records scan.
    ///   - sourceIndex: build the (single) target by scanning this readable VALUE index instead
    ///     of the records (Java's `setSourceIndex`). Falls back to a records scan if the source
    ///     is unusable, unless ``IndexingPolicy/forbidRecordScan``.
    ///   - policy: how to treat existing states and partial builds.
    public init(source: any RecordTransactionSource, subspace: Subspace, metaData: RecordMetaData,
                targetIndexes: [String], sourceIndex: String? = nil,
                policy: IndexingPolicy = IndexingPolicy(), config: Config = Config()) {
        self.source = source
        self.subspace = subspace
        self.metaData = metaData
        self.targetIndexNames = Array(Set(targetIndexes)).sorted()
        self.sourceIndexName = sourceIndex
        self.policy = policy
        self.config = config
    }

    // MARK: - Entry point

    /// Builds the target indexes and, when `markReadable`, makes them readable. A unique index
    /// with violations fails with ``RecordStoreError/uniquenessViolation(index:)`` unless
    /// `allowUniquePending` (or the policy's), which leaves it ``IndexState/readableUniquePending``.
    public func buildIndex(markReadable: Bool = true, allowUniquePending: Bool = false) async throws {
        try validateRequest()
        // Java's `OnlineIndexer.indexingLauncher` / `indexingCatcher`: each attempt runs with a
        // (possibly adjusted) policy; some failures adjust it and retry.
        var attempt = Attempt(policy: policy, sourceIndexName: sourceIndexName)
        var firstPartlyBuilt: PartlyBuiltIndex?
        var attempts = 0
        while true {
            attempts += 1
            do {
                try await runAttempt(attempt, markReadable: markReadable,
                                     allowUniquePending: allowUniquePending || policy.allowUniquePending)
                return
            } catch OnlineIndexerError.partlyBuilt(let info) where attempts < Self.attemptsLimit {
                switch attempt.policy.ifMismatchPrevious {
                case .continue:
                    // Continue by the previous build's method, trying each adjustment once.
                    if firstPartlyBuilt == nil { firstPartlyBuilt = info }
                    let previous = info.saved?.method ?? .invalid
                    if targetIndexNames.count == 1 && !attempt.fallbackToRecordsScan {
                        if [.byRecords, .multiTargetByRecords, .mutualByRecords].contains(previous) {
                            attempt.fallBackToRecordsScan()
                            continue
                        }
                        if previous == .byIndex, !attempt.policy.mutualIndexing,
                           !attempt.isSourceIndex(of: info) {
                            attempt.sourceIndexSubspaceKey = info.saved?.sourceIndexSubspaceKey
                            attempt.sourceIndexAdjusted = true
                            continue
                        }
                    }
                    throw Self.surfaced(firstPartlyBuilt!)
                case .rebuild:
                    attempt.policy.ifWriteOnly = .rebuild
                    continue
                case .error, .markReadable:
                    throw Self.surfaced(info)
                }
            } catch OnlineIndexerError.unusableSourceIndex(let message)
                        where attempt.isByIndex && attempts < Self.attemptsLimit {
                if attempt.sourceIndexAdjusted {
                    // The previous build's source index isn't usable: rebuild as requested.
                    attempt = Attempt(policy: policy, sourceIndexName: sourceIndexName)
                    attempt.policy.ifWriteOnly = .rebuild
                    continue
                }
                if !attempt.policy.forbidRecordScan && !attempt.fallbackToRecordsScan {
                    attempt.fallBackToRecordsScan()
                    continue
                }
                throw OnlineIndexerError.unusableSourceIndex(message)
            }
        }
    }

    /// Java's `INDEXING_ATTEMPTS_RECURSION_LIMIT`.
    static let attemptsLimit = 5

    /// A blocked build surfaces as ``RecordStoreError/indexBuildBlocked(_:)`` (this layer's
    /// pre-existing error); other conflicts as ``OnlineIndexerError/partlyBuilt(_:)``.
    private static func surfaced(_ info: PartlyBuiltIndex) -> Error {
        info.isBlocked ? RecordStoreError.indexBuildBlocked(info.indexName) : OnlineIndexerError.partlyBuilt(info)
    }

    /// Java's `OnlineIndexer.Builder.validate`.
    private func validateRequest() throws {
        guard !targetIndexNames.isEmpty else { throw OnlineIndexerError.validation("no target index was set") }
        for name in targetIndexNames where metaData.index(named: name) == nil {
            throw RecordStoreError.unknownIndex(name)
        }
        if targetIndexNames.count > 1 && sourceIndexName != nil {
            throw OnlineIndexerError.validation("indexing multiple targets by a source index is not supported")
        }
        if policy.mutualIndexing && sourceIndexName != nil {
            throw OnlineIndexerError.validation("indexing mutually by a source index is not supported")
        }
    }

    // MARK: - Attempts

    /// One indexing attempt's method and adjustments (Java's per-attempt `IndexingPolicy` plus
    /// `IndexingOperationState`).
    struct Attempt: Sendable {
        var policy: IndexingPolicy
        var sourceIndexName: String?
        /// A tuple-packed source subspace key, overriding `sourceIndexName` (set to continue a
        /// previous by-index build).
        var sourceIndexSubspaceKey: FDB.Bytes? = nil
        var fallbackToRecordsScan = false
        var sourceIndexAdjusted = false

        var isByIndex: Bool { sourceIndexName != nil || sourceIndexSubspaceKey != nil }
        /// Java's `enforceStampOverwrite` after a fallback.
        var forceStampOverwrite: Bool { fallbackToRecordsScan }

        mutating func fallBackToRecordsScan() {
            fallbackToRecordsScan = true
            sourceIndexName = nil
            sourceIndexSubspaceKey = nil
            policy.mutualIndexing = false
            policy.mutualIndexingBoundaries = nil
        }

        /// Java's `isPolicySourceIndexOf`: whether retrying by the previous build's source index
        /// would just repeat this attempt.
        func isSourceIndex(of info: PartlyBuiltIndex) -> Bool {
            let savedKey = info.saved?.sourceIndexSubspaceKey ?? []
            if info.expected.method == .byIndex && info.expected.sourceIndexSubspaceKey == savedKey { return true }
            return sourceIndexSubspaceKey != nil && sourceIndexSubspaceKey == savedKey
        }
    }

    enum Method { case byRecords, byIndex, mutual }

    private func method(of attempt: Attempt) -> Method {
        if attempt.policy.mutualIndexing { return .mutual }
        if attempt.isByIndex && targetIndexNames.count == 1 { return .byIndex }
        return .byRecords
    }

    private enum StateAction: Sendable { case nothing, markReadable, build }

    private func runAttempt(_ attempt: Attempt, markReadable: Bool, allowUniquePending: Bool) async throws {
        let action = try await run { store in try await self.handleState(store, attempt) }
        switch action {
        case .nothing:
            return
        case .markReadable:
            if markReadable { try await markTargetsReadable(allowUniquePending: allowUniquePending) }
            return
        case .build:
            break
        }
        var throttle = Throttle(config: config)
        switch method(of: attempt) {
        case .byIndex:
            _ = try await run { store in try self.validateSourceAndTarget(store.metaData, attempt) }
            try await iterateBatches(&throttle) { store, limit in
                try await self.buildByIndexBatch(store, attempt, limit: limit)
            }
        case .byRecords:
            try await presetRecordsRange()
            try await iterateBatches(&throttle) { store, limit in
                try await self.buildByRecordsBatch(store, attempt, limit: limit, within: nil)
            }
        case .mutual:
            try await presetRecordsRange()
            try await buildMutually(attempt, &throttle)
        }
        if markReadable { try await markTargetsReadable(allowUniquePending: allowUniquePending) }
    }

    private func targets(_ metaData: RecordMetaData) throws -> [ErasedIndex] {
        try targetIndexNames.map { name in
            guard let index = metaData.index(named: name) else { throw RecordStoreError.unknownIndex(name) }
            return index
        }
    }

    // MARK: State and stamp handling

    /// Java's `IndexingBase.handleStateAndDoBuildIndexAsync` (the transactional part).
    private func handleState(_ store: FDBRecordStore, _ attempt: Attempt) async throws -> StateAction {
        let targets = try targets(store.metaData)
        let primary = targets[0]
        let primaryState = store.indexState(named: primary.name)
        let action = attempt.policy.desiredAction(for: primaryState)
        switch action {
        case .error:
            throw OnlineIndexerError.validation("index \(primary.name) state \(primaryState) is not as expected")
        case .markReadable:
            return .markReadable
        case .rebuild, .continue:
            break
        }
        let shouldClear = action == .rebuild
        guard shouldClear || primaryState != .readable else { return .nothing }

        var toClear = shouldClear ? [primary] : []
        let continuedBuild = !shouldClear && primaryState == .writeOnly
        for target in targets.dropFirst() {
            // Followers must be in the primary's state.
            let state = store.indexState(named: target.name)
            if state != primaryState {
                if attempt.policy.desiredAction(for: state) != .rebuild || continuedBuild {
                    throw OnlineIndexerError.validation(
                        "target index \(target.name) state \(state) doesn't match the primary index \(primary.name) state \(primaryState)")
                }
                toClear.append(target)
            } else if shouldClear {
                toClear.append(target)
            }
        }
        for index in toClear {
            // Java's `clearAndMarkIndexWriteOnly` marks first, then clears: leaving the readable
            // state puts a fully-built marker in the range set, which the clear must remove.
            try await store.clearAndMarkIndexWriteOnly(index.name)
            store.clearIndexData(index)
        }
        if !continuedBuild {
            for index in targets { _ = try await store.markIndexWriteOnly(index.name) }
        }
        let stamp = try indexingStamp(attempt, store.metaData)
        let forceOverwrite = attempt.forceStampOverwrite || shouldClear
        for index in targets {
            try await setIndexingTypeOrThrow(store, index, newStamp: stamp, continuedBuild: continuedBuild,
                                             forceOverwrite: forceOverwrite, policy: attempt.policy)
        }
        return .build
    }

    /// The stamp this attempt writes (Java's `getIndexingTypeStamp` of each indexer).
    private func indexingStamp(_ attempt: Attempt, _ metaData: RecordMetaData) throws -> IndexBuildIndexingStamp {
        switch method(of: attempt) {
        case .byIndex:
            let source = try sourceIndex(attempt, metaData)
            return IndexBuildIndexingStamp(method: .byIndex, sourceIndexSubspaceKey: source.subspaceTupleKey.encode(),
                                           sourceIndexLastModifiedVersion: source.lastModifiedVersion)
        case .mutual:
            return IndexBuildIndexingStamp(method: .mutualByRecords, targetIndexes: targetIndexNames)
        case .byRecords:
            // A single target keeps the legacy BY_RECORDS stamp, as in Java.
            return targetIndexNames.count == 1
                ? IndexBuildIndexingStamp(method: .byRecords)
                : IndexBuildIndexingStamp(method: .multiTargetByRecords, targetIndexes: targetIndexNames)
        }
    }

    /// Java's `IndexingBase.setIndexingTypeOrThrow` for one target.
    private func setIndexingTypeOrThrow(_ store: FDBRecordStore, _ index: ErasedIndex, newStamp: IndexBuildIndexingStamp,
                                        continuedBuild: Bool, forceOverwrite: Bool, policy: IndexingPolicy) async throws {
        func save() { store.transaction.setValue(newStamp.encode(), for: store.indexingTypeStampKey(index)) }
        func partlyBuilt(_ saved: IndexBuildIndexingStamp?) -> OnlineIndexerError {
            .partlyBuilt(PartlyBuiltIndex(
                indexName: index.name,
                reason: saved?.block == true ? "This index was partly built, and blocked" : "This index was partly built by another method",
                saved: saved, expected: newStamp))
        }
        if forceOverwrite && !continuedBuild {
            save()   // a fresh session that overwrites: no questions asked
            return
        }
        guard let saved = try await store.loadIndexingTypeStamp(index) else {
            if continuedBuild && newStamp.method != .byRecords {
                // A write-only index without a stamp was (presumably) partly built by records.
                if try await isWriteOnlyButNoRecordScanned(store, index) { save(); return }
                throw partlyBuilt(IndexBuildIndexingStamp(method: .byRecords))
            }
            save()
            return
        }
        if newStamp == saved { return }
        if saved.isBlocked() && !policy.shouldAllowUnblock(saved.blockID) { throw partlyBuilt(saved) }
        if newStamp.blockless == saved.blockless { save(); return }
        if continuedBuild && policy.shouldAllowTypeConversionContinue(new: newStamp, saved: saved) { save(); return }
        if forceOverwrite, try await isWriteOnlyButNoRecordScanned(store, index) { save(); return }
        throw partlyBuilt(saved)
    }

    /// Java's `isWriteOnlyButNoRecordScanned`: the range set is still completely empty.
    private func isWriteOnlyButNoRecordScanned(_ store: FDBRecordStore, _ index: ErasedIndex) async throws -> Bool {
        guard let first = try await store.indexRangeSet(index).missingRanges(store.transaction, limit: 1).first else {
            return false
        }
        return RangeSet.isFirstKey(first.begin) && RangeSet.isFinalKey(first.end)
    }

    /// Java's `validateTypeStamp`, run in every batch: the stamps must still be this build's.
    private func validateTypeStamps(_ store: FDBRecordStore, _ targets: [ErasedIndex],
                                    expected: IndexBuildIndexingStamp) async throws {
        for index in targets {
            let saved = try await store.loadIndexingTypeStamp(index)
            if saved == nil && expected.method == .byRecords { continue }
            if saved == nil || saved!.method != expected.method || saved!.isBlocked() {
                throw OnlineIndexerError.partlyBuilt(PartlyBuiltIndex(
                    indexName: index.name, reason: "Indexing stamp had changed", saved: saved, expected: expected))
            }
        }
    }

    // MARK: Marking readable

    /// Java's `IndexingBase.markIndexReadable`: each target in its own transaction; if any fails,
    /// the others are still attempted and one failure is thrown.
    private func markTargetsReadable(allowUniquePending: Bool) async throws {
        var failure: Error?
        for name in targetIndexNames {
            do {
                _ = try await run { store in try await store.markIndexReadable(name, allowUniquePending: allowUniquePending) }
            } catch {
                if failure == nil { failure = error }
            }
        }
        if let failure { throw failure }
    }

    // MARK: - By records (single and multi target)

    /// Java's `maybePresetRecordsRangeAsync`: when every target's record types have a
    /// record-type key prefix, mark the primary-key space outside those types as built.
    private func presetRecordsRange() async throws {
        let targets = try targets(metaData)
        var prefixes: [FDB.Bytes] = []
        for name in Set(targets.flatMap(\.recordTypeNames)) {
            guard let type = metaData.recordType(named: name), type.primaryKeyStartsWithRecordType else { return }
            prefixes.append(Tuple(type.recordTypePrefix).encode())
        }
        guard let low = prefixes.min(by: { Self.compare($0, $1) < 0 }),
              let high = prefixes.max(by: { Self.compare($0, $1) < 0 }) else { return }
        let highEnd = high + [0xFF]   // TupleRange.betweenInclusive(low, high).toRange()
        _ = try await run { store in
            for index in targets {
                let rangeSet = store.indexRangeSet(index)
                _ = try await rangeSet.insertRange(store.transaction, begin: nil, end: low, requireEmpty: true)
                _ = try await rangeSet.insertRange(store.transaction, begin: highEnd, end: nil, requireEmpty: true)
            }
        }
    }

    /// One transaction of Java's `IndexingMultiTargetByRecords.buildRangeOnly` (also the
    /// single-target by-records build), or, with `within`, of the mutual indexer's
    /// `buildThisRangeOnly`.
    private func buildByRecordsBatch(_ store: FDBRecordStore, _ attempt: Attempt, limit: Int,
                                     within: RangeSet.Range?) async throws -> BatchOutcome {
        let targets = try targets(store.metaData)
        guard store.indexState(named: targets[0].name) == .writeOnly else {
            // Someone else finished (or disabled) it; stop.
            return BatchOutcome(done: true, recordsScanned: 0)
        }
        try await validateTypeStamps(store, targets, expected: indexingStamp(attempt, store.metaData))
        let primaryRanges = store.indexRangeSet(targets[0])
        guard let missing = try await primaryRanges.missingRanges(
            store.transaction, begin: within?.begin, end: within?.end, limit: 1).first else {
            return BatchOutcome(done: true, recordsScanned: 0)
        }
        let rangeStart = RangeSet.nullIfFirst(missing.begin)
        let rangeEnd = RangeSet.nullIfFinal(missing.end)

        let maintainers = targets.map { ($0, store.indexMaintainer(for: $0)) }
        // Idempotent indexes scan at snapshot and conflict only on the records they index, so
        // concurrent inserts into the range don't abort the batch (Java's
        // `canUseSnapshotResolution`). Others read serializably.
        let snapshot = maintainers.allSatisfy { $0.1.isIdempotent }
        var scanned = 0
        var continuation: FDB.Bytes?
        for try await record in store.scanRecords(begin: rangeStart, end: rangeEnd, snapshot: snapshot) {
            if scanned == limit {
                // The (limit+1)th record is not indexed; the built range ends just before it.
                continuation = record.primaryKey.encode()
                break
            }
            scanned += 1
            try await index(record, into: maintainers, store, snapshot: snapshot)
        }
        let builtEnd = continuation ?? rangeEnd
        for target in targets {
            _ = try await store.indexRangeSet(target).insertRange(
                store.transaction, begin: rangeStart, end: builtEnd, requireEmpty: true)
        }
        return BatchOutcome(done: false, recordsScanned: scanned)
    }

    /// Java's `updateMaintainerBuilder`: indexes `record` in every target that covers its type.
    private func index(_ record: IndexableRecord, into maintainers: [(ErasedIndex, IndexMaintainer)],
                       _ store: FDBRecordStore, snapshot: Bool) async throws {
        var conflictAdded = false
        // Synthetic targets: index every synthetic record this record starts (as its first
        // constituent), so each synthetic record is built exactly once.
        for (index, maintainer) in maintainers {
            guard let typeName = index.syntheticTypeName, let type = store.metaData.syntheticType(named: typeName)
            else { continue }
            if snapshot && !conflictAdded {
                let (b, e) = store.recordsSubspace.subspace(record.primaryKey).range
                try store.transaction.addConflictRange(beginKey: b, endKey: e, type: .read)
                conflictAdded = true
            }
            for synthetic in try await store.syntheticRecords(type, containing: record, asFirstConstituentOnly: true) {
                try await maintainer.update(old: nil, new: synthetic.indexable(anchor: record))
            }
        }
        for (index, maintainer) in maintainers where record.recordType.indexes.contains(where: { $0.name == index.name }) {
            if snapshot && !conflictAdded {
                // Conflict on every key of this record (all its split suffixes and its version).
                let (b, e) = store.recordsSubspace.subspace(record.primaryKey).range
                try store.transaction.addConflictRange(beginKey: b, endKey: e, type: .read)
                conflictAdded = true
            }
            try await maintainer.update(old: nil, new: record)
        }
    }

    // MARK: - By index

    /// Java's `IndexingByIndex.getSourceIndex`.
    private func sourceIndex(_ attempt: Attempt, _ metaData: RecordMetaData) throws -> ErasedIndex {
        if let key = attempt.sourceIndexSubspaceKey {
            guard let index = metaData.allIndexes.first(where: { $0.subspaceTupleKey.encode() == key }) else {
                throw OnlineIndexerError.unusableSourceIndex("unknown source index subspace key \(RangeSet.printable(key))")
            }
            return index
        }
        if let name = attempt.sourceIndexName {
            guard let index = metaData.index(named: name) else {
                throw OnlineIndexerError.unusableSourceIndex("unknown source index \(name)")
            }
            return index
        }
        throw OnlineIndexerError.unusableSourceIndex("no source index")
    }

    /// Java's `IndexingByIndex.validateSourceAndTargetIndexes`.
    private func validateSourceAndTarget(_ metaData: RecordMetaData, _ attempt: Attempt) throws {
        let source = try sourceIndex(attempt, metaData)
        let target = try targets(metaData)[0]
        func check(_ valid: Bool, _ message: String) throws {
            if !valid { throw OnlineIndexerError.unusableSourceIndex("\(message) (source \(source.name), target \(target.name))") }
        }
        try check(target.syntheticTypeName == nil && target.recordTypeNames.count == 1, "target index has multiple types")
        try check(source.recordTypeNames.count == 1, "source index has multiple types")
        try check(source.syntheticTypeName == nil, "source index is on synthetic record types")
        try check(!source.producesMultipleKeys, "source index creates duplicates")
        try check(source.type == .value, "source index is not a VALUE index")
        try check(Set(target.recordTypeNames).isSuperset(of: source.recordTypeNames),
                  "source index's type is not equal to target index's")
    }

    /// One transaction of Java's `IndexingByIndex.buildRangeOnly`: the range set holds source
    /// entry keys (tuple-packed, relative to the source index's subspace).
    private func buildByIndexBatch(_ store: FDBRecordStore, _ attempt: Attempt, limit: Int) async throws -> BatchOutcome {
        let target = try targets(store.metaData)[0]
        guard store.indexState(named: target.name) == .writeOnly else {
            return BatchOutcome(done: true, recordsScanned: 0)
        }
        try await validateTypeStamps(store, [target], expected: indexingStamp(attempt, store.metaData))
        let source = try sourceIndex(attempt, store.metaData)
        guard store.indexState(named: source.name).isScannable else {
            throw OnlineIndexerError.unusableSourceIndex("source index \(source.name) is not scannable")
        }
        let rangeSet = store.indexRangeSet(target)
        guard let missing = try await rangeSet.missingRanges(store.transaction, limit: 1).first else {
            return BatchOutcome(done: true, recordsScanned: 0)
        }
        let rangeStart = RangeSet.nullIfFirst(missing.begin)
        let rangeEnd = RangeSet.nullIfFinal(missing.end)

        let maintainer = store.indexMaintainer(for: target)
        let maintainers = [(target, maintainer)]
        let snapshot = maintainer.isIdempotent
        let sourceSpace = store.indexSubspace(source)
        let (spaceBegin, spaceEnd) = sourceSpace.range
        let pkCount = source.primaryKeyColumnCount
        var scanned = 0
        var continuation: FDB.Bytes?
        for try await (key, _) in store.transaction.getRange(
            beginKey: rangeStart.map { sourceSpace.prefix + $0 } ?? spaceBegin,
            endKey: rangeEnd.map { sourceSpace.prefix + $0 } ?? spaceEnd,
            snapshot: snapshot) {
            let entryKey = Array(key.dropFirst(sourceSpace.prefix.count))
            if scanned == limit {
                continuation = entryKey
                break
            }
            scanned += 1
            let elements = try Tuple.decode(from: entryKey)
            guard elements.count >= pkCount else { throw RecordStoreError.corruptRecord }
            let primaryKey = Tuple(Array(elements.suffix(pkCount)))
            // A serializable load: the batch conflicts with any concurrent change to the record.
            guard let record = try await store.loadExisting(primaryKey)?.indexable else { continue }
            try await index(record, into: maintainers, store, snapshot: false)
        }
        _ = try await rangeSet.insertRange(store.transaction, begin: rangeStart, end: continuation ?? rangeEnd,
                                           requireEmpty: true)
        return BatchOutcome(done: false, recordsScanned: scanned)
    }

    // MARK: - Mutual

    /// Java's `IndexingMutuallyByRecords`: the primary-key space is split into fragments, visited
    /// in a random order with a random (prime) step so concurrent indexers rarely collide. The
    /// first pass builds only fragments nobody has started; the second any fragment with a gap.
    private func buildMutually(_ attempt: Attempt, _ throttle: inout Throttle) async throws {
        var boundaries: [Tuple?] = [nil]
        boundaries += (attempt.policy.mutualIndexingBoundaries ?? []).map { Optional($0) }
        boundaries.append(nil)
        let fragments: [RangeSet.Range] = (0..<(boundaries.count - 1)).map { i in
            (boundaries[i]?.encode() ?? RangeSet.firstKey, boundaries[i + 1]?.encode() ?? RangeSet.finalKey)
        }
        let count = fragments.count
        let step = Self.primeStep(count)
        let first = Int.random(in: 0..<count)
        var current = first
        var pass = 0   // 0: fully unbuilt fragments only; 1: any; 2: give up
        let primary = try targets(metaData)[0]

        while true {
            let missing: [RangeSet.Range] = try await run { store in
                guard store.indexState(named: primary.name) == .writeOnly else { return [] }
                return try await store.indexRangeSet(primary).missingRanges(store.transaction)
            }
            if missing.isEmpty { return }
            var toBuild: RangeSet.Range?
            while toBuild == nil {
                if pass >= 2 {
                    throw OnlineIndexerError.validation("mutual indexing failure - third iteration")
                }
                let fragment = fragments[current]
                toBuild = pass == 0 ? Self.fullyUnbuilt(missing, fragment) : Self.partlyUnbuilt(missing, fragment)
                if toBuild == nil {
                    current = (current + step) % count
                    if current == first { pass += 1 }
                }
            }
            let range = toBuild!
            try await iterateBatches(&throttle) { store, limit in
                try await self.buildByRecordsBatch(store, attempt, limit: limit, within: range)
            }
        }
    }

    /// Java's `getPrimeStep`: a step not dividing `size`, so the walk visits every fragment.
    static func primeStep(_ size: Int) -> Int {
        guard size >= 3 else { return 1 }
        func isPrime(_ n: Int) -> Bool {
            guard n >= 2 else { return false }
            var d = 2
            while d * d <= n { if n % d == 0 { return false }; d += 1 }
            return true
        }
        for _ in 0..<800 {
            var step = Int.random(in: 0..<size)
            if step & 1 == 0 { step -= 1 }
            if step < 2 { return 1 }
            if size % step != 0 && isPrime(step) { return step }
        }
        return 1
    }

    /// Java's `fullyUnBuiltRange`: the fragment, if a single missing range covers it.
    static func fullyUnbuilt(_ missing: [RangeSet.Range], _ fragment: RangeSet.Range) -> RangeSet.Range? {
        for range in missing where compare(range.end, fragment.end) >= 0 {
            if compare(range.begin, fragment.begin) <= 0 { return nonEmpty(fragment) }
            break
        }
        return nil
    }

    /// Java's `partlyUnBuiltRange`: the first part of the fragment that is still missing.
    static func partlyUnbuilt(_ missing: [RangeSet.Range], _ fragment: RangeSet.Range) -> RangeSet.Range? {
        for range in missing {
            if compare(range.begin, fragment.end) > 0 || compare(range.end, fragment.begin) < 0 { continue }
            let begin = compare(range.begin, fragment.begin) >= 0 ? range.begin : fragment.begin
            let end = compare(range.end, fragment.end) <= 0 ? range.end : fragment.end
            if compare(begin, end) < 0 { return nonEmpty((begin, end)) }
        }
        return nil
    }

    private static func nonEmpty(_ range: RangeSet.Range) -> RangeSet.Range? {
        compare(range.begin, range.end) >= 0 ? nil : range
    }

    static func compare(_ lhs: FDB.Bytes, _ rhs: FDB.Bytes) -> Int {
        if lhs == rhs { return 0 }
        return lhs.lexicographicallyPrecedes(rhs) ? -1 : 1
    }

    // MARK: - Transactions and throttling

    struct BatchOutcome: Sendable {
        let done: Bool
        let recordsScanned: Int
    }

    /// Java's `iterateAllRanges`: runs batches until one reports done, adapting the limit.
    private func iterateBatches(
        _ throttle: inout Throttle,
        _ batch: @escaping @Sendable (FDBRecordStore, Int) async throws -> BatchOutcome
    ) async throws {
        while true {
            let started = Date()
            let outcome: BatchOutcome
            do {
                let limit = throttle.limit
                outcome = try await run(batch: true) { store in try await batch(store, limit) }
            } catch let error as FDBError where Throttle.lessensWork(error) {
                try throttle.failed(error)
                continue
            }
            throttle.succeeded(scanned: outcome.recordsScanned)
            if outcome.done { break }
            if let stop = config.stopAfterBatches, throttle.batches >= stop { throw CancellationError() }
            try await throttle.pace(scanned: outcome.recordsScanned, since: started)
        }
    }

    /// Runs `body` in a fresh transaction with a checked-open store, committing on success.
    /// Retryable errors are retried here (with FDB backoff) — except, for a `batch`, the
    /// lessen-work ones, which propagate (after the backoff) so the caller can shrink the batch.
    private func run<T: Sendable>(batch: Bool = false,
                                  _ body: @Sendable (FDBRecordStore) async throws -> T) async throws -> T {
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
                if batch && Throttle.lessensWork(error) {
                    if error.isRetryable { try? await transaction.onError(error) }
                    throw error
                }
                attempts += 1
                guard error.isRetryable, attempts < config.maxRetries else { throw error }
                try await transaction.onError(error)
            }
        }
    }

    /// Java's `IndexingThrottle.Booker`: adapts the per-transaction record limit.
    struct Throttle {
        let config: Config
        private(set) var limit: Int
        private var consecutiveFailures = 0
        private var consecutiveSuccesses = 0
        private var lastAttempted: Int
        /// Committed batches so far.
        private(set) var batches = 0

        init(config: Config) {
            self.config = config
            let initial = min(config.initialLimit ?? config.maxLimit, config.maxLimit)
            self.limit = max(1, initial)
            self.lastAttempted = limit
        }

        /// FDB errors that mean "do less per transaction" (Java's `lessenWorkCodes`).
        static func lessensWork(_ error: FDBError) -> Bool {
            [1004, 1007, 1020, 1031, 1039, 2101].contains(Int(error.code))
        }

        mutating func failed(_ error: FDBError) throws {
            consecutiveFailures += 1
            consecutiveSuccesses = 0
            guard consecutiveFailures <= config.maxRetries else { throw error }
            let factor: Int
            switch consecutiveFailures {
            case 8...: factor = 1           // panic mode after the 7th failure
            case 4...: factor = 5           // 50% after the third failure
            default: factor = 10 - max(1, consecutiveFailures)
            }
            lastAttempted = limit
            limit = max(1, min(lastAttempted - 1, lastAttempted * factor / 10))
        }

        mutating func succeeded(scanned: Int) {
            consecutiveFailures = 0
            batches += 1
            guard let after = config.increaseLimitAfter, limit < config.maxLimit else { return }
            if consecutiveSuccesses >= after {
                let increased = limit < 5 ? limit + 5 : limit < 100 ? limit * 2 : limit * 4 / 3
                limit = min(config.maxLimit, max(limit + 1, increased))
                consecutiveSuccesses = 0
            } else {
                consecutiveSuccesses += 1
            }
        }

        /// Sleeps as needed to stay under `recordsPerSecond`.
        func pace(scanned: Int, since start: Date) async throws {
            guard let rate = config.recordsPerSecond, rate > 0, scanned > 0 else { return }
            let target = Double(scanned) / Double(rate)
            let elapsed = Date().timeIntervalSince(start)
            let wait = min(0.999, target - elapsed)
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
    }
}

extension DatabaseProtocol where Self: RecordTransactionSource {
    /// Builds (backfills) an index online and marks it readable. See ``OnlineIndexer``.
    public func buildIndex(
        subspace: Subspace, metaData: RecordMetaData, indexName: String,
        config: OnlineIndexer.Config = OnlineIndexer.Config()
    ) async throws {
        try await OnlineIndexer(source: self, subspace: subspace, metaData: metaData, indexName: indexName, config: config)
            .buildIndex()
    }

    /// Builds an index for a store opened at `path`.
    public func buildIndex(
        path: KeySpacePath, metaData: RecordMetaData, indexName: String,
        config: OnlineIndexer.Config = OnlineIndexer.Config()
    ) async throws {
        try await buildIndex(subspace: path.toSubspace(), metaData: metaData, indexName: indexName, config: config)
    }

    /// Builds several indexes online — in one records scan, or from `sourceIndex` — and marks
    /// them readable. See ``OnlineIndexer``.
    public func buildIndexes(
        subspace: Subspace, metaData: RecordMetaData, targetIndexes: [String], sourceIndex: String? = nil,
        policy: OnlineIndexer.IndexingPolicy = OnlineIndexer.IndexingPolicy(),
        config: OnlineIndexer.Config = OnlineIndexer.Config()
    ) async throws {
        try await OnlineIndexer(source: self, subspace: subspace, metaData: metaData, targetIndexes: targetIndexes,
                                sourceIndex: sourceIndex, policy: policy, config: config)
            .buildIndex()
    }
}

extension FDBTenant {
    /// Builds an index over a tenant-scoped store. See ``OnlineIndexer``.
    public func buildIndex(
        subspace: Subspace, metaData: RecordMetaData, indexName: String,
        config: OnlineIndexer.Config = OnlineIndexer.Config()
    ) async throws {
        try await OnlineIndexer(source: self, subspace: subspace, metaData: metaData, indexName: indexName, config: config)
            .buildIndex()
    }
}
#endif
