/*
 * TestSupport.swift
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

/// Serializes one-time FoundationDB client initialization across parallel tests.
///
/// `FDBClient.initialize()` may only be called once per process; this actor guards it so the
/// many integration suites can each ask for a database without racing.
actor FDBBootstrap {
    static let shared = FDBBootstrap()
    private var started = false

    func ensureInitialized() async throws {
        if !started {
            if !FDBClient.isInitialized {
                try await FDBClient.initialize()
            }
            started = true
        }
    }
}

/// Common scaffolding for Record Layer integration tests that need a live cluster.
enum RecordLayerTestCase {
    /// Builds the standard test metadata used across suites: `Order` (with a price index and a
    /// fan-out tag index) and `Item` (keyed by SKU, indexed by category).
    static func standardMetaData() -> RecordMetaData {
        RecordMetaData {
            RecordType(Fdb_Test_Order.self, primaryKey: \.orderID)
                .index("order.price", on: \.price)
                .index("order.byTag", on: \.tags, fanType: .fanOut)
                .index("order.customerName", on: \.customer.name)
                .index("order.flowerPrice", on: .concat(.field(\.flower), .field(\.price)))
            RecordType(Fdb_Test_Item.self, primaryKey: \.sku)
                .index("item.category", on: \.category)
        }
    }

    /// Metadata exercising advanced index types: a rank and a version index on `Order`, and
    /// `count`/`sum` aggregate indexes (grouped by category) on `Item`.
    static func advancedMetaData() -> RecordMetaData {
        RecordMetaData {
            RecordType(Fdb_Test_Order.self, primaryKey: \.orderID)
                .index("order.priceRank", on: \.price, type: .rank)
                .index("order.version", on: .version(), type: .version)
            RecordType(Fdb_Test_Item.self, primaryKey: \.sku)
                .index("item.countByCategory", on: .field(\.category), type: .count)
                .index(
                    "item.sumQtyByCategory",
                    on: .concat(.field(\.category), .field(\.quantity)),
                    type: .sum
                )
                .index(
                    "item.minQtyByCategory",
                    on: .concat(.field(\.category), .field(\.quantity)),
                    type: .min
                )
                .index(
                    "item.maxQtyByCategory",
                    on: .concat(.field(\.category), .field(\.quantity)),
                    type: .max
                )
        }
    }

    /// Runs `body` against a freshly opened store in a unique, isolated subspace, cleaning up
    /// all data afterwards. The store is reopened for each transaction the body requests.
    ///
    /// - Parameter body: receives a factory that opens a store within a new transaction.
    static func withStore(
        metaData: RecordMetaData = standardMetaData(),
        _ body: (_ run: StoreRunner) async throws -> Void
    ) async throws {
        try await FDBBootstrap.shared.ensureInitialized()
        let database = try FDBClient.openDatabase()
        let subspace = Subspace(Tuple("fdbrl-test", UUID().uuidString))
        let runner = StoreRunner(database: database, subspace: subspace, metaData: metaData)
        do {
            try await body(runner)
        } catch {
            try? await runner.cleanup()
            throw error
        }
        try await runner.cleanup()
    }
}

/// Opens a store inside its own transaction for each call, so tests can observe committed
/// state across transaction boundaries.
struct StoreRunner {
    let database: FDBDatabase
    let subspace: Subspace
    let metaData: RecordMetaData

    /// Runs `operation` in a new transaction with a freshly opened store, committing on success.
    @discardableResult
    func callAsFunction<T: Sendable>(
        _ operation: (FDBRecordStore) async throws -> T
    ) async throws -> T {
        try await database.withRecordContext { context in
            let store = try await FDBRecordStore.open(
                context: context, subspace: subspace, metaData: metaData)
            return try await operation(store)
        }
    }

    func cleanup() async throws {
        try await database.withRecordContext { context in
            let store = try await FDBRecordStore.open(
                context: context, subspace: subspace, metaData: metaData)
            try await store.deleteAllRecords()
        }
    }
}

/// Convenience builders for sample records.
extension Fdb_Test_Order {
    static func sample(
        id: Int64, flower: String = "rose", price: Int64 = 10,
        customer: String = "alice", tags: [String] = []
    ) -> Fdb_Test_Order {
        var order = Fdb_Test_Order()
        order.orderID = id
        order.flower = flower
        order.price = price
        order.customer.id = 1
        order.customer.name = customer
        order.tags = tags
        return order
    }
}

extension Fdb_Test_Item {
    static func sample(sku: String, name: String = "thing", quantity: Int64 = 1,
                       category: String = "general") -> Fdb_Test_Item {
        var item = Fdb_Test_Item()
        item.sku = sku
        item.name = name
        item.quantity = quantity
        item.category = category
        return item
    }
}
#endif
