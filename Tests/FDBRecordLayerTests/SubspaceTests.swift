/*
 * SubspaceTests.swift
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
import Testing

@testable import FDBRecordLayer
import FoundationDB

@Suite("Subspace")
struct SubspaceTests {
    @Test("pack then unpack round-trips tuple elements")
    func packUnpackRoundTrip() throws {
        let s = Subspace(Tuple("app", Int64(1)))
        let key = s.pack(Tuple("user", Int64(42)))
        #expect(s.contains(key))

        let elements = try s.unpack(key)
        #expect(elements.count == 2)
        #expect(elements[0] as? String == "user")
        #expect(elements[1] as? Int64 == 42)
    }

    @Test("keys carry the subspace prefix and child keys nest")
    func prefixing() {
        let root = Subspace(Tuple("R"))
        let child = root.child("records", Int64(7))
        let key = child.pack(Int64(99))

        #expect(root.contains(key))
        #expect(child.contains(key))
        // Child prefix extends the parent prefix.
        #expect(child.prefix.starts(with: root.prefix))
    }

    @Test("unpacking a foreign key throws")
    func unpackForeignKey() {
        let a = Subspace(Tuple("A"))
        let b = Subspace(Tuple("B"))
        let key = a.pack(Int64(1))
        #expect(throws: SubspaceError.keyNotInSubspace) {
            _ = try b.unpack(key)
        }
    }

    @Test("range brackets all keys in the subspace")
    func ranges() {
        let s = Subspace(Tuple("data"))
        let (begin, end) = s.range
        let lowKey = s.pack(Int64(-1_000_000))
        let highKey = s.pack("zzzzzzzz")

        // Every key in the subspace sorts within [begin, end).
        let outside = Subspace(Tuple("dataa")).pack(Int64(0))
        #expect(lexLess(begin, lowKey) || begin == lowKey)
        #expect(lexLess(highKey, end))
        #expect(!s.contains(outside))
    }

    /// Byte-wise lexicographic less-than, matching FDB key ordering.
    private func lexLess(_ a: FDB.Bytes, _ b: FDB.Bytes) -> Bool {
        for (x, y) in zip(a, b) where x != y { return x < y }
        return a.count < b.count
    }
}

@Suite("KeySpacePath")
struct KeySpacePathTests {
    @Test("path children extend the prefix and resolve to a subspace")
    func resolution() throws {
        let path = KeySpacePath("app").child("tenant-1").child(Int64(2))
        let subspace = path.toSubspace()

        let key = subspace.pack("k")
        let elements = try subspace.unpack(key)
        #expect(elements[0] as? String == "k")

        // The resolved prefix equals the equivalent tuple encoding.
        let equivalent = Tuple("app", "tenant-1", Int64(2)).encode()
        #expect(subspace.prefix == equivalent)
    }
}

@Suite("IndexableValue")
struct IndexableValueTests {
    @Test("integer widths encode identically")
    func integerWidthsAgree() {
        #expect(Int32(5).asTupleElement().encodeTuple() == Int64(5).asTupleElement().encodeTuple())
        #expect(Int(5).asTupleElement().encodeTuple() == Int64(5).asTupleElement().encodeTuple())
        #expect(UInt32(5).asTupleElement().encodeTuple() == Int64(5).asTupleElement().encodeTuple())
    }

    @Test("scalar values encode the same as their tuple elements")
    func scalarEncodings() {
        #expect("hi".asTupleElement().encodeTuple() == "hi".encodeTuple())
        #expect(true.asTupleElement().encodeTuple() == true.encodeTuple())
        #expect(Double(3.5).asTupleElement().encodeTuple() == Double(3.5).encodeTuple())
        #expect(Data([1, 2, 3]).asTupleElement().encodeTuple() == FDB.Bytes([1, 2, 3]).encodeTuple())
    }
}
#endif
