/*
 * IndexableValueTests.swift (file retained as SubspaceTests.swift)
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

// Subspace/KeySpacePath moved to the base FoundationDB module; their tests now live in
// Tests/FoundationDBTests/SubspaceTests.swift. IndexableValue remains in the Record Layer.

#if RecordLayer
import Foundation
import Testing

@testable import FDBRecordLayer
import FoundationDB

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
