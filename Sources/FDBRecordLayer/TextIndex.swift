/*
 * TextIndex.swift
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

// The Java Record Layer's full-text (`text`) index, byte-for-byte compatible with its on-disk
// format:
//
// - Index data: for every token, a BunchedMap (Java's `com.apple.foundationdb.map.BunchedMap`,
//   bunch size 20) in the subspace `index / (<grouping columns...>, token)`, mapping the
//   record's "grouped key" — the index columns after the text column, then the primary key — to
//   the token's positions within the text. A DB key is the map subspace plus the packed first
//   map key of its bunch; its value is Java's `TextIndexBunchedSerializer` encoding of the bunch.
// - Secondary data: `secondary / (0, <primary key...>)` → `Tuple(tokenizerVersion)`, the
//   tokenizer version each record was indexed with (so it can be un-indexed with the same one).
//
// Tokenizing follows Java's `DefaultTextTokenizer`: JDK word segmentation (emulated by
// `JavaWordBreakIterator` below), NFKD normalization, `toLowerCase(Locale.ROOT)` and removal of
// combining marks. See `DefaultTextTokenizer` for the (small) known divergences.

#if RecordLayer
import Foundation
import FoundationDB
import SwiftProtobuf
import Synchronization

// MARK: - Errors

/// Errors raised by text indexes, tokenizers and text queries.
public enum TextIndexError: Error, Sendable, Equatable {
    /// No tokenizer is registered under the index's `textTokenizerName` (Java's "unrecognized text tokenizer").
    case unknownTokenizer(String)
    /// A different tokenizer is already registered under this name.
    case duplicateTokenizer(String)
    /// The tokenizer version is outside the tokenizer's supported range (Java's "unknown tokenizer version").
    case unknownTokenizerVersion(tokenizer: String, version: Int, min: Int, max: Int)
    /// The `textTokenizerVersion` option is not an integer.
    case unparseableTokenizerVersion(String)
    /// The index's text column produced something other than a string (or null).
    case textColumnNotString(index: String)
    /// A BunchedMap value or key could not be (de)serialized (Java's `BunchedSerializationException`).
    case serialization(String)
    /// The BunchedMap's on-disk structure is inconsistent (Java's `BunchedMapException`).
    case corruptBunchedMap(String)
    /// The text query cannot be answered as given.
    case invalidQuery(String)
}

// MARK: - Tokenizers

/// Whether a text is being tokenized for indexing or for querying (Java's `TextTokenizer.TokenizerMode`).
public enum TextTokenizerMode: Sendable {
    case index
    case query
}

/// Splits text into tokens for a text index — Java's `TextTokenizer`.
///
/// A tokenizer is identified by ``name`` (the index option ``IndexOptions/textTokenizerName``)
/// and is versioned: records remember the version they were indexed with, so a tokenizer that
/// changes behavior must bump ``maxVersion`` and keep the old behavior for old versions.
public protocol TextTokenizer: Sendable {
    /// The name the tokenizer is registered under.
    var name: String { get }
    /// The oldest supported version (defaults to ``TextTokenizers/globalMinVersion``).
    var minVersion: Int { get }
    /// The newest supported version.
    var maxVersion: Int { get }
    /// The tokens of `text`, in order. An empty string is a "stop word": it occupies a position
    /// but is not indexed.
    func tokenize(_ text: String, version: Int, mode: TextTokenizerMode) throws -> [String]
    /// Each token mapped to the (ascending) positions it occurs at — Java's `tokenizeToMap`.
    func tokenizeToMap(_ text: String, version: Int, mode: TextTokenizerMode) throws -> [String: [Int]]
}

/// Constants shared by tokenizers.
public enum TextTokenizers {
    /// Java's `TextTokenizer.GLOBAL_MIN_VERSION`.
    public static let globalMinVersion = 0
}

extension TextTokenizer {
    public var minVersion: Int { TextTokenizers.globalMinVersion }

    public func tokenizeToMap(_ text: String, version: Int, mode: TextTokenizerMode) throws -> [String: [Int]] {
        var map: [String: [Int]] = [:]
        for (offset, token) in try tokenize(text, version: version, mode: mode).enumerated() where !token.isEmpty {
            map[token, default: []].append(offset)
        }
        return map
    }

    /// Java's `validateVersion`.
    public func validateVersion(_ version: Int) throws {
        if version < minVersion || version > maxVersion {
            throw TextIndexError.unknownTokenizerVersion(tokenizer: name, version: version, min: minVersion, max: maxVersion)
        }
    }
}

/// The registry of tokenizers available to text indexes — Java's `TextTokenizerRegistryImpl`.
///
/// It starts with the tokenizers Java ships or registers for its test suite: `default`
/// (``DefaultTextTokenizer``), `prefix`, `all_suffixes` and `unique_token_limiting`.
public final class TextTokenizerRegistry: Sendable {
    public static let shared = TextTokenizerRegistry()

    private let tokenizers: Mutex<[String: any TextTokenizer]>

    private static func builtIns() -> [String: any TextTokenizer] {
        let all: [any TextTokenizer] = [
            DefaultTextTokenizer(), PrefixTextTokenizer(), AllSuffixesTextTokenizer(), UniqueTokenLimitTextTokenizer(),
        ]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
    }

    public init() { tokenizers = Mutex(Self.builtIns()) }

    /// Registers a tokenizer. Registering another tokenizer of the same type under the same
    /// name is a no-op; a different type under an existing name throws (Java's behavior).
    public func register(_ tokenizer: any TextTokenizer) throws {
        try tokenizers.withLock { map in
            if let existing = map[tokenizer.name] {
                if type(of: existing) != type(of: tokenizer) { throw TextIndexError.duplicateTokenizer(tokenizer.name) }
                return
            }
            map[tokenizer.name] = tokenizer
        }
    }

    /// The tokenizer for an index option value; `nil` means the default tokenizer.
    public func tokenizer(named name: String?) throws -> any TextTokenizer {
        guard let name else { return DefaultTextTokenizer() }
        guard let tokenizer = tokenizers.withLock({ $0[name] }) else { throw TextIndexError.unknownTokenizer(name) }
        return tokenizer
    }

    /// The registered tokenizer names.
    public var names: [String] { tokenizers.withLock { $0.keys.sorted() } }

    /// Restores the built-in tokenizers, dropping any others (Java's `reset`).
    public func reset() { tokenizers.withLock { $0 = Self.builtIns() } }
}

/// Java's `DefaultTextTokenizer` (name `default`, version 0).
///
/// The text is split into words exactly where the JDK's `BreakIterator.getWordInstance(Locale.ROOT)`
/// splits it (see ``JavaWordBreakIterator``); segments without a letter or digit (spaces,
/// punctuation, symbols, emoji) are skipped and do not take up a position. Each word is NFKD
/// normalized, lower-cased as `String.toLowerCase(Locale.ROOT)` does (including the Greek final
/// sigma rule), and stripped of combining marks (`\p{M}`): `"Après"` → `"apres"`,
/// `"ﬆ"` → `"st"`, `"ΟΔΟΣ"` → `"οδος"` with a final `ς`.
///
/// The JDK's word-break rules are emulated (not executed from its compiled rule table); the
/// emulation, including the final-sigma quirk of `BreakIterator.isBoundary` around supplementary
/// characters, was checked token-for-token against JDK 25 on ~800,000 randomized strings (every
/// script, digits, punctuation, currency signs, combining marks, format characters, whitespace,
/// emoji and random code points) with no differences except those below.
///
/// Divergences from Java, all at the level of Unicode data rather than the algorithm: character
/// properties, case mappings and NFKD come from the Swift runtime / Foundation rather than the
/// JDK, so characters whose data differs between the two Unicode versions (e.g. letters new in
/// Unicode 17, which JDK 25 treats as unassigned, or the Unicode 16 Todhri decompositions
/// Foundation's NFKD lacks) may tokenize differently.
public struct DefaultTextTokenizer: TextTokenizer {
    public static let tokenizerName = "default"

    public init() {}

    public var name: String { Self.tokenizerName }
    public var maxVersion: Int { minVersion }

    public func tokenize(_ text: String, version: Int, mode: TextTokenizerMode) throws -> [String] {
        try validateVersion(version)
        return Self.tokens(text)
    }

    /// The default tokenization (independent of version and mode).
    static func tokens(_ text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        var result: [String] = []
        for range in JavaWordBreakIterator.segments(scalars) {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[range])
            let normalized = String(view).decomposedStringWithCompatibilityMapping
            // Java tests `Character.isLetterOrDigit` on each UTF-16 unit, so supplementary
            // letters alone (surrogate halves) do not make a token.
            guard normalized.utf16.contains(where: JavaCharacter.isLetterOrDigit) else { continue }
            let lowered = JavaCharacter.toLowerCaseRoot(Array(normalized.unicodeScalars))
            var stripped = String.UnicodeScalarView()
            stripped.append(contentsOf: lowered.lazy.filter { !JavaCharacter.isMark($0) })
            result.append(String(stripped))
        }
        return result
    }
}

/// Java's test `PrefixTextTokenizer` (name `prefix`, versions 0–1): the default tokens truncated
/// to 3 (version 0) or 4 (version 1) UTF-16 code units.
public struct PrefixTextTokenizer: TextTokenizer {
    public static let tokenizerName = "prefix"

    public init() {}

    public var name: String { Self.tokenizerName }
    public var maxVersion: Int { 1 }

    public func tokenize(_ text: String, version: Int, mode: TextTokenizerMode) throws -> [String] {
        try validateVersion(version)
        let size = version == 0 ? 3 : 4
        return DefaultTextTokenizer.tokens(text).map { JavaCharacter.utf16Prefix($0, size) }
    }
}

/// Java's test-fixture `AllSuffixesTextTokenizer` (name `all_suffixes`): when indexing, every
/// suffix of every default token (by UTF-16 code unit), each taking a position; when querying,
/// the default tokens.
public struct AllSuffixesTextTokenizer: TextTokenizer {
    public static let tokenizerName = "all_suffixes"

    public init() {}

    public var name: String { Self.tokenizerName }
    public var maxVersion: Int { DefaultTextTokenizer().maxVersion }

    public func tokenize(_ text: String, version: Int, mode: TextTokenizerMode) throws -> [String] {
        let tokens = try DefaultTextTokenizer().tokenize(text, version: version, mode: mode)
        guard mode == .index else { return tokens }
        return tokens.flatMap { token -> [String] in
            let units = Array(token.utf16)
            return (0..<units.count).map { String(decoding: units[$0...], as: UTF16.self) }
        }
    }
}

/// Java's test `UniqueTokenLimitTextTokenizer` (name `unique_token_limiting`, version 0): the
/// default tokens, but the map stops at the 5th distinct token.
public struct UniqueTokenLimitTextTokenizer: TextTokenizer {
    public static let tokenizerName = "unique_token_limiting"
    static let maxUniqueTokens = 5

    public init() {}

    public var name: String { Self.tokenizerName }
    public var maxVersion: Int { 0 }

    public func tokenize(_ text: String, version: Int, mode: TextTokenizerMode) throws -> [String] {
        try DefaultTextTokenizer().tokenize(text, version: TextTokenizers.globalMinVersion, mode: mode)
    }

    public func tokenizeToMap(_ text: String, version: Int, mode: TextTokenizerMode) throws -> [String: [Int]] {
        var map: [String: [Int]] = [:]
        for (offset, token) in try tokenize(text, version: version, mode: mode).enumerated() where !token.isEmpty {
            if map[token] != nil {
                map[token]!.append(offset)
            } else if map.count == Self.maxUniqueTokens {
                return map
            } else {
                map[token] = [offset]
            }
        }
        return map
    }
}

/// Java's test `FilteringTextTokenizer`: another tokenizer's tokens, with those failing
/// `filter(token, version)` replaced by stop words (empty strings).
public struct FilteringTextTokenizer: TextTokenizer {
    public let name: String
    public let underlying: any TextTokenizer
    public let filter: @Sendable (String, Int) -> Bool

    public init(name: String, underlying: any TextTokenizer, filter: @escaping @Sendable (String, Int) -> Bool) {
        self.name = name
        self.underlying = underlying
        self.filter = filter
    }

    public var minVersion: Int { underlying.minVersion }
    public var maxVersion: Int { underlying.maxVersion }

    public func tokenize(_ text: String, version: Int, mode: TextTokenizerMode) throws -> [String] {
        try underlying.tokenize(text, version: version, mode: mode).map { filter($0, version) ? $0 : "" }
    }
}

// MARK: - Java character semantics

/// The `java.lang.Character` / `String` behaviors the default tokenizer depends on.
enum JavaCharacter {
    /// `Character.isLetterOrDigit(char)`: categories Lu, Ll, Lt, Lm, Lo and Nd. A surrogate code
    /// unit is neither.
    static func isLetterOrDigit(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber:
            return true
        default:
            return false
        }
    }

    /// Java regex `\p{M}`: Mn, Mc and Me.
    static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// `ConditionalSpecialCasing.isCased`.
    static func isCased(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter: return true
        default: break
        }
        switch scalar.value {
        case 0x02B0...0x02B8, 0x02C0...0x02C1, 0x02E0...0x02E4, 0x0345, 0x037A,
             0x1D2C...0x1D61, 0x2160...0x217F, 0x24B6...0x24E9:
            return true
        default:
            return false
        }
    }

    /// `String.toLowerCase(Locale.ROOT)`: per-code-point lower-casing, except that a capital
    /// sigma is final (`ς`) when a cased letter precedes it within its word and none follows.
    /// (Swift's full lower-case mapping equals Java's simple mapping plus Java's unconditional
    /// special case, `İ` → `i̇`.)
    static func toLowerCaseRoot(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var boundaries: Set<Int>?
        var result: [Unicode.Scalar] = []
        result.reserveCapacity(scalars.count)
        for (index, scalar) in scalars.enumerated() {
            if scalar.value == 0x03A3 {
                if boundaries == nil {
                    var set: Set<Int> = [0, scalars.count]
                    for range in JavaWordBreakIterator.segments(scalars) { set.insert(range.upperBound) }
                    // The JDK's `isBoundary` also reports a boundary after every supplementary
                    // character that isn't at the start of the text.
                    for k in scalars.indices.dropFirst() where scalars[k].value > 0xFFFF { set.insert(k + 1) }
                    boundaries = set
                }
                result.append(isFinalCased(scalars, index, boundaries!) ? "\u{03C2}" : "\u{03C3}")
            } else {
                result.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
            }
        }
        return result
    }

    /// `ConditionalSpecialCasing.isFinalCased`.
    private static func isFinalCased(_ scalars: [Unicode.Scalar], _ index: Int, _ boundaries: Set<Int>) -> Bool {
        var i = index
        while i >= 0 && !boundaries.contains(i) {
            if isCased(scalars[i - 1]) {
                var j = index + 1
                while j < scalars.count && !boundaries.contains(j) {
                    if isCased(scalars[j]) { return false }
                    j += 1
                }
                return true
            }
            i -= 1
        }
        return false
    }

    /// `String.substring(0, n)` (UTF-16 code units).
    static func utf16Prefix(_ string: String, _ count: Int) -> String {
        let units = string.utf16
        guard units.count > count else { return string }
        return String(decoding: Array(units.prefix(count)), as: UTF16.self)
    }
}

/// An emulation of the JDK's `BreakIterator.getWordInstance(Locale.ROOT)` (the JRE's rule-based
/// word iterator, not ICU's UAX #29 one), which decides Java's token boundaries.
///
/// Its rules, roughly: a word is letters optionally joined by single "mid-word" punctuation
/// (dashes, connector punctuation, `'`, `"`, `.`, U+00AD, U+2027) and may end in a danda; a
/// number is digits joined by single "mid-number" punctuation (`'`, `"`, `,`, `.`, U+066B);
/// words and numbers may alternate (`a1b2`), a number may be preceded by `.`, `#` or a currency
/// sign and followed by `%`, `&`, `¢`, `‰`…; runs of kanji, of katakana and of hiragana are each
/// one segment; spaces stay with an optional following CR/line separator; everything else is a
/// one-character segment. Format characters (Cf) are transparent, and combining marks continue
/// a word, number, space run or single character but end a kana/kanji run or punctuation.
enum JavaWordBreakIterator {
    enum Kind {
        case ignore, mark, letter, digit, kanji, kata, hira, kataHira, space, cr, lineSeparator, danda, other
    }

    struct Info {
        var kind: Kind
        var midWord = false
        var midNum = false
        var preNum = false
        var postNum = false
        /// U+3099/U+309A: a kana-run member that otherwise behaves as a combining mark.
        var kanaMark = false
        /// Whether a lone character of this kind keeps the combining marks that follow it.
        var absorbsMarks = true
    }

    /// Format characters the JDK does not treat as transparent.
    private static let opaqueFormatCharacters: Set<UInt32> = [
        0x00AD, 0x110BD, 0x110CD, 0x1343F, 0x1BCA3, 0x1D17A, 0xE0001, 0xE007F,
    ]

    /// Unassigned code points at the ends of CJK ideograph blocks that the JDK segments as letters.
    private static let unassignedLetterRanges: [ClosedRange<UInt32>] = [
        0x2A6E0...0x2A6FF, 0x2B73A...0x2B73F, 0x2B81E...0x2B81F, 0x2CEA2...0x2CEAF, 0x2EBE1...0x2EBEF,
        0x2FA1E...0x2FFFF, 0x3134B...0x3134F,
    ]

    static func info(_ scalar: Unicode.Scalar) -> Info {
        let v = scalar.value
        let category = scalar.properties.generalCategory
        if v == 0x0964 || v == 0x0965 { return Info(kind: .danda) }
        if v == 0x3005 || (0x4E00...0x9FA5).contains(v) || (0xF900...0xFA2D).contains(v) { return Info(kind: .kanji) }
        let isKata = (0x3099...0x309C).contains(v) || (0x30A1...0x30FE).contains(v)
        let isHira = (0x3041...0x3094).contains(v) || (0x3099...0x309E).contains(v) || v == 0x30FB || v == 0x30FC
        if isKata || isHira {
            var info = Info(kind: isKata && isHira ? .kataHira : (isKata ? .kata : .hira))
            info.kanaMark = v == 0x3099 || v == 0x309A
            return info
        }
        switch v {
        case 0x0D: return Info(kind: .cr)
        case 0x0A, 0x0C, 0x2028, 0x2029: return Info(kind: .lineSeparator)
        case 0x09: return Info(kind: .space)
        default: break
        }
        switch category {
        case .spaceSeparator: return Info(kind: .space)
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .spacingMark:
            return Info(kind: .letter)
        case .decimalNumber, .letterNumber, .otherNumber:
            return Info(kind: .digit)
        case .unassigned where unassignedLetterRanges.contains { $0.contains(v) }:
            return Info(kind: .letter)
        case .format where !opaqueFormatCharacters.contains(v):
            return Info(kind: .ignore)
        case .nonspacingMark, .enclosingMark:
            return Info(kind: .mark)
        default:
            break
        }
        var info = Info(kind: .other)
        info.absorbsMarks = !(category == .control || category == .format || v == 0xFFFF)
        info.midWord = category == .dashPunctuation || category == .connectorPunctuation
            || v == 0x00AD || v == 0x2027 || v == 0x22 || v == 0x27 || v == 0x2E
        info.midNum = v == 0x22 || v == 0x27 || v == 0x2C || v == 0x066B || v == 0x2E
        info.preNum = (category == .currencySymbol && v != 0x00A2) || v == 0x23 || v == 0x2E
        info.postNum = v == 0x25 || v == 0x26 || v == 0x00A2 || v == 0x066A || v == 0x2030 || v == 0x2031
        return info
    }

    private enum State {
        case start, word, wordMid, wordDanda, number, numberMid, numberPost, pre, preMark
        case space, cr, lineSeparator, any, opaque, markStart, runMark
        // A lone kanji / kana keeps following combining marks; a run of two or more does not.
        case kanji1, kanjiRun, kata1, kataRun, hira1, hiraRun, kataHira1, kataHiraRun, kanaMarkStart

        var accepting: Bool { self != .start && self != .wordMid && self != .numberMid }
    }

    private static func transition(_ state: State, _ info: Info) -> State? {
        let markLike = info.kind == .mark || info.kanaMark
        switch state {
        case .start:
            switch info.kind {
            case .mark: return .markStart
            case .letter: return .word
            case .digit: return .number
            case .kanji: return .kanji1
            case .kata: return .kata1
            case .hira: return .hira1
            case .kataHira: return info.kanaMark ? .kanaMarkStart : .kataHira1
            case .space: return .space
            case .cr: return .cr
            case .lineSeparator: return .lineSeparator
            case .danda, .other, .ignore: return info.preNum ? .pre : (info.absorbsMarks ? .any : .opaque)
            }
        case .word:
            if info.kind == .letter || markLike { return .word }
            if info.kind == .digit { return .number }
            if info.kind == .danda { return .wordDanda }
            return info.midWord ? .wordMid : nil
        case .wordMid:
            return info.kind == .letter ? .word : nil
        case .wordDanda:
            return info.kind == .digit ? .number : nil
        case .number:
            if info.kind == .digit || markLike { return .number }
            if info.kind == .letter { return .word }
            if info.midNum { return .numberMid }
            return info.postNum ? .numberPost : nil
        case .numberMid:
            return info.kind == .digit ? .number : nil
        case .pre:
            if info.kind == .digit { return .number }
            return markLike ? .preMark : nil
        case .preMark, .any, .runMark:
            return markLike ? state : nil
        case .space:
            switch info.kind {
            case .space: return .space
            case .cr: return .cr
            case .lineSeparator: return .lineSeparator
            default: return markLike ? .space : nil
            }
        case .cr:
            return info.kind == .lineSeparator ? .lineSeparator : nil
        case .kanji1:
            if info.kind == .kanji { return .kanjiRun }
            return markLike ? .runMark : nil
        case .kanjiRun:
            return info.kind == .kanji ? .kanjiRun : nil
        case .kata1, .hira1, .kataHira1:
            if info.kanaMark { return state }
            if info.kind == .mark { return .runMark }
            return kanaRun(state, info)
        case .kataRun, .hiraRun, .kataHiraRun, .kanaMarkStart:
            return kanaRun(state, info)
        case .numberPost, .lineSeparator, .markStart, .opaque:
            return nil
        }
    }

    /// Continues (or starts) a katakana / hiragana run; characters in both sets fit either.
    private static func kanaRun(_ state: State, _ info: Info) -> State? {
        let wasKata = state == .kata1 || state == .kataRun
        let wasHira = state == .hira1 || state == .hiraRun
        switch info.kind {
        case .kata: return wasHira ? nil : .kataRun
        case .hira: return wasKata ? nil : .hiraRun
        case .kataHira: return wasKata ? .kataRun : (wasHira ? .hiraRun : .kataHiraRun)
        default: return nil
        }
    }

    /// The segments of `scalars`, in order, covering all of it.
    static func segments(_ scalars: [Unicode.Scalar]) -> [Range<Int>] {
        let infos = scalars.map(info)
        var result: [Range<Int>] = []
        var start = 0
        while start < scalars.count {
            var state = State.start
            var lastAccept: Int?
            var i = start
            while i < scalars.count {
                let info = infos[i]
                if info.kind == .ignore {
                    // Transparent; a break never falls right before one.
                    if lastAccept == i { lastAccept = i + 1 }
                    i += 1
                    continue
                }
                guard let next = transition(state, info) else { break }
                state = next
                i += 1
                if state.accepting { lastAccept = i }
            }
            let end = lastAccept ?? scalars.count
            result.append(start..<end)
            start = end
        }
        return result
    }
}

// MARK: - Bunched serializer

/// Java's `TextIndexBunchedSerializer`: keys are packed tuples; a bunch is `0x20`, then for each
/// entry its key (except the first, which is the DB key's suffix) as `varint(length) + bytes`,
/// then its position list as `varint(byte size) + delta-encoded varints`. Varints are big-endian
/// base 128 (high bit = more bytes follow).
enum TextIndexBunchedSerializer {
    static let prefix: UInt8 = 0x20

    /// One map entry; the key is kept as its packed tuple bytes.
    struct Entry: Sendable, Equatable {
        var key: FDB.Bytes
        var value: [Int]
    }

    static func varIntSize(_ value: Int) -> Int {
        value == 0 ? 1 : (32 - UInt32(truncatingIfNeeded: value).leadingZeroBitCount + 6) / 7
    }

    static func appendVarInt(_ value: Int, to out: inout FDB.Bytes) {
        let count = varIntSize(value)
        for i in stride(from: count - 1, through: 0, by: -1) {
            out.append(UInt8((value >> (7 * i)) & 0x7F) | (i == 0 ? 0 : 0x80))
        }
    }

    static func readVarInt(_ data: FDB.Bytes, _ offset: inout Int) throws -> Int {
        var value = 0
        while true {
            guard offset < data.count else { throw TextIndexError.serialization("truncated varint") }
            let byte = data[offset]
            offset += 1
            value = (value << 7) + Int(byte & 0x7F)
            guard value <= Int(Int32.max) else { throw TextIndexError.serialization("varint overflow") }
            if byte & 0x80 == 0 { return value }
        }
    }

    /// The serialized size of a position list, validating that it is ascending and non-negative.
    static func listSize(_ list: [Int]) throws -> Int {
        var sum = 0
        var last = 0
        for value in list {
            guard value >= 0, value >= last, value <= Int(Int32.max) else {
                throw TextIndexError.serialization("list is not monotonically increasing non-negative integers")
            }
            sum += varIntSize(value - last)
            last = value
        }
        return sum
    }

    static func appendList(_ list: [Int], size: Int, to out: inout FDB.Bytes) {
        appendVarInt(size, to: &out)
        var last = 0
        for value in list {
            appendVarInt(value - last, to: &out)
            last = value
        }
    }

    static func readList(_ data: FDB.Bytes, _ offset: inout Int) throws -> [Int] {
        let size = try readVarInt(data, &offset)
        guard size > 0 else { return [] }
        let end = offset + size
        guard end <= data.count else { throw TextIndexError.serialization("position list overruns value") }
        var list: [Int] = []
        var last = 0
        while offset < end {
            last += try readVarInt(data, &offset)
            list.append(last)
        }
        return list
    }

    /// Java's `serializeEntry` (used for `APPEND_IF_FITS`).
    static func serializeEntry(_ entry: Entry) throws -> FDB.Bytes {
        let size = try listSize(entry.value)
        var out: FDB.Bytes = []
        out.reserveCapacity(varIntSize(entry.key.count) + entry.key.count + varIntSize(size) + size)
        appendVarInt(entry.key.count, to: &out)
        out += entry.key
        appendList(entry.value, size: size, to: &out)
        return out
    }

    /// Java's `serializeEntries`.
    static func serializeEntries(_ entries: ArraySlice<Entry>) throws -> FDB.Bytes {
        guard !entries.isEmpty else { throw TextIndexError.serialization("cannot serialize empty entry list") }
        var out: FDB.Bytes = [prefix]
        for (i, entry) in entries.enumerated() {
            if i != 0 {
                appendVarInt(entry.key.count, to: &out)
                out += entry.key
            }
            appendList(entry.value, size: try listSize(entry.value), to: &out)
        }
        return out
    }

    static func serializeEntries(_ entries: [Entry]) throws -> FDB.Bytes { try serializeEntries(entries[...]) }

    /// Java's `deserializeEntries`: `firstKey` is the bunch's DB key suffix.
    static func deserializeEntries(firstKey: FDB.Bytes, _ data: FDB.Bytes, values: Bool = true) throws -> [Entry] {
        guard data.first == prefix else { throw TextIndexError.serialization("serialized data begins with incorrect prefix") }
        var entries: [Entry] = []
        var offset = 1
        var first = true
        while offset < data.count {
            let key: FDB.Bytes
            if first {
                key = firstKey
                first = false
            } else {
                let length = try readVarInt(data, &offset)
                guard offset + length <= data.count else { throw TextIndexError.serialization("key overruns value") }
                key = Array(data[offset..<offset + length])
                offset += length
            }
            if values {
                entries.append(Entry(key: key, value: try readList(data, &offset)))
            } else {
                let size = try readVarInt(data, &offset)
                guard offset + size <= data.count else { throw TextIndexError.serialization("position list overruns value") }
                offset += size
                entries.append(Entry(key: key, value: []))
            }
        }
        // Java fails a bunch whose first entry has no position list ("no final entry list").
        if first { throw TextIndexError.serialization("no entries in bunch") }
        return entries
    }
}

// MARK: - BunchedMap

/// Java's `BunchedMap<Tuple, List<Integer>>` with the text serializer: a sorted map stored in a
/// subspace with up to `bunchSize` entries per database key, written with exactly the same keys,
/// values, mutations and conflict ranges as Java.
struct BunchedMap: Sendable {
    /// Java's `MAX_VALUE_SIZE` (FDB's limit is 100k; the map stays well clear of it).
    static let maxValueSize = 10_000

    typealias Entry = TextIndexBunchedSerializer.Entry
    private typealias KV = (key: FDB.Bytes, value: FDB.Bytes)

    let bunchSize: Int

    private static func less(_ a: FDB.Bytes, _ b: FDB.Bytes) -> Bool { a.lexicographicallyPrecedes(b) }

    private static func readConflictKey(_ tr: any TransactionProtocol, _ key: FDB.Bytes) throws {
        try tr.addConflictRange(beginKey: key, endKey: key + [0x00], type: .read)
    }

    private static func writeConflictKey(_ tr: any TransactionProtocol, _ key: FDB.Bytes) throws {
        try tr.addConflictRange(beginKey: key, endKey: key + [0x00], type: .write)
    }

    private static func snapshotRange(
        _ tr: any TransactionProtocol, _ begin: FDB.KeySelector, _ end: FDB.KeySelector
    ) async throws -> [KV] {
        var result: [KV] = []
        for try await (key, value) in tr.getRange(beginSelector: begin, endSelector: end, snapshot: true, reverse: false) {
            result.append((key, value))
        }
        return result
    }

    private static func deserialize(_ subspace: FDB.Bytes, _ kv: KV) throws -> [Entry] {
        try TextIndexBunchedSerializer.deserializeEntries(firstKey: Array(kv.key.dropFirst(subspace.count)), kv.value)
    }

    // MARK: Write helpers (Java's private methods, same order of operations)

    private func addEntryListReadConflictRange(
        _ tr: any TransactionProtocol, _ subspace: FDB.Bytes, _ begin: FDB.Bytes, _ entries: ArraySlice<Entry>
    ) throws {
        try tr.addConflictRange(beginKey: begin, endKey: subspace + entries.last!.key + [0x00], type: .read)
    }

    private func insertAlone(_ tr: any TransactionProtocol, _ keyBytes: FDB.Bytes, _ entry: Entry) throws {
        try Self.readConflictKey(tr, keyBytes)
        tr.setValue(try TextIndexBunchedSerializer.serializeEntries([entry]), for: keyBytes)
    }

    private func writeEntryListWithoutChecking(
        _ tr: any TransactionProtocol, _ subspace: FDB.Bytes, _ keyBytes: FDB.Bytes, _ oldKV: KV?,
        _ newKey: FDB.Bytes, _ entries: ArraySlice<Entry>, _ serialized: FDB.Bytes
    ) throws {
        try addEntryListReadConflictRange(tr, subspace, newKey, entries)
        if let oldKV, oldKV.key != newKey {
            tr.clear(key: oldKV.key)
        }
        tr.setValue(serialized, for: newKey)
        if keyBytes != newKey {
            try Self.writeConflictKey(tr, keyBytes)
        }
    }

    private func writeEntryList(
        _ tr: any TransactionProtocol, _ subspace: FDB.Bytes, _ keyBytes: FDB.Bytes, _ oldKV: KV?,
        _ newKey: FDB.Bytes, _ entries: ArraySlice<Entry>, _ kvAfter: KV?, isFirst: Bool, isLast: Bool
    ) throws {
        let serialized = try TextIndexBunchedSerializer.serializeEntries(entries)
        if serialized.count > Self.maxValueSize {
            if isFirst || entries.count == 1 {
                try insertAlone(tr, keyBytes, entries.first!)
            } else if isLast {
                try insertAfter(tr, subspace, keyBytes, kvAfter, entries.last!)
            } else {
                let split = entries.startIndex + entries.count / 2
                let firstEntries = entries[entries.startIndex..<split]
                let secondEntries = entries[split...]
                let firstSerialized = try TextIndexBunchedSerializer.serializeEntries(firstEntries)
                let secondSerialized = try TextIndexBunchedSerializer.serializeEntries(secondEntries)
                try writeEntryListWithoutChecking(tr, subspace, keyBytes, oldKV, newKey, firstEntries, firstSerialized)
                let secondKey = subspace + secondEntries.first!.key
                try writeEntryListWithoutChecking(tr, subspace, keyBytes, nil, secondKey, secondEntries, secondSerialized)
            }
            return
        }
        if isLast, entries.count > 1, let oldKV, oldKV.key == newKey {
            // APPEND_IF_FITS silently does nothing when the result is too large; the size was
            // checked above.
            try addEntryListReadConflictRange(tr, subspace, newKey, entries)
            tr.atomicOp(key: newKey, param: try TextIndexBunchedSerializer.serializeEntry(entries.last!), mutationType: .appendIfFits)
            try Self.writeConflictKey(tr, keyBytes)
        } else {
            try writeEntryListWithoutChecking(tr, subspace, keyBytes, oldKV, newKey, entries, serialized)
        }
        // Claiming the gap before the next bunch / after the previous one.
        if isFirst, entries.count >= 2 {
            let second = entries[entries.index(after: entries.startIndex)]
            try tr.addConflictRange(beginKey: keyBytes, endKey: subspace + second.key, type: .write)
        }
        if isLast, entries.count >= 2 {
            let secondToLast = entries[entries.index(entries.endIndex, offsetBy: -2)]
            try tr.addConflictRange(beginKey: subspace + secondToLast.key, endKey: keyBytes, type: .write)
        }
    }

    private func insertAfter(
        _ tr: any TransactionProtocol, _ subspace: FDB.Bytes, _ keyBytes: FDB.Bytes, _ kvAfter: KV?, _ entry: Entry
    ) throws {
        guard let kvAfter else {
            try insertAlone(tr, keyBytes, entry)
            return
        }
        let afterEntries = try Self.deserialize(subspace, kvAfter)
        if afterEntries.count >= bunchSize {
            try insertAlone(tr, keyBytes, entry)
        } else {
            try writeEntryList(tr, subspace, keyBytes, kvAfter, keyBytes, ([entry] + afterEntries)[...], nil,
                               isFirst: true, isLast: false)
        }
    }

    // MARK: Public operations

    /// Java's `put`: inserts or replaces `key` → `value` in the map stored under `subspace`;
    /// returns the previous value.
    @discardableResult
    func put(_ tr: any TransactionProtocol, subspace: FDB.Bytes, key: FDB.Bytes, value: [Int]) async throws -> [Int]? {
        let keyBytes = subspace + key
        // One snapshot read for the bunch at or before the key and the one after it.
        let kvs = try await Self.snapshotRange(
            tr, .lastLessOrEqual(keyBytes), FDB.KeySelector(key: keyBytes, orEqual: true, offset: 2))
        var kvBefore: KV?
        var kvAfter: KV?
        for kv in kvs where kv.key.starts(with: subspace) {
            if Self.less(keyBytes, kv.key) {
                kvAfter = kv
                break
            }
            kvBefore = kv
        }
        let entry = Entry(key: key, value: value)
        guard let kvBefore else {
            try insertAfter(tr, subspace, keyBytes, kvAfter, entry)
            return nil
        }
        var entries = try Self.deserialize(subspace, kvBefore)
        var insertIndex = 0
        while insertIndex < entries.count && Self.less(entries[insertIndex].key, key) { insertIndex += 1 }
        if insertIndex < entries.count && entries[insertIndex].key == key {
            let oldValue = entries[insertIndex].value
            if oldValue != value {
                entries[insertIndex] = entry
                try writeEntryList(tr, subspace, keyBytes, kvBefore, kvBefore.key, entries[...], kvAfter,
                                   isFirst: false, isLast: false)
            } else {
                // Unchanged: just make sure a concurrent change to it forces a retry.
                try Self.readConflictKey(tr, keyBytes)
            }
            return oldValue
        } else if insertIndex < entries.count {
            entries.insert(entry, at: insertIndex)
            if entries.count <= bunchSize {
                try writeEntryList(tr, subspace, keyBytes, kvBefore, kvBefore.key, entries[...], kvAfter,
                                   isFirst: false, isLast: false)
            } else {
                let split = entries.count / 2
                try writeEntryList(tr, subspace, keyBytes, kvBefore, kvBefore.key, entries[..<split], nil,
                                   isFirst: false, isLast: false)
                let secondEntries = entries[split...]
                try writeEntryList(tr, subspace, keyBytes, nil, subspace + secondEntries.first!.key, secondEntries, kvAfter,
                                   isFirst: false, isLast: false)
            }
            return nil
        } else {
            if entries.count < bunchSize {
                entries.append(entry)
                try writeEntryList(tr, subspace, keyBytes, kvBefore, kvBefore.key, entries[...], kvAfter,
                                   isFirst: false, isLast: true)
            } else {
                try insertAfter(tr, subspace, keyBytes, kvAfter, entry)
            }
            return nil
        }
    }

    /// Java's `entryForKey`: the bunch that would hold `key`, if any.
    private func entryForKey(_ tr: any TransactionProtocol, subspace: FDB.Bytes, key: FDB.Bytes) async throws -> KV? {
        let keyBytes = subspace + key
        try Self.readConflictKey(tr, keyBytes)
        let kvs = try await Self.snapshotRange(tr, .lastLessOrEqual(keyBytes), .firstGreaterThan(keyBytes))
        guard let kv = kvs.last else { return nil }
        if Self.less(keyBytes, kv.key) {
            throw TextIndexError.corruptBunchedMap("signpost key found for key is greater than original key")
        }
        return kv.key.starts(with: subspace) ? kv : nil
    }

    /// Java's `get`.
    func get(_ tr: any TransactionProtocol, subspace: FDB.Bytes, key: FDB.Bytes) async throws -> [Int]? {
        guard let kv = try await entryForKey(tr, subspace: subspace, key: key) else { return nil }
        return try Self.deserialize(subspace, kv).first { $0.key == key }?.value
    }

    /// Java's `remove`: removes `key`, returning its value if it was present.
    @discardableResult
    func remove(_ tr: any TransactionProtocol, subspace: FDB.Bytes, key: FDB.Bytes) async throws -> [Int]? {
        guard let kv = try await entryForKey(tr, subspace: subspace, key: key) else { return nil }
        var entries = try Self.deserialize(subspace, kv)
        guard let found = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let oldValue = entries[found].value
        // The rewritten value depends on every entry read.
        try addEntryListReadConflictRange(tr, subspace, kv.key, entries[...])
        try Self.writeConflictKey(tr, subspace + key)
        if entries.count == 1 {
            tr.clear(key: kv.key)
        } else {
            entries.remove(at: found)
            let newKey: FDB.Bytes
            if found == 0 {
                tr.clear(key: kv.key)
                newKey = subspace + entries[0].key
            } else {
                newKey = kv.key
            }
            tr.setValue(try TextIndexBunchedSerializer.serializeEntries(entries), for: newKey)
        }
        return oldValue
    }

    /// Every entry of every map whose subspace lies in `[begin, end)`, in key order, read at
    /// the given isolation (Java's `scanMulti` without a continuation). `splitPrefixLength`
    /// gives, for a DB key, the length of its map subspace prefix.
    static func scanMulti(
        _ tr: any TransactionProtocol, begin: FDB.Bytes, end: FDB.Bytes, snapshot: Bool,
        mapSubspaceOf: (FDB.Bytes) throws -> FDB.Bytes
    ) async throws -> [(subspace: FDB.Bytes, entry: Entry)] {
        var result: [(FDB.Bytes, Entry)] = []
        let range = tr.getRange(
            beginSelector: .firstGreaterOrEqual(begin), endSelector: .firstGreaterOrEqual(end), snapshot: snapshot, reverse: false)
        for try await (key, value) in range {
            let subspace = try mapSubspaceOf(key)
            for entry in try deserialize(subspace, (key, value)) {
                result.append((subspace, entry))
            }
        }
        return result
    }
}

// MARK: - Index maintainer

/// Java's `TextIndexMaintainer`.
enum TextIndexMaintainer {
    /// Java's `BUNCH_SIZE`.
    static let bunchSize = 20
    static let bunchedMap = BunchedMap(bunchSize: bunchSize)
    /// Java's `TOKENIZER_VERSION_SUBSPACE_TUPLE`, under the index's secondary subspace.
    static let tokenizerVersionSubspaceKey: Int64 = 0

    struct Config {
        let tokenizer: any TextTokenizer
        let tokenizerVersion: Int
        let addAggressiveConflictRanges: Bool
        let omitPositions: Bool
    }

    /// Java's `getTokenizer`, `getIndexTokenizerVersion`, `getIfAddAggressiveConflictRanges`
    /// and `getIfOmitPositions`.
    static func config(_ index: ErasedIndex) throws -> Config {
        let tokenizer = try TextTokenizerRegistry.shared.tokenizer(named: index.options[IndexOptions.textTokenizerName])
        var version = TextTokenizers.globalMinVersion
        if let raw = index.options[IndexOptions.textTokenizerVersion] {
            guard let parsed = Int32(raw) else { throw TextIndexError.unparseableTokenizerVersion(raw) }
            version = Int(parsed)
        }
        return Config(
            tokenizer: tokenizer, tokenizerVersion: version,
            addAggressiveConflictRanges: index.options[IndexOptions.textAddAggressiveConflictRanges]?.lowercased() == "true",
            omitPositions: index.options[IndexOptions.textOmitPositions]?.lowercased() == "true")
    }

    /// Text indexes are idempotent (Java does not override `StandardIndexMaintainer.isIdempotent`).
    static func isIdempotent(_ index: ErasedIndex) -> Bool { true }

    /// The number of leading grouping columns (Java's `textFieldPosition`): every column but
    /// the grouped (text) ones.
    static func textPosition(_ index: ErasedIndex, columns: Int) -> Int { max(0, columns - index.groupedCount) }

    static func recordTokenizerKey(_ m: IndexMaintainer, _ primaryKey: Tuple) -> FDB.Bytes {
        m.store.indexSecondarySubspace(m.index).prefix + Tuple(tokenizerVersionSubspaceKey).encode() + primaryKey.encode()
    }

    static func recordTokenizerVersion(_ m: IndexMaintainer, _ primaryKey: Tuple) async throws -> Int {
        guard let raw = try await m.transaction.getValue(for: recordTokenizerKey(m, primaryKey)) else {
            return TextTokenizers.globalMinVersion
        }
        guard let first = try Tuple.decode(from: raw).first, let value = IndexMaintainer.integer(first) else {
            throw TextIndexError.serialization("record tokenizer version is not an integer")
        }
        return Int(value)
    }

    /// Java's `update`: keeps each record's tokenizer version and re-indexes a record whose
    /// stored version differs from the index's.
    static func update(_ maintainer: IndexMaintainer, old: IndexableRecord?, new: IndexableRecord?) async throws {
        let config = try config(maintainer.index)
        switch (old, new) {
        case (nil, let new?):
            maintainer.transaction.setValue(Tuple(Int64(config.tokenizerVersion)).encode(),
                                            for: recordTokenizerKey(maintainer, new.primaryKey))
            try await standardUpdate(maintainer, config, old: nil, new: new)
        case (let old?, nil):
            try await standardUpdate(maintainer, config, old: old, new: nil)
            maintainer.transaction.clear(key: recordTokenizerKey(maintainer, old.primaryKey))
        case (let old?, let new?):
            if try await recordTokenizerVersion(maintainer, old.primaryKey) == config.tokenizerVersion {
                try await standardUpdate(maintainer, config, old: old, new: new)
            } else {
                try await standardUpdate(maintainer, config, old: old, new: nil)
                maintainer.transaction.setValue(Tuple(Int64(config.tokenizerVersion)).encode(),
                                                for: recordTokenizerKey(maintainer, new.primaryKey))
                try await standardUpdate(maintainer, config, old: nil, new: new)
            }
        case (nil, nil):
            return
        }
    }

    /// `StandardIndexMaintainer.update`: entries common to old and new are left alone.
    private static func standardUpdate(
        _ m: IndexMaintainer, _ config: Config, old: IndexableRecord?, new: IndexableRecord?
    ) async throws {
        var oldEntries = old.map { $0.entries(for: m.index) } ?? []
        var newEntries = new.map { $0.entries(for: m.index) } ?? []
        if old != nil, new != nil {
            let common = Set(oldEntries.map { Tuple($0).encode() }).intersection(newEntries.map { Tuple($0).encode() })
            if !common.isEmpty {
                oldEntries.removeAll { common.contains(Tuple($0).encode()) }
                newEntries.removeAll { common.contains(Tuple($0).encode()) }
            }
        }
        if let old, !oldEntries.isEmpty {
            // Remove with the tokenizer version the record was indexed with.
            let version = try await recordTokenizerVersion(m, old.primaryKey)
            for entry in oldEntries {
                try await updateOneKey(m, config, old, remove: true, entry, version: version)
            }
        }
        if let new, !newEntries.isEmpty {
            for entry in newEntries {
                try await updateOneKey(m, config, new, remove: false, entry, version: config.tokenizerVersion)
            }
        }
    }

    /// Java's `updateOneKeyAsync`.
    private static func updateOneKey(
        _ m: IndexMaintainer, _ config: Config, _ record: IndexableRecord, remove: Bool,
        _ entry: [any TupleElement], version: Int
    ) async throws {
        let textPosition = textPosition(m.index, columns: entry.count)
        guard textPosition < entry.count else { return }
        let text: String
        switch entry[textPosition] {
        case is NullValue:
            return
        case let string as String:
            text = string
        default:
            throw TextIndexError.textColumnNotString(index: m.index.name)
        }
        if text.isEmpty { return }
        let grouping = Array(entry.prefix(textPosition))
        let groupedKey = Tuple(Array(entry.dropFirst(textPosition + 1)) + record.primaryKey.elements).encode()
        let positionMap = try config.tokenizer.tokenizeToMap(text, version: version, mode: .index)
        if positionMap.isEmpty { return }
        let indexSubspace = m.indexSubspace
        if config.addAggressiveConflictRanges {
            // One conflict range over the (group of the) index instead of many per-token ones.
            let (begin, end) = grouping.isEmpty ? indexSubspace.range : indexSubspace.range(Tuple(grouping))
            try m.transaction.addConflictRange(beginKey: begin, endKey: end, type: .read)
            try m.transaction.addConflictRange(beginKey: begin, endKey: end, type: .write)
        }
        for token in positionMap.keys.sorted() {
            let mapSubspace = indexSubspace.prefix + Tuple(grouping + [token]).encode()
            if remove {
                try await bunchedMap.remove(m.transaction, subspace: mapSubspace, key: groupedKey)
            } else {
                let positions = config.omitPositions ? [] : positionMap[token]!
                try await bunchedMap.put(m.transaction, subspace: mapSubspace, key: groupedKey, value: positions)
            }
        }
    }
}

// MARK: - Queries

/// A full-text predicate answered by a text index — Java's `Text` / `Comparisons.TextComparison`.
///
/// A predicate built from a `String` tokenizes it with the index's tokenizer (in query mode);
/// one built from `[String]` uses the tokens as given (empty strings are stop words).
public struct TextComparison: Sendable {
    public enum Kind: Sendable, Equatable {
        /// Every token occurs (Java `TEXT_CONTAINS_ALL`).
        case containsAll
        /// Every token occurs, all within a window of `maxDistance` positions (Java `TEXT_CONTAINS_ALL_WITHIN`).
        case containsAllWithin(maxDistance: Int)
        /// Some token occurs (Java `TEXT_CONTAINS_ANY`).
        case containsAny
        /// The tokens occur consecutively, stop words occupying their positions (Java `TEXT_CONTAINS_PHRASE`).
        case containsPhrase
        /// Some token starts with the (single) prefix (Java `TEXT_CONTAINS_PREFIX`).
        case containsPrefix
        /// For every prefix, some token starts with it (Java `TEXT_CONTAINS_ALL_PREFIXES`).
        case containsAllPrefixes
        /// For some prefix, some token starts with it (Java `TEXT_CONTAINS_ANY_PREFIX`).
        case containsAnyPrefix
    }

    enum Comparand: Sendable {
        case text(String)
        case tokens([String])
    }

    public let kind: Kind
    let comparand: Comparand

    public static func containsAll(_ text: String) -> TextComparison { .init(kind: .containsAll, comparand: .text(text)) }
    public static func containsAll(_ tokens: [String]) -> TextComparison { .init(kind: .containsAll, comparand: .tokens(tokens)) }
    public static func containsAll(_ text: String, maxDistance: Int) -> TextComparison {
        .init(kind: .containsAllWithin(maxDistance: maxDistance), comparand: .text(text))
    }
    public static func containsAll(_ tokens: [String], maxDistance: Int) -> TextComparison {
        .init(kind: .containsAllWithin(maxDistance: maxDistance), comparand: .tokens(tokens))
    }
    public static func containsAny(_ text: String) -> TextComparison { .init(kind: .containsAny, comparand: .text(text)) }
    public static func containsAny(_ tokens: [String]) -> TextComparison { .init(kind: .containsAny, comparand: .tokens(tokens)) }
    public static func containsPhrase(_ text: String) -> TextComparison { .init(kind: .containsPhrase, comparand: .text(text)) }
    public static func containsPhrase(_ tokens: [String]) -> TextComparison {
        .init(kind: .containsPhrase, comparand: .tokens(tokens))
    }
    public static func containsPrefix(_ prefix: String) -> TextComparison {
        .init(kind: .containsPrefix, comparand: .text(prefix))
    }
    public static func containsAllPrefixes(_ text: String) -> TextComparison {
        .init(kind: .containsAllPrefixes, comparand: .text(text))
    }
    public static func containsAllPrefixes(_ prefixes: [String]) -> TextComparison {
        .init(kind: .containsAllPrefixes, comparand: .tokens(prefixes))
    }
    public static func containsAnyPrefix(_ text: String) -> TextComparison {
        .init(kind: .containsAnyPrefix, comparand: .text(text))
    }
    public static func containsAnyPrefix(_ prefixes: [String]) -> TextComparison {
        .init(kind: .containsAnyPrefix, comparand: .tokens(prefixes))
    }
}

/// A range over the index columns that follow the token — any columns after the text column,
/// then the primary key (Java's text-scan "suffix comparisons"). Endpoints are tuple prefixes:
/// an inclusive high end includes every key that extends it, an exclusive low end excludes them.
public struct TextSuffixRange: Sendable {
    public var low: Tuple?
    public var lowInclusive: Bool
    public var high: Tuple?
    public var highInclusive: Bool

    public init(low: Tuple? = nil, lowInclusive: Bool = true, high: Tuple? = nil, highInclusive: Bool = false) {
        self.low = low
        self.lowInclusive = lowInclusive
        self.high = high
        self.highInclusive = highInclusive
    }

    /// Java's `TupleRange.toRange` (relative to the token's map subspace).
    func contains(_ suffix: FDB.Bytes) -> Bool {
        if let low {
            let bytes = low.encode()
            let begin = lowInclusive ? bytes : Self.strinc(bytes)
            if suffix.lexicographicallyPrecedes(begin) { return false }
        }
        if let high {
            let bytes = high.encode()
            let end = highInclusive ? Self.strinc(bytes) : bytes
            if !suffix.lexicographicallyPrecedes(end) { return false }
        }
        return true
    }

    static func strinc(_ bytes: FDB.Bytes) -> FDB.Bytes {
        var b = bytes
        while let last = b.last, last == 0xFF { b.removeLast() }
        guard !b.isEmpty else { return [0xFF] }
        b[b.count - 1] += 1
        return b
    }
}

/// One posting read from a text index: a record's occurrence of a token.
public struct TextIndexEntry: Sendable {
    /// The grouping columns' values.
    public let group: Tuple
    public let token: String
    /// The columns after the text column followed by the primary key (the map key).
    public let suffix: Tuple
    public let primaryKey: Tuple
    /// The token's positions in the text (empty when the index omits positions).
    public let positions: [Int]
    let suffixBytes: FDB.Bytes
}

extension FDBRecordStore {
    /// The primary keys of records of type `M` whose text, as indexed by the `text` index
    /// `name`, satisfies `comparison` — Java's `TextScan`. The index must be scannable.
    ///
    /// - Parameters:
    ///   - group: values for all of the index's grouping columns (those before the text column).
    ///   - suffix: restricts the columns after the token (trailing columns, then primary key);
    ///     not allowed with prefix comparisons, as in Java.
    /// - Returns: distinct primary keys, ordered by the index columns after the token (for an
    ///   index with no trailing columns, primary-key order); for a single prefix, in token order.
    public func textSearchPrimaryKeys<M: SwiftProtobuf.Message>(
        _ type: M.Type, indexNamed name: String, _ comparison: TextComparison,
        group: Tuple = Tuple(), suffix: TextSuffixRange? = nil
    ) async throws -> [Tuple] {
        let index = try scannableIndex(type, named: name)
        let entries = try await textSearchEntries(index, comparison, group: group, suffix: suffix)
        var seen = Set<FDB.Bytes>()
        return entries.compactMap { seen.insert($0.primaryKey.encode()).inserted ? $0.primaryKey : nil }
    }

    /// The records matching `comparison` (see ``textSearchPrimaryKeys(_:indexNamed:_:group:suffix:)``).
    public func textSearch<M: SwiftProtobuf.Message & Sendable>(
        _ type: M.Type, indexNamed name: String, _ comparison: TextComparison,
        group: Tuple = Tuple(), suffix: TextSuffixRange? = nil
    ) async throws -> [FDBStoredRecord<M>] {
        guard let recordType = metaData.recordType(for: M.self) else {
            throw RecordStoreError.unknownRecordType(M.protoMessageName)
        }
        var records: [FDBStoredRecord<M>] = []
        for primaryKey in try await textSearchPrimaryKeys(type, indexNamed: name, comparison, group: group, suffix: suffix) {
            if let record: FDBStoredRecord<M> = try await loadTyped(primaryKey, recordType: recordType, filter: nil) {
                records.append(record)
            }
        }
        return records
    }

    /// The postings for `token` (or, with `prefix: true`, for every token starting with it) in
    /// a group of a text index — Java's `BY_TEXT_TOKEN` index scan.
    public func scanTextIndex<M: SwiftProtobuf.Message>(
        _ type: M.Type, indexNamed name: String, token: String, prefix: Bool = false, group: Tuple = Tuple()
    ) async throws -> [TextIndexEntry] {
        let index = try scannableIndex(type, named: name)
        try checkTextIndex(index, group: group)
        return prefix
            ? try await scanTextTokenPrefix(index, token, group: group)
            : try await scanTextToken(index, token, group: group, suffix: nil)
    }

    // MARK: Internals

    private func checkTextIndex(_ index: ErasedIndex, group: Tuple) throws {
        guard index.type == .text else { throw TextIndexError.invalidQuery("index \(index.name) is not a text index") }
        let columns = index.columnIdentities.count
        if columns > 0 {
            let groupingColumns = TextIndexMaintainer.textPosition(index, columns: columns)
            guard group.count == groupingColumns else {
                throw TextIndexError.invalidQuery(
                    "index \(index.name) needs \(groupingColumns) grouping value(s), got \(group.count)")
            }
        }
    }

    /// The comparand's tokens (Java's `TextScan.getTokenList`).
    private func textTokens(_ index: ErasedIndex, _ comparison: TextComparison, removeStopWords: Bool) throws -> [String] {
        var tokens: [String]
        switch comparison.comparand {
        case .tokens(let list):
            tokens = list
        case .text(let text):
            let config = try TextIndexMaintainer.config(index)
            tokens = try config.tokenizer.tokenize(text, version: config.tokenizerVersion, mode: .query)
        }
        if removeStopWords { tokens.removeAll { $0.isEmpty } }
        return tokens
    }

    private func textSearchEntries(
        _ index: ErasedIndex, _ comparison: TextComparison, group: Tuple, suffix: TextSuffixRange?
    ) async throws -> [TextIndexEntry] {
        try checkTextIndex(index, group: group)
        let tokens = try textTokens(index, comparison, removeStopWords: true)
        if tokens.isEmpty { return [] }
        let kind = comparison.kind
        let isPrefix = kind == .containsPrefix || kind == .containsAllPrefixes || kind == .containsAnyPrefix
        if isPrefix && suffix != nil {
            throw TextIndexError.invalidQuery("text prefix comparison included inequality scan comparison")
        }
        if kind == .containsPrefix || (tokens.count == 1 && isPrefix) {
            guard tokens.count == 1 else {
                throw TextIndexError.invalidQuery("text prefix comparison included \(tokens.count) comparands instead of one")
            }
            return try await scanTextTokenPrefix(index, tokens[0], group: group)
        }
        if tokens.count == 1 {
            return try await scanTextToken(index, tokens[0], group: group, suffix: suffix)
        }
        var perToken: [[TextIndexEntry]] = []
        for token in tokens {
            perToken.append(isPrefix
                ? try await scanTextTokenPrefix(index, token, group: group)
                : try await scanTextToken(index, token, group: group, suffix: suffix))
        }
        switch kind {
        case .containsAny, .containsAnyPrefix:
            return Self.union(perToken)
        case .containsAll, .containsAllPrefixes:
            return Self.intersection(perToken).map { $0[0] }
        case .containsAllWithin(let maxDistance):
            return Self.intersection(perToken).filter { Self.containAllWithin($0, maxDistance) }.map { $0[0] }
        case .containsPhrase:
            let withStopWords = try textTokens(index, comparison, removeStopWords: false)
            return Self.intersection(perToken).filter { Self.containPhrase($0, withStopWords) }.map { $0[0] }
        case .containsPrefix:
            fatalError("handled above")
        }
    }

    /// One token's postings, in suffix order.
    private func scanTextToken(
        _ index: ErasedIndex, _ token: String, group: Tuple, suffix: TextSuffixRange?
    ) async throws -> [TextIndexEntry] {
        let mapSubspace = indexSubspace(index).prefix + Tuple(group.elements + [token]).encode()
        let (begin, end) = (mapSubspace + [0x00], mapSubspace + [0xFF])
        var entries = try await scanTextRange(index, begin: begin, end: end, groupCount: group.count)
        if let suffix { entries.removeAll { !suffix.contains($0.suffixBytes) } }
        return entries
    }

    /// Postings of every token starting with `prefix` (Java's `TupleRange.prefixedBy`), in
    /// (token, suffix) order.
    private func scanTextTokenPrefix(_ index: ErasedIndex, _ prefix: String, group: Tuple) async throws -> [TextIndexEntry] {
        let begin = indexSubspace(index).prefix + group.encode() + Array(Tuple(prefix).encode().dropLast())
        return try await scanTextRange(index, begin: begin, end: TextSuffixRange.strinc(begin), groupCount: group.count)
    }

    private func scanTextRange(
        _ index: ErasedIndex, begin: FDB.Bytes, end: FDB.Bytes, groupCount: Int
    ) async throws -> [TextIndexEntry] {
        let space = indexSubspace(index)
        let primaryKeyCount = index.primaryKeyColumnCount
        let scanned = try await BunchedMap.scanMulti(transaction, begin: begin, end: end, snapshot: false) { key in
            // The map subspace is the grouping columns plus the token (Java's `TextSubspaceSplitter`).
            let elements = try space.unpack(key)
            guard elements.count > groupCount else { throw TextIndexError.corruptBunchedMap("index key too short") }
            return space.prefix + Tuple(Array(elements.prefix(groupCount + 1))).encode()
        }
        return try scanned.map { subspace, entry in
            let head = try Tuple.decode(from: Array(subspace.dropFirst(space.prefix.count)))
            guard let token = head.last as? String else { throw TextIndexError.corruptBunchedMap("token is not a string") }
            let suffix = try Tuple.decode(from: entry.key)
            return TextIndexEntry(
                group: Tuple(Array(head.dropLast())), token: token, suffix: Tuple(suffix),
                primaryKey: Tuple(Array(suffix.suffix(primaryKeyCount))), positions: entry.value, suffixBytes: entry.key)
        }
    }

    // MARK: Set operations and position filters (Java's cursors and TextScan predicates)

    private static func union(_ lists: [[TextIndexEntry]]) -> [TextIndexEntry] {
        var seen = Set<FDB.Bytes>()
        var result: [TextIndexEntry] = []
        for entry in lists.joined() where seen.insert(entry.suffixBytes).inserted { result.append(entry) }
        return result.sorted { $0.suffixBytes.lexicographicallyPrecedes($1.suffixBytes) }
    }

    /// Entries whose suffix appears in every list, as one entry per list (in list order).
    private static func intersection(_ lists: [[TextIndexEntry]]) -> [[TextIndexEntry]] {
        let maps = lists.map { list in
            Dictionary(list.map { ($0.suffixBytes, $0) }, uniquingKeysWith: { first, _ in first })
        }
        var result: [[TextIndexEntry]] = []
        var seen = Set<FDB.Bytes>()
        for entry in lists[0] where seen.insert(entry.suffixBytes).inserted {
            let matched = maps.compactMap { $0[entry.suffixBytes] }
            if matched.count == maps.count { result.append(matched) }
        }
        return result.sorted { $0[0].suffixBytes.lexicographicallyPrecedes($1[0].suffixBytes) }
    }

    /// Java's `entriesContainAllWithin`.
    static func containAllWithin(_ entries: [TextIndexEntry], _ maxDistance: Int) -> Bool {
        let lists = entries.map(\.positions).filter { !$0.isEmpty }
        // Empty lists mean "positions not kept"; if nothing has positions, assume close enough.
        if lists.isEmpty { return true }
        var cursors = lists.map { (value: $0[0], next: 1) }
        var maximum = cursors.map(\.value).max()!
        while true {
            let minIndex = cursors.indices.min { cursors[$0].value < cursors[$1].value }!
            if maximum - cursors[minIndex].value <= maxDistance { return true }
            let list = lists[minIndex]
            guard cursors[minIndex].next < list.count else { return false }
            cursors[minIndex] = (list[cursors[minIndex].next], cursors[minIndex].next + 1)
            maximum = max(maximum, cursors[minIndex].value)
        }
    }

    /// Java's `entriesContainPhrase`: positions must follow each other, stop words (and tokens
    /// without positions) counting as gaps.
    static func containPhrase(_ entries: [TextIndexEntry], _ tokensWithStopWords: [String]) -> Bool {
        var lists = entries.map(\.positions)
        var deltas: [Int] = []
        if tokensWithStopWords.contains("") || lists.contains(where: \.isEmpty) {
            var kept: [[Int]] = []
            var iterator = lists.makeIterator()
            var delta = 1
            for token in tokensWithStopWords {
                if token.isEmpty {
                    delta += 1
                } else if let list = iterator.next() {
                    if list.isEmpty {
                        delta += 1
                    } else {
                        kept.append(list)
                        deltas.append(delta)
                        delta = 1
                    }
                }
            }
            lists = kept
        } else {
            deltas = Array(repeating: 1, count: lists.count)
        }
        if lists.isEmpty { return true }
        var current = lists.map { $0[0] }
        var next = Array(repeating: 1, count: lists.count)
        while true {
            var expected = current[0]
            var allMatched = true
            for i in 1..<max(1, current.count) {
                expected += deltas[i]
                var value = current[i]
                while value < expected && next[i] < lists[i].count {
                    value = lists[i][next[i]]
                    next[i] += 1
                }
                if value < expected { return false }
                current[i] = value
                if value > expected {
                    allMatched = false
                    break
                }
            }
            if allMatched { return true }
            guard next[0] < lists[0].count else { return false }
            current[0] = lists[0][next[0]]
            next[0] += 1
        }
    }
}
#endif
