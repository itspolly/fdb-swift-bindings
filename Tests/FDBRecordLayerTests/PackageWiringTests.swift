/*
 * PackageWiringTests.swift
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
import Testing

@testable import FDBRecordLayer

@Suite("Package wiring")
struct PackageWiringTests {
    @Test("Record Layer module is compiled in when the trait is enabled")
    func formatVersionIsPositive() {
        #expect(recordLayerFormatVersion > 0)
    }

    @Test("Generated protobuf test types are available")
    func generatedTypesExist() {
        var order = Fdb_Test_Order()
        order.orderID = 7
        order.flower = "rose"
        #expect(order.orderID == 7)
        #expect(order.flower == "rose")
    }
}
#endif
