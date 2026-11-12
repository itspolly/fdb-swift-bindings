/*
 * FDBRecordContext.swift
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
import FoundationDB
import Synchronization

/// A transaction-scoped handle through which record stores operate — Java's `FDBRecordContext`.
///
/// `FDBRecordContext` wraps a ``TransactionProtocol``: every record store reads and writes
/// through the same context, so all operations within it are part of one FoundationDB
/// transaction and commit (or roll back) atomically.
///
/// Besides the transaction, a context holds the per-transaction state the Java layer keeps on
/// its context:
/// - the **local version** counter that keeps versions of records saved in one transaction
///   distinct;
/// - the **version mutation cache**: versionstamped writes (record versions and version-index
///   entries) are buffered here and applied just before commit. FoundationDB forbids reading a
///   key written with a versionstamp mutation in the same transaction, so buffering lets later
///   operations in the transaction see (and replace or cancel) those writes;
/// - **commit checks** that must pass before the transaction may commit.
///
/// The most convenient way to obtain one is ``FoundationDB/DatabaseProtocol/withRecordContext(_:)``,
/// which runs the body inside the base bindings' retry loop, runs the pre-commit work, and
/// commits on success:
///
/// ```swift
/// try await database.withRecordContext { context in
///     let store = try await FDBRecordStore.open(context: context, path: path, metaData: meta)
///     _ = try await store.save(order)
/// }
/// ```
/// When committing manually, use ``commit()`` rather than committing the transaction directly,
/// or the buffered version mutations are lost.
///
/// A context is `Sendable` and may be shared by concurrent tasks within one transaction.
public final class FDBRecordContext: VersionMutationCache, Sendable {
    /// The underlying transaction. Reads/writes issued here join the context's transaction.
    public let transaction: any TransactionProtocol

    /// Monotonic counter used to disambiguate multiple record versions written in one
    /// transaction. Atomic so concurrent tasks sharing the context never share a local version.
    private let versionCounter = Atomic<Int>(0)

    private struct VersionMutation: Sendable {
        let mutationType: FDB.MutationType
        let value: FDB.Bytes
    }

    private struct State: Sendable {
        /// Record version key → local version, for records saved in this transaction.
        var localVersions: [FDB.Bytes: Int] = [:]
        /// Versionstamped-key/value writes to apply at commit, keyed by the mutation's key.
        var versionMutations: [FDB.Bytes: VersionMutation] = [:]
        /// Checks that must succeed before commit, keyed by name so each is added once.
        var commitChecks: [(name: String, check: @Sendable () async throws -> Void)] = []
        var committed = false
        /// The meta-data version stamp was written in this transaction (it can't be read back).
        var dirtyMetaDataVersionStamp = false
        /// Some store's cached state (header / index states) was changed in this transaction.
        var dirtyStoreState = false
    }

    private let state = Mutex(State())

    /// Wraps an existing transaction in a record context.
    public init(transaction: any TransactionProtocol) {
        self.transaction = transaction
    }

    // MARK: Local versions

    /// Claims the next local version, rejecting one that no longer fits the 2 bytes reserved for
    /// it in ``FDBRecordVersion`` (Java's `claimLocalVersion`).
    func claimLocalVersion() throws -> Int {
        let value = versionCounter.wrappingAdd(1, ordering: .relaxed).oldValue
        guard value <= Int(UInt16.max) else { throw RecordStoreError.localVersionExhausted }
        return value
    }

    func addToLocalVersionCache(key: FDB.Bytes, localVersion: Int) {
        state.withLock { $0.localVersions[key] = localVersion }
    }

    @discardableResult
    func removeLocalVersion(key: FDB.Bytes) -> Bool {
        state.withLock { $0.localVersions.removeValue(forKey: key) != nil }
    }

    /// The local version of a record saved earlier in this transaction whose version key is
    /// `key`, if any.
    func getLocalVersion(key: FDB.Bytes) -> Int? {
        state.withLock { $0.localVersions[key] }
    }

    // MARK: Version mutations

    /// Buffers a versionstamped mutation to apply at commit, replacing any earlier one on the
    /// same key (Java's `addVersionMutation`).
    @discardableResult
    func addVersionMutation(_ mutationType: FDB.MutationType, key: FDB.Bytes, value: FDB.Bytes) -> FDB.Bytes? {
        state.withLock {
            $0.versionMutations.updateValue(VersionMutation(mutationType: mutationType, value: value), forKey: key)?.value
        }
    }

    /// Buffers a versionstamped mutation, merging with any earlier one on the same key (Java's
    /// `updateVersionMutation`).
    func updateVersionMutation(
        _ mutationType: FDB.MutationType, key: FDB.Bytes, value: FDB.Bytes,
        merge: (FDB.Bytes, FDB.Bytes) -> FDB.Bytes
    ) {
        state.withLock { state in
            let merged = state.versionMutations[key].map { merge($0.value, value) } ?? value
            state.versionMutations[key] = VersionMutation(mutationType: mutationType, value: merged)
        }
    }

    /// Cancels a buffered versionstamped mutation (Java's `removeVersionMutation`).
    @discardableResult
    func removeVersionMutation(key: FDB.Bytes) -> FDB.Bytes? {
        state.withLock { $0.versionMutations.removeValue(forKey: key)?.value }
    }

    /// Whether a versionstamped mutation is buffered for `key`.
    func hasVersionMutation(key: FDB.Bytes) -> Bool {
        state.withLock { $0.versionMutations[key] != nil }
    }

    // MARK: Meta-data version stamp (store-state caching)

    /// FoundationDB's cluster-wide `\xff/metadataVersion` key.
    static let metaDataVersionKey: FDB.Bytes = [0xFF] + Array("/metadataVersion".utf8)

    /// Reads the cluster's meta-data version stamp, or `nil` if this transaction already
    /// changed it (Java's `getMetaDataVersionStampAsync`).
    func metaDataVersionStamp(snapshot: Bool = true) async throws -> FDB.Bytes? {
        if state.withLock({ $0.dirtyMetaDataVersionStamp }) { return nil }
        do {
            return try await transaction.getValue(for: Self.metaDataVersionKey, snapshot: snapshot)
        } catch let error as FDBError where error.code == 1036 { // accessed_unreadable
            state.withLock { $0.dirtyMetaDataVersionStamp = true }
            return nil
        }
    }

    /// Bumps the cluster's meta-data version stamp at commit, invalidating every client's cached
    /// store states (Java's `setMetaDataVersionStamp`).
    func setMetaDataVersionStamp() {
        state.withLock { $0.dirtyMetaDataVersionStamp = true }
        transaction.atomicOp(
            key: Self.metaDataVersionKey, param: FDB.Bytes(repeating: 0, count: 14),
            mutationType: .setVersionstampedValue)
    }

    var hasDirtyStoreState: Bool { state.withLock { $0.dirtyStoreState } }
    func markStoreStateDirty() { state.withLock { $0.dirtyStoreState = true } }

    // MARK: Commit

    /// Registers a check to run before commit; a check with the same name is added only once.
    func addCommitCheck(named name: String, _ check: @escaping @Sendable () async throws -> Void) {
        state.withLock { state in
            if !state.commitChecks.contains(where: { $0.name == name }) {
                state.commitChecks.append((name, check))
            }
        }
    }

    /// Runs commit checks and applies buffered version mutations. Called by
    /// ``commit()`` and by `withRecordContext` before the base retry loop commits.
    func runPreCommit() async throws {
        let checks = state.withLock { state -> [@Sendable () async throws -> Void] in
            defer { state.commitChecks.removeAll() }
            return state.commitChecks.map(\.check)
        }
        for check in checks { try await check() }
        let mutations = state.withLock { state -> [(FDB.Bytes, VersionMutation)] in
            defer { state.versionMutations.removeAll(); state.committed = true }
            return state.versionMutations.map { ($0.key, $0.value) }
                .sorted { $0.0.lexicographicallyPrecedes($1.0) }
        }
        for (key, mutation) in mutations {
            transaction.atomicOp(key: key, param: mutation.value, mutationType: mutation.mutationType)
        }
    }

    /// Runs pre-commit work and commits the underlying transaction.
    ///
    /// Not needed when using ``FoundationDB/DatabaseProtocol/withRecordContext(_:)``, which
    /// commits automatically.
    @discardableResult
    public func commit() async throws -> Bool {
        try await runPreCommit()
        return try await transaction.commit()
    }
}

extension DatabaseProtocol {
    /// Runs `operation` inside a record context, using the base bindings' automatic retry
    /// loop, running pre-commit work and committing the transaction if the body succeeds.
    public func withRecordContext<T: Sendable>(
        _ operation: (FDBRecordContext) async throws -> T
    ) async throws -> T {
        try await withTransaction { transaction in
            let context = FDBRecordContext(transaction: transaction)
            let result = try await operation(context)
            try await context.runPreCommit()
            return result
        }
    }
}

extension FDBTenant {
    /// Runs `operation` inside a record context scoped to this tenant.
    ///
    /// A record store opened with the resulting context lives entirely within the tenant's key
    /// space, so two tenants can host independent stores at the same subspace/primary keys.
    public func withRecordContext<T: Sendable>(
        _ operation: (FDBRecordContext) async throws -> T
    ) async throws -> T {
        try await withTransaction { transaction in
            let context = FDBRecordContext(transaction: transaction)
            let result = try await operation(context)
            try await context.runPreCommit()
            return result
        }
    }
}
#endif
