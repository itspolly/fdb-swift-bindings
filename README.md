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

### Reverse ranges

Pass `reverse: true` to `getRange` to stream a range in descending key order (paginated the same
way as forward) — handy for "latest first" reads such as the tail of an event log:

```swift
let (begin, end) = log.range
for try await (key, value) in transaction.getRange(beginKey: begin, endKey: end, reverse: true) {
    // newest entries first
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

### Versionstamped keys (event log)

The tuple layer supports **versionstamps** — a 10-byte commit version the database assigns
atomically at commit, plus a 2-byte user version. Pack an incomplete versionstamp and write it
with a `setVersionstampedKey` op to get append-only, globally-ordered, unique keys without a
counter — ideal for an event log:

```swift
let log = Subspace(Tuple("events"))
try await database.withTransaction { transaction in
    let key = try log.packWithVersionstamp(Tuple(Versionstamp.incomplete()))
    transaction.setVersionstampedKey(key, value: payload)   // version filled in at commit
}
```

`packWithVersionstamp` appends the required 4-byte little-endian offset of the placeholder (on
`Tuple` or, prefix-aware, on `Subspace`). Reading the range back yields entries in commit order,
and `unpack` decodes each key's now-complete `Versionstamp`. After commit,
`transaction.getVersionstamp()` returns the 10 bytes that were assigned.

### Watches (pub/sub)

A **watch** completes when a key's value changes, giving you push notifications without polling.
`database.watch(key:)` returns an `AsyncThrowingStream` that yields the key's current value, then
the new value after every change — ideal for a live feed like a score:

```swift
let key = [UInt8]("match/score".utf8)
for try await score in database.watch(key: key) {
    print("score is now", score.map { String(decoding: $0, as: UTF8.self) } ?? "unset")
}
// Stop by breaking out of the loop; the underlying watch is cancelled automatically.
```

Rapid successive writes may coalesce into a single notification (you always get the latest
value), and FoundationDB caps concurrent watches (the `MAX_WATCHES` database option). The same
`watch(key:)` is available on `FDBTenant`. For one-shot use, `transaction.watch(key:)` returns an
`FDBWatch` whose `wait()` resolves on the next change (the watch arms when the transaction
commits).

### Subspaces

`Subspace` and `KeySpacePath` namespace keys by a common prefix and integrate directly with
the transaction API — `pack`/`range`/`unpack` produce and consume the `[UInt8]` keys that
`setValue`/`getRange`/`clearRange` already use:

```swift
let users = Subspace(Tuple("app", "users"))
try await database.withTransaction { transaction in
    transaction.setValue([UInt8]("alice".utf8), for: users.pack(Int64(1)))

    let (begin, end) = users.range
    for try await (key, value) in transaction.getRange(beginKey: begin, endKey: end) {
        let id = try users.unpack(key)[0] as! Int64
        print(id, String(decoding: value, as: UTF8.self))
    }
}
```

## Tenants

FoundationDB [tenants](https://apple.github.io/foundationdb/tenants.html) give server-enforced,
isolated key spaces within one database. The cluster must have `tenant_mode` enabled
(`fdbcli --exec 'configure tenant_mode=optional_experimental'`), and the client must select API
version ≥ 720 (the default is now 730).

```swift
try await database.createTenant(name: "tenant-a")
let tenant = try database.openTenant(name: "tenant-a")

try await tenant.withTransaction { transaction in
    transaction.setValue([UInt8]("v".utf8), for: [UInt8]("k".utf8))
}
// The key "k" written above is invisible to other tenants and to the default key space.

let id = try await tenant.id()
let names = try await database.listTenants()
try await database.deleteTenant(name: "tenant-a")  // tenant must be empty
```

Tenant metadata can be read with `database.tenantInfo(name:)` / `listTenantsInfo()`, which parse
the tenant map into `TenantInfo` (id + key prefix). For hard multi-tenancy under
`required_experimental` mode, attach an authorization token (e.g. a JWT) so a tenant's
transactions are authorized:

```swift
let tenant = try database.openTenant(name: "tenant-a", authorizationToken: jwtBytes)
```

Tenant transactions are ordinary `FDBTransaction`s, so they work with everything above —
including `Subspace` and the Record Layer (`tenant.withRecordContext { … }`).

## Record Layer

The optional `FDBRecordLayer` module is a Swift port of the [FoundationDB Record
Layer](https://foundationdb.github.io/fdb-record-layer/Overview.html): a schema-driven store
for [Protocol Buffer](https://github.com/apple/swift-protobuf) records, with a clustered
primary-key index, secondary indexes, and a query planner — all layered on the low-level
bindings above.

It is gated behind the **`RecordLayer` package trait** so the base `FoundationDB` library
stays free of the swift-protobuf dependency unless you opt in. Enable it on your dependency:

```swift
dependencies: [
    .package(
        url: "https://github.com/FoundationDB/fdb-swift-bindings",
        branch: "main",
        traits: ["RecordLayer"]
    )
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "FDBRecordLayer", package: "fdb-swift-bindings"),
    ])
]
```

### Define records

Records are protobuf messages. Compile your `.proto` with
[swift-protobuf](https://github.com/apple/swift-protobuf) (the `SwiftProtobufPlugin` build
plugin is convenient):

```protobuf
syntax = "proto3";
package example;

