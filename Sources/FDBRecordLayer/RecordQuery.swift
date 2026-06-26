/*
 * RecordQuery.swift
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

/// A declarative query over records of a single type.
///
/// ```swift
/// let query = RecordQuery(Order.self)
///     .where(Query.field(\.price).lessThan(50))
///     .sorted(by: .field(\.price))
/// let cursor = try store.executeQuery(query)
/// ```
///
/// The store's planner decides whether to satisfy the filter with an index scan or a full
/// record scan; either way the `filter` is applied as a residual so results are always exact.
public struct RecordQuery<M: SwiftProtobuf.Message & Sendable>: Sendable {
    /// The record type to query.
    public let recordType: M.Type
    /// The predicate to match, if any.
    public var filter: QueryComponent<M>?
    /// An optional sort expression applied to the results.
    public var sort: KeyExpression<M>?
    /// Whether the sort is descending.
    public var sortReversed: Bool
    /// Whether duplicate records (by primary key) must be removed — required after a
    /// fan-out index scan can surface the same record more than once.
    public var requiresDistinct: Bool

    public init(
        _ recordType: M.Type,
        filter: QueryComponent<M>? = nil,
        sort: KeyExpression<M>? = nil,
        sortReversed: Bool = false,
        requiresDistinct: Bool = false
    ) {
        self.recordType = recordType
        self.filter = filter
        self.sort = sort
        self.sortReversed = sortReversed
        self.requiresDistinct = requiresDistinct
    }

    /// Returns a copy with the given filter.
    public func `where`(_ filter: QueryComponent<M>) -> RecordQuery<M> {
        var copy = self
        copy.filter = filter
        return copy
    }

    /// Returns a copy sorted by the given expression.
    public func sorted(by expression: KeyExpression<M>, reversed: Bool = false) -> RecordQuery<M> {
        var copy = self
        copy.sort = expression
        copy.sortReversed = reversed
        return copy
    }

    /// Returns a copy that removes duplicate records.
    public func distinct() -> RecordQuery<M> {
        var copy = self
        copy.requiresDistinct = true
        return copy
    }
}
#endif
