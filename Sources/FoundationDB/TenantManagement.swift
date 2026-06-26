/*
 * TenantManagement.swift
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

/// Tenant lifecycle management via the FoundationDB management special key space.
///
/// Tenants live under `\xff\xff/management/tenant/map/<name>`: writing the key creates a
/// tenant, clearing it deletes one, and a range read lists them. Writes to the special key
/// space require the `specialKeySpaceEnableWrites` transaction option.
///
/// The cluster must have `tenant_mode` set to something other than `disabled` (e.g.
/// `fdbcli --exec 'configure tenant_mode=optional'`), otherwise creation fails.
extension FDBDatabase {
    /// The `\xff\xff/management/tenant/map/` prefix.
    private static var tenantMapPrefix: FDB.Bytes {
        [0xFF, 0xFF] + Array("/management/tenant/map/".utf8)
    }

    /// Creates a tenant with the given name. No-op semantics if it already exists are
    /// determined by the cluster.
    public func createTenant(name: FDB.Bytes) async throws {
        let key = Self.tenantMapPrefix + name
        try await withTransaction { transaction in
            try transaction.setOption(forOption: .specialKeySpaceEnableWrites)
            transaction.setValue([], for: key)
        }
    }

    /// Creates a tenant with the given name string.
    public func createTenant(name: String) async throws {
        try await createTenant(name: Array(name.utf8))
    }

    /// Deletes the tenant with the given name. The tenant must be empty.
    public func deleteTenant(name: FDB.Bytes) async throws {
        let key = Self.tenantMapPrefix + name
        try await withTransaction { transaction in
            try transaction.setOption(forOption: .specialKeySpaceEnableWrites)
            transaction.clear(key: key)
        }
    }

    /// Deletes the tenant with the given name string.
    public func deleteTenant(name: String) async throws {
        try await deleteTenant(name: Array(name.utf8))
    }

    /// Lists existing tenant names (up to `limit`).
    public func listTenants(limit: Int = 100) async throws -> [FDB.Bytes] {
        let prefix = Self.tenantMapPrefix
        let begin = prefix
        let end = Self.strinc(prefix)
        return try await withTransaction { transaction in
            var names: [FDB.Bytes] = []
            for try await (key, _) in transaction.getRange(beginKey: begin, endKey: end) {
                if names.count >= limit { break }
                if key.count > prefix.count {
                    names.append(Array(key[prefix.count...]))
                }
            }
            return names
        }
    }

    /// The smallest key greater than every key with the given prefix (prefix successor).
    private static func strinc(_ prefix: FDB.Bytes) -> FDB.Bytes {
        var bytes = prefix
        while let last = bytes.last {
            if last == 0xFF {
                bytes.removeLast()
            } else {
                bytes[bytes.count - 1] = last + 1
                return bytes
            }
        }
        return bytes
    }
}
