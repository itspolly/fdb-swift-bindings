/*
 * SyntheticRecordTypes.swift
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

/// An index on a synthetic record type. Its expression addresses constituents as fields of the
/// synthetic record: field number `i` (1-based, in constituent declaration order) is the `i`-th
/// constituent, so `.nest(number: 2, fanType: nil, child: .field(number: 3, fanType: nil))` is
/// field 3 of the second constituent — Java's `field("constituentName").nest("field")`.
public struct SyntheticIndex: Sendable {
    public let name: String
    public let type: IndexType
    public let expression: KeyExpressionNode
    public let key: Int?
    public let addedVersion: Int
    public let lastModifiedVersion: Int
    public let groupedCount: Int?
    public let options: [String: String]

    public init(
        _ name: String, on expression: KeyExpressionNode, type: IndexType = .value, key: Int? = nil,
        addedVersion: Int? = nil, lastModifiedVersion: Int? = nil, groupedCount: Int? = nil,
        options: [String: String] = [:]
    ) {
        self.name = name
        self.type = type
        self.expression = expression
        self.key = key
        let modified = lastModifiedVersion ?? addedVersion ?? 0
        self.lastModifiedVersion = modified
        self.addedVersion = addedVersion ?? modified
        self.groupedCount = groupedCount
        self.options = options
    }
}

/// A record type defined as a join of stored records — Java's `JoinedRecordType`. Joined
/// records are never stored; their indexes are maintained whenever a constituent is saved or
/// deleted.
public struct JoinedRecordType: Sendable {
    public struct Constituent: Sendable {
        public let name: String
        /// The stored record type's proto message name.
        public let recordType: String
        /// Whether the join still produces a record when this constituent has no match.
        public let outerJoined: Bool

        public init(_ name: String, _ type: any SwiftProtobuf.Message.Type, outerJoined: Bool = false) {
            self.init(name, recordTypeName: type.protoMessageName, outerJoined: outerJoined)
        }

        public init(_ name: String, recordTypeName: String, outerJoined: Bool = false) {
            self.name = name
            self.recordType = recordTypeName
            self.outerJoined = outerJoined
        }
    }

    /// An equality condition: `left.leftExpression == right.rightExpression`.
    public struct Join: Sendable {
        public let left: String
        public let leftExpression: KeyExpressionNode
        public let right: String
        public let rightExpression: KeyExpressionNode

        public init(_ left: String, _ leftExpression: KeyExpressionNode,
                    _ right: String, _ rightExpression: KeyExpressionNode) {
            self.left = left
            self.leftExpression = leftExpression
            self.right = right
            self.rightExpression = rightExpression
        }
    }

    public let name: String
    public let recordTypeKey: Int64?
    public let constituents: [Constituent]
    public let joins: [Join]
    public let indexes: [SyntheticIndex]

    public init(_ name: String, recordTypeKey: Int64? = nil, constituents: [Constituent], joins: [Join],
                indexes: [SyntheticIndex] = []) {
        self.name = name
        self.recordTypeKey = recordTypeKey
        self.constituents = constituents
        self.joins = joins
        self.indexes = indexes
    }
}

/// A record type with one synthetic record per element of nested repeated message(s) of a
/// stored record — Java's `UnnestedRecordType`.
public struct UnnestedRecordType: Sendable {
    public struct NestedConstituent: Sendable {
        public let name: String
        /// The constituent this one is nested in (the parent's name, or another nested one's).
        public let parent: String
        /// The nested message's proto name.
        public let typeName: String
        /// The expression producing the nested messages from the parent, e.g.
        /// `.field(number: 5, fanType: .fanOut)` for a repeated message field.
        public let nestingExpression: KeyExpressionNode

        public init(_ name: String, parent: String, typeName: String, nestingExpression: KeyExpressionNode) {
            self.name = name
            self.parent = parent
            self.typeName = typeName
            self.nestingExpression = nestingExpression
        }
    }

    public let name: String
    public let recordTypeKey: Int64?
    /// The parent constituent's name and stored record type.
    public let parentName: String
    public let parentType: String
    public let nested: [NestedConstituent]
    public let indexes: [SyntheticIndex]

    public init(_ name: String, recordTypeKey: Int64? = nil, parentName: String,
                parentType: any SwiftProtobuf.Message.Type, nested: [NestedConstituent],
                indexes: [SyntheticIndex] = []) {
        self.init(name, recordTypeKey: recordTypeKey, parentName: parentName,
                  parentTypeName: parentType.protoMessageName, nested: nested, indexes: indexes)
    }

    public init(_ name: String, recordTypeKey: Int64? = nil, parentName: String, parentTypeName: String,
                nested: [NestedConstituent], indexes: [SyntheticIndex] = []) {
        self.name = name
        self.recordTypeKey = recordTypeKey
        self.parentName = parentName
        self.parentType = parentTypeName
        self.nested = nested
        self.indexes = indexes
    }

    /// Constituent names in synthetic-field order: the parent, then each nested constituent.
    var constituentNames: [String] { [parentName] + nested.map(\.name) }
}

/// A synthetic type after metadata resolution.
struct ErasedSyntheticType: Sendable {
    enum Kind: Sendable {
        case joined(JoinedRecordType)
        case unnested(UnnestedRecordType)
    }

    let name: String
    let kind: Kind
    var recordTypeKey: Int64
    var indexes: [ErasedIndex]

    /// Stored record types this type is built from.
    var constituentRecordTypes: Set<String> {
        switch kind {
        case .joined(let joined): return Set(joined.constituents.map(\.recordType))
        case .unnested(let unnested): return [unnested.parentType]
        }
    }
}
#endif
