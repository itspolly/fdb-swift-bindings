/*
 * RecordLayer.swift
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

/// # FDBRecordLayer
///
/// A Swift port of the FoundationDB Record Layer: a schema-driven store for
/// Protocol Buffer records layered on top of the low-level ``FoundationDB`` bindings.
///
/// The Record Layer maintains a clustered primary-key index plus secondary indexes,
/// and answers ``RecordQuery`` requests through a small rule-based planner.
///
/// ## Enabling the layer
///
/// This module only contains code when the package's `RecordLayer` trait is enabled
/// (it pulls in `swift-protobuf`). Enable it from a consuming package:
///
/// ```swift
/// .package(url: "...", traits: ["RecordLayer"])
/// ```
///
/// or on the command line with `swift build --traits RecordLayer`.
///
/// ## Core types
///
/// - ``FDBRecordContext`` — a transaction-scoped handle.
/// - ``RecordMetaData`` — the schema: record types, primary keys, and indexes.
/// - ``FDBRecordStore`` — save/load/delete/query operations within a context.
/// - ``FDBStoredRecord`` — a persisted record with its primary key and version.
/// - ``RecordQuery`` — declarative query criteria executed by the planner.
#if RecordLayer
import SwiftProtobuf

/// The store format version this implementation writes: Java's
/// `FormatVersion.FULL_STORE_LOCK` (14). See ``FormatVersion``.
public let recordLayerFormatVersion = FormatVersion.current.rawValue

/// The Java Record Layer's `FormatVersion`: a monotonically increasing number in each store's
/// header recording which on-disk features the store may use.
///
/// This implementation reads and writes stores up to ``current``. Opening a store whose header
/// carries a higher version fails, exactly as the Java layer refuses stores from a newer client.
/// Stores below ``minimumSupported`` predate features this implementation relies on (records
/// carrying a split suffix, versions stored beside records) and are refused rather than read
/// in a legacy mode.
public enum FormatVersion: Int, Sendable, Comparable, CaseIterable {
    case infoAdded = 1
    case recordCountAdded = 2
    case recordCountKeyAdded = 3
    case formatControl = 4
    case saveUnsplitWithSuffix = 5
    case saveVersionWithRecord = 6
    case cacheableState = 7
    case headerUserFields = 8
    case readableUniquePending = 9
    case checkIndexBuildTypeDuringUpdate = 10
    case recordCountState = 11
    case storeLockState = 12
    case incarnation = 13
    case fullStoreLock = 14

    /// The version written to new stores and that existing stores are upgraded to on open.
    public static let current: FormatVersion = .fullStoreLock
    /// The oldest Java store format this implementation can open.
    public static let minimumSupported: FormatVersion = .saveVersionWithRecord

    public static func < (lhs: FormatVersion, rhs: FormatVersion) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The top-level keyspaces of a record store's subspace — Java's `FDBRecordStoreKeyspace`.
enum RecordStoreKeyspace: Int64, Sendable {
    case storeInfo = 0
    case record = 1
    case index = 2
    case indexSecondarySpace = 3
    case recordCount = 4
    case indexStateSpace = 5
    case indexRangeSpace = 6
    case indexUniquenessViolationsSpace = 7
    case recordVersionSpace = 8
    case indexBuildSpace = 9
    case indexSlidingWindowSpace = 10
}
#endif
