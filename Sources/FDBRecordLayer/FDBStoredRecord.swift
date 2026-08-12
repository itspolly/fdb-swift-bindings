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
/// last written, plus a counter distinguishing records written by the same transaction.
///
/// The 12-byte layout matches the Java Record Layer:
///
/// ```
/// | 0 ..< 10                     | 10 ..< 12                  |
/// | commit versionstamp (global) | local version (big-endian) |
/// ```
///
/// The global half is assigned by FoundationDB at commit and is monotonic across transactions;
/// the local half is claimed from ``FDBRecordContext`` per saved record, so two records saved in
/// *one* transaction still receive distinct, save-ordered versions. Because the local version is
/// big-endian and trails the versionstamp, plain lexicographic byte order is version order.
///
/// A version changes every time the record is saved — an opaque optimistic-concurrency token (an
/// ETag). Populated on `load` for record types that opt in via ``RecordType/storingVersions(_:)``,
/// and compared by ``FDBRecordStore/save(_:ifVersionMatches:)``.
public struct FDBRecordVersion: Sendable, Hashable {
    /// Byte length of the FoundationDB commit versionstamp that opens a version.
    public static let globalVersionLength = 10
    /// Byte length of the trailing local-version counter.
    public static let localVersionLength = 2

    /// The raw version bytes: a 10-byte versionstamp followed by the 2-byte local version.
    public let bytes: FDB.Bytes

    public init(bytes: FDB.Bytes) {
        self.bytes = bytes
    }

    /// The commit versionstamp half — equal for every record written by the same transaction.
    public var globalVersion: FDB.Bytes {
        Array(bytes.prefix(Self.globalVersionLength))
    }

    /// The within-transaction counter half, or `nil` for versions that predate it.
    public var localVersion: Int? {
        let tail = bytes.dropFirst(Self.globalVersionLength)
        guard tail.count == Self.localVersionLength else { return nil }
        return tail.reduce(0) { $0 << 8 | Int($1) }
    }

    /// The value written before commit: a zeroed versionstamp placeholder that FoundationDB
    /// overwrites in place, followed by the already-known local version.
    static func incompleteBytes(localVersion: Int) -> FDB.Bytes {
        FDB.Bytes(repeating: 0, count: globalVersionLength)
            + withUnsafeBytes(of: UInt16(localVersion).bigEndian) { Array($0) }
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