message Customer { int64 id = 1; string name = 2; }
message Order {
  int64 order_id = 1;
  string flower = 2;
  int64 price = 3;
  Customer customer = 4;
  repeated string tags = 5;
}
```

### Describe the schema

Metadata is declared in Swift with typed `KeyPath`s. Primary keys and indexes are matched to
queries by key-path identity, so the planner can select an index automatically:

```swift
import FDBRecordLayer

let meta = RecordMetaData {
    RecordType(Example_Order.self, primaryKey: \.orderID)
        .index("price", on: \.price)              // value index
        .index("customerName", on: \.customer.name)   // nested field
        .index("byTag", on: \.tags, fanType: .fanOut) // one entry per repeated value
}
```

#### Or declare metadata in the `.proto`

Alternatively, annotate fields directly with FoundationDB's options (import the vendored
`record_metadata_options.proto`), mirroring the Java Record Layer:

```protobuf
syntax = "proto2";
import "record_metadata_options.proto";

message Order {
  optional int64 order_id = 1 [(com.apple.foundationdb.record.field).primary_key = true];
  optional int64 price    = 2 [(com.apple.foundationdb.record.field).index = { type: "value" }];
}
```

Compile a descriptor set and build metadata from it (field values are extracted at runtime by
field number, so no key paths are needed):

```bash
protoc --include_imports --descriptor_set_out=schema.desc -I protos Order.proto
```

```swift
let data = try Data(contentsOf: URL(fileURLWithPath: "schema.desc"))
let meta = try RecordMetaData(descriptorSetData: data, recordTypes: [Order.self])
```

### Save, load, delete

A store operates within an `FDBRecordContext` (a transaction). `withRecordContext` reuses the
base bindings' retry loop and commits on success:

```swift
try await database.withRecordContext { context in
    let store = try await FDBRecordStore.open(
        context: context, path: KeySpacePath("app"), metaData: meta)

    var order = Example_Order()
    order.orderID = 1; order.flower = "rose"; order.price = 10; order.tags = ["red"]
    try await store.save(order)

    let stored = try await store.load(Example_Order.self, Int64(1))
    print(stored?.record.flower as Any)   // "rose"
}
```

`save` is an upsert (insert-or-replace by primary key). For existence assertions use
`insert(_:)` (throws `recordAlreadyExists` if the primary key is taken) and `update(_:)`
(throws `recordDoesNotExist` if it isn't).

### Query

Build a `RecordQuery` with the fluent `Query` API; the planner chooses an index scan or full
scan, always re-applying the filter as a residual so results are exact:

```swift
let query = RecordQuery(Example_Order.self)
    .where(Query.and(
        Query.field(\.price).lessThan(50),
        Query.field(\.customer.name).equals("alice")
    ))
    .sorted(by: .field(\.price))

try await database.withRecordContext { context in
    let store = try await FDBRecordStore.open(context: context, path: KeySpacePath("app"), metaData: meta)
    for try await record in try await store.executeQuery(query) {
        print(record.record.orderID)
    }
}
```

`Query.any(\.tags).equals("red")` matches a repeated field via a fan-out index (results are
de-duplicated).

The planner uses **multi-column index prefixes** (an equality prefix plus a trailing range,
e.g. a `concat(flower, price)` index for `flower == "rose" AND price < 50`) and satisfies an
`OR` of index-able branches with a **de-duplicated union** of index scans, falling back to a
full scan otherwise.

A filter on the **primary key** (or its leading prefix) is served by a direct record-range
scan — no secondary index needed, and no extra fetch (the records are the scan). So a primary
key is both a uniqueness constraint *and* a queryable index; don't add a secondary index that
just duplicates it.

`equals`/`notEquals` work on any `Equatable` field (including `Bool` and protobuf enums); the
ordering comparisons (`lessThan`, `greaterThan`, …) require the field to be `Comparable`.

For queries that only need indexed columns, **covering reads** skip the record fetch entirely:

```swift
// Returns (primaryKey, [columns]) straight from the index — no record load.
let entries = try await store.executeCoveringQuery(
    RecordQuery(Order.self).where(Query.field(\.price).equals(20)), using: "priceIdx")

