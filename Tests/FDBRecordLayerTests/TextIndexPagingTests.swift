/*
 * TextIndexPagingTests.swift
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

/// Paged text searches, resumed in fresh transactions, must return exactly what an unpaged
/// search does.
@Suite("Text index paging (integration)", .serialized)
struct TextIndexPagingTests {
    private let meta = RecordMetaData {
        RecordType(Fdb_Test_Item.self, primaryKey: \.sku).index("item.text", on: \.name, type: .text)
    }

    /// 90 records over several bunches per token (bunch size 20).
    private func populate(_ db: FDBDatabase, _ subspace: Subspace) async throws {
        let words = ["apple", "apricot", "banana", "blueberry", "cherry", "coconut", "date"]
        try await db.withRecordContext { context in
            let store = try await FDBRecordStore.open(context: context, subspace: subspace, metaData: meta)
            for i in 0..<90 {
                let name = (0..<3).map { words[(i * ($0 + 1) + $0) % words.count] }.joined(separator: " ")
                _ = try await store.save(Fdb_Test_Item.sample(sku: String(format: "s%03d", i), name: name))
            }
        }
    }

    private func all(_ db: FDBDatabase, _ subspace: Subspace, _ comparison: TextComparison) async throws -> [Tuple] {
        try await db.withRecordContext { context in
            let store = try await FDBRecordStore.open(context: context, subspace: subspace, metaData: meta)
            return try await store.textSearchPrimaryKeys(Fdb_Test_Item.self, indexNamed: "item.text", comparison)
        }
    }

    /// Reads every page, each in its own transaction.
    private func paged(_ db: FDBDatabase, _ subspace: Subspace, _ comparison: TextComparison, limit: Int) async throws -> [Tuple] {
        var result: [Tuple] = []
        var continuation: FDB.Bytes?
        var pages = 0
        repeat {
            let page = try await db.withRecordContext { context in
                let store = try await FDBRecordStore.open(context: context, subspace: subspace, metaData: meta)
                return try await store.textSearchPrimaryKeys(
                    Fdb_Test_Item.self, indexNamed: "item.text", comparison, limit: limit, continuation: continuation)
            }
            #expect(page.primaryKeys.count <= limit)
            result += page.primaryKeys
            continuation = page.continuation
            pages += 1
        } while continuation != nil && pages < 1000
        return result
    }

    @Test("ordered searches page exactly like the unpaged search", arguments: [1, 3, 7, 25])
    func orderedSearches(limit: Int) async throws {
        try await FDBBootstrap.shared.ensureInitialized()
        let db = try FDBClient.openDatabase()
        let subspace = Subspace(Tuple("fdbrl-textpage", UUID().uuidString))
        try await populate(db, subspace)
        for comparison in [TextComparison.containsAll("apple"), .containsAll("apple banana"),
                           .containsAny("cherry date"), .containsPhrase("banana cherry"),
                           .containsAll("apple date", maxDistance: 1), .containsPrefix("ap")] {
            let expected = try await all(db, subspace, comparison)
            let got = try await paged(db, subspace, comparison, limit: limit)
            if comparison.kind == .containsPrefix {
                // Prefix results are in token order and dedupe per page only (as in Java).
                #expect(Set(got.map { $0.encode() }) == Set(expected.map { $0.encode() }))
            } else {
                #expect(got == expected, "\(comparison.kind)")
            }
        }
        try await db.withRecordContext { FDBRecordStore.deleteStore(context: $0, subspace: subspace) }
    }

    @Test("multi-prefix searches cover the same records across pages", arguments: [1, 4])
    func prefixSearches(limit: Int) async throws {
        try await FDBBootstrap.shared.ensureInitialized()
        let db = try FDBClient.openDatabase()
        let subspace = Subspace(Tuple("fdbrl-textpage", UUID().uuidString))
        try await populate(db, subspace)
        for comparison in [TextComparison.containsAnyPrefix("ch da"), .containsAllPrefixes("ap ba")] {
            let expected = Set(try await all(db, subspace, comparison).map { $0.encode() })
            let got = Set(try await paged(db, subspace, comparison, limit: limit).map { $0.encode() })
            #expect(got == expected, "\(comparison.kind)")
        }
        try await db.withRecordContext { FDBRecordStore.deleteStore(context: $0, subspace: subspace) }
    }

    @Test("raw postings page in order")
    func postingPages() async throws {
        try await FDBBootstrap.shared.ensureInitialized()
        let db = try FDBClient.openDatabase()
        let subspace = Subspace(Tuple("fdbrl-textpage", UUID().uuidString))
        try await populate(db, subspace)
        let expected = try await db.withRecordContext { context in
            let store = try await FDBRecordStore.open(context: context, subspace: subspace, metaData: meta)
            return try await store.scanTextIndex(Fdb_Test_Item.self, indexNamed: "item.text", token: "b", prefix: true)
                .map { "\($0.token)/\($0.primaryKey)" }
        }
        var got: [String] = []
        var continuation: FDB.Bytes?
        repeat {
            let page = try await db.withRecordContext { context in
                let store = try await FDBRecordStore.open(context: context, subspace: subspace, metaData: meta)
                return try await store.scanTextIndex(Fdb_Test_Item.self, indexNamed: "item.text", token: "b", prefix: true,
                                                     limit: 6, continuation: continuation)
            }
            got += page.entries.map { "\($0.token)/\($0.primaryKey)" }
            continuation = page.continuation
        } while continuation != nil
        #expect(got == expected)
        #expect(expected.count > 20)
        try await db.withRecordContext { FDBRecordStore.deleteStore(context: $0, subspace: subspace) }
    }
}
#endif
