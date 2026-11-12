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
import FoundationDB
import SwiftProtobuf

/// The kind of secondary index, which determines how its entries are maintained. Each case
/// corresponds to a Java Record Layer index type (the name in parentheses) and writes the same
/// keys and values.
public enum IndexType: Sendable, Hashable {
    /// A standard value index (`value`): `index / <columns...> / <primaryKey...>` → ∅.
    case value
    /// Counts records per group (`count`): `index / <group...>` → little-endian int64.
    case count
    /// Counts saves per group, never decremented (`count_updates`).
    case countUpdates
    /// Counts records whose grouped column is not null (`count_not_null`).
    case countNotNull
    /// Sums the grouped integer column per group (`sum`).
    case sum
    /// Minimum of the grouped column; answered from value-index-style entries so it stays exact
    /// across deletes (Java answers `MIN` aggregates from a value index the same way).
    case min
    /// Maximum of the grouped column; see ``min``.
    case max
    /// Smallest tuple ever indexed per group (`min_ever_tuple`); never decreases on delete.
    case minEverTuple
    /// Largest tuple ever indexed per group (`max_ever_tuple`).
    case maxEverTuple
    /// Smallest non-negative integer ever indexed per group (`min_ever_long`).
    case minEverLong
    /// Largest non-negative integer ever indexed per group (`max_ever_long`).
    case maxEverLong
    /// Largest record version ever indexed per group (`max_ever_version`).
    case maxEverVersion
    /// Orders records by version (`version`); the expression must include ``KeyExpression/version()``.
    case version
    /// Value-index entries plus a per-group ranked set for O(log n) rank queries (`rank`).
    case rank
    /// Full-text index (`text`): tokenized words mapped to the records and positions containing
    /// them, stored in Java's BunchedMap format.
    case text
    /// Time-windowed leaderboards (`time_window_leaderboard`): ranked sets of scores per
    /// configured time window.
    case timeWindowLeaderboard

    /// The Java Record Layer's index type name (`IndexTypes`).
    public var javaName: String {
        switch self {
        case .value, .min, .max: return "value"
        case .count: return "count"
        case .countUpdates: return "count_updates"
        case .countNotNull: return "count_not_null"
        case .sum: return "sum"
        case .minEverTuple: return "min_ever_tuple"
        case .maxEverTuple: return "max_ever_tuple"
        case .minEverLong: return "min_ever_long"
        case .maxEverLong: return "max_ever_long"
        case .maxEverVersion: return "max_ever_version"
        case .version: return "version"
        case .rank: return "rank"
        case .text: return "text"
        case .timeWindowLeaderboard: return "time_window_leaderboard"
        }
    }

    /// The type for a Java index type name.
    public init?(javaName: String) {
        switch javaName {
        case "value": self = .value
        case "count": self = .count
        case "count_updates": self = .countUpdates
        case "count_not_null": self = .countNotNull
        case "sum": self = .sum
        case "min_ever_tuple", "min_ever": self = .minEverTuple
        case "max_ever_tuple", "max_ever": self = .maxEverTuple
        case "min_ever_long": self = .minEverLong
        case "max_ever_long": self = .maxEverLong
        case "max_ever_version": self = .maxEverVersion
        case "version": self = .version
        case "rank": self = .rank
        case "text": self = .text
        case "time_window_leaderboard": self = .timeWindowLeaderboard
        default: return nil
        }
    }

    /// Whether this type is maintained with FDB atomic mutations (Java's `AtomicMutationIndexMaintainer`).
    var isAtomic: Bool {
        switch self {
        case .count, .countUpdates, .countNotNull, .sum, .minEverTuple, .maxEverTuple,
             .minEverLong, .maxEverLong, .maxEverVersion:
            return true
        case .value, .min, .max, .version, .rank, .text, .timeWindowLeaderboard:
            return false
        }
    }

    /// The default number of trailing "grouped" columns (the rest form the group), mirroring how
    /// Java's grouping key expressions are conventionally declared for each type.
    var defaultGroupedCount: Int {
        switch self {
        case .count, .countUpdates: return 0
        case .timeWindowLeaderboard: return 2 // score, timestamp
        default: return 1
        }
    }
}

/// Whether an index participates in reads and/or writes — Java's `IndexState`. The raw value is
/// the code persisted (as a one-element tuple) at `store / 5 / indexName`; a readable index has
/// no key at all.
public enum IndexState: Int, Sendable, Hashable {
    /// Fully built and usable by queries.
    case readable = 0
    /// Maintained on writes but not yet usable by queries (e.g. while building).
    case writeOnly = 1
    /// Not maintained at all.
    case disabled = 2
    /// Built and scannable, but a unique index with outstanding uniqueness violations (recorded
    /// in the index's uniqueness-violation space). New writes still fail on new violations.
    case readableUniquePending = 3

    /// Whether queries may scan the index (``readable`` or ``readableUniquePending``).
    public var isScannable: Bool { self == .readable || self == .readableUniquePending }
}

