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

import Foundation

/// Parsed metadata for a tenant, decoded from its tenant-map entry.
public struct TenantInfo: Sendable, Hashable {
    /// The tenant's name.
    public let name: FDB.Bytes
    /// The cluster-assigned tenant id.
    public let id: Int64
    /// The key prefix under which the tenant's data is stored.
    public let prefix: FDB.Bytes
}

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

    /// Returns parsed metadata (id, prefix) for a tenant, or `nil` if it does not exist.
    public func tenantInfo(name: FDB.Bytes) async throws -> TenantInfo? {
        let key = Self.tenantMapPrefix + name
        return try await withTransaction { transaction in
            guard let value = try await transaction.getValue(for: key) else { return nil }
            return Self.parseTenantInfo(name: name, json: value)
        }
    }

    /// Returns parsed metadata for a tenant by name string.
    public func tenantInfo(name: String) async throws -> TenantInfo? {
        try await tenantInfo(name: Array(name.utf8))
    }

    /// Lists existing tenants with parsed metadata (up to `limit`).
    public func listTenantsInfo(limit: Int = 100) async throws -> [TenantInfo] {
        let prefix = Self.tenantMapPrefix
        let begin = prefix
        let end = Self.strinc(prefix)
        return try await withTransaction { transaction in
            var infos: [TenantInfo] = []
            for try await (key, value) in transaction.getRange(beginKey: begin, endKey: end) {
                if infos.count >= limit { break }
                guard key.count > prefix.count else { continue }
                let name = Array(key[prefix.count...])
                if let info = Self.parseTenantInfo(name: name, json: value) { infos.append(info) }
            }
            return infos
        }
    }

    /// Parses a tenant-map JSON value: `{"id": N, "prefix": {"base64": "..."}, ...}`.
    private static func parseTenantInfo(name: FDB.Bytes, json: FDB.Bytes) -> TenantInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json)) as? [String: Any],
              let id = (object["id"] as? NSNumber)?.int64Value,
              let prefixObject = object["prefix"] as? [String: Any],
              let prefixBase64 = prefixObject["base64"] as? String,
              let prefixData = Data(base64Encoded: prefixBase64)
        else {
            return nil
        }
        return TenantInfo(name: name, id: id, prefix: FDB.Bytes(prefixData))
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
