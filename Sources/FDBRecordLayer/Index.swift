/*
 * Index.swift
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

/// The kind of secondary index, which determines how its entries are maintained.
public enum IndexType: Sendable, Hashable {
    /// A standard value index: maps the index key to the record's primary key.
    case value
    /// Counts records per group (the index expression columns form the group).
    case count
    /// Sums the last column of the index expression per group (remaining columns).
    case sum
    /// Tracks the minimum of the last column per group.
    case min
    /// Tracks the maximum of the last column per group.
    case max
    /// Orders records by commit version (a versionstamp).
    case version
    /// Maintains a rank/ordered-set over the index key for leaderboard-style queries.
    case rank
}

/// Whether an index participates in reads and/or writes. The raw value is persisted in the
/// store header.
public enum IndexState: Int, Sendable, Hashable {
    /// Fully built and usable by queries.
    case readable = 0
    /// Maintained on writes but not yet usable by queries (e.g. while building).
    case writeOnly = 1
    /// Not maintained at all.
    case disabled = 2
}

/// A secondary index over records of type `M`.
///
/// An index is a name plus a ``KeyExpression`` that computes its entries, and a
/// ``IndexType`` that selects how those entries are stored and updated.
public struct Index<M: SwiftProtobuf.Message>: Sendable {
    /// The index's unique name within its record type.
    public let name: String
    /// How the index is maintained.
    public let type: IndexType
    /// Computes the index entries for a record.
    public let expression: KeyExpression<M>

    public init(_ name: String, _ expression: KeyExpression<M>, type: IndexType = .value) {
        self.name = name
        self.type = type
        self.expression = expression
    }
}
#endif
