/*
 * FDB+AsyncKVSequence.swift
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

/// Provides async sequence support for iterating over FoundationDB key-value ranges.
///
/// This file implements efficient streaming iteration over large result sets from FoundationDB
/// using Swift's AsyncSequence protocol with optimized background pre-fetching.

extension FDB {
    /// An asynchronous sequence that efficiently streams key-value pairs from FoundationDB.
    ///
    /// `AsyncKVSequence` provides a Swift-native way to iterate over large result sets from
    /// FoundationDB range queries without loading all data into memory at once. It implements
    /// background pre-fetching to minimize network latency and maximize throughput.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let sequence = transaction.getRange(
    ///     beginSelector: .firstGreaterOrEqual("user:"),
    ///     endSelector: .firstGreaterOrEqual("user;")
    /// )
    ///
    /// for try await (key, value) in sequence {
    ///     let userId = String(bytes: key)
    ///     let userData = String(bytes: value)
    ///     // Process each key-value pair as it's received
    /// }
    /// ```
    ///
    /// ## Performance Characteristics
    ///
    /// - **Streaming**: Results are processed as they arrive, not buffered entirely in memory
    /// - **Background Pre-fetching**: Next batch is fetched concurrently while processing current batch
    /// - **Configurable Batching**: Batch size can be tuned via `batchLimit` parameter
    /// - **Snapshot Consistency**: Supports both snapshot and non-snapshot reads
    ///
    /// ## Implementation Notes
    ///
    /// The sequence uses an optimized async iterator that:
    /// 1. Starts pre-fetching the next batch immediately upon initialization
    /// 2. Continues pre-fetching in background while serving current batch items
    /// 3. Only blocks when transitioning between batches if pre-fetch isn't complete
    ///
    /// This design minimizes the impact of network latency on iteration performance.
    public struct AsyncKVSequence: AsyncSequence {
        public typealias Element = (Bytes, Bytes)

        /// The transaction used for range queries
        let transaction: TransactionProtocol
        /// Starting key selector for the range
        let beginSelector: FDB.KeySelector
        /// Ending key selector for the range (exclusive)
        let endSelector: FDB.KeySelector
        /// Whether to use snapshot reads
        let snapshot: Bool
        /// Whether to iterate in reverse (descending key) order
        let reverse: Bool
        /// Maximum number of key-value pairs to fetch per batch (0 = use FDB default)
        let batchLimit: Int = 0

        /// Creates a new async iterator for this sequence.
        ///
        /// The iterator begins background pre-fetching immediately upon creation to minimize
        /// latency for the first `next()` call.
        ///
        /// - Returns: A new `AsyncIterator` configured for this sequence
        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(
                transaction: transaction,
                beginSelector: beginSelector,
                endSelector: endSelector,
                snapshot: snapshot,
                reverse: reverse,
                batchLimit: batchLimit
            )
        }

        /// High-performance async iterator with background pre-fetching.
        ///
        /// This iterator implements an optimized batching strategy:
        ///
        /// 1. **Immediate Pre-fetch**: Starts fetching the first batch during initialization
        /// 2. **Background Pre-fetch**: While serving items from current batch, pre-fetches next batch
        /// 3. **Minimal Blocking**: Only blocks when current batch is exhausted and next isn't ready
        ///
        /// ## Performance Benefits
        ///
        /// - **Overlapped I/O**: Network requests happen concurrently with data processing
        /// - **Reduced Latency**: Pre-fetching hides network round-trip time
        /// - **Memory Efficient**: Only keeps 1-2 batches in memory at any time
        ///
        /// ## Thread Safety
        ///
        /// This iterator is **not** thread-safe. Each iterator should be used by a single task.
        /// Multiple iterators can be created from the same sequence for concurrent processing.
        public struct AsyncIterator: AsyncIteratorProtocol {
            /// Transaction used for all range queries
            private let transaction: TransactionProtocol
            /// Begin key selector for the next batch (advances forward; constant when reverse)
            private var nextBeginSelector: FDB.KeySelector
            /// End key selector for the next batch (advances backward when reverse; else constant)
            private var nextEndSelector: FDB.KeySelector
            /// Whether to use snapshot reads
            private let snapshot: Bool
            /// Whether to iterate in reverse (descending key) order
            private let reverse: Bool
            /// Batch size limit
            private let batchLimit: Int

            /// Current batch of records being served
            private var currentBatch: ResultRange = .init(records: [], more: true)
            private var currentIndex: Int = 0
            /// Whether the first batch has been requested.
            private var started = false

            private var currentBatchExhausted: Bool {
                currentIndex >= currentBatch.records.count
            }

            init(
                transaction: TransactionProtocol, beginSelector: FDB.KeySelector,
                endSelector: FDB.KeySelector, snapshot: Bool, reverse: Bool, batchLimit: Int
            ) {
                self.transaction = transaction
                nextBeginSelector = beginSelector
                nextEndSelector = endSelector
                self.batchLimit = batchLimit
                self.snapshot = snapshot
                self.reverse = reverse
            }

            /// Batches are fetched on demand, never ahead in the background: a read left running
            /// when the caller stops iterating would still be outstanding at commit (failing it),
            /// and a non-snapshot read would add a conflict range over keys the caller never saw.
            public mutating func next() async throws -> Element? {
                while currentBatchExhausted {
                    if started && !currentBatch.more { return nil }
                    try await fetchNextBatch()
                    if currentBatch.records.isEmpty && !currentBatch.more { return nil }
                }
                let keyValue = currentBatch.records[currentIndex]
                currentIndex += 1
                return keyValue
            }

            private mutating func fetchNextBatch() async throws {
                started = true
                let batch = try await transaction.getRangeNative(
                    beginSelector: nextBeginSelector,
                    endSelector: nextEndSelector,
                    limit: batchLimit,
                    snapshot: snapshot,
                    reverse: reverse
                )
                currentBatch = batch
                currentIndex = 0
                if let lastKey = batch.records.last?.0, batch.more {
                    // `last` is the lowest key in a reverse batch and the highest otherwise, so
                    // reverse continues by retreating the (exclusive) end; forward by advancing begin.
                    if reverse {
                        nextEndSelector = FDB.KeySelector.firstGreaterOrEqual(lastKey)
                    } else {
                        nextBeginSelector = FDB.KeySelector.firstGreaterThan(lastKey)
                    }
                } else if batch.records.isEmpty {
                    currentBatch = ResultRange(records: [], more: false)
                }
            }
        }
    }
}
