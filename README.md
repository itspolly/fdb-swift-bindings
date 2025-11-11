# FoundationDB Swift Bindings

Swift bindings for FoundationDB, providing a native Swift API for interacting with FoundationDB clusters.

## Quick Start

### Initialize the Client

```swift
import FoundationDB

// Initialize FoundationDB
try await FDBClient.initialize()
let database = try FDBClient.openDatabase()
```

### Basic Operations

```swift
// Simple key-value operations
try await database.withTransaction { transaction in
    // Set a value
    let key = "hello"
    let value = "world"
    transaction.setValue([UInt8](value.utf8), for: [UInt8](key.utf8))

    // Get a value
    if let valueBytes = try await transaction.getValue(for: [UInt8](key.utf8)) {
        print(String(decoding: valueBytes, as: UTF8.self)) // "world"
    }

    // Delete a key
    transaction.clear(key: [UInt8](key.utf8))
}
```

### Range Queries

```swift
// Efficient streaming over large result sets
let sequence = transaction.getRange(
    beginSelector: .firstGreaterOrEqual([UInt8]("user:".utf8)),
    endSelector: .firstGreaterOrEqual([UInt8]("user;".utf8))
)

for try await (key, value) in sequence {
    let userId = String(decoding: key, as: UTF8.self)
    let userData = String(decoding: value, as: UTF8.self)
    // Process each key-value pair as it streams
}
```

### Atomic Operations

```swift
try await database.withTransaction { transaction in
    // Atomic increment
    let counterKey = "counter"
    let increment = withUnsafeBytes(of: Int64(1).littleEndian) { Array($0) }
    transaction.atomicOp(key: [UInt8](counterKey.utf8), param: increment, mutationType: .add)
}
```

## Requirements

- Swift 6.1+
- FoundationDB 7.1+
- macOS 12+ / Linux
- pkgconfig 

## Installation

Add the following package config following `/opt/homebrew/lib/pkgconfig/libfdb.pc` for macOS.
Adapt files directory and version of your current installation.

```
prefix=/usr/local
exec_prefix=${prefix}
includedir=${prefix}/include
libdir=${exec_prefix}/lib

Name: CFoundationDB
Description: The foundationdb C library
Version: 7.3.9
Cflags: -I${includedir}
Libs: -L${libdir} -lfdb_c
```



Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/FoundationDB/fdb-swift-bindings", branch: "main")
]
```

## Documentation

For detailed API documentation and advanced usage patterns, see the inline documentation in the source files.

## License

Licensed under the Apache License, Version 2.0. See LICENSE for details.
