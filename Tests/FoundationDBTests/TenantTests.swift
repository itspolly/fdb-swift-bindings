/*
 * TenantTests.swift
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
import Testing

import FoundationDB

/// Integration tests for native FoundationDB tenants.
///
/// Requires a running cluster with `tenant_mode` ≠ `disabled`
/// (`fdbcli --exec 'configure tenant_mode=optional_experimental'`).
@Suite("Tenants (integration)", .serialized)
struct TenantTests {
    private func database() async throws -> FDBDatabase {
        try await FDBClient.maybeInitialize()
        return try FDBClient.openDatabase()
    }

    private func uniqueName() -> String { "fdbswift-test-\(UUID().uuidString)" }

    /// Clears a tenant's entire key space so it can be deleted (tenants must be empty).
    private func emptyTenant(_ tenant: FDBTenant) async throws {
        try await tenant.withTransaction { transaction in
            transaction.clearRange(beginKey: [], endKey: [0xFF])
        }
    }

    @Test("create, list, and delete a tenant")
    func lifecycle() async throws {
        let db = try await database()
        let name = uniqueName()

        try await db.createTenant(name: name)
        let listed = try await db.listTenants(limit: 10_000)
        #expect(listed.contains { String(decoding: $0, as: UTF8.self) == name })

        try await db.deleteTenant(name: name)
        let listedAfter = try await db.listTenants(limit: 10_000)
        #expect(!listedAfter.contains { String(decoding: $0, as: UTF8.self) == name })
    }

    @Test("tenant transactions are isolated from the default key space and other tenants")
    func isolation() async throws {
        let db = try await database()
        let nameA = uniqueName()
        let nameB = uniqueName()
        try await db.createTenant(name: nameA)
        try await db.createTenant(name: nameB)
        let tenantA = try db.openTenant(name: nameA)
        let tenantB = try db.openTenant(name: nameB)

        // Unique key so a parallel suite writing to the default key space can't interfere.
        let key = [UInt8]("k-\(UUID().uuidString)".utf8)
        let value = [UInt8]("value-A".utf8)

        try await tenantA.withTransaction { $0.setValue(value, for: key) }

        let inA = try await tenantA.withTransaction { try await $0.getValue(for: key) }
        #expect(inA == value)

        // The same key is absent in tenant B and in the default (non-tenant) key space.
        let inB = try await tenantB.withTransaction { try await $0.getValue(for: key) }
        #expect(inB == nil)
        let inDefault = try await db.withTransaction { try await $0.getValue(for: key) }
        #expect(inDefault == nil)

        // Each tenant has an id.
        let idA = try await tenantA.id()
        let idB = try await tenantB.id()
        #expect(idA != idB)

        // Cleanup.
        try await emptyTenant(tenantA)
        try await emptyTenant(tenantB)
        try await db.deleteTenant(name: nameA)
        try await db.deleteTenant(name: nameB)
    }

    @Test("tenantInfo and listTenantsInfo parse id and prefix")
    func metadata() async throws {
        let db = try await database()
        let name = uniqueName()
        try await db.createTenant(name: name)

        let info = try await db.tenantInfo(name: name)
        #expect(info != nil)
        #expect((info?.id ?? -1) >= 0)
        #expect(!(info?.prefix.isEmpty ?? true))

        let listed = try await db.listTenantsInfo(limit: 10_000)
        #expect(listed.contains { String(decoding: $0.name, as: UTF8.self) == name && $0.id == info?.id })

        try await db.deleteTenant(name: name)
        let after = try await db.tenantInfo(name: name)
        #expect(after == nil)
    }

    @Test("a tenant opened with an authorization token creates transactions without error")
    func authorizationToken() async throws {
        let db = try await database()
        let name = uniqueName()
        try await db.createTenant(name: name)

        // A non-JWT token still attaches as a local transaction option; we assert the handle
        // creates transactions (the option is applied) — full token auth needs a configured cluster.
        let tenant = try db.openTenant(name: name, authorizationToken: [UInt8]("test-token".utf8))
        let transaction = try tenant.createTransaction()
        transaction.cancel()

        try await db.deleteTenant(name: name)
    }
}
