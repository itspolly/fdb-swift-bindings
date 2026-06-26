/*
 * TenantRecordStoreTests.swift
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

/// Record stores opened in different tenants are fully isolated, even at identical subspaces
/// and primary keys. Requires a cluster with `tenant_mode` ≠ `disabled`.
@Suite("Tenant + record store (integration)", .serialized)
struct TenantRecordStoreTests {
    @Test("stores in different tenants are independent at the same subspace/primary key")
    func tenantScopedStores() async throws {
        try await FDBBootstrap.shared.ensureInitialized()
        let db = try FDBClient.openDatabase()
        let meta = RecordLayerTestCase.standardMetaData()
        let subspace = Subspace(Tuple("orders")) // identical in both tenants

        let nameA = "fdbswift-rl-\(UUID().uuidString)"
        let nameB = "fdbswift-rl-\(UUID().uuidString)"
        try await db.createTenant(name: nameA)
        try await db.createTenant(name: nameB)
        let tenantA = try db.openTenant(name: nameA)
        let tenantB = try db.openTenant(name: nameB)

        // Same primary key (1) and subspace, different data, in each tenant.
        try await tenantA.withRecordContext { context in
            let store = try await FDBRecordStore.open(context: context, subspace: subspace, metaData: meta)
            _ = try await store.save(Fdb_Test_Order.sample(id: 1, flower: "rose"))
        }
        try await tenantB.withRecordContext { context in
            let store = try await FDBRecordStore.open(context: context, subspace: subspace, metaData: meta)
            _ = try await store.save(Fdb_Test_Order.sample(id: 1, flower: "tulip"))
        }

        let flowerA = try await tenantA.withRecordContext { context in
            let store = try await FDBRecordStore.open(context: context, subspace: subspace, metaData: meta)
            return try await store.load(Fdb_Test_Order.self, Int64(1))?.record.flower
        }
        let flowerB = try await tenantB.withRecordContext { context in
            let store = try await FDBRecordStore.open(context: context, subspace: subspace, metaData: meta)
            return try await store.load(Fdb_Test_Order.self, Int64(1))?.record.flower
        }
        #expect(flowerA == "rose")
        #expect(flowerB == "tulip")

        // Cleanup: empty each tenant, then delete it.
        for tenant in [tenantA, tenantB] {
            try await tenant.withTransaction { $0.clearRange(beginKey: [], endKey: [0xFF]) }
        }
        try await db.deleteTenant(name: nameA)
        try await db.deleteTenant(name: nameB)
    }
}
#endif
