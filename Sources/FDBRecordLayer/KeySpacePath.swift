/*
 * KeySpacePath.swift
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

/// A logical, directory-style path that resolves to a ``Subspace``.
///
/// This is a lightweight analogue of the Java Record Layer's `KeySpacePath`: a record store
/// is opened at a path such as `KeySpacePath("app").child("tenant-1")`. Each element is
/// tuple-encoded and concatenated to form the resolved subspace prefix.
///
/// Because tuple encoding is a simple concatenation of per-element encodings, appending a
/// child is just appending that element's encoding to the prefix.
public struct KeySpacePath: Sendable, Hashable {
    /// The resolved byte prefix for this path.
    public let prefix: FDB.Bytes

    /// Creates a path with an explicit raw prefix (defaults to the root).
    public init(prefix: FDB.Bytes = []) {
        self.prefix = prefix
    }

    /// Creates a path rooted at a single string directory, e.g. `KeySpacePath("app")`.
    public init(_ root: String) {
        self.prefix = root.encodeTuple()
    }

    /// Creates a path from the elements of `tuple`.
    public init(_ tuple: Tuple) {
        self.prefix = tuple.encode()
    }

    /// Returns a new path with `element` appended as the next directory.
    public func child(_ element: any TupleElement) -> KeySpacePath {
        KeySpacePath(prefix: prefix + element.encodeTuple())
    }

    /// Resolves this path to the ``Subspace`` it names.
    public func toSubspace() -> Subspace {
        Subspace(prefix: prefix)
    }
}
#endif
