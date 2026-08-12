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

/// A transaction-scoped handle through which record stores operate.
///
/// `FDBRecordContext` is a thin wrapper over a ``TransactionProtocol``: every record store
/// reads and writes through the same context, so all operations within it are part of one
/// FoundationDB transaction and commit (or roll back) atomically.
///
/// The most convenient way to obtain one is ``FoundationDB/DatabaseProtocol/withRecordContext(_:)``,
/// which runs the body inside the base bindings' retry loop and commits on success:
///
/// ```swift
/// try await database.withRecordContext { context in
///     let store = try await FDBRecordStore.open(context: context, path: path, metaData: meta)
///     _ = try await store.save(order)
/// }
/// ```
/// A context is `Sendable`: the transaction it wraps is itself `Sendable`, so the same context
/// (and stores opened on it) may be shared by concurrent tasks within one transaction.
public final class FDBRecordContext: Sendable {
    /// The underlying transaction. Reads/writes issued here join the context's transaction.
    public let transaction: any TransactionProtocol

    /// Monotonic counter used to disambiguate multiple record versions written in one
    /// transaction (see version indexes). Atomic so concurrent tasks sharing the context
    /// cannot hand out the same local version twice.
    private let versionCounter = Atomic<Int>(0)

    /// Wraps an existing transaction in a record context.
    public init(transaction: any TransactionProtocol) {
        self.transaction = transaction
    }

    /// Returns the next local version number within this transaction.
    func nextLocalVersion() -> Int {
        versionCounter.wrappingAdd(1, ordering: .relaxed).oldValue
    }

    /// Commits the underlying transaction.
    ///
    /// Not needed when using ``FoundationDB/DatabaseProtocol/withRecordContext(_:)``, which
    /// commits automatically.
    @discardableResult
    public func commit() async throws -> Bool {
        try await transaction.commit()
    }
}

extension DatabaseProtocol {
    /// Runs `operation` inside a record context, using the base bindings' automatic retry
    /// loop, committing the transaction if the body returns successfully.
    public func withRecordContext<T: Sendable>(
        _ operation: (FDBRecordContext) async throws -> T
    ) async throws -> T {
        try await withTransaction { transaction in
            try await operation(FDBRecordContext(transaction: transaction))
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
            try await operation(FDBRecordContext(transaction: transaction))
        }
    }
}
#endif
