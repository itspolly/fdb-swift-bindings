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

/// Marker for the current Record Layer source format version.
///
/// Stored in each record store's header so the store can detect data written by an
/// incompatible future version of the layer.
public let recordLayerFormatVersion = 1
#endif
