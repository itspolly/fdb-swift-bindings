/*
 * TextIndexTests.swift
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

/// Tokenizers and the bunched serializer, checked against the Java Record Layer's own test
/// expectations (`TextTokenizerTest`, `TextIndexBunchedSerializerTest`).
@Suite("Text index tokenizers and serializer")
struct TextIndexTestsTokenizers {
    /// Compares scalar-by-scalar: Swift's `==` on strings is canonical equivalence, Java's is exact.
    private func scalars(_ tokens: [String]) -> [[UInt32]] { tokens.map { $0.unicodeScalars.map(\.value) } }

    @Test("default tokenizer matches Java on TextSamples")
    func defaultTokenizerSamples() throws {
        #expect(TextSamples.samples.count == TextSamples.expectedDefault.count)
        for (sample, expected) in zip(TextSamples.samples, TextSamples.expectedDefault) {
            let tokens = try DefaultTextTokenizer().tokenize(sample, version: 0, mode: .index)
            #expect(scalars(tokens) == scalars(expected), "\(sample)")
            // The unique-token-limiting tokenizer tokenizes like the default one.
            #expect(scalars(try UniqueTokenLimitTextTokenizer().tokenize(sample, version: 0, mode: .index)) == scalars(expected))
        }
    }

    @Test("prefix tokenizer v0 and v1 match Java")
    func prefixTokenizerSamples() throws {
        for (sample, expected) in zip(TextSamples.samples, TextSamples.expectedPrefixV0) {
            #expect(scalars(try PrefixTextTokenizer().tokenize(sample, version: 0, mode: .index)) == scalars(expected))
        }
        for (sample, expected) in zip(TextSamples.samples, TextSamples.expectedPrefixV1) {
            #expect(scalars(try PrefixTextTokenizer().tokenize(sample, version: 1, mode: .index)) == scalars(expected))
        }
        #expect(throws: TextIndexError.unknownTokenizerVersion(tokenizer: "prefix", version: 2, min: 0, max: 1)) {
            try PrefixTextTokenizer().tokenize("x", version: 2, mode: .index)
        }
    }

    @Test("filtering tokenizer leaves stop words as empty tokens, as Java")
    func filteringTokenizerSamples() throws {
        let stopWords: Set<String> = ["the", "of", "in", "and", "a", "an", "some"]
        let filtering = FilteringTextTokenizer(name: "filter_common", underlying: DefaultTextTokenizer()) { token, _ in
            !stopWords.contains(token)
        }
        for (sample, expected) in zip(TextSamples.samples, TextSamples.expectedFiltered) {
            #expect(scalars(try filtering.tokenize(sample, version: 0, mode: .index)) == scalars(expected))
        }
        // Stop words keep their positions in the token map.
        #expect(try filtering.tokenizeToMap("the cat and the hat", version: 0, mode: .index) == ["cat": [1], "hat": [4]])
    }

    @Test("unique-token-limiting tokenizer stops its map at five distinct tokens, as Java")
    func uniqueTokenLimitSamples() throws {
        for (sample, expected) in zip(TextSamples.samples, TextSamples.expectedUniqueLimitReconstituted) {
            let map = try UniqueTokenLimitTextTokenizer().tokenizeToMap(sample, version: 0, mode: .index)
            // Java's `reconstitutedTokenList`: tokens laid out at their positions, gaps empty.
            let maxOffset = map.values.flatMap { $0 }.max() ?? -1
            var laidOut = Array(repeating: "", count: maxOffset + 1)
            for (token, offsets) in map { for offset in offsets { laidOut[offset] = token } }
            #expect(scalars(laidOut) == scalars(expected))
        }
    }

    @Test("all-suffixes tokenizer indexes every suffix but queries whole tokens")
    func allSuffixes() throws {
        let tokenizer = AllSuffixesTextTokenizer()
        #expect(try tokenizer.tokenize("Hello hi", version: 0, mode: .index) == ["hello", "ello", "llo", "lo", "o", "hi", "i"])
        #expect(try tokenizer.tokenize("Hello hi", version: 0, mode: .query) == ["hello", "hi"])
    }

    @Test("JDK word-break and normalization behaviors")
    func jdkWordBreaking() throws {
        let cases: [(String, [String])] = [
            ("Don't stop", ["don't", "stop"]),
            ("e.g. i.e. U.S.A.", ["e.g", "i.e", "u.s.a"]),
            ("3.14 1,000 1.000,5 v1.2.3", ["3.14", "1,000", "1.000,5", "v1.2.3"]),
            ("hello-world foo_bar a.b user@example.com http://x.com/a?b=c",
             ["hello-world", "foo_bar", "a.b", "user", "example.com", "http", "x.com", "a", "b", "c"]),
            ("日本語のテキストです", ["日本語", "の", "テキスト", "てす"]),
            ("カタカナ ひらがな", ["カタカナ", "ひらかな"]),
            ("ΟΔΟΣ Σίσυφος ΣΑΣ", ["οδος", "σισυφος", "σας"]),
            ("İstanbul Igloo ß ﬆ ﬁ", ["istanbul", "igloo", "ß", "st", "fi"]),
            ("½ x² ①②③", ["1⁄2", "x2", "123"]),
            ("$100 #hashtag @mention 50% 5¢", ["$100", "hashtag", "mention", "50%", "5¢"]),
            ("O'Neil can’t a.1 1.a", ["o'neil", "can", "t", "a", ".1", "1", "a"]),
            ("emoji 😀 test 👍🏽 ok", ["emoji", "test", "ok"]),
            ("a\u{200D}b x\u{0301}y a-\u{0301}b", ["a\u{200D}b", "xy", "a", "b"]),
        ]
        for (text, expected) in cases {
            #expect(scalars(try DefaultTextTokenizer().tokenize(text, version: 0, mode: .index)) == scalars(expected), "\(text)")
        }
        // The final sigma is decided within the word, exactly as `String.toLowerCase` does.
        #expect(try DefaultTextTokenizer().tokenize("ΟΔΟΣ", version: 0, mode: .index).first?.unicodeScalars.last == "\u{03C2}")
        #expect(try DefaultTextTokenizer().tokenize("ΑΣ.Α", version: 0, mode: .index).first?.unicodeScalars.dropFirst().first == "\u{03C3}")
        #expect(try DefaultTextTokenizer().tokenizeToMap("a b a, c... a", version: 0, mode: .index) == ["a": [0, 2, 4], "b": [1], "c": [3]])
    }

    @Test("tokenizer registry")
    func registry() throws {
        let registry = TextTokenizerRegistry()
        #expect(registry.names == ["all_suffixes", "default", "prefix", "unique_token_limiting"])
        #expect(try registry.tokenizer(named: nil).name == "default")
        #expect(throws: TextIndexError.unknownTokenizer("nope")) { try registry.tokenizer(named: "nope") }
        let custom = FilteringTextTokenizer(name: "no_digits", underlying: DefaultTextTokenizer()) { token, _ in
            !token.allSatisfy(\.isNumber)
        }
        try registry.register(custom)
        try registry.register(custom) // the same kind again is fine
        #expect(try registry.tokenizer(named: "no_digits").tokenize("route 66", version: 0, mode: .index) == ["route", ""])
        #expect(throws: TextIndexError.duplicateTokenizer("prefix")) {
            try registry.register(FilteringTextTokenizer(name: "prefix", underlying: DefaultTextTokenizer()) { _, _ in true })
        }
        registry.reset()
        #expect(throws: TextIndexError.unknownTokenizer("no_digits")) { try registry.tokenizer(named: "no_digits") }
        #expect(throws: TextIndexError.unknownTokenizerVersion(tokenizer: "default", version: 1, min: 0, max: 0)) {
            try DefaultTextTokenizer().tokenize("x", version: 1, mode: .index)
        }
    }

    @Test("bunched serializer bytes match Java's TextIndexBunchedSerializerTest")
    func serializerBytes() throws {
        typealias S = TextIndexBunchedSerializer
        let key1066 = Tuple(Int64(1066)).encode()
        // serializeEntry
        #expect(try S.serializeEntry(.init(key: key1066, value: [0, 1, 128, 256]))
                == [0x03] + key1066 + [0x05, 0x00, 0x01, 0x7F, 0x81, 0x00])
        // example
        let entries: [S.Entry] = [.init(key: key1066, value: [1, 3, 5, 8]),
                                  .init(key: Tuple(Int64(1415)).encode(), value: [0, 600, 605])]
        let bytes = try S.serializeEntries(entries)
        #expect(bytes == [0x20, 0x04, 0x01, 0x02, 0x02, 0x03, 0x03, 0x16, 0x05, 0x87, 0x04, 0x00, 0x84, 0x58, 0x05])
        #expect(try S.deserializeEntries(firstKey: key1066, bytes) == entries)
        // Round trip with odd keys and empty lists.
        let odd: [S.Entry] = [.init(key: Tuple(Int64(0)).encode(), value: []), .init(key: [], value: [0, 1]),
                              .init(key: Tuple("hello").encode(), value: [0, 1, 1]),
                              .init(key: Tuple(Int64(7)).encode(), value: [0, 127, 255, 12345, 67890])]
        #expect(try S.deserializeEntries(firstKey: odd[0].key, try S.serializeEntries(odd)) == odd)
        #expect(try S.deserializeEntries(firstKey: odd[0].key, try S.serializeEntries(odd), values: false).map(\.key) == odd.map(\.key))
        // Invalid input, as in Java.
        for bad in [[0, 1, 0], [-1, 1, 2], [1, 3, -1]] {
            #expect(throws: TextIndexError.self) { try S.serializeEntry(.init(key: key1066, value: bad)) }
        }
        #expect(throws: TextIndexError.self) { try S.serializeEntries([]) }
        for data: FDB.Bytes in [[0x21, 0x04, 0x01, 0x02, 0x03, 0x04], [0x20, 0x04, 0x01, 0x02, 0x03],
                                [0x20, 0x00, 0x03] + Tuple(Int64(1415)).encode()] {
            #expect(throws: TextIndexError.self) { try S.deserializeEntries(firstKey: key1066, data) }
        }
    }
}

/// Text indexes against a live cluster.
@Suite("Text index (integration)", .serialized)
struct TextIndexTests {
    private func database() async throws -> FDBDatabase {
        try await FDBBootstrap.shared.ensureInitialized()
        return try FDBClient.openDatabase()
    }

    private func freshSubspace() -> Subspace { Subspace(Tuple("fdbrl-text", UUID().uuidString)) }

    private func run<T: Sendable>(_ db: FDBDatabase, _ subspace: Subspace, _ meta: RecordMetaData,
                                  _ body: (FDBRecordStore) async throws -> T) async throws -> T {
        try await db.withRecordContext { context in
            let store = try await FDBRecordStore.open(context: context, subspace: subspace, metaData: meta)
            return try await body(store)
        }
    }

    private func cleanup(_ db: FDBDatabase, _ subspace: Subspace) async throws {
        try await db.withRecordContext { FDBRecordStore.deleteStore(context: $0, subspace: subspace) }
    }

    private func raw(_ db: FDBDatabase, _ range: (begin: FDB.Bytes, end: FDB.Bytes)) async throws -> [(FDB.Bytes, FDB.Bytes)] {
        try await db.withTransaction { tx in
            var result: [(FDB.Bytes, FDB.Bytes)] = []
            for try await kv in tx.getRange(beginKey: range.begin, endKey: range.end) { result.append(kv) }
            return result
        }
    }

    /// Item records with a text index named `item.text` on `name`.
    private func simpleMeta() -> RecordMetaData {
        RecordMetaData { RecordType(Fdb_Test_Item.self, primaryKey: \.sku).index("item.text", on: \.name, type: .text) }
    }

    /// A text index declared with options (and optionally grouped by `category`).
    private func optionsMeta(_ options: [String: String], grouped: Bool = false) -> RecordMetaData {
        let name = KeyExpressionNode.field(number: 2, fanType: nil)
        let category = KeyExpressionNode.field(number: 4, fanType: nil)
        let index = MultiTypeIndex("item.text", on: grouped ? .then([category, name]) : name, type: .text,
                                   recordTypes: [Fdb_Test_Item.self], options: options)
        return RecordMetaData(multiTypeIndexes: [index]) { RecordType(Fdb_Test_Item.self, primaryKey: \.sku) }
    }

    /// The (map key, positions) entries of every bunch of one token, as (bunch first keys, entries).
    private func bunches(_ db: FDBDatabase, _ subspace: Subspace, _ mapPrefix: [any TupleElement]) async throws
        -> (firstKeys: [String], entries: [(String, [Int])]) {
        let map = subspace.subspace(Tuple([Int64(2), "item.text"] + mapPrefix))
        var firstKeys: [String] = []
        var entries: [(String, [Int])] = []
        for (key, value) in try await raw(db, map.range) {
            let suffix = Array(key.dropFirst(map.prefix.count))
            firstKeys.append(try map.unpack(key).first as! String)
            for entry in try TextIndexBunchedSerializer.deserializeEntries(firstKey: suffix, value) {
                entries.append((try Tuple.decode(from: entry.key).first as! String, entry.value))
            }
        }
        return (firstKeys, entries)
    }

    // MARK: - On-disk format

    @Test("entries, bunches and tokenizer versions use Java's exact keys and values")
    func exactBytes() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let meta = simpleMeta()
        try await run(db, subspace, meta) { _ = try await $0.save(Fdb_Test_Item.sample(sku: "a", name: "Hello, hello world")) }

        let indexRange = subspace.subspace(Tuple(Int64(2), "item.text")).range
        var kvs = try await raw(db, indexRange)
        #expect(kvs.map(\.0) == [subspace.pack(Tuple(Int64(2), "item.text", "hello", "a")),
                                 subspace.pack(Tuple(Int64(2), "item.text", "world", "a"))])
        // 0x20 prefix; position list byte size; delta-encoded positions.
        #expect(kvs.map(\.1) == [[0x20, 0x02, 0x00, 0x01], [0x20, 0x01, 0x02]])
        // The record's tokenizer version: secondary / (0, pk) → Tuple(0).
        let versionKey = subspace.pack(Tuple(Int64(3), "item.text", Int64(0), "a"))
        #expect(try await raw(db, subspace.subspace(Tuple(Int64(3), "item.text")).range).map(\.0) == [versionKey])
        #expect(try await raw(db, subspace.subspace(Tuple(Int64(3), "item.text")).range).map(\.1) == [[0x14]])

        // A second record joins the "hello" bunch (Java appends with APPEND_IF_FITS).
        try await run(db, subspace, meta) { _ = try await $0.save(Fdb_Test_Item.sample(sku: "b", name: "hello")) }
        kvs = try await raw(db, indexRange)
        #expect(kvs.map(\.0) == [subspace.pack(Tuple(Int64(2), "item.text", "hello", "a")),
                                 subspace.pack(Tuple(Int64(2), "item.text", "world", "a"))])
        #expect(kvs[0].1 == [0x20, 0x02, 0x00, 0x01, 0x03, 0x02, 0x62, 0x00, 0x01, 0x00])

        // Removing the bunch's first record re-keys the bunch under the next map key.
        try await run(db, subspace, meta) { _ = try await $0.delete(Fdb_Test_Item.self, primaryKey: Tuple("a")) }
        kvs = try await raw(db, indexRange)
        #expect(kvs.map(\.0) == [subspace.pack(Tuple(Int64(2), "item.text", "hello", "b"))])
        #expect(kvs.map(\.1) == [[0x20, 0x01, 0x00]])
        #expect(try await raw(db, subspace.subspace(Tuple(Int64(3), "item.text")).range).map(\.0)
                == [subspace.pack(Tuple(Int64(3), "item.text", Int64(0), "b"))])
        try await cleanup(db, subspace)
    }

    @Test("bunches hold at most 20 entries and split as Java's BunchedMap does")
    func bunching() async throws {
        let db = try await database()
        let meta = simpleMeta()
        let skus = (1...25).map { String(format: "k%02d", $0) }

        // Ascending inserts fill a bunch, then start a new one.
        let ascending = freshSubspace()
        try await run(db, ascending, meta) { store in
            for sku in skus { _ = try await store.save(Fdb_Test_Item.sample(sku: sku, name: "word")) }
        }
        var layout = try await bunches(db, ascending, ["word"])
        #expect(layout.firstKeys == ["k01", "k21"])
        #expect(layout.entries.map(\.0) == skus)
        #expect(layout.entries.allSatisfy { $0.1 == [0] })
        try await cleanup(db, ascending)

        // Descending inserts (one transaction each) re-key the bunch in front until it is full.
        let descending = freshSubspace()
        for sku in skus.reversed() {
            try await run(db, descending, meta) { _ = try await $0.save(Fdb_Test_Item.sample(sku: sku, name: "word")) }
        }
        layout = try await bunches(db, descending, ["word"])
        #expect(layout.firstKeys == ["k01", "k06"])
        #expect(layout.entries.map(\.0) == skus)

        // Removing a middle entry rewrites in place; removing a first entry re-keys.
        try await run(db, descending, meta) { store in
            _ = try await store.delete(Fdb_Test_Item.self, primaryKey: Tuple("k03"))
            _ = try await store.delete(Fdb_Test_Item.self, primaryKey: Tuple("k06"))
        }
        layout = try await bunches(db, descending, ["word"])
        #expect(layout.firstKeys == ["k01", "k07"])
        #expect(layout.entries.map(\.0) == skus.filter { $0 != "k03" && $0 != "k06" })
        // Inserting into the middle of a bunch that is already full splits it in half.
        try await run(db, descending, meta) { store in
            for sku in ["k10a", "k10b"] { _ = try await store.save(Fdb_Test_Item.sample(sku: sku, name: "word")) }
        }
        layout = try await bunches(db, descending, ["word"])
        #expect(layout.firstKeys == ["k01", "k07", "k15"])
        #expect(layout.entries.map(\.0) == (skus.filter { $0 != "k03" && $0 != "k06" } + ["k10a", "k10b"]).sorted())
        try await cleanup(db, descending)
    }

    @Test("values over 10,000 bytes are not bunched together")
    func largeValues() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let meta = simpleMeta()
        let text = Array(repeating: "w", count: 6_000).joined(separator: " ")
        try await run(db, subspace, meta) { store in
            for sku in ["a", "b", "c"] { _ = try await store.save(Fdb_Test_Item.sample(sku: sku, name: text)) }
        }
        let layout = try await bunches(db, subspace, ["w"])
        #expect(layout.firstKeys == ["a", "b", "c"])
        #expect(layout.entries.map { $0.1.count } == [6_000, 6_000, 6_000])
        try await run(db, subspace, meta) { store in
            do { let result: [Tuple] = try await store.textSearchPrimaryKeys(Fdb_Test_Item.self, indexNamed: "item.text", .containsAll("w")); #expect(result == [Tuple("a"), Tuple("b"), Tuple("c")]) }
        }
        try await cleanup(db, subspace)
    }

    // MARK: - Maintenance

    @Test("updates replace a record's tokens; deletes remove them and its tokenizer version")
    func updateAndDelete() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let meta = simpleMeta()
        let indexRange = subspace.subspace(Tuple(Int64(2), "item.text")).range
        func tokens() async throws -> [String] {
            try await raw(db, indexRange).map { try subspace.unpack($0.0)[2] as! String }
        }
        try await run(db, subspace, meta) { store in
            _ = try await store.save(Fdb_Test_Item.sample(sku: "a", name: "quick brown fox"))
            _ = try await store.save(Fdb_Test_Item.sample(sku: "b", name: "lazy brown dog"))
        }
        // "brown" has one bunch holding both records.
        #expect(try await tokens() == ["brown", "dog", "fox", "lazy", "quick"])
        try await run(db, subspace, meta) { _ = try await $0.save(Fdb_Test_Item.sample(sku: "a", name: "quick red fox")) }
        #expect(try await tokens() == ["brown", "dog", "fox", "lazy", "quick", "red"])
        try await run(db, subspace, meta) { store in
            do { let result: [Tuple] = try await store.textSearchPrimaryKeys(Fdb_Test_Item.self, indexNamed: "item.text", .containsAll("brown")); #expect(result == [Tuple("b")]) }
            do { let result: [Tuple] = try await store.textSearchPrimaryKeys(Fdb_Test_Item.self, indexNamed: "item.text", .containsAll("red fox")); #expect(result == [Tuple("a")]) }
        }
        // An empty text indexes nothing (but the record still gets a tokenizer version).
        try await run(db, subspace, meta) { _ = try await $0.save(Fdb_Test_Item.sample(sku: "a", name: "")) }
        #expect(try await tokens() == ["brown", "dog", "lazy"])
        try await run(db, subspace, meta) { store in
            _ = try await store.delete(Fdb_Test_Item.self, primaryKey: Tuple("a"))
            _ = try await store.delete(Fdb_Test_Item.self, primaryKey: Tuple("b"))
        }
        #expect(try await raw(db, indexRange).isEmpty)
        #expect(try await raw(db, subspace.subspace(Tuple(Int64(3), "item.text")).range).isEmpty)
        try await cleanup(db, subspace)
    }

    @Test("a changed tokenizer version re-indexes a record with the new version on update")
    func tokenizerVersionChange() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let v0 = optionsMeta([IndexOptions.textTokenizerName: "prefix", IndexOptions.textTokenizerVersion: "0"])
        let v1 = optionsMeta([IndexOptions.textTokenizerName: "prefix", IndexOptions.textTokenizerVersion: "1"])
        let indexRange = subspace.subspace(Tuple(Int64(2), "item.text")).range
        let versionKey = subspace.pack(Tuple(Int64(3), "item.text", Int64(0), "a"))
        try await run(db, subspace, v0) { _ = try await $0.save(Fdb_Test_Item.sample(sku: "a", name: "hello world")) }
        #expect(try await raw(db, indexRange).map { try subspace.unpack($0.0)[2] as! String } == ["hel", "wor"])
        // Queries tokenize with the index's version.
        try await run(db, subspace, v1) { store in
            #expect(try await store.textSearchPrimaryKeys(Fdb_Test_Item.self, indexNamed: "item.text", .containsAll("hello")).isEmpty)
            _ = try await store.save(Fdb_Test_Item.sample(sku: "a", name: "hello there"))
            do { let result: [Tuple] = try await store.textSearchPrimaryKeys(Fdb_Test_Item.self, indexNamed: "item.text", .containsAll("hello")); #expect(result == [Tuple("a")]) }
        }
        // Old (v0) tokens were removed with the v0 tokenizer; new ones written with v1.
        #expect(try await raw(db, indexRange).map { try subspace.unpack($0.0)[2] as! String } == ["hell", "ther"])
        do { let result: [FDB.Bytes] = try await raw(db, (versionKey, versionKey + [0x00])).map(\.1); #expect(result == [Tuple(Int64(1)).encode()]) }
        try await cleanup(db, subspace)
    }

    @Test("omit-positions, aggressive-conflict-range and unknown-tokenizer options")
    func indexOptions() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let meta = optionsMeta([IndexOptions.textOmitPositions: "true", IndexOptions.textAddAggressiveConflictRanges: "true"])
        try await run(db, subspace, meta) { store in
            _ = try await store.save(Fdb_Test_Item.sample(sku: "a", name: "to be or not to be"))
            _ = try await store.save(Fdb_Test_Item.sample(sku: "b", name: "be quick"))
        }
        let kvs = try await raw(db, subspace.subspace(Tuple(Int64(2), "item.text", "be")).range)
        #expect(kvs.map(\.1) == [[0x20, 0x00, 0x03, 0x02, 0x62, 0x00, 0x00]])
        try await run(db, subspace, meta) { store in
            // Without positions, phrase matching assumes the tokens are adjacent.
            do { let result: [Tuple] = try await store.textSearchPrimaryKeys(Fdb_Test_Item.self, indexNamed: "item.text", .containsPhrase("be to")); #expect(result == [Tuple("a")]) }
        }
        try await cleanup(db, subspace)

        let unknown = optionsMeta([IndexOptions.textTokenizerName: "no-such-tokenizer"])
        let other = freshSubspace()
        await #expect(throws: TextIndexError.unknownTokenizer("no-such-tokenizer")) {
            try await run(db, other, unknown) { _ = try await $0.save(Fdb_Test_Item.sample(sku: "a", name: "x")) }
        }
        try await cleanup(db, other)
    }

    // MARK: - Queries

    @Test("containsAll / Any / Phrase / Prefix / AllPrefixes / AnyPrefix / within distance")
    func queries() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let meta = simpleMeta()
        try await run(db, subspace, meta) { store in
            for (sku, name) in [("a", "the quick brown fox jumps over the lazy dog"), ("b", "the quick red fox"),
                                ("c", "a lazy brown dog sleeps"), ("d", "Brown bears and brown dogs")] {
                _ = try await store.save(Fdb_Test_Item.sample(sku: sku, name: name))
            }
        }
        try await run(db, subspace, meta) { store in
            func keys(_ comparison: TextComparison) async throws -> [String] {
                try await store.textSearchPrimaryKeys(Fdb_Test_Item.self, indexNamed: "item.text", comparison)
                    .map { $0.elements[0] as! String }
            }
            #expect(try await keys(.containsAll("Quick FOX")) == ["a", "b"])
            #expect(try await keys(.containsAll("brown dog")) == ["a", "c"])
            #expect(try await keys(.containsAll(["brown", "dogs"])) == ["d"])
            #expect(try await keys(.containsAny("red bears")) == ["b", "d"])
            #expect(try await keys(.containsAny(["sleeps", "jumps"])) == ["a", "c"])
            #expect(try await keys(.containsPhrase("brown fox")) == ["a"])
            #expect(try await keys(.containsPhrase("lazy dog")) == ["a"])
            #expect(try await keys(.containsPhrase("brown")) == ["a", "c", "d"])
            // Stop words (empty tokens) hold a position in a phrase.
            #expect(try await keys(.containsPhrase(["quick", "", "fox"])) == ["a", "b"])
            #expect(try await keys(.containsPhrase(["the", "", "red"])) == ["b"])
            #expect(try await keys(.containsPhrase(["the", "", "fox"])) == [])
            #expect(try await keys(.containsPrefix("do")) == ["a", "c", "d"])
            #expect(try await keys(.containsPrefix("Bro")) == ["a", "c", "d"])
            #expect(try await keys(.containsAllPrefixes("qu fo")) == ["a", "b"])
            #expect(try await keys(.containsAllPrefixes(["sle", "do"])) == ["c"])
            #expect(try await keys(.containsAnyPrefix("bea sle")) == ["c", "d"])
            #expect(try await keys(.containsAll("quick dog", maxDistance: 7)) == ["a"])
            #expect(try await keys(.containsAll("quick dog", maxDistance: 6)) == [])
            #expect(try await keys(.containsAll("")) == [])
            #expect(try await keys(.containsAll("zebra")) == [])
            await #expect(throws: TextIndexError.self) { _ = try await keys(.containsPrefix("two words")) }

            let records = try await store.textSearch(Fdb_Test_Item.self, indexNamed: "item.text", .containsAny("red sleeps"))
            #expect(records.map(\.record.name) == ["the quick red fox", "a lazy brown dog sleeps"])

            let postings = try await store.scanTextIndex(Fdb_Test_Item.self, indexNamed: "item.text", token: "brown")
            #expect(postings.map(\.primaryKey) == [Tuple("a"), Tuple("c"), Tuple("d")])
            #expect(postings.map(\.positions) == [[2], [2], [0, 3]])
            let prefixed = try await store.scanTextIndex(Fdb_Test_Item.self, indexNamed: "item.text", token: "do", prefix: true)
            #expect(prefixed.map(\.token) == ["dog", "dog", "dogs"])
        }
        try await cleanup(db, subspace)
    }

    @Test("grouped text index: group values and suffix ranges restrict the scan")
    func groupedIndex() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let meta = optionsMeta([:], grouped: true)
        try await run(db, subspace, meta) { store in
            _ = try await store.save(Fdb_Test_Item.sample(sku: "a", name: "red apple", category: "x"))
            _ = try await store.save(Fdb_Test_Item.sample(sku: "b", name: "red cherry", category: "y"))
            _ = try await store.save(Fdb_Test_Item.sample(sku: "c", name: "green apple", category: "x"))
        }
        // index / (group, token, pk)
        #expect(try await raw(db, subspace.subspace(Tuple(Int64(2), "item.text", "x", "red")).range).map(\.0)
                == [subspace.pack(Tuple(Int64(2), "item.text", "x", "red", "a"))])
        try await run(db, subspace, meta) { store in
            func keys(_ comparison: TextComparison, _ group: String, _ suffix: TextSuffixRange? = nil) async throws -> [Tuple] {
                try await store.textSearchPrimaryKeys(Fdb_Test_Item.self, indexNamed: "item.text", comparison,
                                                      group: Tuple(group), suffix: suffix)
            }
            do { let result: [Tuple] = try await keys(.containsAll("red"), "x"); #expect(result == [Tuple("a")]) }
            do { let result: [Tuple] = try await keys(.containsAll("red"), "y"); #expect(result == [Tuple("b")]) }
            do { let result: [Tuple] = try await keys(.containsAny("apple cherry"), "x"); #expect(result == [Tuple("a"), Tuple("c")]) }
            #expect(try await keys(.containsPrefix("ap"), "y") == [])
            do { let result: [Tuple] = try await keys(.containsAny("apple"), "x", TextSuffixRange(low: Tuple("b"))); #expect(result == [Tuple("c")]) }
            do { let result: [Tuple] = try await keys(.containsAny("apple"), "x", TextSuffixRange(high: Tuple("a"), highInclusive: true)); #expect(result == [Tuple("a")]) }
            do { let result: [Tuple] = try await keys(.containsAny("apple"), "x", TextSuffixRange(high: Tuple("a"))); #expect(result == []) }
            await #expect(throws: TextIndexError.self) { _ = try await keys(.containsPrefix("ap"), "x", TextSuffixRange(low: Tuple("b"))) }
            // All grouping columns must be given.
            await #expect(throws: TextIndexError.self) {
                _ = try await store.textSearchPrimaryKeys(Fdb_Test_Item.self, indexNamed: "item.text", .containsAll("red"))
            }
        }
        try await cleanup(db, subspace)
    }

    @Test("queries require a scannable text index")
    func requiresScannableIndex() async throws {
        let db = try await database()
        let subspace = freshSubspace()
        let meta = simpleMeta()
        try await run(db, subspace, meta) { _ = try await $0.markIndexDisabled("item.text") }
        _ = try await run(db, subspace, meta) { store in
            await #expect {
                _ = try await store.textSearchPrimaryKeys(Fdb_Test_Item.self, indexNamed: "item.text", .containsAll("x"))
            } throws: { error in
                if case RecordStoreError.indexNotBuilt("item.text") = error { return true }
                return false
            }
        }
        try await cleanup(db, subspace)
    }
}

/// Java's `TextSamples` and the expected tokens from `TextTokenizerTest` (generated from the
/// Java sources, with Java's `\u` escapes and NFC normalization preserved).
enum TextSamples {
    /// Java's `TextSamples.ALL`.
    static let samples: [String] = [
        "The Angstrom unit (Å) was named after Anders Ångström.",
        "According to the encyclopædia, Æthelred the Unræd was king from 966 to 1016.",
        "ℍ𝕖𝕝𝕝𝕠 𝕥𝕙𝕖𝕣𝕖.",
        "苹果园区",
        "蘋果園區",
        "Text tokenization and normalization is 💯🔥👌!",
        "Who ﬆarted the ﬁre?",
        "Après deux Napoléons, France a reçu un Thiers.".precomposedStringWithCanonicalMapping,
        "Die Nationalmannschaft hat die Weltmeisterschaft gewonnen. Hörte ich während ich die Friedrichstraße hinunterlief.".precomposedStringWithCanonicalMapping,
        "Όλοι οι άνθρωποι είναι θνητοί. Ο ΣΩΚΡΆΤΗΣ είναι άνθρωπος. Ο Σωκρᾰ́της είναι θνητός.",
        "나는 한국어를 못해.".precomposedStringWithCanonicalMapping,
        "נוּן",
        "Engliſh uſed to have multiple verſions of the letter \"s\".",
        "Two households, both alike in dignity,\nIn fair Verona, where we lay our scene,\nFrom ancient grudge break to new mutiny,\nWhere civil blood makes civil hands unclean.\nFrom forth the fatal loins of these two foes\nA pair of star-cross’d lovers take their life;\nWhose misadventur’d piteous overthrows\nDoth with their death bury their parents’ strife.\nThe fearful passage of their death-mark’d love,\nAnd the continuance of their parents’ rage,\nWhich, but their children’s end, nought could remove,\nIs now the two hours’ traffic of our stage;\nThe which, if you with patient ears attend,\nWhat here shall miss, our toil shall strive to mend.",
        "Актёр посети́л мно́гие достопримеча́тельности Москвы́.",
        "లేదా అది అర్ధంలేనిదేనా?",
        "การสะกดการันต์ไทยมีความซับซ้อนมาก",
        "https://www.example.com/fake-path/1932e32ab3efc0014228eadc28219da2/hm",
        "אַ שפּראַך איז אַ דיאַלעקט מיט אַן אַרמיי און פֿלאָט.",
    ]
    static let expectedDefault: [[String]] = [
        ["the", "angstrom", "unit", "a", "was", "named", "after", "anders", "angstrom"],
        ["according", "to", "the", "encyclopædia", "æthelred", "the", "unræd", "was", "king", "from", "966", "to", "1016"],
        ["hello", "there"],
        ["苹果园区"],
        ["蘋果園區"],
        ["text", "tokenization", "and", "normalization", "is"],
        ["who", "started", "the", "fire"],
        ["apres", "deux", "napoleons", "france", "a", "recu", "un", "thiers"],
        ["die", "nationalmannschaft", "hat", "die", "weltmeisterschaft", "gewonnen", "horte", "ich", "wahrend", "ich", "die", "friedrichstraße", "hinunterlief"],
        ["ολοι", "οι", "ανθρωποι", "ειναι", "θνητοι", "ο", "σωκρατης", "ειναι", "ανθρωπος", "ο", "σωκρατης", "ειναι", "θνητος"],
        ["나는", "한국어를", "못해"],
        ["נון"],
        ["english", "used", "to", "have", "multiple", "versions", "of", "the", "letter", "s"],
        ["two", "households", "both", "alike", "in", "dignity", "in", "fair", "verona", "where", "we", "lay", "our", "scene", "from", "ancient", "grudge", "break", "to", "new", "mutiny", "where", "civil", "blood", "makes", "civil", "hands", "unclean", "from", "forth", "the", "fatal", "loins", "of", "these", "two", "foes", "a", "pair", "of", "star-cross", "d", "lovers", "take", "their", "life", "whose", "misadventur", "d", "piteous", "overthrows", "doth", "with", "their", "death", "bury", "their", "parents", "strife", "the", "fearful", "passage", "of", "their", "death-mark", "d", "love", "and", "the", "continuance", "of", "their", "parents", "rage", "which", "but", "their", "children", "s", "end", "nought", "could", "remove", "is", "now", "the", "two", "hours", "traffic", "of", "our", "stage", "the", "which", "if", "you", "with", "patient", "ears", "attend", "what", "here", "shall", "miss", "our", "toil", "shall", "strive", "to", "mend"],
        ["актер", "посетил", "многие", "достопримечательности", "москвы"],
        ["లద", "అద", "అరధలనదన"],
        ["การสะกดการนตไทยมความซบซอนมาก"],
        ["https", "www.example.com", "fake-path", "1932e32ab3efc0014228eadc28219da2", "hm"],
        ["א", "שפראך", "איז", "א", "דיאלעקט", "מיט", "אן", "ארמיי", "און", "פלאט"],
    ]
    static let expectedPrefixV0: [[String]] = [
        ["the", "ang", "uni", "a", "was", "nam", "aft", "and", "ang"],
        ["acc", "to", "the", "enc", "æth", "the", "unr", "was", "kin", "fro", "966", "to", "101"],
        ["hel", "the"],
        ["苹果园"],
        ["蘋果園"],
        ["tex", "tok", "and", "nor", "is"],
        ["who", "sta", "the", "fir"],
        ["apr", "deu", "nap", "fra", "a", "rec", "un", "thi"],
        ["die", "nat", "hat", "die", "wel", "gew", "hor", "ich", "wah", "ich", "die", "fri", "hin"],
        ["ολο", "οι", "ανθ", "ειν", "θνη", "ο", "σωκ", "ειν", "ανθ", "ο", "σωκ", "ειν", "θνη"],
        ["나ᄂ", "한", "못"],
        ["נון"],
        ["eng", "use", "to", "hav", "mul", "ver", "of", "the", "let", "s"],
        ["two", "hou", "bot", "ali", "in", "dig", "in", "fai", "ver", "whe", "we", "lay", "our", "sce", "fro", "anc", "gru", "bre", "to", "new", "mut", "whe", "civ", "blo", "mak", "civ", "han", "unc", "fro", "for", "the", "fat", "loi", "of", "the", "two", "foe", "a", "pai", "of", "sta", "d", "lov", "tak", "the", "lif", "who", "mis", "d", "pit", "ove", "dot", "wit", "the", "dea", "bur", "the", "par", "str", "the", "fea", "pas", "of", "the", "dea", "d", "lov", "and", "the", "con", "of", "the", "par", "rag", "whi", "but", "the", "chi", "s", "end", "nou", "cou", "rem", "is", "now", "the", "two", "hou", "tra", "of", "our", "sta", "the", "whi", "if", "you", "wit", "pat", "ear", "att", "wha", "her", "sha", "mis", "our", "toi", "sha", "str", "to", "men"],
        ["акт", "пос", "мно", "дос", "мос"],
        ["లద", "అద", "అరధ"],
        ["การ"],
        ["htt", "www", "fak", "193", "hm"],
        ["א", "שפר", "איז", "א", "דיא", "מיט", "אן", "ארמ", "און", "פלא"],
    ]
    static let expectedPrefixV1: [[String]] = [
        ["the", "angs", "unit", "a", "was", "name", "afte", "ande", "angs"],
        ["acco", "to", "the", "ency", "æthe", "the", "unræ", "was", "king", "from", "966", "to", "1016"],
        ["hell", "ther"],
        ["苹果园区"],
        ["蘋果園區"],
        ["text", "toke", "and", "norm", "is"],
        ["who", "star", "the", "fire"],
        ["apre", "deux", "napo", "fran", "a", "recu", "un", "thie"],
        ["die", "nati", "hat", "die", "welt", "gewo", "hort", "ich", "wahr", "ich", "die", "frie", "hinu"],
        ["ολοι", "οι", "ανθρ", "εινα", "θνητ", "ο", "σωκρ", "εινα", "ανθρ", "ο", "σωκρ", "εινα", "θνητ"],
        ["나느", "한ᄀ", "못ᄒ"],
        ["נון"],
        ["engl", "used", "to", "have", "mult", "vers", "of", "the", "lett", "s"],
        ["two", "hous", "both", "alik", "in", "dign", "in", "fair", "vero", "wher", "we", "lay", "our", "scen", "from", "anci", "grud", "brea", "to", "new", "muti", "wher", "civi", "bloo", "make", "civi", "hand", "uncl", "from", "fort", "the", "fata", "loin", "of", "thes", "two", "foes", "a", "pair", "of", "star", "d", "love", "take", "thei", "life", "whos", "misa", "d", "pite", "over", "doth", "with", "thei", "deat", "bury", "thei", "pare", "stri", "the", "fear", "pass", "of", "thei", "deat", "d", "love", "and", "the", "cont", "of", "thei", "pare", "rage", "whic", "but", "thei", "chil", "s", "end", "noug", "coul", "remo", "is", "now", "the", "two", "hour", "traf", "of", "our", "stag", "the", "whic", "if", "you", "with", "pati", "ears", "atte", "what", "here", "shal", "miss", "our", "toil", "shal", "stri", "to", "mend"],
        ["акте", "посе", "мног", "дост", "моск"],
        ["లద", "అద", "అరధల"],
        ["การส"],
        ["http", "www.", "fake", "1932", "hm"],
        ["א", "שפרא", "איז", "א", "דיאל", "מיט", "אן", "ארמי", "און", "פלאט"],
    ]
    static let expectedFiltered: [[String]] = [
        ["", "angstrom", "unit", "", "was", "named", "after", "anders", "angstrom"],
        ["according", "to", "", "encyclopædia", "æthelred", "", "unræd", "was", "king", "from", "966", "to", "1016"],
        ["hello", "there"],
        ["苹果园区"],
        ["蘋果園區"],
        ["text", "tokenization", "", "normalization", "is"],
        ["who", "started", "", "fire"],
        ["apres", "deux", "napoleons", "france", "", "recu", "un", "thiers"],
        ["die", "nationalmannschaft", "hat", "die", "weltmeisterschaft", "gewonnen", "horte", "ich", "wahrend", "ich", "die", "friedrichstraße", "hinunterlief"],
        ["ολοι", "οι", "ανθρωποι", "ειναι", "θνητοι", "ο", "σωκρατης", "ειναι", "ανθρωπος", "ο", "σωκρατης", "ειναι", "θνητος"],
        ["나는", "한국어를", "못해"],
        ["נון"],
        ["english", "used", "to", "have", "multiple", "versions", "", "", "letter", "s"],
        ["two", "households", "both", "alike", "", "dignity", "", "fair", "verona", "where", "we", "lay", "our", "scene", "from", "ancient", "grudge", "break", "to", "new", "mutiny", "where", "civil", "blood", "makes", "civil", "hands", "unclean", "from", "forth", "", "fatal", "loins", "", "these", "two", "foes", "", "pair", "", "star-cross", "d", "lovers", "take", "their", "life", "whose", "misadventur", "d", "piteous", "overthrows", "doth", "with", "their", "death", "bury", "their", "parents", "strife", "", "fearful", "passage", "", "their", "death-mark", "d", "love", "", "", "continuance", "", "their", "parents", "rage", "which", "but", "their", "children", "s", "end", "nought", "could", "remove", "is", "now", "", "two", "hours", "traffic", "", "our", "stage", "", "which", "if", "you", "with", "patient", "ears", "attend", "what", "here", "shall", "miss", "our", "toil", "shall", "strive", "to", "mend"],
        ["актер", "посетил", "многие", "достопримечательности", "москвы"],
        ["లద", "అద", "అరధలనదన"],
        ["การสะกดการนตไทยมความซบซอนมาก"],
        ["https", "www.example.com", "fake-path", "1932e32ab3efc0014228eadc28219da2", "hm"],
        ["א", "שפראך", "איז", "א", "דיאלעקט", "מיט", "אן", "ארמיי", "און", "פלאט"],
    ]
    static let expectedUniqueLimitReconstituted: [[String]] = [
        ["the", "angstrom", "unit", "a", "was"],
        ["according", "to", "the", "encyclopædia", "æthelred", "the"],
        ["hello", "there"],
        ["苹果园区"],
        ["蘋果園區"],
        ["text", "tokenization", "and", "normalization", "is"],
        ["who", "started", "the", "fire"],
        ["apres", "deux", "napoleons", "france", "a"],
        ["die", "nationalmannschaft", "hat", "die", "weltmeisterschaft", "gewonnen"],
        ["ολοι", "οι", "ανθρωποι", "ειναι", "θνητοι"],
        ["나는", "한국어를", "못해"],
        ["נון"],
        ["english", "used", "to", "have", "multiple"],
        ["two", "households", "both", "alike", "in"],
        ["актер", "посетил", "многие", "достопримечательности", "москвы"],
        ["లద", "అద", "అరధలనదన"],
        ["การสะกดการนตไทยมความซบซอนมาก"],
        ["https", "www.example.com", "fake-path", "1932e32ab3efc0014228eadc28219da2", "hm"],
        ["א", "שפראך", "איז", "א", "דיאלעקט", "מיט"],
    ]
}
#endif
