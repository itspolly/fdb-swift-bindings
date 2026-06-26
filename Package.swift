/*
 * Package.swift
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

// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "FoundationDB",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "FoundationDB", targets: ["FoundationDB"]),
        // The Record Layer is only non-empty when the `RecordLayer` trait is enabled.
        .library(name: "FDBRecordLayer", targets: ["FDBRecordLayer"]),
    ],
    traits: [
        // Enables the Record Layer (and pulls in swift-protobuf). Off by default so the
        // base `FoundationDB` library stays free of the protobuf dependency.
        .trait(name: "RecordLayer"),
        .default(enabledTraits: []),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.29.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CFoundationDB",
            pkgConfig: "libfdb",
            providers: [
                .apt(["foundationdb-clients"]),
                .yum(["foundationdb-clients"]),
            ]
        ),
        .target(
            name: "FoundationDB",
            dependencies: ["CFoundationDB"]
        ),
        .target(
            name: "FDBRecordLayer",
            dependencies: [
                "FoundationDB",
                // Trait-gated: when `RecordLayer` is off, swift-protobuf is not linked and
                // the (entirely `#if RecordLayer`-guarded) sources compile to nothing.
                .product(
                    name: "SwiftProtobuf",
                    package: "swift-protobuf",
                    condition: .when(traits: ["RecordLayer"])
                ),
            ],
            // The vendored `.proto` is reference material (its Swift is checked into
            // Generated/); it is not compiled by this target.
            exclude: ["Proto/record_metadata_options.proto"]
        ),
        .testTarget(
            name: "FoundationDBTests",
            dependencies: ["FoundationDB"]
        ),
        .testTarget(
            name: "FDBRecordLayerTests",
            dependencies: [
                "FDBRecordLayer",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            // Import-only proto (resolves annotated.proto's import); not generated itself.
            exclude: ["Protos/record_metadata_options.proto"],
            plugins: [
                // Generates Swift types from the `.proto` files in this target at build time.
                .plugin(name: "SwiftProtobufPlugin", package: "swift-protobuf"),
            ]
        ),
        .executableTarget(
            name: "StackTester",
            dependencies: ["FoundationDB"],
            path: "Tests/StackTester/Sources/StackTester"
        ),
    ]
)
