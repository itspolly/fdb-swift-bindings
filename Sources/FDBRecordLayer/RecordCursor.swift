/*
 * RecordCursor.swift
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
import SwiftProtobuf

/// An asynchronous stream of records produced by a scan or query.
///
/// `RecordCursor` is an `AsyncSequence`, so results can be consumed lazily with `for try
/// await`, or gathered eagerly with ``collect()``. Each call to `makeAsyncIterator()` starts
/// a fresh traversal.
///
/// A cursor is built from a *step factory*: a closure that returns a fresh "produce the next
/// record" function. This lets the store back a cursor by a range scan, an index lookup, or
/// an in-memory buffer without exposing those details.
public struct RecordCursor<M: SwiftProtobuf.Message & Sendable>: AsyncSequence {
    public typealias Element = FDBStoredRecord<M>

    private let makeStep: () -> () async throws -> FDBStoredRecord<M>?

    init(makeStep: @escaping () -> () async throws -> FDBStoredRecord<M>?) {
        self.makeStep = makeStep
    }

    /// An empty cursor.
    static var empty: RecordCursor<M> {
        RecordCursor { { nil } }
    }

    /// A cursor that yields the records of an in-memory array (used by in-memory query stages).
    static func ofBuffer(_ buffer: [FDBStoredRecord<M>]) -> RecordCursor<M> {
        RecordCursor {
            var index = 0
            return {
                guard index < buffer.count else { return nil }
                defer { index += 1 }
                return buffer[index]
            }
        }
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var step: () async throws -> FDBStoredRecord<M>?
        public mutating func next() async throws -> FDBStoredRecord<M>? {
            try await step()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(step: makeStep())
    }

    /// Eagerly gathers all records into an array.
    public func collect() async throws -> [FDBStoredRecord<M>] {
        var result: [FDBStoredRecord<M>] = []
        for try await record in self {
            result.append(record)
        }
        return result
    }

    /// Returns at most `count` records.
    public func limited(to count: Int) -> RecordCursor<M> {
        let base = makeStep
        return RecordCursor {
            let step = base()
            var produced = 0
            return {
                guard produced < count else { return nil }
                guard let next = try await step() else { return nil }
                produced += 1
                return next
            }
        }
    }
}
#endif
