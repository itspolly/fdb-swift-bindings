/*
 * FDBStoredRecord.swift
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

/// A record's version: the commit versionstamp assigned by FoundationDB when the record was
/// last written.
///
/// Monotonic and unique per committing transaction, so it changes every time the record is
/// saved — an opaque optimistic-concurrency token (an ETag). Populated on `load` for record
/// types that opt in via ``RecordType/storingVersions(_:)``, and compared by
/// ``FDBRecordStore/save(_:ifVersionMatches:)``.
public struct FDBRecordVersion: Sendable, Hashable {
    /// The raw version bytes (a FoundationDB versionstamp).
    public let bytes: FDB.Bytes

    public init(bytes: FDB.Bytes) {
        self.bytes = bytes
    }
}

/// A record that has been (or is being) persisted in a record store.
///
/// Carries the deserialized message along with its primary key, the protobuf type name, and,
/// for version-indexed records, the assigned ``FDBRecordVersion``.
public struct FDBStoredRecord<M: SwiftProtobuf.Message & Sendable>: Sendable {
    /// The fully-qualified protobuf message name of the record's type.
    public let recordType: String
    /// The record's primary key.
    public let primaryKey: Tuple
    /// The record itself.
    public let record: M
    /// The record's version, if the store maintains versions.
    public let version: FDBRecordVersion?

    public init(recordType: String, primaryKey: Tuple, record: M, version: FDBRecordVersion? = nil) {
        self.recordType = recordType
        self.primaryKey = primaryKey
        self.record = record
        self.version = version
    }
}
#endif