/// A secondary index over records of type `M`.
///
/// An index is a name plus a ``KeyExpression`` that computes its entries, and a
/// ``IndexType`` that selects how those entries are stored and updated.
public struct Index<M: SwiftProtobuf.Message>: Sendable {
    /// The index's unique name across the whole metadata.
    public let name: String
    /// How the index is maintained.
    public let type: IndexType
    /// Computes the index entries for a record.
    public let expression: KeyExpression<M>
    /// An explicit subspace key for the index's data. When `nil` the index name is used, which is
    /// the Java Record Layer's default. Never reuse a retired key.
    public let key: Int?
    /// Whether the index enforces uniqueness: a `save` that would give two records the same
    /// index key fails with ``RecordStoreError/uniquenessViolation(index:)``. Applies to
    /// `.value` indexes.
    public let unique: Bool
    /// The metadata version in which the index was added (Java's `addedVersion`).
    public let addedVersion: Int
    /// The metadata version in which the index definition last changed (Java's
    /// `lastModifiedVersion`). When a store's recorded metadata version is older than this, the
    /// index is (re)built: inline when the store is small, otherwise it is left disabled for an
    /// ``OnlineIndexer`` to build.
    ///
    /// When adding an index to an existing schema, set this (and bump ``RecordMetaData/version``
    /// to at least the same value); an index whose version is not newer than a store's recorded
    /// metadata version is assumed to be already built there.
    public let lastModifiedVersion: Int
    /// For aggregate indexes, how many trailing columns are aggregated (the rest form the
    /// group). Defaults per ``IndexType``.
    public let groupedCount: Int?
    /// For `count`, `count_not_null` and `sum`: clear a group's key when it returns to zero
    /// (Java's `clearWhenZero` option).
    public let clearWhenZero: Bool
    /// Java's index options (`IndexOptions`), e.g. `rankNLevels`, `textTokenizerName`,
    /// `replacedBy...`. ``unique`` and ``clearWhenZero`` are folded in.
    public let options: [String: String]

    public init(
        _ name: String, _ expression: KeyExpression<M>,
        type: IndexType = .value, key: Int? = nil, unique: Bool = false,
        addedVersion: Int? = nil, lastModifiedVersion: Int? = nil,
        groupedCount: Int? = nil, clearWhenZero: Bool = false,
        options: [String: String] = [:]
    ) {
        var options = options
        if unique { options[IndexOptions.unique] = "true" }
        if clearWhenZero { options[IndexOptions.clearWhenZero] = "true" }
        self.options = options
        self.name = name
        self.type = type
        self.expression = expression
        self.key = key
        self.unique = unique
        let modified = lastModifiedVersion ?? addedVersion ?? 0
        self.lastModifiedVersion = modified
        self.addedVersion = addedVersion ?? modified
        self.groupedCount = groupedCount
        self.clearWhenZero = clearWhenZero
    }
}

/// Option names understood by indexes — Java's `IndexOptions` (plus the options its index
/// maintainers read).
public enum IndexOptions {
    public static let unique = "unique"
    public static let clearWhenZero = "clearWhenZero"
    /// Prefix of options naming indexes that replace this one once they are readable; the value
    /// is the replacing index's name (Java's `REPLACED_BY_OPTION_PREFIX`).
    public static let replacedByPrefix = "replacedBy"
    public static let rankHashFunction = "rankHashFunction"
    public static let rankNLevels = "rankNLevels"
    public static let rankCountDuplicates = "rankCountDuplicates"
    public static let textTokenizerName = "textTokenizerName"
    public static let textTokenizerVersion = "textTokenizerVersion"
    public static let textAddAggressiveConflictRanges = "textAddAggressiveConflictRanges"
    public static let textOmitPositions = "textOmitPositions"
    public static let primaryKeyComponentPositions = "primaryKeyComponentPositions"
}

/// An index on several record types (or, with no types listed, every type) — Java's multi-type
/// and universal indexes. Its expression must be structural (field-number based), since it is
/// evaluated against each type's records.
public struct MultiTypeIndex: Sendable {
    public let name: String
    public let type: IndexType
    public let expression: KeyExpressionNode
    /// Record type names (`M.protoMessageName`); empty means every type (a universal index).
    public let recordTypes: [String]
    public let key: Int?
    public let addedVersion: Int
    public let lastModifiedVersion: Int
    public let groupedCount: Int?
    public let options: [String: String]

    public init(
        _ name: String, on expression: KeyExpressionNode, type: IndexType = .value,
        recordTypes: [any SwiftProtobuf.Message.Type] = [], key: Int? = nil, unique: Bool = false,
        addedVersion: Int? = nil, lastModifiedVersion: Int? = nil, groupedCount: Int? = nil,
        options: [String: String] = [:]
    ) {
        precondition(expression.isSerializable, "A multi-type index needs a structural key expression")
        self.name = name
        self.type = type
        self.expression = expression
        self.recordTypes = recordTypes.map { $0.protoMessageName }
        self.key = key
        let modified = lastModifiedVersion ?? addedVersion ?? 0
        self.lastModifiedVersion = modified
        self.addedVersion = addedVersion ?? modified
        self.groupedCount = groupedCount
        var options = options
        if unique { options[IndexOptions.unique] = "true" }
        self.options = options
    }
}

/// An index that has been removed from the schema — Java's `FormerIndex`. Listing it lets a
/// store whose recorded metadata version predates the removal clear the index's leftover data
/// (entries, state, build progress) when it is next opened.
public struct FormerIndex: Sendable {
    /// The removed index's subspace key: its name, or its explicit integer key.
    public let subspaceKey: any TupleElement
    public let formerName: String?
    public let addedVersion: Int
    public let removedVersion: Int

    public init(name: String, explicitKey: Int? = nil, addedVersion: Int = 0, removedVersion: Int) {
        self.subspaceKey = explicitKey.map { Int64($0) } ?? name
        self.formerName = name
        self.addedVersion = addedVersion
        self.removedVersion = removedVersion
    }
}
#endif
