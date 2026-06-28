/*
 * Watch.swift
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

/// A handle to a FoundationDB watch created by ``TransactionProtocol/watch(key:)``.
///
/// A watch fires once: ``wait()`` suspends until the watched key's value changes from its value
/// at the creating transaction's read version (the watch is armed when that transaction commits).
/// To keep observing changes, re-watch in a loop — or use ``DatabaseProtocol/watch(key:)``, which
/// does that for you.
public final class FDBWatch: @unchecked Sendable {
    private let future: Future<ResultVoid>

    init(future: Future<ResultVoid>) {
        self.future = future
    }

    /// Suspends until the watched key changes (or the watch is cancelled / errors).
    ///
    /// Cooperates with task cancellation: cancelling the surrounding task cancels the watch and
    /// throws `FDBError` with the `operation_cancelled` code.
    public func wait() async throws {
        try await withTaskCancellationHandler {
            _ = try await future.getAsync()
        } onCancel: {
            future.cancel()
        }
    }

    /// Cancels the watch; a pending ``wait()`` then throws `operation_cancelled`.
    public func cancel() {
        future.cancel()
    }
}

/// Builds a stream that yields the current value and then the value after each change, by
/// repeatedly running `step` (read the value + arm a watch, atomically) and awaiting the watch.
func watchValueStream(
    _ step: @escaping @Sendable () async throws -> (value: FDB.Bytes?, watch: FDBWatch)
) -> AsyncThrowingStream<FDB.Bytes?, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                while true {
                    try Task.checkCancellation()
                    let (value, watch) = try await step()
                    continuation.yield(value)
                    try await watch.wait()
                }
            } catch {
                // Task cancellation (stream torn down) finishes cleanly; anything else propagates.
                if Task.isCancelled {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: error)
                }
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

extension DatabaseProtocol where Self: Sendable {
    /// Watches `key` for changes, yielding its current value immediately and then the new value
    /// after every change — pub/sub over a single key.
    ///
    /// Each change is delivered as the latest value (rapid successive writes may coalesce into one
    /// notification), so it is well suited to "current state" feeds like a live score. The stream
    /// runs until the consumer stops iterating (which cancels the underlying watch) or an error
    /// occurs. Note FoundationDB limits the number of concurrent watches (see the `MAX_WATCHES`
    /// database option).
    public func watch(key: FDB.Bytes) -> AsyncThrowingStream<FDB.Bytes?, Error> {
        watchValueStream { [self] in
            try await self.withTransaction { transaction in
                let value = try await transaction.getValue(for: key)
                return (value, transaction.watch(key: key))
            }
        }
    }
}

extension FDBTenant {
    /// Watches `key` within this tenant's keyspace. See ``DatabaseProtocol/watch(key:)``.
    public func watch(key: FDB.Bytes) -> AsyncThrowingStream<FDB.Bytes?, Error> {
        watchValueStream { [self] in
            try await self.withTransaction { transaction in
                let value = try await transaction.getValue(for: key)
                return (value, transaction.watch(key: key))
            }
        }
    }
}
