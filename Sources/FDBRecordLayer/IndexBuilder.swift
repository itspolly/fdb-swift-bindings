/*
 * IndexBuilder.swift
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

extension DatabaseProtocol {
    /// Builds (backfills) an index over the existing records of a store, online and in
    /// batches — one transaction per batch — then marks it `readable`.
    ///
    /// A new index on a non-empty store opens in the `writeOnly` state: concurrent writes are
    /// indexed but queries ignore it. This walks the existing records, populates the index, and
    /// flips it to `readable`. Progress is persisted, so the call is resumable: if interrupted,
    /// invoking it again continues from where it left off.
    ///
    /// - Parameters:
    ///   - subspace: the store's subspace.
    ///   - metaData: the schema (must include the index).
    ///   - indexName: the index to build.
    ///   - batchSize: records processed per transaction (default 1000).
    public func buildIndex(
        subspace: Subspace, metaData: RecordMetaData, indexName: String, batchSize: Int = 1000
    ) async throws {
        while true {
            let done = try await withRecordContext { context in
                let store = try await FDBRecordStore.open(
                    context: context, subspace: subspace, metaData: metaData)
                return try await store.backfillIndex(named: indexName, batchSize: batchSize)
            }
            if done { break }
        }
    }

    /// Builds an index for a store opened at `path`.
    public func buildIndex(
        path: KeySpacePath, metaData: RecordMetaData, indexName: String, batchSize: Int = 1000
    ) async throws {
        try await buildIndex(
            subspace: path.toSubspace(), metaData: metaData, indexName: indexName, batchSize: batchSize)
    }
}

extension FDBTenant {
    /// Builds an index over a tenant-scoped store. See
    /// ``FoundationDB/DatabaseProtocol/buildIndex(subspace:metaData:indexName:batchSize:)``.
    public func buildIndex(
        subspace: Subspace, metaData: RecordMetaData, indexName: String, batchSize: Int = 1000
    ) async throws {
        while true {
            let done = try await withRecordContext { context in
                let store = try await FDBRecordStore.open(
                    context: context, subspace: subspace, metaData: metaData)
                return try await store.backfillIndex(named: indexName, batchSize: batchSize)
            }
            if done { break }
        }
    }
}
#endif
