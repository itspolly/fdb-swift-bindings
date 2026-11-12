/*
 * RecordMetaData.swift
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
import FoundationDB
import SwiftProtobuf

// MARK: - Record type DSL

/// A record type declaration collected by ``RecordMetaDataBuilder``.
public protocol RecordTypeProtocol {
    /// The fully-qualified protobuf message name (e.g. `"fdb.test.Order"`).
    var recordName: String { get }
}

/// Internal refinement that lets ``RecordMetaData`` obtain the type-erased representation.
/// Kept separate from the public ``RecordTypeProtocol`` so the erased types stay internal.
protocol ErasableRecordType: RecordTypeProtocol {
    func _erase() -> ErasedRecordType
}

/// Declares how records of a particular protobuf message type are stored and indexed.
///
/// ```swift
/// RecordType(Order.self, primaryKey: \.orderId)
///     .index("priceIdx", on: \.price)
///     .index("byTag", on: \.tags, fanType: .fanOut)
/// ```
public struct RecordType<M: SwiftProtobuf.Message>: ErasableRecordType, Sendable {
    public let recordName: String
    /// The clustered primary-key expression (must produce exactly one key, no fan-out).
    public let primaryKey: KeyExpression<M>
    /// The secondary indexes declared on this record type.
    public private(set) var indexes: [Index<M>]
    /// The record type key (Java's `recordTypeKey`), used by ``KeyExpression/recordType()``.
    /// Defaults to the union field number.
    public let key: Int?
    /// The field number of this type in the store's record union (Java's `RecordTypeUnion`):
    /// records are persisted wrapped in the union, so a Java client with a union declaring the
    /// same field numbers reads them. Defaults to a positive `key`, else declaration order
    /// starting at 1 — pin one or the other if declarations may be reordered.
    public let unionField: Int?
    /// The metadata version that introduced this type (Java's `sinceVersion`). Indexes on a type
    /// newer than a store's recorded metadata version are known to be empty there and are marked
    /// readable without a build.
    public let sinceVersion: Int?
    /// Whether records carry a commit-versionstamp version. In the Java layer this is a store-wide
    /// setting: if any type opts in (or any `version` index exists), every record is versioned.
    public private(set) var storesVersions: Bool = false

    /// Creates a record type with an explicit primary-key expression.
    public init(_ type: M.Type, key: Int? = nil, unionField: Int? = nil, sinceVersion: Int? = nil,
                primaryKey: KeyExpression<M>) {
        self.recordName = M.protoMessageName
        self.primaryKey = primaryKey
        self.indexes = []
        self.key = key
        self.unionField = unionField
        self.sinceVersion = sinceVersion
    }

    /// Creates a record type with a single-field primary key.
    public init<V: IndexableValue>(_ type: M.Type, key: Int? = nil, unionField: Int? = nil, sinceVersion: Int? = nil,
                                   primaryKey keyPath: KeyPath<M, V> & Sendable) {
        self.init(type, key: key, unionField: unionField, sinceVersion: sinceVersion, primaryKey: .field(keyPath))
    }

    /// Enables per-record versioning (see ``RecordMetaData/storeRecordVersions``).
    public func storingVersions(_ enabled: Bool = true) -> RecordType<M> {
        var copy = self
        copy.storesVersions = enabled
        return copy
    }

    // MARK: Index builders (chainable)

    /// Adds an index built from an arbitrary key expression.
    public func index(
        _ name: String, on expression: KeyExpression<M>,
        type: IndexType = .value, key: Int? = nil, unique: Bool = false,
        addedVersion: Int? = nil, lastModifiedVersion: Int? = nil,
        groupedCount: Int? = nil, clearWhenZero: Bool = false, options: [String: String] = [:]
    ) -> RecordType<M> {
        var copy = self
        copy.indexes.append(Index(
            name, expression, type: type, key: key, unique: unique,
            addedVersion: addedVersion, lastModifiedVersion: lastModifiedVersion,
            groupedCount: groupedCount, clearWhenZero: clearWhenZero, options: options))
        return copy
    }

    /// Adds a single-field (possibly nested) index.
    public func index<V: IndexableValue>(
        _ name: String, on keyPath: KeyPath<M, V> & Sendable,
        type: IndexType = .value, key: Int? = nil, unique: Bool = false,
        addedVersion: Int? = nil, lastModifiedVersion: Int? = nil
    ) -> RecordType<M> {
        index(name, on: .field(keyPath), type: type, key: key, unique: unique,
              addedVersion: addedVersion, lastModifiedVersion: lastModifiedVersion)
    }

    /// Adds an index over a repeated field.
    public func index<V: IndexableValue>(
        _ name: String, on keyPath: KeyPath<M, [V]> & Sendable, fanType: FanType = .fanOut,
        type: IndexType = .value, key: Int? = nil, unique: Bool = false,
        addedVersion: Int? = nil, lastModifiedVersion: Int? = nil
    ) -> RecordType<M> {
        index(name, on: .field(keyPath, fanType), type: type, key: key, unique: unique,
              addedVersion: addedVersion, lastModifiedVersion: lastModifiedVersion)
    }

    func _erase() -> ErasedRecordType {
        let pk = primaryKey
        let erasedIndexes = indexes.map { idx in
            ErasedIndex(
                name: idx.name,
                type: idx.type,
                subspaceKey: idx.key.map { Int64($0) } ?? idx.name,
                explicitKey: idx.key,
                unique: idx.unique,
                producesMultipleKeys: idx.expression.producesMultipleKeys,
                columnIdentities: idx.expression.columnIdentities,
                addedVersion: idx.addedVersion,
                lastModifiedVersion: idx.lastModifiedVersion,
                groupedCount: idx.groupedCount ?? idx.type.defaultGroupedCount,
                clearWhenZero: idx.clearWhenZero,
                rawEntries: { message in idx.expression.evaluate(message as! M) },
                options: idx.options,
                rootNode: idx.expression.node
            )
        }
        let probe = pk.evaluate(M()).first ?? []
        return ErasedRecordType(
            recordName: recordName,
            messageType: M.self,
            explicitKey: key,
            explicitUnionField: unionField,
            sinceVersion: sinceVersion,
            storesVersions: storesVersions,
            primaryKeyStartsWithRecordType: probe.first is RecordTypeKeyPlaceholder,
            rawPrimaryKey: { message in pk.evaluate(message as! M).first ?? [] },
            primaryKeyColumnIdentities: pk.columnIdentities,
            deserialize: { bytes in try M(serializedBytes: bytes) },
            indexes: erasedIndexes,
            primaryKeyNode: pk.node
        )
    }
}

// MARK: - Type-erased internals

/// Internal, type-erased view of an ``Index`` used by the store and planner.
struct ErasedIndex: Sendable {
    let name: String
    let type: IndexType
    /// The index's subspace key under `store / 2` (and the other per-index keyspaces): the
    /// index name, or its explicit integer key — Java's `Index.getSubspaceKey()`.
    let subspaceKey: any TupleElement
    /// Caller-supplied stable key, if any.
    let explicitKey: Int?
    /// Whether the index enforces uniqueness.
    let unique: Bool
    let producesMultipleKeys: Bool
    let columnIdentities: [FieldID?]
    let addedVersion: Int
    let lastModifiedVersion: Int
    /// Trailing grouped columns for aggregate indexes.
    let groupedCount: Int
    let clearWhenZero: Bool
    /// Evaluates the index expression; may contain ``RecordVersionPlaceholder`` /
    /// ``RecordTypeKeyPlaceholder`` columns, which ``ErasedRecordType/indexEntries`` resolves.
    let rawEntries: @Sendable (any SwiftProtobuf.Message) -> [[any TupleElement]]
    /// Java index options (see ``IndexOptions``).
    var options: [String: String] = [:]
    /// The expression's structure (without grouping; see ``groupedCount``).
    var rootNode: KeyExpressionNode = .opaque
    /// Names of the record types the index covers: stored types, or one synthetic type.
    var recordTypeNames: [String] = []
    /// Primary-key width of the covered records (synthetic primary keys included).
    var primaryKeyColumnCount: Int = 0
    /// The synthetic type this index is on, if any.
    var syntheticTypeName: String? = nil
    /// Whether the index was declared on several (or all) stored types.
    var isMultiType: Bool = false
    /// Whether the index is universal (declared with no record types: every type, present or future).
    var isUniversal: Bool = false

    /// Names of indexes that replace this one once all of them are readable (Java's
    /// `getReplacedByIndexNames`).
    var replacedByIndexNames: [String] {
        options.filter { $0.key.hasPrefix(IndexOptions.replacedByPrefix) }.map(\.value).sorted()
    }

    /// The subspace key as a one-element tuple (Java's `getSubspaceTupleKey()`).
    var subspaceTupleKey: Tuple { Tuple(subspaceKey) }

    /// Whether the expression contains a ``KeyExpression/version()`` column.
    var usesRecordVersion: Bool { type == .version || type == .maxEverVersion }
}

/// Internal, type-erased view of a ``RecordType`` used by the store.
struct ErasedRecordType: Sendable {
    let recordName: String
    /// The generated Swift type of the record message, when known (used to reconstruct
    /// descriptors by reflection).
    let messageType: (any SwiftProtobuf.Message.Type)?
    /// Caller-supplied record type key, if any.
    let explicitKey: Int?
    /// Caller-supplied union field number, if any.
    let explicitUnionField: Int?
    let sinceVersion: Int?
    /// Assigned by ``RecordMetaData``: this type's field number in the record union.
    var unionFieldNumber: Int = -1
    /// A union field implied by an explicit record type key.
    var pinnedUnionField: Int?
    /// Assigned by ``RecordMetaData``: Java's `recordTypeKey` (explicit key, else the union field).
    var recordTypeKey: Int64 = -1
    /// Assigned by ``RecordMetaData``: the key this type's records were stored under by the
    /// pre-Java-layout Swift record layer (`store / 1 / legacyTypeKey / pk`). Used only to
    /// migrate such stores.
    var legacyTypeKey: Int = -1
    /// Whether each record carries a version (resolved store-wide by ``RecordMetaData``).
    var storesVersions: Bool
    /// Whether the primary key begins with ``KeyExpression/recordType()``.
    let primaryKeyStartsWithRecordType: Bool
    let rawPrimaryKey: @Sendable (any SwiftProtobuf.Message) -> [any TupleElement]
    /// Identities of every primary-key column (a `recordType()` column has none).
    let primaryKeyColumnIdentities: [FieldID?]
    let deserialize: @Sendable ([UInt8]) throws -> any SwiftProtobuf.Message
    var indexes: [ErasedIndex]
    /// The primary key's structure (for serializing to Java's `MetaData`).
    var primaryKeyNode: KeyExpressionNode

    init(
        recordName: String, messageType: (any SwiftProtobuf.Message.Type)? = nil,
        explicitKey: Int?, explicitUnionField: Int?, sinceVersion: Int?,
        storesVersions: Bool, primaryKeyStartsWithRecordType: Bool,
        rawPrimaryKey: @escaping @Sendable (any SwiftProtobuf.Message) -> [any TupleElement],
        primaryKeyColumnIdentities: [FieldID?],
        deserialize: @escaping @Sendable ([UInt8]) throws -> any SwiftProtobuf.Message,
        indexes: [ErasedIndex], primaryKeyNode: KeyExpressionNode = .opaque
    ) {
        self.recordName = recordName
        self.messageType = messageType
        self.explicitKey = explicitKey
        self.explicitUnionField = explicitUnionField
        self.sinceVersion = sinceVersion
        self.storesVersions = storesVersions
        self.primaryKeyStartsWithRecordType = primaryKeyStartsWithRecordType
        self.rawPrimaryKey = rawPrimaryKey
        self.primaryKeyColumnIdentities = primaryKeyColumnIdentities
        self.deserialize = deserialize
        self.indexes = indexes
        self.primaryKeyNode = primaryKeyNode
    }

    /// The record's primary key, with any `recordType()` column resolved.
    func primaryKey(_ message: any SwiftProtobuf.Message) -> Tuple {
        Tuple(resolveColumns(rawPrimaryKey(message), version: nil))
    }

    /// Number of columns in a primary key (including a leading record-type column).
    var primaryKeyColumnCount: Int { primaryKeyColumnIdentities.count }

    /// Primary-key identities the planner can match predicates against: the columns after a
    /// leading `recordType()`, whose range is fixed by ``recordTypePrefix``.
    var primaryKeyIdentities: [FieldID?] {
        primaryKeyStartsWithRecordType ? Array(primaryKeyColumnIdentities.dropFirst()) : primaryKeyColumnIdentities
    }

    /// The fixed key prefix shared by every record of this type, when the primary key starts
    /// with `recordType()`.
    var recordTypePrefix: [any TupleElement] { primaryKeyStartsWithRecordType ? [recordTypeKey] : [] }

    /// The index entries for `message`, with version / record-type columns resolved.
    /// `version` is the record's version as a tuple element (complete or incomplete).
    func indexEntries(_ index: ErasedIndex, _ message: any SwiftProtobuf.Message, version: Versionstamp?) -> [[any TupleElement]] {
        index.rawEntries(message).map { resolveColumns($0, version: version) }
    }

    func resolveColumns(_ columns: [any TupleElement], version: Versionstamp?) -> [any TupleElement] {
        columns.map { column in
            if column is RecordTypeKeyPlaceholder { return recordTypeKey }
            if column is RecordVersionPlaceholder { return version.map { $0 as any TupleElement } ?? NullValue() }
            return column
        }
    }
}

// MARK: - Result builder

/// Result builder that collects ``RecordType`` declarations into a ``RecordMetaData``.
@resultBuilder
public enum RecordMetaDataBuilder {
    public static func buildExpression(_ expression: any RecordTypeProtocol) -> any RecordTypeProtocol {
        expression
    }

    public static func buildBlock(_ components: any RecordTypeProtocol...) -> [any RecordTypeProtocol] {
        components
    }

    public static func buildArray(_ components: [[any RecordTypeProtocol]]) -> [any RecordTypeProtocol] {
        components.flatMap { $0 }
    }
}

// MARK: - RecordMetaData

/// The schema for a record store: the set of record types, their primary keys, and indexes —
/// Java's `RecordMetaData`.
///
/// ```swift
/// let meta = RecordMetaData(version: 2) {
///     RecordType(Order.self, primaryKey: \.orderId)
///         .index("priceIdx", on: \.price)
///         .index("byFlower", on: \.flower, addedVersion: 2)   // added in version 2
///     RecordType(Item.self, primaryKey: \.sku)
/// }
/// ```
///
/// Records are stored wrapped in a union message whose field numbers default to declaration
/// order (from 1); indexes default to their name as subspace key. Pin `unionField:` / `key:`
/// explicitly if declarations may be reordered.
public struct RecordMetaData: Sendable {
    /// The schema version, recorded in each store's header. Must never decrease, and must be at
    /// least every index's ``Index/lastModifiedVersion``.
    public let version: Int
    /// Whether records carry versions — store-wide, as in Java.
    public let storeRecordVersions: Bool
    /// Whether records larger than one FDB value are split across several keys (Java's
    /// `splitLongRecords`). On by default here; unsplit records use the same suffix-0 layout
    /// either way, so this only changes whether a >100KB record fails or is split.
    public let splitLongRecords: Bool
    /// Indexes removed from the schema, whose data stores clear on upgrade.
    public let formerIndexes: [FormerIndex]
    /// Java's (deprecated) record-count key: when set, the store keeps an atomic count of
    /// records per value of this expression at `S / 4`.
    public let recordCountKey: KeyExpressionNode?
    /// Synthetic record types.
    let syntheticTypes: [ErasedSyntheticType]
    /// A serialized `FileDescriptorSet` describing the record messages, when known (loaded from
    /// Java metadata, or supplied with ``withDescriptorSet(_:)``). Field names in Java-format
    /// key expressions (e.g. the header's record count key) come from it.
    public private(set) var descriptorSet: Data? = nil

    /// The descriptor set to use for field names and Java metadata: the attached one, else one
    /// reconstructed from the generated Swift message types by reflection (``ProtoReflection``).
    func effectiveDescriptorSet() throws -> Data {
        if let descriptorSet { return descriptorSet }
        let types = recordTypes.compactMap(\.messageType)
        guard types.count == recordTypes.count else {
            throw ProtoReflectionError.unsupported("record types without a known Swift message type")
        }
        return try ProtoReflection.fileDescriptorSet(for: types).serializedData()
    }

    /// The same metadata with a descriptor set for the record messages attached.
    public func withDescriptorSet(_ data: Data) -> RecordMetaData {
        var copy = self
        copy.descriptorSet = data
        return copy
    }

    /// Type-erased record types with their assigned keys.
    let recordTypes: [ErasedRecordType]
    private let indexByName: [String: Int]
    private let typeByUnionField: [Int: Int]

    /// Builds metadata from a list of record-type declarations.
    public init(version: Int = 1, splitLongRecords: Bool = true, formerIndexes: [FormerIndex] = [],
                multiTypeIndexes: [MultiTypeIndex] = [], recordCountKey: KeyExpressionNode? = nil,
                joinedRecordTypes: [JoinedRecordType] = [], unnestedRecordTypes: [UnnestedRecordType] = [],
                types: [any RecordTypeProtocol]) {
        self.init(version: version, splitLongRecords: splitLongRecords, formerIndexes: formerIndexes,
                  multiTypeIndexes: multiTypeIndexes, recordCountKey: recordCountKey,
                  joinedRecordTypes: joinedRecordTypes, unnestedRecordTypes: unnestedRecordTypes,
                  erasedTypes: types.map { ($0 as! any ErasableRecordType)._erase() })
    }

    /// Builds metadata using the result-builder DSL.
    public init(version: Int = 1, splitLongRecords: Bool = true, formerIndexes: [FormerIndex] = [],
                multiTypeIndexes: [MultiTypeIndex] = [], recordCountKey: KeyExpressionNode? = nil,
                joinedRecordTypes: [JoinedRecordType] = [], unnestedRecordTypes: [UnnestedRecordType] = [],
                @RecordMetaDataBuilder _ build: () -> [any RecordTypeProtocol]) {
        self.init(version: version, splitLongRecords: splitLongRecords, formerIndexes: formerIndexes,
                  multiTypeIndexes: multiTypeIndexes, recordCountKey: recordCountKey,
                  joinedRecordTypes: joinedRecordTypes, unnestedRecordTypes: unnestedRecordTypes,
                  types: build())
    }

    /// Builds metadata from already-erased record types, assigning their keys and validating
    /// the schema (Java's `MetaDataValidator` checks that apply here).
    init(version: Int, splitLongRecords: Bool = true, formerIndexes: [FormerIndex] = [],
         multiTypeIndexes: [MultiTypeIndex] = [], recordCountKey: KeyExpressionNode? = nil,
         joinedRecordTypes: [JoinedRecordType] = [], unnestedRecordTypes: [UnnestedRecordType] = [],
         erasedTypes: [ErasedRecordType]) {
        var erased = erasedTypes

        // Legacy Swift layout keys (explicit key, else positional from 0) — kept only so a store
        // written by the pre-Java-layout Swift layer can be migrated.
        var usedLegacy = Set(erased.compactMap { $0.explicitKey })
        precondition(usedLegacy.count == erased.compactMap { $0.explicitKey }.count,
                     "Duplicate explicit record-type keys in RecordMetaData")
        var nextLegacy = 0
        // Union field numbers: explicit, else a positive explicit record type key (so a type
        // pinned with `key:` keeps its union field when declarations are reordered), else
        // declaration order from 1.
        for i in erased.indices where erased[i].explicitUnionField == nil {
            if let key = erased[i].explicitKey, key > 0 { erased[i].pinnedUnionField = key }
        }
        var usedUnion = Set(erased.compactMap { $0.explicitUnionField ?? $0.pinnedUnionField })
        precondition(usedUnion.count == erased.compactMap { $0.explicitUnionField ?? $0.pinnedUnionField }.count,
                     "Duplicate union field numbers in RecordMetaData")
        precondition(usedUnion.allSatisfy { $0 > 0 && $0 < 19000 || $0 > 19999 && $0 <= 536_870_911 },
                     "Union field numbers must be valid protobuf field numbers")
        var nextUnion = 1
        for i in erased.indices {
            if let key = erased[i].explicitKey {
                erased[i].legacyTypeKey = key
            } else {
                while usedLegacy.contains(nextLegacy) { nextLegacy += 1 }
                erased[i].legacyTypeKey = nextLegacy
                usedLegacy.insert(nextLegacy)
            }
            if let field = erased[i].explicitUnionField ?? erased[i].pinnedUnionField {
                erased[i].unionFieldNumber = field
            } else {
                while usedUnion.contains(nextUnion) { nextUnion += 1 }
                erased[i].unionFieldNumber = nextUnion
                usedUnion.insert(nextUnion)
            }
            erased[i].recordTypeKey = Int64(erased[i].explicitKey ?? erased[i].unionFieldNumber)
        }

        // Store-wide record versions, as in Java.
        let versions = erased.contains { $0.storesVersions || $0.indexes.contains { $0.usesRecordVersion } }
        for i in erased.indices { erased[i].storesVersions = versions }

        // Decorate per-type indexes, then add multi-type / universal indexes to each covered type.
        for i in erased.indices {
            for j in erased[i].indexes.indices {
                erased[i].indexes[j].recordTypeNames = [erased[i].recordName]
                erased[i].indexes[j].primaryKeyColumnCount = erased[i].primaryKeyColumnCount
            }
        }
        for multi in multiTypeIndexes {
            let covered = multi.recordTypes.isEmpty ? erased.map(\.recordName) : multi.recordTypes
            for name in covered {
                precondition(erased.contains { $0.recordName == name },
                             "Multi-type index \(multi.name) names unknown record type \(name)")
            }
            let pkCounts = Set(erased.filter { covered.contains($0.recordName) }.map(\.primaryKeyColumnCount))
            precondition(pkCounts.count == 1, "Multi-type index \(multi.name) spans types with different primary key widths")
            let node = multi.expression
            var index = ErasedIndex(
                name: multi.name, type: multi.type,
                subspaceKey: multi.key.map { Int64($0) } ?? multi.name,
                explicitKey: multi.key, unique: multi.options[IndexOptions.unique] == "true",
                producesMultipleKeys: node.producesMultipleKeys,
                columnIdentities: node.columnIdentities(prefix: []),
                addedVersion: multi.addedVersion, lastModifiedVersion: multi.lastModifiedVersion,
                groupedCount: multi.groupedCount ?? multi.type.defaultGroupedCount,
                clearWhenZero: multi.options[IndexOptions.clearWhenZero] == "true",
                rawEntries: { node.evaluate($0) },
                options: multi.options, rootNode: node)
            index.recordTypeNames = covered
            index.primaryKeyColumnCount = pkCounts.first!
            index.isMultiType = true
            index.isUniversal = multi.recordTypes.isEmpty
            for i in erased.indices where covered.contains(erased[i].recordName) {
                erased[i].indexes.append(index)
            }
        }

        // Synthetic types: negative keys (-1, -2, ...) unless given, as in Java.
        var synthetic: [ErasedSyntheticType] = []
        var nextSyntheticKey: Int64 = -1
        let explicitSyntheticKeys = Set(joinedRecordTypes.compactMap(\.recordTypeKey) + unnestedRecordTypes.compactMap(\.recordTypeKey))
        func syntheticKey(_ explicit: Int64?) -> Int64 {
            if let explicit { return explicit }
            while explicitSyntheticKeys.contains(nextSyntheticKey) { nextSyntheticKey -= 1 }
            defer { nextSyntheticKey -= 1 }
            return nextSyntheticKey
        }
        func syntheticIndexes(_ indexes: [SyntheticIndex], typeName: String, constituents: Int) -> [ErasedIndex] {
            indexes.map { decl in
                var index = ErasedIndex(
                    name: decl.name, type: decl.type,
                    subspaceKey: decl.key.map { Int64($0) } ?? decl.name, explicitKey: decl.key,
                    unique: decl.options[IndexOptions.unique] == "true",
                    producesMultipleKeys: decl.expression.producesMultipleKeys,
                    columnIdentities: decl.expression.columnIdentities(prefix: []),
                    addedVersion: decl.addedVersion, lastModifiedVersion: decl.lastModifiedVersion,
                    groupedCount: decl.groupedCount ?? decl.type.defaultGroupedCount,
                    clearWhenZero: decl.options[IndexOptions.clearWhenZero] == "true",
                    rawEntries: { _ in [] }, options: decl.options, rootNode: decl.expression)
                index.recordTypeNames = [typeName]
                // Synthetic primary key: type key + one nested tuple per constituent.
                index.primaryKeyColumnCount = 1 + constituents
                index.syntheticTypeName = typeName
                return index
            }
        }
        for joined in joinedRecordTypes {
            for constituent in joined.constituents {
                precondition(erased.contains { $0.recordName == constituent.recordType },
                             "Joined type \(joined.name) names unknown record type \(constituent.recordType)")
            }
            synthetic.append(ErasedSyntheticType(
                name: joined.name, kind: .joined(joined), recordTypeKey: syntheticKey(joined.recordTypeKey),
                indexes: syntheticIndexes(joined.indexes, typeName: joined.name, constituents: joined.constituents.count)))
        }
        for unnested in unnestedRecordTypes {
            precondition(erased.contains { $0.recordName == unnested.parentType },
                         "Unnested type \(unnested.name) names unknown parent type \(unnested.parentType)")
            synthetic.append(ErasedSyntheticType(
                name: unnested.name, kind: .unnested(unnested), recordTypeKey: syntheticKey(unnested.recordTypeKey),
                indexes: syntheticIndexes(unnested.indexes, typeName: unnested.name, constituents: 1 + unnested.nested.count)))
        }

        // Index validation.
        var names = Set<String>()
        var subspaceKeys = Set<FDB.Bytes>()
        var seenMultiType = Set<String>()
        for type in erased {
            if type.primaryKeyStartsWithRecordType {
                let keys = Set(erased.filter(\.primaryKeyStartsWithRecordType).map(\.recordTypeKey))
                precondition(keys.count == erased.filter(\.primaryKeyStartsWithRecordType).count,
                             "Record types with recordType()-prefixed primary keys need distinct record type keys")
            }
            for index in type.indexes {
                if index.isMultiType, !seenMultiType.insert(index.name).inserted { continue }
                precondition(names.insert(index.name).inserted, "Duplicate index name \(index.name)")
                precondition(subspaceKeys.insert(index.subspaceTupleKey.encode()).inserted,
                             "Duplicate index subspace key for index \(index.name)")
                precondition(index.lastModifiedVersion <= version,
                             "Index \(index.name) lastModifiedVersion \(index.lastModifiedVersion) exceeds metadata version \(version)")
                precondition(index.addedVersion <= index.lastModifiedVersion,
                             "Index \(index.name) addedVersion exceeds lastModifiedVersion")
                precondition(!index.unique || index.type == .value,
                             "Index \(index.name): only value indexes can be unique")
            }
        }
        for index in synthetic.flatMap(\.indexes) {
            precondition(names.insert(index.name).inserted, "Duplicate index name \(index.name)")
            precondition(subspaceKeys.insert(index.subspaceTupleKey.encode()).inserted,
                         "Duplicate index subspace key for index \(index.name)")
            precondition(index.lastModifiedVersion <= version, "Index \(index.name) is newer than the metadata")
        }
        for former in formerIndexes {
            precondition(!subspaceKeys.contains(Tuple(former.subspaceKey).encode()),
                         "FormerIndex subspace key is reused by a current index")
            precondition(former.removedVersion <= version, "FormerIndex removedVersion exceeds metadata version")
        }

        self.version = version
        self.storeRecordVersions = versions
        self.splitLongRecords = splitLongRecords
        self.formerIndexes = formerIndexes
        self.recordCountKey = recordCountKey
        self.syntheticTypes = synthetic
        self.recordTypes = erased
        var byName: [String: Int] = [:]
        var byUnion: [Int: Int] = [:]
        for (i, type) in erased.enumerated() {
            byName[type.recordName] = i
            byUnion[type.unionFieldNumber] = i
        }
        self.indexByName = byName
        self.typeByUnionField = byUnion
    }

    /// Looks up the erased record type for a protobuf message type.
    func recordType<M: SwiftProtobuf.Message>(for type: M.Type) -> ErasedRecordType? {
        recordType(named: M.protoMessageName)
    }

    /// Looks up the erased record type by its protobuf message name.
    func recordType(named name: String) -> ErasedRecordType? {
        guard let index = indexByName[name] else { return nil }
        return recordTypes[index]
    }

    /// Looks up the record type stored under a union field number.
    func recordType(unionField: Int) -> ErasedRecordType? {
        typeByUnionField[unionField].map { recordTypes[$0] }
    }

    /// Looks up the erased record type that declares the index named `indexName`.
    func recordType(forIndexNamed indexName: String) -> ErasedRecordType? {
        recordTypes.first { $0.indexes.contains { $0.name == indexName } }
    }

    /// Every index in the schema, once each (multi-type indexes appear on several types).
    var allIndexes: [ErasedIndex] {
        var seen = Set<String>()
        var result: [ErasedIndex] = []
        for index in recordTypes.flatMap(\.indexes) + syntheticTypes.flatMap(\.indexes)
            where seen.insert(index.name).inserted {
            result.append(index)
        }
        return result
    }

    /// Looks up an index by name.
    func index(named name: String) -> ErasedIndex? {
        for type in recordTypes { if let index = type.indexes.first(where: { $0.name == name }) { return index } }
        for type in syntheticTypes { if let index = type.indexes.first(where: { $0.name == name }) { return index } }
        return nil
    }

    /// Looks up a synthetic type by name.
    func syntheticType(named name: String) -> ErasedSyntheticType? {
        syntheticTypes.first { $0.name == name }
    }

    /// Synthetic types built from records of `recordTypeName`.
    func syntheticTypes(involving recordTypeName: String) -> [ErasedSyntheticType] {
        syntheticTypes.filter { $0.constituentRecordTypes.contains(recordTypeName) }
    }
}
#endif
