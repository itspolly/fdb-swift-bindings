/*
 * Tenant.swift
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

import CFoundationDB

/// A handle to a FoundationDB *tenant* — a named, server-isolated key space within a database.
///
/// Transactions created from a tenant operate entirely within that tenant's key space: keys
/// are implicitly prefixed and isolated, so two tenants can use identical keys without
/// colliding. Open one with ``FDBDatabase/openTenant(name:)`` (the tenant must already exist —
/// see ``FDBDatabase/createTenant(name:)``).
///
/// Mirrors ``FDBDatabase``: it wraps the C tenant handle (thread-safe, hence
/// `@unchecked Sendable`) and frees it on `deinit`. Native tenants require API version ≥ 720
/// (the default is 730).
public final class FDBTenant: @unchecked Sendable {
    /// The underlying FoundationDB tenant pointer (thread-safe to use concurrently).
    private let tenant: OpaquePointer

    init(tenant: OpaquePointer) {
        self.tenant = tenant
    }

    deinit {
        fdb_tenant_destroy(tenant)
    }

    /// Creates a new transaction scoped to this tenant.
    public func createTransaction() throws -> FDBTransaction {
        var transaction: OpaquePointer?
        let error = fdb_tenant_create_transaction(tenant, &transaction)
        if error != 0 {
            throw FDBError(code: error)
        }
        guard let tr = transaction else {
            throw FDBError(.internalError)
        }
        return FDBTransaction(transaction: tr)
    }

    /// Executes `operation` in a tenant-scoped transaction, retrying on retryable errors and
    /// committing on success — the tenant analogue of ``DatabaseProtocol/withTransaction(_:)``.
    public func withTransaction<T: Sendable>(
        _ operation: (TransactionProtocol) async throws -> T
    ) async throws -> T {
        try await runTransaction(creating: { try createTransaction() }, operation)
    }

    /// The tenant's unique integer id, assigned by the cluster at creation.
    public func id() async throws -> FDB.Version {
        guard let result = try await Future<ResultInt64>(fdb_tenant_get_id(tenant)).getAsync() else {
            throw FDBError(.internalError)
        }
        return result.value
    }
}
