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
public final class FDBRecordContext {
    /// The underlying transaction. Reads/writes issued here join the context's transaction.
    public let transaction: any TransactionProtocol

    /// Monotonic counter used to disambiguate multiple record versions written in one
    /// transaction (see version indexes).
    private var versionCounter: Int = 0

    /// Wraps an existing transaction in a record context.
    public init(transaction: any TransactionProtocol) {
        self.transaction = transaction
    }

    /// Returns the next local version number within this transaction.
    func nextLocalVersion() -> Int {
        defer { versionCounter += 1 }
        return versionCounter
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
#endif
