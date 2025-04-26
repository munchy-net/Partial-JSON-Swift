//
//  PartialJSONSwift.swift
//  PartialJSONSwift
//
//  A tiny, dependency-free utility for incrementally parsing streaming JSON.
//  Feed arbitrary text chunks (bytes, tokens, characters) into
//  `PartialJSONStream`, and it will publish the most recent *complete* JSON
//  value it could reconstruct without blocking on incomplete input.
//
//  You can restrict which JSON fragment types are considered acceptable while
//  the parser waits for more data via the `Allow` option set.  This is useful
//  for user interfaces that should remain responsive even when the incoming
//  data is malformed or arrives slowly (e.g. token-by-token LLM streaming).
//
//  All public symbols are documented inline.  ⌥-click a symbol in Xcode or open
//  Quick Help to view the corresponding API docs.
//

import Foundation
import Combine

// MARK: - Allow

/// A bit-mask describing which JSON fragment *types* may be returned when the
/// parser encounters **incomplete** input.
///
///   * If a type **is** included and the incoming data ends in the middle of a
///     value of that type, the parser returns a *partial* representation rather
///     than throwing `PartialJSONError.incomplete`.
///   * If a type **is not** included the parser defers, throwing
///     `PartialJSONError.incomplete`, so the caller can wait for more data.
///
/// Use the predefined convenience sets (`atom`, `collection`, `all`) for
/// typical use-cases instead of building the mask manually.
public struct Allow: OptionSet, Sendable {
    /// Raw bit pattern.
    public let rawValue: Int

    // Individual fragment kinds ------------------------------------------------
    /// String literals – e.g. `"hello"`.
    public static let str       = Allow(rawValue: 1 << 0)
    /// Ordinary numbers recognised by `JSONSerialization`.
    public static let num       = Allow(rawValue: 1 << 1)
    /// JSON arrays `[...]`.
    public static let arr       = Allow(rawValue: 1 << 2)
    /// JSON objects `{...}`.
    public static let obj       = Allow(rawValue: 1 << 3)
    /// The special literal `null`.
    public static let null      = Allow(rawValue: 1 << 4)
    /// Boolean literals `true` / `false`.
    public static let bool      = Allow(rawValue: 1 << 5)
    /// The non-standard literal `NaN`.
    public static let nan       = Allow(rawValue: 1 << 6)
    /// Positive infinity (`Infinity`).
    public static let infinity  = Allow(rawValue: 1 << 7)
    /// Negative infinity (`-Infinity`).
    public static let _infinity = Allow(rawValue: 1 << 8)

    // Convenience groups --------------------------------------------------------
    /// Both `Infinity` and `-Infinity`.
    public static let inf        : Allow = [.infinity, ._infinity]
    /// All non-numeric single-token literals (`null`, `true`, `false`, `NaN`, ±∞).
    public static let special    : Allow = [.null, .bool, .nan, .inf]
    /// "Atomic" values: strings, numbers and the `special` group.
    public static let atom       : Allow = [.str, .num, .special]
    /// Container values: arrays and objects.
    public static let collection : Allow = [.arr, .obj]
    /// Every fragment kind.
    public static let all        : Allow = [.atom, .collection]

    /// Designated initializer.
    public init(rawValue: Int) { self.rawValue = rawValue }
}

// MARK: - Error types

/// Thrown when the parser needs more characters to decide whether the current
/// fragment is valid JSON.
public enum PartialJSONError: Error, CustomStringConvertible, Sendable {
    /// The parser reached end-of-input while still inside *what*.
    case incomplete(String)

    public var description: String {
        switch self {
        case .incomplete(let what):
            return "Incomplete JSON – \(what)"
        }
    }
}

/// Thrown when the provided text can *never* form valid JSON (syntax error).
public enum MalformedJSONError: Error, CustomStringConvertible, Sendable {
    /// A user-friendly description of the syntax error.
    case malformed(String)

    public var description: String {
        switch self {
        case .malformed(let what):
            return "Malformed JSON – \(what)"
        }
    }
}

// MARK: - Synchronous parsing helper

