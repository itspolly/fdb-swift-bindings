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
    /// An explicit, stable key prefixing this type's records. When provided, the on-disk layout
    /// is independent of declaration order; when `nil`, a positional key is assigned. Treat keys
    /// like protobuf field numbers: never reuse a retired one.
    public let key: Int?

    /// Creates a record type with an explicit primary-key expression.
    public init(_ type: M.Type, key: Int? = nil, primaryKey: KeyExpression<M>) {
        self.recordName = M.protoMessageName
        self.primaryKey = primaryKey
        self.indexes = []
        self.key = key
    }

    /// Creates a record type with a single-field primary key.
    public init<V: IndexableValue>(_ type: M.Type, key: Int? = nil, primaryKey keyPath: KeyPath<M, V> & Sendable) {
        self.init(type, key: key, primaryKey: .field(keyPath))
    }

    // Composite primary keys use `init(_:primaryKey:)` with `.concat(...)`.

    // MARK: Index builders (chainable)

    /// Adds an index built from an arbitrary key expression.
    public func index(_ name: String, on expression: KeyExpression<M>, type: IndexType = .value, key: Int? = nil) -> RecordType<M> {
        var copy = self
        copy.indexes.append(Index(name, expression, type: type, key: key))
        return copy
    }

    /// Adds a single-field (possibly nested) value index.
    public func index<V: IndexableValue>(
        _ name: String, on keyPath: KeyPath<M, V> & Sendable, type: IndexType = .value, key: Int? = nil
    ) -> RecordType<M> {
        index(name, on: .field(keyPath), type: type, key: key)
    }

    /// Adds an index over a repeated field.
    public func index<V: IndexableValue>(
        _ name: String, on keyPath: KeyPath<M, [V]> & Sendable, fanType: FanType = .fanOut,
        type: IndexType = .value, key: Int? = nil
    ) -> RecordType<M> {
        index(name, on: .field(keyPath, fanType), type: type, key: key)
    }

    func _erase() -> ErasedRecordType {
        let pk = primaryKey
        let erasedIndexes = indexes.map { idx in
            ErasedIndex(
                name: idx.name,
                type: idx.type,
                subspaceKey: -1,
                explicitKey: idx.key,
                producesMultipleKeys: idx.expression.producesMultipleKeys,
                columnIdentities: idx.expression.columnIdentities,
                entries: { message in idx.expression.evaluate(message as! M) }
            )
        }
        return ErasedRecordType(
            recordName: recordName,
            typeKey: -1,
            explicitKey: key,
            primaryKeyColumns: { message in pk.evaluate(message as! M).first ?? [] },
            primaryKeyIdentities: pk.columnIdentities,
            deserialize: { bytes in try M(serializedBytes: bytes) },
            indexes: erasedIndexes
        )
    }
}

// MARK: - Type-erased internals

/// Internal, type-erased view of an ``Index`` used by the store and planner.
struct ErasedIndex: Sendable {
    let name: String
    let type: IndexType
    /// Assigned by ``RecordMetaData`` to give the index its own key subspace.
    var subspaceKey: Int
    /// Caller-supplied stable key, if any (otherwise positional).
    let explicitKey: Int?
    let producesMultipleKeys: Bool
    let columnIdentities: [FieldID?]
    /// Computes the index entries (columns, before the primary key) for a record.
    let entries: @Sendable (any SwiftProtobuf.Message) -> [[any TupleElement]]
}

/// Internal, type-erased view of a ``RecordType`` used by the store.
struct ErasedRecordType: Sendable {
    let recordName: String
    /// Assigned by ``RecordMetaData``; prefixes every record key of this type.
    var typeKey: Int
    /// Caller-supplied stable key, if any (otherwise positional).
    let explicitKey: Int?
    let primaryKeyColumns: @Sendable (any SwiftProtobuf.Message) -> [any TupleElement]
    let primaryKeyIdentities: [FieldID?]
    let deserialize: @Sendable ([UInt8]) throws -> any SwiftProtobuf.Message
    var indexes: [ErasedIndex]
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

/// The schema for a record store: the set of record types, their primary keys, and indexes.
///
/// Build it with the result-builder DSL:
///
/// ```swift
/// let meta = RecordMetaData {
///     RecordType(Order.self, primaryKey: \.orderId)
///         .index("priceIdx", on: \.price)
///     RecordType(Item.self, primaryKey: \.sku)
/// }
/// ```
///
/// Record types are assigned integer keys in declaration order, and indexes are assigned
/// their own key subspaces in declaration order. Reordering declarations therefore changes
/// the on-disk layout — keep the order stable for an existing store.
public struct RecordMetaData: Sendable {
    /// A user-controlled schema version, stored in the record store header.
    public let version: Int

    /// Type-erased record types with their assigned keys.
    let recordTypes: [ErasedRecordType]
    private let indexByName: [String: Int]

    /// Builds metadata from a list of record-type declarations.
    public init(version: Int = 1, types: [any RecordTypeProtocol]) {
        self.init(version: version, erasedTypes: types.map { ($0 as! any ErasableRecordType)._erase() })
    }

    /// Builds metadata from already-erased record types, assigning their on-disk keys.
    ///
    /// Shared by the Swift DSL and the proto-annotation paths.
    init(version: Int, erasedTypes: [ErasedRecordType]) {
        var erased = erasedTypes

        // Resolve each record type's and index's storage key: use the explicit key when given,
        // otherwise fill the next free position. Explicit keys make the layout independent of
        // declaration order; positional keys preserve the original behavior for keyless schemas.
        var usedTypeKeys = Set(erased.compactMap { $0.explicitKey })
        precondition(usedTypeKeys.count == erased.compactMap { $0.explicitKey }.count,
                     "Duplicate explicit record-type keys in RecordMetaData")
        let allIndexExplicitKeys = erased.flatMap { $0.indexes.compactMap { $0.explicitKey } }
        var usedIndexKeys = Set(allIndexExplicitKeys)
        precondition(usedIndexKeys.count == allIndexExplicitKeys.count,
                     "Duplicate explicit index keys in RecordMetaData")

        var nextTypeKey = 0
        var nextIndexKey = 0
        for typeIndex in erased.indices {
            if let key = erased[typeIndex].explicitKey {
                erased[typeIndex].typeKey = key
            } else {
                while usedTypeKeys.contains(nextTypeKey) { nextTypeKey += 1 }
                erased[typeIndex].typeKey = nextTypeKey
                usedTypeKeys.insert(nextTypeKey)
            }
            for indexIndex in erased[typeIndex].indexes.indices {
                if let key = erased[typeIndex].indexes[indexIndex].explicitKey {
                    erased[typeIndex].indexes[indexIndex].subspaceKey = key
                } else {
                    while usedIndexKeys.contains(nextIndexKey) { nextIndexKey += 1 }
                    erased[typeIndex].indexes[indexIndex].subspaceKey = nextIndexKey
                    usedIndexKeys.insert(nextIndexKey)
                }
            }
        }
        self.version = version
        self.recordTypes = erased
        var byName: [String: Int] = [:]
        for (i, type) in erased.enumerated() {
            byName[type.recordName] = i
        }
        self.indexByName = byName
    }

    /// Builds metadata using the result-builder DSL.
    public init(version: Int = 1, @RecordMetaDataBuilder _ build: () -> [any RecordTypeProtocol]) {
        self.init(version: version, types: build())
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

    /// Looks up the erased record type that declares the index named `indexName`.
    func recordType(forIndexNamed indexName: String) -> ErasedRecordType? {
        recordTypes.first { $0.indexes.contains { $0.name == indexName } }
    }
}
#endif
