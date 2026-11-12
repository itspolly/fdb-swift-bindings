/*
 * StoreHeader.swift
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

// MARK: - Minimal protobuf wire codec

/// A minimal protobuf (proto2) wire-format reader/writer for the handful of Record Layer
/// messages the store persists itself (`DataStoreInfo`, `IndexBuildIndexingStamp`).
///
/// Messages are kept as an ordered list of raw fields, so fields this code doesn't know about —
/// written by a newer Java or Swift Record Layer — survive a read-modify-write untouched, exactly
/// as protobuf-java preserves unknown fields.
struct ProtoFields: Sendable, Equatable {
    enum WireType: UInt8, Sendable { case varint = 0, fixed64 = 1, lengthDelimited = 2, fixed32 = 5 }

    struct Field: Sendable, Equatable {
        let number: Int
        let wireType: WireType
        /// For varint fields the decoded value; otherwise unused.
        let varint: UInt64
        /// For length-delimited / fixed fields, the raw payload bytes.
        let payload: FDB.Bytes
    }

    private(set) var fields: [Field] = []

    init() {}

    init(decoding bytes: FDB.Bytes) throws {
        var offset = 0
        while offset < bytes.count {
            let tag = try Self.readVarint(bytes, &offset)
            let number = Int(tag >> 3)
            guard number > 0, let wireType = WireType(rawValue: UInt8(tag & 0x7)) else {
                throw RecordStoreError.corruptHeader
            }
            switch wireType {
            case .varint:
                fields.append(Field(number: number, wireType: wireType, varint: try Self.readVarint(bytes, &offset), payload: []))
            case .fixed64, .fixed32:
                let width = wireType == .fixed64 ? 8 : 4
                guard offset + width <= bytes.count else { throw RecordStoreError.corruptHeader }
                fields.append(Field(number: number, wireType: wireType, varint: 0, payload: Array(bytes[offset..<offset + width])))
                offset += width
            case .lengthDelimited:
                let length = Int(try Self.readVarint(bytes, &offset))
                guard length >= 0, offset + length <= bytes.count else { throw RecordStoreError.corruptHeader }
                fields.append(Field(number: number, wireType: wireType, varint: 0, payload: Array(bytes[offset..<offset + length])))
                offset += length
            }
        }
    }

    func encode() -> FDB.Bytes {
        var out: FDB.Bytes = []
        for field in fields {
            Self.writeVarint(UInt64(field.number << 3) | UInt64(field.wireType.rawValue), into: &out)
            switch field.wireType {
            case .varint:
                Self.writeVarint(field.varint, into: &out)
            case .fixed64, .fixed32:
                out += field.payload
            case .lengthDelimited:
                Self.writeVarint(UInt64(field.payload.count), into: &out)
                out += field.payload
            }
        }
        return out
    }

    // Accessors (last occurrence wins for singular fields, as in protobuf).

    func varint(_ number: Int) -> UInt64? {
        fields.last { $0.number == number && $0.wireType == .varint }?.varint
    }

    func bytes(_ number: Int) -> FDB.Bytes? {
        fields.last { $0.number == number && $0.wireType == .lengthDelimited }?.payload
    }

    func repeatedBytes(_ number: Int) -> [FDB.Bytes] {
        fields.filter { $0.number == number && $0.wireType == .lengthDelimited }.map(\.payload)
    }

    func has(_ number: Int) -> Bool { fields.contains { $0.number == number } }

    /// Replaces every occurrence of a singular varint field (or removes it when `nil`), keeping
    /// the field's original position when present so re-encoding is stable.
    mutating func setVarint(_ number: Int, _ value: UInt64?) {
        replace(number, with: value.map { [Field(number: number, wireType: .varint, varint: $0, payload: [])] } ?? [])
    }

    mutating func setBytes(_ number: Int, _ value: FDB.Bytes?) {
        replace(number, with: value.map { [Field(number: number, wireType: .lengthDelimited, varint: 0, payload: $0)] } ?? [])
    }

    mutating func setRepeatedBytes(_ number: Int, _ values: [FDB.Bytes]) {
        replace(number, with: values.map { Field(number: number, wireType: .lengthDelimited, varint: 0, payload: $0) })
    }

    private mutating func replace(_ number: Int, with newFields: [Field]) {
        if let first = fields.firstIndex(where: { $0.number == number }) {
            fields.removeAll { $0.number == number }
            fields.insert(contentsOf: newFields, at: min(first, fields.count))
        } else {
            // Keep fields in ascending number order for new fields, like generated code does.
            let insertAt = fields.firstIndex { $0.number > number } ?? fields.count
            fields.insert(contentsOf: newFields, at: insertAt)
        }
    }

    static func readVarint(_ bytes: FDB.Bytes, _ offset: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < bytes.count, shift < 64 else { throw RecordStoreError.corruptHeader }
            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    static func writeVarint(_ value: UInt64, into out: inout FDB.Bytes) {
        var v = value
        while v >= 0x80 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
    }

    /// proto `int32` values are sign-extended to 64 bits on the wire.
    static func int32(_ raw: UInt64?) -> Int32? { raw.map { Int32(truncatingIfNeeded: Int64(bitPattern: $0)) } }
    static func raw(_ value: Int32) -> UInt64 { UInt64(bitPattern: Int64(value)) }
}

// MARK: - DataStoreInfo

/// The record store header, stored at `store / 0` — Java's `RecordMetaDataProto.DataStoreInfo`.
///
/// Field numbers match `record_metadata.proto` in the Java Record Layer, so a store's header is
/// readable by either implementation. Unknown fields are preserved on rewrite.
public struct DataStoreInfo: Sendable, Equatable {
    /// Java's `DataStoreInfo.StoreLockState.State`.
    public enum LockState: Int32, Sendable {
        case unspecified = 0
        /// Records may not be created, updated or deleted; indexes and metadata may still change.
        case forbidRecordUpdate = 1
        /// The store may not be opened at all unless the opener presents the lock's reason.
        case fullStore = 2
    }

    /// Java's `DataStoreInfo.StoreLockState`.
    public struct StoreLockState: Sendable, Equatable {
        public var state: LockState
        public var reason: String
        public var timestamp: Int64

        public init(state: LockState, reason: String, timestamp: Int64 = 0) {
            self.state = state
            self.reason = reason
            self.timestamp = timestamp
        }
    }

    var fields: ProtoFields

    public init() { fields = ProtoFields() }

    init(decoding bytes: FDB.Bytes) throws { fields = try ProtoFields(decoding: bytes) }

    func encode() -> FDB.Bytes { fields.encode() }

    /// `formatVersion` (field 1). `0` means the header has never been written (a new store).
    public var formatVersion: Int {
        get { Int(ProtoFields.int32(fields.varint(1)) ?? 0) }
        set { fields.setVarint(1, ProtoFields.raw(Int32(newValue))) }
    }

    /// `metaDataversion` (field 2).
    public var metaDataVersion: Int {
        get { Int(ProtoFields.int32(fields.varint(2)) ?? 0) }
        set { fields.setVarint(2, ProtoFields.raw(Int32(newValue))) }
    }

    /// `userVersion` (field 3).
    public var userVersion: Int {
        get { Int(ProtoFields.int32(fields.varint(3)) ?? 0) }
        set { fields.setVarint(3, ProtoFields.raw(Int32(newValue))) }
    }

    /// `record_count_key` (field 4): the serialized `KeyExpression` the counts were built with.
    var recordCountKey: FDB.Bytes? {
        get { fields.bytes(4) }
        set { fields.setBytes(4, newValue) }
    }

    /// Java's `DataStoreInfo.RecordCountState`.
    public enum RecordCountState: Int32, Sendable {
        case readable = 1
        case writeOnly = 2
        case disabled = 3
    }

    /// `record_count_state` (field 9); absent means readable.
    public var recordCountState: RecordCountState? {
        get { ProtoFields.int32(fields.varint(9)).flatMap(RecordCountState.init(rawValue:)) }
        set { fields.setVarint(9, newValue.map { ProtoFields.raw($0.rawValue) }) }
    }

    /// `lastUpdateTime` (field 5), milliseconds since the epoch.
    public var lastUpdateTime: UInt64 {
        get { fields.varint(5) ?? 0 }
        set { fields.setVarint(5, newValue) }
    }

    /// `omit_unsplit_record_suffix` (field 6).
    public var omitUnsplitRecordSuffix: Bool {
        get { (fields.varint(6) ?? 0) != 0 }
        set { fields.setVarint(6, newValue ? 1 : nil) }
    }

    /// `cacheable` (field 7).
    public var cacheable: Bool {
        get { (fields.varint(7) ?? 0) != 0 }
        set { fields.setVarint(7, newValue ? 1 : nil) }
    }

    /// `user_field` (field 8): a small user-defined map persisted in the header.
    public var userFields: [String: FDB.Bytes] {
        get {
            var result: [String: FDB.Bytes] = [:]
            for entry in fields.repeatedBytes(8) {
                guard let parsed = try? ProtoFields(decoding: entry) else { continue }
                let key = parsed.bytes(1).map { String(decoding: $0, as: UTF8.self) } ?? ""
                result[key] = parsed.bytes(2) ?? []
            }
            return result
        }
        set {
            let entries = newValue.sorted { $0.key < $1.key }.map { key, value -> FDB.Bytes in
                var entry = ProtoFields()
                entry.setBytes(1, Array(key.utf8))
                entry.setBytes(2, value)
                return entry.encode()
            }
            fields.setRepeatedBytes(8, entries)
        }
    }

    /// `store_lock_state` (field 10).
    public var storeLockState: StoreLockState? {
        get {
            guard let raw = fields.bytes(10), let parsed = try? ProtoFields(decoding: raw) else { return nil }
            let state = LockState(rawValue: ProtoFields.int32(parsed.varint(1)) ?? 0) ?? .unspecified
            let reason = parsed.bytes(2).map { String(decoding: $0, as: UTF8.self) } ?? ""
            let timestamp = parsed.varint(3).map { Int64(bitPattern: $0) } ?? 0
            return StoreLockState(state: state, reason: reason, timestamp: timestamp)
        }
        set {
            guard let newValue else { fields.setBytes(10, nil); return }
            var lock = ProtoFields()
            lock.setVarint(1, ProtoFields.raw(newValue.state.rawValue))
            lock.setBytes(2, Array(newValue.reason.utf8))
            lock.setVarint(3, UInt64(bitPattern: newValue.timestamp))
            fields.setBytes(10, lock.encode())
        }
    }

    /// `incarnation` (field 11).
    public var incarnation: Int {
        get { Int(ProtoFields.int32(fields.varint(11)) ?? 0) }
        set { fields.setVarint(11, ProtoFields.raw(Int32(newValue))) }
    }
}

// MARK: - IndexBuildIndexingStamp

/// Java's `IndexBuildProto.IndexBuildIndexingStamp`, stored at
/// `store / 9 / indexSubspaceKey / 2` while an index is being built. It records *how* the index
/// is being built so that writers can tell which of their updates the build already covers, and
/// so that a later indexer can tell whether it may continue the build.
///
/// Fields (`index_build.proto`):
/// 1. `method`
/// 2. `source_index_subspace_key` — BY_INDEX only: the source index's subspace key, tuple-packed
/// 3. `source_index_last_modified_version` — BY_INDEX only
/// 4. `targetIndex` (repeated) — MULTI_TARGET / MUTUAL only: target names, sorted; the first is
///    the primary index
/// 5. `block`, 6. `blockExpireEpochMilliSeconds`, 7. `blockID`
///
/// Unknown fields are preserved, and new fields are written in field-number order, so a stamp
/// built here encodes to the same bytes protobuf-java produces.
struct IndexBuildIndexingStamp: Sendable, Equatable {
    enum Method: Int32, Sendable, CustomStringConvertible {
        case invalid = 0
        case byRecords = 1
        case byIndex = 2
        case scrubRepair = 3
        case multiTargetByRecords = 4
        case mutualByRecords = 5
        case none = 6

        var description: String {
            switch self {
            case .invalid: return "INVALID"
            case .byRecords: return "BY_RECORDS"
            case .byIndex: return "BY_INDEX"
            case .scrubRepair: return "SCRUB_REPAIR"
            case .multiTargetByRecords: return "MULTI_TARGET_BY_RECORDS"
            case .mutualByRecords: return "MUTUAL_BY_RECORDS"
            case .none: return "NONE"
            }
        }
    }

    var fields: ProtoFields

    init(method: Method, sourceIndexSubspaceKey: FDB.Bytes? = nil, sourceIndexLastModifiedVersion: Int? = nil,
         targetIndexes: [String] = []) {
        fields = ProtoFields()
        fields.setVarint(1, ProtoFields.raw(method.rawValue))
        if let sourceIndexSubspaceKey { fields.setBytes(2, sourceIndexSubspaceKey) }
        if let sourceIndexLastModifiedVersion {
            fields.setVarint(3, ProtoFields.raw(Int32(truncatingIfNeeded: sourceIndexLastModifiedVersion)))
        }
        if !targetIndexes.isEmpty { fields.setRepeatedBytes(4, targetIndexes.map { Array($0.utf8) }) }
    }

    init(decoding bytes: FDB.Bytes) throws { fields = try ProtoFields(decoding: bytes) }

    func encode() -> FDB.Bytes { fields.encode() }

    var method: Method { Method(rawValue: ProtoFields.int32(fields.varint(1)) ?? 0) ?? .invalid }

    /// `source_index_subspace_key` (field 2): `Tuple(sourceIndex.subspaceKey).pack()`.
    var sourceIndexSubspaceKey: FDB.Bytes? { fields.bytes(2) }

    /// `source_index_last_modified_version` (field 3).
    var sourceIndexLastModifiedVersion: Int? { ProtoFields.int32(fields.varint(3)).map(Int.init) }

    /// `targetIndex` (field 4).
    var targetIndexes: [String] { fields.repeatedBytes(4).map { String(decoding: $0, as: UTF8.self) } }

    /// `block` (field 5): set by an operator to pause indexing.
    var block: Bool {
        get { (fields.varint(5) ?? 0) != 0 }
        set { fields.setVarint(5, newValue ? 1 : nil) }
    }

    /// `blockExpireEpochMilliSeconds` (field 6): if non-zero, when the block expires.
    var blockExpireEpochMilliSeconds: UInt64 {
        get { fields.varint(6) ?? 0 }
        set { fields.setVarint(6, newValue == 0 ? nil : newValue) }
    }

    /// `blockID` (field 7): a short description of why the build is blocked.
    var blockID: String {
        get { fields.bytes(7).map { String(decoding: $0, as: UTF8.self) } ?? "" }
        set { fields.setBytes(7, newValue.isEmpty ? nil : Array(newValue.utf8)) }
    }

    /// Java's `isTypeStampBlocked`: blocked, and the block has not expired.
    func isBlocked(nowMillis: UInt64 = UInt64(max(0, Date().timeIntervalSince1970 * 1000))) -> Bool {
        block && (blockExpireEpochMilliSeconds == 0 || blockExpireEpochMilliSeconds > nowMillis)
    }

    /// Java's `blocklessStampOf`: the stamp without its block fields.
    var blockless: IndexBuildIndexingStamp {
        var copy = self
        copy.fields.setVarint(5, nil)
        copy.fields.setVarint(6, nil)
        copy.fields.setBytes(7, nil)
        return copy
    }

    /// A readable rendering for errors and logs (Java's `IndexingBase.stampToString`).
    var summary: String {
        var parts = [method.description]
        if let key = sourceIndexSubspaceKey {
            parts.append("source=" + ((try? Tuple.decode(from: key)).map { "\($0)" } ?? "\(key)"))
        }
        if let version = sourceIndexLastModifiedVersion { parts.append("sourceVersion=\(version)") }
        if !targetIndexes.isEmpty { parts.append("targets=\(targetIndexes)") }
        if block { parts.append("blocked" + (blockID.isEmpty ? "" : "(\(blockID))")) }
        return parts.joined(separator: " ")
    }
}
#endif