/// Parses **all** of `text` as JSON and returns the corresponding Foundation
/// value (`String`, `NSNumber`, `[Any]`, `[String: Any]`, or `NSNull`).
///
/// The function throws:
///  * `MalformedJSONError` – the syntax rules of JSON were violated.
///  * `PartialJSONError.incomplete` – the input ended before a value finished
///    *and* the unfinished value’s kind is *not* contained in `allow`.
@discardableResult
public func parseJSON(_ text: String, allow: Allow = .all) throws -> Any {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw MalformedJSONError.malformed("empty input")
    }
    var scanner = Scanner(trimmed, allow: allow)
    return try scanner.parseValue()
}

// MARK: - Observable streaming wrapper

/// `ObservableObject` that incrementally builds JSON from an arbitrary stream
/// of `String` fragments (network frames, file chunks, LLM tokens, …).
///
/// Attach a `@StateObject` in SwiftUI and call `append(_:)` whenever new bytes
/// arrive.  The latest fully-formed snapshot is published through `current`.
@available(macOS 10.15, *)
@MainActor
public final class PartialJSONStream: ObservableObject, Sendable {

    /// The most recent *complete* snapshot or a parse error.
    @Published public private(set) var current: Any?

    private var lastGood: Any?
    private var buffer   = ""
    private let allow: Allow

    /// Create a new stream.
    /// - Parameter allow: Fragment kinds that may be returned unfinished while
    ///   awaiting more data.  Defaults to `Allow.all`.
    public init(allow: Allow = .all) { self.allow = allow }

    /// Feed the next raw text chunk into the parser.
    public func append(_ chunk: String) {
        buffer.append(chunk)
        do {
            let value = try parseJSON(buffer, allow: allow)
            current   = value
            lastGood  = value
        } catch is PartialJSONError {
            // Still waiting – surface the last confirmed snapshot.
            if let good = lastGood { current = good }
        } catch {
            // Fatal syntax error – surface it and stop updating.
            current = error
        }
    }

    /// Reset **all** internal state (buffer and snapshots).
    public func clear() {
        buffer.removeAll(keepingCapacity: true)
        current  = nil
        lastGood = nil
    }
}

// MARK: - Lexer / recursive-descent parser (internal)

/// Internal helper that does the heavy lifting.  Single-pass, zero-allocation
/// recursive-descent parser.  NOT thread-safe – call through `parseJSON`.
private struct Scanner {
    private let chars: [Character]
    private var i: Int = 0
    private let allow: Allow

    init(_ src: String, allow: Allow) {
        chars = Array(src)
        self.allow = allow
    }

    private var c: Character? { (i < chars.count) ? chars[i] : nil }
    @inline(__always) private mutating func advance() { i += 1 }
    @inline(__always) private mutating func skipWS() {
        while let ch = c, " \n\r\t".contains(ch) { advance() }
    }

    // Entry-point --------------------------------------------------------------
    mutating func parseValue() throws -> Any {
        skipWS()
        guard let ch = c else { throw PartialJSONError.incomplete("unexpected EOF") }

        switch ch {
        case "\"":              return try parseString()
        case "{":                 return try parseObject()
        case "[":                 return try parseArray()
        case "-", "0"..."9":   return try parseNumber()
        default:                   return try parseLiterals()
        }
    }

    // String ------------------------------------------------------------------
    private mutating func parseString() throws -> String {
        let start = i
        var escape = false
        advance() // skip opening quote

        while let ch = c {
            if ch == "\\" { escape.toggle(); advance(); continue }
            if ch == "\"", !escape {
                advance()
                let slice = String(chars[start..<i])
                // Use JSONSerialization to unescape sequences correctly.
                return try JSONSerialization.jsonObject(
                    with: Data(slice.utf8),
                    options: [.fragmentsAllowed]) as! String
            }
            escape = false; advance()
        }

        // Ran out of input -----------------------------------------------------
        guard allow.contains(.str) else {
            throw PartialJSONError.incomplete("unterminated string")
        }
        // Return the *raw* (still-escaped) string sans opening quote.
        return String(chars[(start + 1)..<i])
    }