// count() tallies matches by scanning index ranges only when the filter is fully covered.
let n = try await store.count(RecordQuery(Order.self).where(Query.field(\.price).lessThan(50)))
```

### Adding an index to a populated store

A new index on a store that already has records opens in the `writeOnly` state — maintained on
writes but hidden from queries — until it is backfilled. Build it online (in batches, across
transactions, resumable) to make it `readable`:

```swift
try await database.buildIndex(subspace: subspace, metaData: meta, indexName: "priceIdx")
```

### Stable keys and schema evolution

Record types and indexes occupy storage by an integer key. Give them **explicit, stable keys**
so the on-disk layout is independent of declaration order — then you can reorder declarations,
and add or remove entries, freely (treat keys like protobuf field numbers: never reuse a retired
one). Without explicit keys, keys are positional, so a keyless schema must only ever be
*appended* to.

```swift
RecordMetaData {
    RecordType(Order.self, key: 1, primaryKey: \.orderId)
        .index("price", on: \.price, key: 10)
    RecordType(Customer.self, key: 2, primaryKey: \.id)
}
```

To retire an index: `try await store.clearIndex(named: "price")` (wipes its data), then drop it
from the schema and never reuse its key. Clearing one index never affects another.

### Unique indexes

Mark a value index `unique: true` to enforce a uniqueness constraint — a `save` that would give
two records the same index key fails with `RecordStoreError.uniquenessViolation`. A unique index
is still a normal queryable value index (it just adds a write-time check), and composes with
other indexes on the same type.

```swift
RecordType(User.self, key: 1, primaryKey: \.id)
    .index("email", on: \.email, key: 10, unique: true)
```

### Record versions & optimistic concurrency

Opt a record type into versioning with `.storingVersions()`. Each save stamps the record with
the transaction's commit versionstamp (an opaque, monotonic ETag), surfaced as
`FDBStoredRecord.version` on load. `save(_:ifVersionMatches:)` writes only if the stored version
still matches — otherwise it throws `RecordStoreError.versionMismatch`, which is **not** a
retryable error, so the surrounding retry loop does not silently re-run your update. Pass `nil`
to require that the record does not yet exist (create-only).

```swift
RecordType(Order.self, key: 1, primaryKey: \.orderId).storingVersions()

// Request A: read + return the version as an ETag.
let stored = try await store.load(Order.self, id)
// Request B (later): update only if unchanged since A.
try await store.save(updated, ifVersionMatches: stored?.version)  // throws .versionMismatch if stale
```

`delete(_:primaryKey:ifVersionMatches:)` deletes under the same condition.

Within a single transaction you don't need this — reading a record already makes a concurrent
modification conflict; versions are for stateless, cross-request "if unchanged" updates.

### Indexing enum fields

Protobuf scalar fields are indexable out of the box. A protobuf **enum** needs a one-line,
zero-body conformance (the library supplies the implementation for any `RawRepresentable` whose
`RawValue` is `Int`, which every proto enum is); the enum is then indexed by its raw value:

```swift
extension MyApp_DeviceType: IndexableValue {}
```

### Paging

Set a `limit` and page with an opaque continuation token (stateless — safe to hand to an API
client and resume later):

```swift
var continuation: [UInt8]? = nil
repeat {
    let page = try await store.executeQuery(query.limited(to: 100), continuation: continuation)
    handle(page.records)
    continuation = page.continuation
} while continuation != nil
```

### Advanced indexes

Declare aggregate, rank, and version indexes via the `type:` parameter, and read them with
dedicated helpers:

```swift
RecordType(Example_Item.self, primaryKey: \.sku)
    .index("countByCategory", on: .field(\.category), type: .count)
    .index("sumQtyByCategory", on: .concat(.field(\.category), .field(\.quantity)), type: .sum)
RecordType(Example_Order.self, primaryKey: \.orderID)
    .index("priceRank", on: \.price, type: .rank)
    .index("version", on: .version(), type: .version)
