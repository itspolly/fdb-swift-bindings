/*
 * Subspace.swift
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


/// Errors raised while packing/unpacking keys against a ``Subspace``.
public enum SubspaceError: Error, Sendable, Equatable {
    /// A key handed to ``Subspace/unpack(_:)`` did not begin with the subspace prefix.
    case keyNotInSubspace
}

/// A `Subspace` defines a namespace within FoundationDB's key space by reserving a common
/// byte prefix that is prepended to every key it produces.
///
/// Subspaces are the building block the Record Layer uses to lay out a record store: the
/// store, its records, and each index live in nested subspaces. Keys are produced by
/// packing a ``Tuple`` (`prefix + tuple.encode()`), which preserves lexicographic ordering,
/// and the original tuple can be recovered with ``unpack(_:)``.
///
/// This mirrors the `Subspace` concept from FoundationDB's other language bindings, built
/// on the existing ``Tuple`` layer in the base `FoundationDB` module.
public struct Subspace: Sendable, Hashable {
    /// The raw byte prefix prepended to every key produced by this subspace.
    public let prefix: FDB.Bytes

    /// Creates a subspace with an explicit raw byte prefix (empty = the entire key space).
    public init(prefix: FDB.Bytes = []) {
        self.prefix = prefix
    }

    /// Creates a subspace whose prefix is `rawPrefix` followed by the encoding of `tuple`.
    public init(_ tuple: Tuple, rawPrefix: FDB.Bytes = []) {
        self.prefix = rawPrefix + tuple.encode()
    }

    // MARK: - Packing

    /// Returns the key for `tuple` within this subspace: `prefix + tuple.encode()`.
    public func pack(_ tuple: Tuple) -> FDB.Bytes {
        prefix + tuple.encode()
    }

    /// Returns the key for the tuple formed from `elements` within this subspace.
    public func pack(_ elements: any TupleElement...) -> FDB.Bytes {
        prefix + Tuple(elements).encode()
    }

    /// Returns the subspace prefix itself as a key (the tuple with no elements).
    public func packEmpty() -> FDB.Bytes {
        prefix
    }

    /// Returns the key for `tuple` within this subspace, with the 4-byte little-endian offset of
    /// its incomplete ``Versionstamp`` appended — ready for a `setVersionstampedKey` atomic op.
    ///
    /// The offset accounts for the subspace prefix. The tuple must contain exactly one top-level
    /// incomplete versionstamp.
    public func packWithVersionstamp(_ tuple: Tuple) throws -> FDB.Bytes {
        let (bytes, offset) = try tuple.encodeWithVersionstampOffset()
        return prefix + bytes + Tuple.littleEndian32(UInt32(prefix.count + offset))
    }

    // MARK: - Unpacking

    /// Recovers the tuple elements encoded after the prefix in `key`.
    ///
    /// - Throws: ``SubspaceError/keyNotInSubspace`` if `key` is not within this subspace.
    public func unpack(_ key: FDB.Bytes) throws -> [any TupleElement] {
        guard contains(key) else { throw SubspaceError.keyNotInSubspace }
        return try Tuple.decode(from: Array(key.dropFirst(prefix.count)))
    }

    /// Whether `key` falls within this subspace (begins with the prefix).
    public func contains(_ key: FDB.Bytes) -> Bool {
        key.starts(with: prefix)
    }

    // MARK: - Nesting

    /// Returns a child subspace nested under `tuple`.
    public func subspace(_ tuple: Tuple) -> Subspace {
        Subspace(prefix: prefix + tuple.encode())
    }

    /// Returns a child subspace nested under the tuple formed from `elements`.
    public func child(_ elements: any TupleElement...) -> Subspace {
        Subspace(prefix: prefix + Tuple(elements).encode())
    }

    // MARK: - Ranges

    /// The `[begin, end)` byte range covering every key in this subspace.
    ///
    /// Tuple-encoded suffixes always begin with a type-code byte in `0x00...0x33`, so the
    /// `prefix + [0x00]` ... `prefix + [0xFF]` range covers all of them.
    public var range: (begin: FDB.Bytes, end: FDB.Bytes) {
        (prefix + [0x00], prefix + [0xFF])
    }

    /// The `[begin, end)` byte range covering every key nested under `tuple`.
    public func range(_ tuple: Tuple) -> (begin: FDB.Bytes, end: FDB.Bytes) {
        let p = prefix + tuple.encode()
        return (p + [0x00], p + [0xFF])
    }
}
