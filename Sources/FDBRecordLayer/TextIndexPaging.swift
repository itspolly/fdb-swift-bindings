/*
 * TextIndexPaging.swift
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
import SwiftProtobuf

/// One page of text-search results with an opaque continuation (`nil` when exhausted).
public struct TextSearchPage: Sendable {
    public let primaryKeys: [Tuple]
    public let continuation: FDB.Bytes?
}

/// One page of raw text-index postings.
public struct TextIndexEntryPage: Sendable {
    public let entries: [TextIndexEntry]
    public let continuation: FDB.Bytes?
}

/// Streams the postings of every BunchedMap in `[begin, end)` in key order — (map subspace,
/// map key) — starting strictly after `resumeAfter` (a full ordering key: map subspace bytes +
/// map key bytes). Bunches are read a batch at a time, only as far as the caller consumes, so a
/// page's reads are proportional to the page (Java's `BunchedMapMultiIterator` with a
/// continuation).
struct PostingStream {
    let transaction: any TransactionProtocol
    let space: Subspace
    let begin: FDB.Bytes
    let end: FDB.Bytes
    let groupCount: Int
    let primaryKeyCount: Int
    var resumeAfter: FDB.Bytes?

    private var buffer: [TextIndexEntry] = []
    private var nextBegin: FDB.KeySelector?
    private var exhausted = false
    private var started = false

    init(transaction: any TransactionProtocol, space: Subspace, begin: FDB.Bytes, end: FDB.Bytes,
         groupCount: Int, primaryKeyCount: Int, resumeAfter: FDB.Bytes?) {
        self.transaction = transaction
        self.space = space
        self.begin = begin
        self.end = end
        self.groupCount = groupCount
        self.primaryKeyCount = primaryKeyCount
        self.resumeAfter = resumeAfter
    }

    /// The ordering key of an entry: its map subspace followed by its map key.
    static func orderKey(_ entry: TextIndexEntry, space: Subspace) -> FDB.Bytes {
        space.prefix + Tuple(entry.group.elements + [entry.token]).encode() + entry.suffixBytes
    }

    mutating func next() async throws -> TextIndexEntry? {
        while buffer.isEmpty {
            if exhausted { return nil }
            try await fetch()
        }
        return buffer.removeFirst()
    }

    private mutating func fetch() async throws {
        if !started {
            started = true
            var start = FDB.KeySelector.firstGreaterOrEqual(begin)
            if let resumeAfter {
                // The bunch holding the resume key starts at or before it.
                if let bunchKey = try await transaction.getKey(selector: .lastLessOrEqual(resumeAfter), snapshot: false),
                   !bunchKey.lexicographicallyPrecedes(begin) {
                    start = .firstGreaterOrEqual(bunchKey)
                }
            }
            nextBegin = start
        }
        guard let selector = nextBegin else { exhausted = true; return }
        let result = try await transaction.getRangeNative(
            beginSelector: selector, endSelector: .firstGreaterOrEqual(end), limit: 8, snapshot: false, reverse: false)
        for (key, value) in result.records {
            let elements = try space.unpack(key)
            guard elements.count > groupCount, let token = elements[groupCount] as? String else {
                throw TextIndexError.corruptBunchedMap("index key too short")
            }
            let mapSubspace = space.prefix + Tuple(Array(elements.prefix(groupCount + 1))).encode()
            let firstKey = Array(key.dropFirst(mapSubspace.count))
            for entry in try TextIndexBunchedSerializer.deserializeEntries(firstKey: firstKey, value) {
                let suffix = try Tuple.decode(from: entry.key)
                let posting = TextIndexEntry(
                    group: Tuple(Array(elements.prefix(groupCount))), token: token, suffix: Tuple(suffix),
                    primaryKey: Tuple(Array(suffix.suffix(primaryKeyCount))), positions: entry.value,
                    suffixBytes: entry.key)
                if let resumeAfter, !resumeAfter.lexicographicallyPrecedes(mapSubspace + entry.key) { continue }
                buffer.append(posting)
            }
        }
        if let last = result.records.last?.0, result.more {
            nextBegin = .firstGreaterThan(last)
        } else {
            exhausted = true
        }
    }
}

extension FDBRecordStore {
    /// One page of ``textSearchPrimaryKeys(_:indexNamed:_:group:suffix:)``: at most `limit`
    /// distinct primary keys, resuming after `continuation` (pass `nil` for the first page).
    ///
    /// Single-token, single-prefix and multi-token (all / any / phrase / within) searches stream
    /// their postings in order and stop as soon as the page is full, so each page reads only
    /// what it returns plus at most one batch of bunches per token. Searches over several
    /// *prefixes* are unordered, as in Java: `containsAnyPrefix` pages through each prefix in
    /// turn, and `containsAllPrefixes` streams the first prefix while reading the others' full
    /// postings once per page. As with Java's distinct-by-primary-key plans, duplicates are
    /// removed within a page; for prefix searches a record can reappear on a later page.
    public func textSearchPrimaryKeys<M: SwiftProtobuf.Message>(
        _ type: M.Type, indexNamed name: String, _ comparison: TextComparison,
        group: Tuple = Tuple(), suffix: TextSuffixRange? = nil, limit: Int, continuation: FDB.Bytes?
    ) async throws -> TextSearchPage {
        precondition(limit > 0, "limit must be positive")
        let index = try scannableIndex(type, named: name)
        try checkTextIndex(index, group: group)
        let tokens = try textTokens(index, comparison, removeStopWords: true)
        if tokens.isEmpty { return TextSearchPage(primaryKeys: [], continuation: nil) }
        let kind = comparison.kind
        let isPrefix = kind == .containsPrefix || kind == .containsAllPrefixes || kind == .containsAnyPrefix
        if isPrefix && suffix != nil {
            throw TextIndexError.invalidQuery("text prefix comparison included inequality scan comparison")
        }
        let state = try TextContinuation(continuation)
        var results = PageCollector(limit: limit)

        if kind == .containsPrefix || (tokens.count == 1 && isPrefix) {
            guard tokens.count == 1 else {
                throw TextIndexError.invalidQuery("text prefix comparison included \(tokens.count) comparands instead of one")
            }
            var stream = prefixStream(index, tokens[0], group: group, resumeAfter: state.resumeKey)
            while let entry = try await stream.next() {
                if results.add(entry.primaryKey, resume: PostingStream.orderKey(entry, space: indexSubspace(index))) { break }
            }
            return results.page { TextContinuation(child: 0, resumeKey: $0).encode() }
        }

        if !isPrefix {
            // Ordered by the map key (trailing columns + primary key) across all tokens.
            var streams = tokens.map { token in
                tokenStream(index, token, group: group,
                            resumeAfter: state.resumeKey.map { tokenSubspace(index, token, group) + $0 })
            }
            let withStopWords = kind == .containsPhrase ? try textTokens(index, comparison, removeStopWords: false) : []
            var heads: [TextIndexEntry?] = []
            for i in streams.indices { heads.append(try await streams[i].nextIn(suffix)) }
            while true {
                let live = heads.compactMap { $0 }
                if live.isEmpty { break }
                switch kind {
                case .containsAny:
                    let smallest = live.min { $0.suffixBytes.lexicographicallyPrecedes($1.suffixBytes) }!
                    let key = smallest.suffixBytes
                    for i in heads.indices where heads[i]?.suffixBytes == key {
                        heads[i] = try await streams[i].nextIn(suffix)
                    }
                    if results.add(smallest.primaryKey, resume: key) { return results.page { TextContinuation(child: 0, resumeKey: $0).encode() } }
                default:
                    // Intersection: all streams must be live and agree.
                    guard live.count == heads.count else { return results.page { TextContinuation(child: 0, resumeKey: $0).encode() } }
                    let maxKey = live.map(\.suffixBytes).max { $0.lexicographicallyPrecedes($1) }!
                    if live.allSatisfy({ $0.suffixBytes == maxKey }) {
                        let matched: Bool
                        switch kind {
                        case .containsAllWithin(let distance): matched = Self.containAllWithin(live, distance)
                        case .containsPhrase: matched = Self.containPhrase(live, withStopWords)
                        default: matched = true
                        }
                        for i in heads.indices { heads[i] = try await streams[i].nextIn(suffix) }
                        if matched, results.add(live[0].primaryKey, resume: maxKey) {
                            return results.page { TextContinuation(child: 0, resumeKey: $0).encode() }
                        }
                    } else {
                        for i in heads.indices where heads[i]!.suffixBytes.lexicographicallyPrecedes(maxKey) {
                            heads[i] = try await streams[i].nextIn(suffix, atLeast: maxKey)
                        }
                    }
                }
            }
            return results.page { TextContinuation(child: 0, resumeKey: $0).encode() }
        }

        if kind == .containsAnyPrefix {
            // Unordered union: each prefix in turn.
            for child in state.child..<tokens.count {
                var stream = prefixStream(index, tokens[child], group: group,
                                          resumeAfter: child == state.child ? state.resumeKey : nil)
                while let entry = try await stream.next() {
                    if results.add(entry.primaryKey, resume: PostingStream.orderKey(entry, space: indexSubspace(index))) {
                        return results.page { TextContinuation(child: child, resumeKey: $0).encode() }
                    }
                }
            }
            return results.page { TextContinuation(child: tokens.count, resumeKey: $0).encode() }
        }

        // containsAllPrefixes: stream the first prefix; the others' postings are read whole.
        var others: [Set<FDB.Bytes>] = []
        for token in tokens.dropFirst() {
            var set = Set<FDB.Bytes>()
            var stream = prefixStream(index, token, group: group, resumeAfter: nil)
            while let entry = try await stream.next() { set.insert(entry.suffixBytes) }
            others.append(set)
        }
        var driver = prefixStream(index, tokens[0], group: group, resumeAfter: state.resumeKey)
        while let entry = try await driver.next() {
            guard others.allSatisfy({ $0.contains(entry.suffixBytes) }) else { continue }
            if results.add(entry.primaryKey, resume: PostingStream.orderKey(entry, space: indexSubspace(index))) { break }
        }
        return results.page { TextContinuation(child: 0, resumeKey: $0).encode() }
    }

    /// One page of ``textSearch(_:indexNamed:_:group:suffix:)``.
    public func textSearch<M: SwiftProtobuf.Message & Sendable>(
        _ type: M.Type, indexNamed name: String, _ comparison: TextComparison,
        group: Tuple = Tuple(), suffix: TextSuffixRange? = nil, limit: Int, continuation: FDB.Bytes?
    ) async throws -> QueryPage<M> {
        guard let recordType = metaData.recordType(for: M.self) else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }
        let page = try await textSearchPrimaryKeys(
            type, indexNamed: name, comparison, group: group, suffix: suffix, limit: limit, continuation: continuation)
        var records: [FDBStoredRecord<M>] = []
        for primaryKey in page.primaryKeys {
            if let record: FDBStoredRecord<M> = try await loadTyped(primaryKey, recordType: recordType, filter: nil) {
                records.append(record)
            }
        }
        return QueryPage(records: records, continuation: page.continuation)
    }

    /// One page of ``scanTextIndex(_:indexNamed:token:prefix:group:)``: at most `limit` postings.
    public func scanTextIndex<M: SwiftProtobuf.Message>(
        _ type: M.Type, indexNamed name: String, token: String, prefix: Bool = false, group: Tuple = Tuple(),
        limit: Int, continuation: FDB.Bytes?
    ) async throws -> TextIndexEntryPage {
        precondition(limit > 0, "limit must be positive")
        let index = try scannableIndex(type, named: name)
        try checkTextIndex(index, group: group)
        let state = try TextContinuation(continuation)
        var stream = prefix
            ? prefixStream(index, token, group: group, resumeAfter: state.resumeKey)
            : tokenStream(index, token, group: group, resumeAfter: state.resumeKey)
        var entries: [TextIndexEntry] = []
        while entries.count < limit, let entry = try await stream.next() { entries.append(entry) }
        let next = entries.count == limit
            ? entries.last.map { TextContinuation(child: 0, resumeKey: PostingStream.orderKey($0, space: indexSubspace(index))).encode() }
            : nil
        return TextIndexEntryPage(entries: entries, continuation: next)
    }

    // MARK: Streams

    private func tokenSubspace(_ index: ErasedIndex, _ token: String, _ group: Tuple) -> FDB.Bytes {
        indexSubspace(index).prefix + Tuple(group.elements + [token]).encode()
    }

    private func tokenStream(_ index: ErasedIndex, _ token: String, group: Tuple, resumeAfter: FDB.Bytes?) -> PostingStream {
        let map = tokenSubspace(index, token, group)
        return PostingStream(transaction: transaction, space: indexSubspace(index), begin: map + [0x00], end: map + [0xFF],
                             groupCount: group.count, primaryKeyCount: index.primaryKeyColumnCount, resumeAfter: resumeAfter)
    }

    private func prefixStream(_ index: ErasedIndex, _ prefix: String, group: Tuple, resumeAfter: FDB.Bytes?) -> PostingStream {
        let begin = indexSubspace(index).prefix + group.encode() + Array(Tuple(prefix).encode().dropLast())
        return PostingStream(transaction: transaction, space: indexSubspace(index), begin: begin,
                             end: TextSuffixRange.strinc(begin), groupCount: group.count,
                             primaryKeyCount: index.primaryKeyColumnCount, resumeAfter: resumeAfter)
    }
}

extension PostingStream {
    /// The next posting inside `suffix` (if given) whose map key is at least `atLeast`.
    mutating func nextIn(_ suffix: TextSuffixRange?, atLeast: FDB.Bytes? = nil) async throws -> TextIndexEntry? {
        while let entry = try await next() {
            if let atLeast, entry.suffixBytes.lexicographicallyPrecedes(atLeast) { continue }
            if let suffix, !suffix.contains(entry.suffixBytes) { continue }
            return entry
        }
        return nil
    }
}

/// Collects distinct primary keys up to a limit, remembering where to resume.
private struct PageCollector {
    let limit: Int
    var keys: [Tuple] = []
    var seen = Set<FDB.Bytes>()
    var lastResume: FDB.Bytes?

    init(limit: Int) { self.limit = limit }

    /// Adds a result; returns `true` once the page is full.
    mutating func add(_ primaryKey: Tuple, resume: FDB.Bytes) -> Bool {
        lastResume = resume
        if seen.insert(primaryKey.encode()).inserted { keys.append(primaryKey) }
        return keys.count >= limit
    }

    func page(_ encode: (FDB.Bytes) -> FDB.Bytes) -> TextSearchPage {
        TextSearchPage(primaryKeys: keys, continuation: keys.count >= limit ? lastResume.map(encode) : nil)
    }
}

/// Text-scan continuation: the child (token) being scanned and the ordering key to resume after.
private struct TextContinuation {
    var child = 0
    var resumeKey: FDB.Bytes?

    init(child: Int, resumeKey: FDB.Bytes?) {
        self.child = child
        self.resumeKey = resumeKey
    }

    init(_ bytes: FDB.Bytes?) throws {
        guard let bytes else { return }
        let elements = try Tuple.decode(from: bytes)
        guard elements.count == 2, let child = IndexMaintainer.integer(elements[0]), let key = elements[1] as? FDB.Bytes else {
            throw TextIndexError.invalidQuery("malformed text scan continuation")
        }
        self.child = Int(child)
        self.resumeKey = key
    }

    func encode() -> FDB.Bytes { Tuple(Int64(child), resumeKey ?? []).encode() }
}
#endif
