/*
 * RangeSet.swift
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

/// Errors thrown by ``RangeSet`` for invalid arguments or unreadable on-disk data.
///
/// These correspond to the `IllegalArgumentException`s thrown by the Java `RangeSet`.
enum RangeSetError: Error, Sendable, Equatable {
    /// A key was empty or not strictly less than ``RangeSet/finalKey`` (`\xff`).
    case keyOutOfRange(FDB.Bytes)
    /// `begin` sorts after `end`.
    case invertedRange(begin: FDB.Bytes, end: FDB.Bytes)
    /// A key in the range-set subspace was not a one-element tuple holding a byte string.
    case malformedEntry(FDB.Bytes)
}

/// A persistent set of disjoint byte-key ranges, a port of fdb-extensions'
/// `com.apple.foundationdb.async.RangeSet` with an identical on-disk format.
///
/// Each range `[begin, end)` in the set is stored as one key-value pair:
/// key = `subspace.pack(Tuple(begin))` (the begin bytes as a tuple byte-string element),
/// value = the raw `end` bytes. Valid keys lie in `[\x00, \xff)`; a `nil` begin/end means
/// ``firstKey``/``finalKey``. Adjacent ranges are not merged except in the single-writer
/// `requireEmpty` case (exactly as in Java), so the stored entries are byte-for-byte what the
/// Java implementation would write for the same sequence of operations.
///
/// Swift transactions have no separate "snapshot view" object, so the Java behaviour of
/// skipping a read conflict when given `tr.snapshot()` is expressed with a `snapshot:` flag on
/// the read-only operations.
struct RangeSet: Sendable {
    /// The subspace in which ranges are stored.
    let subspace: Subspace

    /// The smallest key accepted by the set (`\x00`); Java `RangeSet.FIRST_KEY`.
    static let firstKey: FDB.Bytes = [0x00]
    /// The exclusive upper bound of keys accepted by the set (`\xff`); Java `RangeSet.FINAL_KEY`.
    static let finalKey: FDB.Bytes = [0xFF]
    /// Value for `limit` meaning "no limit"; Java `RangeSet.UNLIMITED`.
    static let unlimited: Int = Int.max

    /// A range `[begin, end)` of byte keys (Java `com.apple.foundationdb.Range`).
    typealias Range = (begin: FDB.Bytes, end: FDB.Bytes)

    /// Creates a range set backed by `subspace`, which should be empty or hold another
    /// `RangeSet`'s data.
    init(subspace: Subspace) {
        self.subspace = subspace
    }

    // MARK: - FIRST_KEY / FINAL_KEY helpers

    static func isFirstKey(_ key: FDB.Bytes) -> Bool { key == firstKey }
    static func isFinalKey(_ key: FDB.Bytes) -> Bool { key == finalKey }
    static func nullIfFirst(_ key: FDB.Bytes) -> FDB.Bytes? { isFirstKey(key) ? nil : key }
    static func nullIfFinal(_ key: FDB.Bytes) -> FDB.Bytes? { isFinalKey(key) ? nil : key }

    // MARK: - Private helpers

    fileprivate static func compareUnsigned(_ lhs: FDB.Bytes, _ rhs: FDB.Bytes) -> Int {
        if lhs == rhs { return 0 }
        return lhs.lexicographicallyPrecedes(rhs) ? -1 : 1
    }

    private static func checkKey(_ key: FDB.Bytes) throws {
        if key.isEmpty || compareUnsigned(key, finalKey) >= 0 {
            throw RangeSetError.keyOutOfRange(key)
        }
    }

    private static func checkRange(_ begin: FDB.Bytes, _ end: FDB.Bytes) throws {
        if compareUnsigned(begin, end) > 0 {
            throw RangeSetError.invertedRange(begin: begin, end: end)
        }
    }

    /// The first key strictly after `key` (`key + \x00`).
    fileprivate static func keyAfter(_ key: FDB.Bytes) -> FDB.Bytes {
        key + [0x00]
    }

    /// `subspace.pack(Tuple.from(bytes))`.
    fileprivate func pack(_ bytes: FDB.Bytes) -> FDB.Bytes {
        subspace.pack(bytes)
    }

    /// `subspace.unpack(key).getBytes(0)`.
    fileprivate func unpackBegin(_ key: FDB.Bytes) throws -> FDB.Bytes {
        guard let first = try subspace.unpack(key).first as? FDB.Bytes else {
            throw RangeSetError.malformedEntry(key)
        }
        return first
    }

    /// Reads the last entry at or before packed key `frobnicatedBegin` (snapshot, reverse, limit 1).
    fileprivate func entryAtOrBefore(
        _ tx: any TransactionProtocol, _ frobnicatedBegin: FDB.Bytes
    ) async throws -> (key: FDB.Bytes, value: FDB.Bytes)? {
        let result = try await tx.getRangeNative(
            beginSelector: .firstGreaterOrEqual(subspace.range.begin),
            endSelector: .firstGreaterOrEqual(Self.keyAfter(frobnicatedBegin)),
            limit: 1, snapshot: true, reverse: true
        )
        return result.records.first.map { (key: $0.0, value: $0.1) }
    }

    private static func addReadConflictKey(_ tx: any TransactionProtocol, _ key: FDB.Bytes) throws {
        try tx.addConflictRange(beginKey: key, endKey: keyAfter(key), type: .read)
    }

    // MARK: - contains

    /// Whether `key` lies in some range of the set.
    ///
    /// Adds a read conflict on only the packed key itself (unless `snapshot`), even though it does
    /// a (snapshot) range read, so that only changes affecting whether this key is contained
    /// conflict. Use ``addReadConflictKey(_:key:)`` to add that conflict later.
    func contains(_ tx: any TransactionProtocol, key: FDB.Bytes, snapshot: Bool = false) async throws -> Bool {
        try Self.checkKey(key)
        let frobnicated = pack(key)
        if !snapshot {
            try Self.addReadConflictKey(tx, frobnicated)
        }
        guard let entry = try await entryAtOrBefore(tx, frobnicated) else {
            return false
        }
        return Self.compareUnsigned(key, entry.value) < 0
    }

    /// Adds the read conflict that a non-snapshot ``contains(_:key:snapshot:)`` adds for `key`.
    func addReadConflictKey(_ tx: any TransactionProtocol, key: FDB.Bytes) throws {
        try Self.checkKey(key)
        try Self.addReadConflictKey(tx, pack(key))
    }

    // MARK: - insertRange

    /// Inserts `[begin, end)` into the set (`nil` = ``firstKey`` / ``finalKey``).
    ///
    /// With `requireEmpty`, writes only if no part of the range is already present; otherwise
    /// fills in all gaps. Returns `true` iff anything was written.
    ///
    /// Conflicts (as Java): a read-conflict range on `[pack(begin), pack(end))`; all reads are
    /// snapshot. A write-conflict range is added for each gap filled (for `requireEmpty`, the
    /// whole range), plus a read-conflict key on a preceding entry that gets extended.
    @discardableResult
    func insertRange(
        _ tx: any TransactionProtocol, begin: FDB.Bytes?, end: FDB.Bytes?, requireEmpty: Bool = false
    ) async throws -> Bool {
        let beginNonNull = begin ?? Self.firstKey
        let endNonNull = end ?? Self.finalKey
        try Self.checkKey(beginNonNull)
        try Self.checkRange(beginNonNull, endNonNull)

        if Self.compareUnsigned(beginNonNull, endNonNull) == 0 {
            return false
        }

        let frobnicatedBegin = pack(beginNonNull)
        let frobnicatedEnd = pack(endNonNull)
        try tx.addConflictRange(beginKey: frobnicatedBegin, endKey: frobnicatedEnd, type: .read)

        let keyAfterBegin = Self.keyAfter(frobnicatedBegin)
        let before = try await entryAtOrBefore(tx, frobnicatedBegin)

        var lastSeen = frobnicatedBegin
        if let before, Self.compareUnsigned(beginNonNull, before.value) < 0 {
            if requireEmpty {
                return false
            }
            lastSeen = pack(before.value)
        }

        if requireEmpty {
            // Only add in the empty case, so nothing may start inside (begin, end).
            let after = try await tx.getRangeNative(
                beginKey: keyAfterBegin, endKey: frobnicatedEnd, limit: 1, snapshot: true
            )
            if !after.records.isEmpty {
                return false
            }
            if let before, Self.compareUnsigned(beginNonNull, before.value) == 0 {
                // Consolidate with the abutting preceding range (single forward writer case).
                try Self.addReadConflictKey(tx, before.key)
                tx.setValue(endNonNull, for: before.key)
            } else {
                tx.setValue(endNonNull, for: frobnicatedBegin)
            }
            try tx.addConflictRange(beginKey: frobnicatedBegin, endKey: frobnicatedEnd, type: .write)
            return true
        }

        // Fill in the gaps between existing ranges.
        var changed = false
        if Self.compareUnsigned(keyAfterBegin, frobnicatedEnd) < 0 {
            for try await (key, value) in tx.getRange(
                beginKey: keyAfterBegin, endKey: frobnicatedEnd, snapshot: true
            ) {
                if Self.compareUnsigned(lastSeen, key) < 0 {
                    tx.setValue(try unpackBegin(key), for: lastSeen)
                    try tx.addConflictRange(beginKey: lastSeen, endKey: key, type: .write)
                    changed = true
                }
                lastSeen = pack(value)
            }
        }
        // The last gap, from lastSeen to the end.
        if Self.compareUnsigned(lastSeen, frobnicatedEnd) < 0 {
            tx.setValue(endNonNull, for: lastSeen)
            try tx.addConflictRange(beginKey: lastSeen, endKey: frobnicatedEnd, type: .write)
            changed = true
        }
        return changed
    }

    /// Inserts `range`; see ``insertRange(_:begin:end:requireEmpty:)``.
    @discardableResult
    func insertRange(_ tx: any TransactionProtocol, _ range: Range, requireEmpty: Bool = false) async throws -> Bool {
        try await insertRange(tx, begin: range.begin, end: range.end, requireEmpty: requireEmpty)
    }

    // MARK: - missingRanges

    /// Streams the gaps in the set within `[begin, end)` (`nil` = ``firstKey`` / ``finalKey``),
    /// in key order, stopping after `limit` results. Java `missingRanges(ReadTransaction, ...)`
    /// returning an `AsyncIterable`.
    ///
    /// Adds a read-conflict range on `[pack(begin), pack(end))` unless `snapshot`; the reads
    /// themselves are snapshot reads.
    func missingRangeSequence(
        _ tx: any TransactionProtocol, begin: FDB.Bytes? = nil, end: FDB.Bytes? = nil,
        limit: Int = RangeSet.unlimited, snapshot: Bool = false
    ) throws -> MissingRangeSequence {
        let beginNonNull = begin ?? Self.firstKey
        let endNonNull = end ?? Self.finalKey
        try Self.checkKey(beginNonNull)
        try Self.checkRange(beginNonNull, endNonNull)
        if !snapshot {
            try tx.addConflictRange(beginKey: pack(beginNonNull), endKey: pack(endNonNull), type: .read)
        }
        return MissingRangeSequence(
            rangeSet: self, transaction: tx, begin: beginNonNull, end: endNonNull, limit: limit)
    }

    /// The gaps in the set within `[begin, end)`, as a list; see
    /// ``missingRangeSequence(_:begin:end:limit:snapshot:)``.
    func missingRanges(
        _ tx: any TransactionProtocol, begin: FDB.Bytes? = nil, end: FDB.Bytes? = nil,
        limit: Int = RangeSet.unlimited, snapshot: Bool = false
    ) async throws -> [Range] {
        var result: [Range] = []
        for try await range in try missingRangeSequence(tx, begin: begin, end: end, limit: limit, snapshot: snapshot) {
            result.append(range)
        }
        return result
    }

    /// The gaps in the set within `superRange`.
    func missingRanges(
        _ tx: any TransactionProtocol, _ superRange: Range, limit: Int = RangeSet.unlimited,
        snapshot: Bool = false
    ) async throws -> [Range] {
        try await missingRanges(tx, begin: superRange.begin, end: superRange.end, limit: limit, snapshot: snapshot)
    }

    // MARK: - isEmpty / clear / rep

    /// Whether no ranges have been inserted (the only gap is the complete `[\x00, \xff)`).
    func isEmpty(_ tx: any TransactionProtocol, snapshot: Bool = false) async throws -> Bool {
        let first = try await missingRanges(tx, begin: nil, end: nil, limit: 1, snapshot: snapshot).first
        guard let first else { return false }
        return first.begin == Self.firstKey && first.end == Self.finalKey
    }

    /// Removes every range from the set (clears the subspace's range).
    func clear(_ tx: any TransactionProtocol) {
        let range = subspace.range
        tx.clearRange(beginKey: range.begin, endKey: range.end)
    }

    /// A debugging dump of the stored ranges, one `begin -> end` per line
    /// (`ByteArrayUtil.printable` formatting), as Java `rep`.
    func rep(_ tx: any TransactionProtocol) async throws -> String {
        var out = ""
        let range = subspace.range
        for try await (key, value) in tx.getRange(beginKey: range.begin, endKey: range.end) {
            out += Self.printable(try unpackBegin(key)) + " -> " + Self.printable(value) + "\n"
        }
        return out
    }

    /// Java `ByteArrayUtil.printable`.
    static func printable(_ bytes: FDB.Bytes) -> String {
        var s = ""
        for b in bytes {
            if b >= 32 && b < 127 && b != UInt8(ascii: "\\") {
                s.unicodeScalars.append(Unicode.Scalar(b))
            } else if b == UInt8(ascii: "\\") {
                s += "\\\\"
            } else {
                s += "\\x" + (b < 16 ? "0" : "") + String(b, radix: 16)
            }
        }
        return s
    }
}

// MARK: - MissingRangeSequence

extension RangeSet {
    /// The lazily computed gaps of a ``RangeSet`` (Java `RangeSet.MissingRangeIterator`).
    struct MissingRangeSequence: AsyncSequence {
        typealias Element = RangeSet.Range

        let rangeSet: RangeSet
        let transaction: any TransactionProtocol
        let begin: FDB.Bytes
        let end: FDB.Bytes
        let limit: Int

        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(sequence: self)
        }

        struct AsyncIterator: AsyncIteratorProtocol {
            private let sequence: MissingRangeSequence
            private var started = false
            private var done = false
            private var currBegin: FDB.Bytes
            private var numFound = 0
            private var after: FDB.AsyncKVSequence.AsyncIterator?

            init(sequence: MissingRangeSequence) {
                self.sequence = sequence
                self.currBegin = sequence.begin
            }

            mutating func next() async throws -> Element? {
                if done { return nil }
                let rs = sequence.rangeSet
                let tx = sequence.transaction

                if !started {
                    started = true
                    let frobnicatedBegin = rs.pack(sequence.begin)
                    let frobnicatedEnd = rs.pack(sequence.end)
                    if let before = try await rs.entryAtOrBefore(tx, frobnicatedBegin),
                       RangeSet.compareUnsigned(sequence.begin, before.value) < 0 {
                        currBegin = before.value
                    }
                    let keyAfterBegin = RangeSet.keyAfter(frobnicatedBegin)
                    if RangeSet.compareUnsigned(keyAfterBegin, frobnicatedEnd) < 0 {
                        after = tx.getRange(beginKey: keyAfterBegin, endKey: frobnicatedEnd, snapshot: true)
                            .makeAsyncIterator()
                    }
                }

                while let kv = try await after?.next() {
                    let nextBeg = try rs.unpackBegin(kv.0)
                    let currBeg = currBegin
                    currBegin = kv.1
                    if RangeSet.compareUnsigned(currBeg, nextBeg) < 0 {
                        numFound += 1
                        if !(sequence.limit == RangeSet.unlimited || numFound < sequence.limit) {
                            done = true
                        }
                        return (begin: currBeg, end: nextBeg)
                    }
                }
                after = nil

                if RangeSet.compareUnsigned(currBegin, sequence.end) < 0 {
                    let tail = (begin: currBegin, end: sequence.end)
                    currBegin = sequence.end
                    return tail
                }
                done = true
                return nil
            }
        }
    }
}
#endif
