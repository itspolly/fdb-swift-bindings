/*
 * IndexableValue.swift
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

/// A value that can appear in a primary key or index entry.
///
/// Protocol Buffer scalar field types (and `enum`s) conform to `IndexableValue` so they can
/// be turned into ``TupleElement``s for key encoding. The conversion is total and canonical:
/// equal values always produce equal tuple encodings, which is what makes index lookups and
/// ordering work.
///
/// Integer widths all funnel through `Int64`'s tuple encoding, so e.g. `Int32(5)` and
/// `Int64(5)` index to the same key and compare equal — exactly what you want when a query
/// compares an `int32` field against an integer literal.
public protocol IndexableValue: Sendable {
    /// The tuple element used to represent this value in a key.
    func asTupleElement() -> any TupleElement

    /// A non-default sentinel value of this type.
    ///
    /// Used internally to resolve a `KeyPath` to a protobuf field number: a fresh message is
    /// stamped with this value through the key path and then traversed to see which field
    /// number carries it. It just needs to differ from the proto default (0 / "" / false / …).
    static var probeValue: Self { get }
}

extension Int64: IndexableValue {
    public func asTupleElement() -> any TupleElement { self }
    public static var probeValue: Int64 { 1 }
}

extension Int32: IndexableValue {
    public func asTupleElement() -> any TupleElement { Int64(self) }
    public static var probeValue: Int32 { 1 }
}

extension Int: IndexableValue {
    public func asTupleElement() -> any TupleElement { Int64(self) }
    public static var probeValue: Int { 1 }
}

extension UInt32: IndexableValue {
    public func asTupleElement() -> any TupleElement { Int64(self) }
    public static var probeValue: UInt32 { 1 }
}

extension UInt64: IndexableValue {
    public func asTupleElement() -> any TupleElement { self }
    public static var probeValue: UInt64 { 1 }
}

extension String: IndexableValue {
    public func asTupleElement() -> any TupleElement { self }
    public static var probeValue: String { "\u{01}" }
}

extension Bool: IndexableValue {
    public func asTupleElement() -> any TupleElement { self }
    public static var probeValue: Bool { true }
}

extension Double: IndexableValue {
    public func asTupleElement() -> any TupleElement { self }
    public static var probeValue: Double { 1 }
}

extension Float: IndexableValue {
    public func asTupleElement() -> any TupleElement { self }
    public static var probeValue: Float { 1 }
}

extension UUID: IndexableValue {
    public func asTupleElement() -> any TupleElement { self }
    public static var probeValue: UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    }
}

/// Protobuf `bytes` fields decode to `Data`.
extension Data: IndexableValue {
    public func asTupleElement() -> any TupleElement { FDB.Bytes(self) }
    public static var probeValue: Data { Data([1]) }
}

extension Array: IndexableValue where Element == UInt8 {
    public func asTupleElement() -> any TupleElement { self }
    public static var probeValue: [UInt8] { [1] }
}

/// Protobuf enums are `RawRepresentable` with an `Int` raw value; index them by raw value.
extension IndexableValue where Self: RawRepresentable, Self.RawValue == Int {
    public func asTupleElement() -> any TupleElement { Int64(rawValue) }
    public static var probeValue: Self { Self(rawValue: 1) ?? Self(rawValue: 0)! }
}
#endif