    // Number ------------------------------------------------------------------
    private mutating func parseNumber() throws -> Any {
        @inline(__always)
        func match(_ str: String) -> Bool {
            i + str.count <= chars.count &&
            String(chars[i..<i + str.count]) == str
        }
        @inline(__always)
        func prefix(_ str: String) -> Bool {
            let remain = chars.count - i
            return remain < str.count &&
                   str.hasPrefix(String(chars[i..<chars.count]))
        }

        // Handle non-standard ±∞ / NaN first so JSONSerialization doesn’t choke.
        if match("-Infinity") { i += 9; return -Double.infinity }
        if match("-NaN")      { i += 4; return -Double.nan     }
        if prefix("-Infinity") || prefix("-NaN") {
            throw PartialJSONError.incomplete("literal")
        }

        let start = i
        if c == "-" { advance() }
        while let ch = c, "-+.eE0123456789".contains(ch) {
            if ",]} \n\r\t".contains(ch) { break }
            advance()
        }
        var slice = String(chars[start..<i])

        // Try the cheap route first.
        if let val = try? JSONSerialization.jsonObject(
                        with: Data(slice.utf8), options: [.fragmentsAllowed]) {
            return val
        }

        // If JSONSerialization failed, we might be missing a digit.
        guard allow.contains(.num) else {
            throw PartialJSONError.incomplete("number literal")
        }

        // Trim trailing punctuation until it parses or we give up.
        while let last = slice.last, ".eE+-".contains(last) {
            slice.removeLast()
            if !slice.isEmpty,
               let val = try? JSONSerialization.jsonObject(
                           with: Data(slice.utf8), options: [.fragmentsAllowed]) {
                return val
            }
        }
        throw PartialJSONError.incomplete("number literal")
    }

    // Array -------------------------------------------------------------------
    private mutating func parseArray() throws -> [Any] {
        var result: [Any] = []
        advance(); skipWS()
        while c != nil, c != "]" {
            do {
                result.append(try parseValue())
            } catch let err as PartialJSONError {
                // Preserve positional integrity with a placeholder.
                result.append(NSNull())
                throw err
            }
            skipWS()
            if c == "," { advance(); skipWS() }
        }
        if c == "]" { advance() }
        else if !allow.contains(.arr) {
            throw PartialJSONError.incomplete("array")
        }
        return result
    }

    // Object ------------------------------------------------------------------
    private mutating func parseObject() throws -> [String: Any] {
        var result: [String: Any] = [:]
        advance(); skipWS()

        while c != nil, c != "}" {
            guard c == "\"" else {
                throw PartialJSONError.incomplete("object key")
            }
            let key = try parseString()
            skipWS()

            guard c == ":" else {
                throw PartialJSONError.incomplete("missing ':'")
            }
            advance(); skipWS()

            do {
                result[key] = try parseValue()
                skipWS()
                if c == "," { advance(); skipWS() }
            } catch let err as PartialJSONError {
                result[key] = NSNull()
                throw err
            }
        }

        if c == "}" { advance() }
        else if !allow.contains(.obj) {
            throw PartialJSONError.incomplete("object")
        }
        return result
    }

    // Literals ----------------------------------------------------------------
    private mutating func parseLiterals() throws -> Any {
        @inline(__always)
        func match(_ full: String) -> Bool {
            i + full.count <= chars.count &&
            String(chars[i..<i + full.count]) == full
        }
        @inline(__always)
        func prefix(_ full: String) -> Bool {
            let remain = chars.count - i
            return remain < full.count &&
                   String(chars[i..<chars.count]) == full.prefix(remain)
        }

        switch true {
        case match("null"):
            i += 4; return NSNull()
        case match("true"):
            i += 4; return true
        case match("false"):
            i += 5; return false
        case match("Infinity"):
            i += 8; return Double.infinity
        case match("NaN"):
            i += 3; return Double.nan

        case prefix("null"), prefix("true"), prefix("false"),
             prefix("Infinity"), prefix("NaN"):
            throw PartialJSONError.incomplete("literal")

        default:
            throw MalformedJSONError.malformed("unexpected token")
        }
    }
}