```

```swift
let count = try await store.aggregate(Example_Item.self, indexNamed: "countByCategory", group: Tuple("flower"))
let belowMedian = try await store.rank(Example_Order.self, indexNamed: "priceRank", lessThan: Int64(50))
for try await order in try store.scanByVersion(Example_Order.self, indexNamed: "version") { /* commit order */ }
```

`min`/`max` indexes keep their entries ordered, so the extremum is the first/last entry in a
group's range — correct even after deletes — read via `store.minimum(...)` / `store.maximum(...)`.

Queries match indexes by field identity across both declaration styles: a `KeyPath` predicate
resolves to its protobuf field number, so it can select an index that was declared with proto
annotations (and vice versa).

## Requirements

- Swift 6.1+
- FoundationDB 7.1+ client library and headers
- `pkg-config`
- macOS 12+ / Linux

## Finding the FoundationDB C bindings

Whether you are building this repository directly or adding it as a Swift
package dependency, the system needs the FoundationDB C client library and a
`pkg-config` file so that the Swift Package Manager can locate it. Follow the
steps below once on any machine that will compile the package.

### 1. Install the FoundationDB client library

Download and install the FoundationDB client package for your platform from the
[FoundationDB releases page](https://github.com/apple/foundationdb/releases).
This provides:

- The shared library (`libfdb_c.dylib` on macOS, `libfdb_c.so` on Linux)
- The C headers at `<your-install-prefix>/include/foundationdb/`

### 2. Install `pkg-config`

```bash
brew install pkg-config   # macOS
# or: apt install pkg-config / yum install pkgconfig
```

### 3. Create the `libfdb.pc` pkg-config file

The Swift Package Manager uses `pkg-config` to find the library at build
time. A template is included in the repo at
`Sources/CFoundationDB/include/CFoundationDB_mac.pc` (and `..._linux.pc`).
Copy it to a directory on your `PKG_CONFIG_PATH`. Note that the file
_must_ be named `libfdb.pc`:

```bash
# Common locations — use whichever exists on your system:
#   /usr/local/lib/pkgconfig/    (default on macOS/Linux)
#   /opt/homebrew/lib/pkgconfig/ (Homebrew)

sudo cp Sources/CFoundationDB/include/CFoundationDB_mac.pc \
        /usr/local/lib/pkgconfig/libfdb.pc
```

Open the copy and set `prefix` to the root of your FoundationDB installation:

```ini
prefix=/usr/local          # adjust to your actual install prefix
exec_prefix=${prefix}
includedir=${prefix}/include
libdir=${exec_prefix}/lib

Name: CFoundationDB
Description: The foundationdb C library
Version: 7.3.77            # adjust to match your installed version
Cflags: -I${includedir}
Libs: -L${libdir} -lfdb_c
```

> **Important:** `Cflags` must point to the *parent* of the `foundationdb/`
> directory (i.e., `${includedir}`, **not** `${includedir}/foundationdb`).
> The header is included as `#include <foundationdb/fdb_c.h>`, so the compiler
> needs to search from the directory that *contains* the `foundationdb/` folder.

Verify the configuration before building:

```bash
pkg-config --cflags --libs libfdb
# Expected output (paths will match your prefix):
# -I/usr/local/include -L/usr/local/lib -lfdb_c
```

## Adding as a Swift package dependency

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/FoundationDB/fdb-swift-bindings", branch: "main")
]
```

## Building locally

After completing the setup above to make the FoundationDB C client visible, build with:

```bash
swift build
```

### Running the tests

To run the tests, there must be a locally accessible FoundationDB cluster.
The standard FoundationDB installer registers a launch daemon (macOS) or
systemd service (Linux) that starts an FDB server automatically, with a
cluster file at:

- macOS: `/usr/local/etc/foundationdb/fdb.cluster`
- Linux: `/etc/foundationdb/fdb.cluster`

If you are using a custom or minimal install the server may not start
automatically.  Consult your installation's documentation.

To use a non-default cluster file, set the `FDB_CLUSTER_FILE` environment variable
when running tests:

```bash
FDB_CLUSTER_FILE=path/to/fdb.cluster swift test
```

The `libfdb_c` dynamic library must also be on the dynamic library search path
at test run time. This is automatic with a standard install. For a custom
install prefix, add the library directory to the path before running tests by adjusting
your system path or (on Linux) using the `LD_LIBRARY_PATH` environment variable.

On macOS, `DYLD_*` environment variables are stripped from the system test helper by SIP, so
if `libfdb_c.dylib` is not on the default loader path you may see
`Library not loaded: @rpath/libfdb_c.dylib`. Embed an rpath at link time instead:

```bash
swift test -Xlinker -rpath -Xlinker /usr/local/lib
```

### Record Layer tests

The Record Layer and its tests are behind the `RecordLayer` trait, so enable it explicitly:

```bash
swift test --traits RecordLayer -Xlinker -rpath -Xlinker /usr/local/lib
```

> Integration tests block until the cluster is available (FoundationDB has no default
> operation timeout). If a run appears to hang, check `fdbcli --exec 'status minimal'`; a
> freshly installed cluster must be initialized once with
> `fdbcli --exec 'configure new single ssd'`.

## Documentation

For detailed API documentation and advanced usage patterns, see the inline documentation in the source files.

## License

Licensed under the Apache License, Version 2.0. See LICENSE for details.
