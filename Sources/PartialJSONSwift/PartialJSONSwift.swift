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

import Combine
import Foundation

// MARK: - Allow -------------------------------------------------------------

public struct Allow: OptionSet, Sendable {
  public let rawValue: Int

  public static let str = Self(rawValue: 1 << 0)
  public static let num = Self(rawValue: 1 << 1)
  public static let arr = Self(rawValue: 1 << 2)
  public static let obj = Self(rawValue: 1 << 3)
  public static let null = Self(rawValue: 1 << 4)
  public static let bool = Self(rawValue: 1 << 5)
  public static let nan = Self(rawValue: 1 << 6)
  public static let infinity = Self(rawValue: 1 << 7)
  public static let _infinity = Self(rawValue: 1 << 8)

  public static let inf: Self = [.infinity, ._infinity]
  public static let special: Self = [.null, .bool, .nan, .inf]
  public static let atom: Self = [.str, .num, .special]
  public static let collection: Self = [.arr, .obj]
  public static let all: Self = [.atom, .collection]

  public init(rawValue: Int) { self.rawValue = rawValue }
}

// MARK: - Errors ------------------------------------------------------------

public enum PartialJSONError: Error, CustomStringConvertible, Sendable {
  case incomplete(String)
  public var description: String {
    if case .incomplete(let w) = self { return "Incomplete JSON – \(w)" }
    return ""
  }
}

public enum MalformedJSONError: Error, CustomStringConvertible, Sendable {
  case malformed(String)
  public var description: String {
    if case .malformed(let w) = self { return "Malformed JSON – \(w)" }
    return ""
  }
}

// MARK: - Synchronous helper ------------------------------------------------

@discardableResult
public func parseJSON(_ text: String, allow: Allow = .all) throws -> Any {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else {
    throw MalformedJSONError.malformed("empty input")
  }
  var scanner = Scanner(trimmed, allow: allow)
  return try scanner.parseValue()
}

// MARK: - Streaming wrapper -------------------------------------------------

@available(macOS 10.15, *)
@MainActor
public final class PartialJSONStream: ObservableObject, Sendable {

  @Published public private(set) var current: Any?

  private var lastGood: Any?
  private var buffer = ""
  private let allow: Allow

  public init(allow: Allow = .all) { self.allow = allow }

  public func append(_ chunk: String) {
    buffer.append(chunk)
    do {
      let value = try parseJSON(buffer, allow: allow)
      current = value
      lastGood = value
    } catch is PartialJSONError {
      if let good = lastGood { current = good }
    } catch {
      current = error
    }
  }

  public func clear() {
    buffer.removeAll(keepingCapacity: true)
    current = nil
    lastGood = nil
  }
}

// MARK: - Recursive‑descent parser ------------------------------------------

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

  // Entry ------------------------------------------------------------------
  mutating func parseValue() throws -> Any {
    skipWS()
    guard let ch = c else { throw PartialJSONError.incomplete("unexpected EOF") }

    switch ch {
    case "\"": return try parseString()
    case "{": return try parseObject()
    case "[": return try parseArray()
    case "-", "0"..."9": return try parseNumber()
    default: return try parseLiterals()
    }
  }

  // String -----------------------------------------------------------------
  private mutating func parseString() throws -> String {
    let start = i
    var escape = false
    advance()

    while let ch = c {
      if ch == "\\" {
        escape.toggle()
        advance()
        continue
      }
      if ch == "\"", !escape {
        advance()
        let slice = String(chars[start..<i])
        return try JSONSerialization.jsonObject(
          with: Data(slice.utf8),
          options: .fragmentsAllowed) as! String
      }
      escape = false
      advance()
    }

    guard allow.contains(.str) else {
      throw PartialJSONError.incomplete("unterminated string")
    }

    var slice = String(chars[(start + 1)..<i])
    while !slice.isEmpty {
      if let val = try? JSONSerialization.jsonObject(
        with: Data(("\"" + slice + "\"").utf8),
        options: .fragmentsAllowed) as? String
      {
        return val
      }
      slice.removeLast()
    }
    return ""
  }

  // Number -----------------------------------------------------------------
  private mutating func parseNumber() throws -> Any {
    @inline(__always) func match(_ s: String) -> Bool {
      i + s.count <= chars.count && String(chars[i..<i + s.count]) == s
    }
    @inline(__always) func prefix(_ s: String) -> Bool {
      let remain = chars.count - i
      return remain < s.count && s.hasPrefix(String(chars[i..<chars.count]))
    }

    // ±Infinity / NaN first
    if match("-Infinity") {
      i += 9
      return -Double.infinity
    }
    if match("-NaN") {
      i += 4
      return Double.nan
    }

    if prefix("-Infinity") {
      if allow.contains(._infinity) {
        i = chars.count
        return -Double.infinity
      }
      throw MalformedJSONError.malformed("unexpected -Infinity")
    }
    if prefix("-NaN") {
      if allow.contains(.nan) {
        i = chars.count
        return Double.nan
      }
      throw MalformedJSONError.malformed("unexpected NaN")
    }

    let start = i
    if c == "-" { advance() }
    while let ch = c, "-+.eE0123456789".contains(ch) {
      if ",]} \n\r\t".contains(ch) { break }
      advance()
    }
    var slice = String(chars[start..<i])

    if let val = try? JSONSerialization.jsonObject(
      with: Data(slice.utf8), options: .fragmentsAllowed)
    {
      return val
    }

    guard allow.contains(.num) else {
      throw PartialJSONError.incomplete("number literal")
    }

    while let last = slice.last, ".eE+-".contains(last) {
      slice.removeLast()
      if !slice.isEmpty,
        let val = try? JSONSerialization.jsonObject(
          with: Data(slice.utf8), options: .fragmentsAllowed)
      {
        return val
      }
    }
    throw PartialJSONError.incomplete("number literal")
  }

  // Array ------------------------------------------------------------------
  private mutating func parseArray() throws -> [Any] {
    var result: [Any] = []
    advance()
    skipWS()

    while c != nil, c != "]" {

      // --- optimistic placeholder for container values ----------------
      var placeholderIndex: Int? = nil
      if let ch = c, ch == "{" || ch == "[" {
        placeholderIndex = result.count
        result.append(NSNull())
      }

      do {
        let value = try parseValue()
        if let idx = placeholderIndex {
          result[idx] = value
        } else {
          result.append(value)
        }
      } catch let err as PartialJSONError {
        guard allow.contains(.arr) else { throw err }
        i = chars.count
        return result
      }

      skipWS()
      if c == "," {
        advance()
        skipWS()
      }
    }

    if c == "]" {
      advance()
    } else if !allow.contains(.arr) {
      throw PartialJSONError.incomplete("array")
    }
    return result
  }

  // Object -----------------------------------------------------------------
  private mutating func parseObject() throws -> [String: Any] {
    var result: [String: Any] = [:]
    var currentKey: String? = nil
    advance()
    skipWS()

    parsing: while true {
      guard let ch = c, ch != "}" else { break parsing }

      do {
        // ----- key --------------------------------------------------
        guard ch == "\"" else { throw PartialJSONError.incomplete("object key") }
        currentKey = try parseString()
        guard let key = currentKey else { throw PartialJSONError.incomplete("object key") }
        skipWS()

        // ----- colon ------------------------------------------------
        guard c == ":" else { throw PartialJSONError.incomplete("missing ':'") }
        advance()
        skipWS()

        // ----- value ------------------------------------------------
        result[key] = try parseValue()
        skipWS()

        if c == "," {
          advance()
          skipWS()
        }
      } catch let err as PartialJSONError {
        if let k = currentKey, result[k] == nil {
          result[k] = NSNull()
        }
        guard allow.contains(.obj) else { throw err }
        i = chars.count
        return result
      }
    }

    if c == "}" {
      advance()
    } else if !allow.contains(.obj) {
      throw PartialJSONError.incomplete("object")
    }
    return result
  }

  // Literals ---------------------------------------------------------------
  private mutating func parseLiterals() throws -> Any {
    @inline(__always) func match(_ s: String) -> Bool {
      i + s.count <= chars.count && String(chars[i..<i + s.count]) == s
    }
    @inline(__always) func prefix(_ s: String) -> Bool {
      let remain = chars.count - i
      return remain < s.count && s.hasPrefix(String(chars[i..<chars.count]))
    }
    @inline(__always) func acceptPartial<T>(
      _ flag: Allow,
      _ value: @autoclosure () -> T,
      name: String
    ) throws -> Any {
      if allow.contains(flag) {
        i = chars.count
        return value()
      }
      throw MalformedJSONError.malformed("unexpected \(name)")
    }

    switch true {
    // complete literals
    case match("null"):
      i += 4
      return NSNull()
    case match("true"):
      i += 4
      return true
    case match("false"):
      i += 5
      return false
    case match("-Infinity"):
      i += 9
      return -Double.infinity
    case match("Infinity"):
      i += 8
      return Double.infinity
    case match("NaN"):
      i += 3
      return Double.nan

    // partial openers
    case prefix("null"):
      return try acceptPartial(.null, NSNull(), name: "null")
    case prefix("true"):
      return try acceptPartial(.bool, true, name: "boolean")
    case prefix("false"):
      return try acceptPartial(.bool, false, name: "boolean")
    case prefix("-Infinity"):
      return try acceptPartial(._infinity, -Double.infinity, name: "-Infinity")
    case prefix("Infinity"):
      return try acceptPartial(.infinity, Double.infinity, name: "Infinity")
    case prefix("NaN"):
      return try acceptPartial(.nan, Double.nan, name: "NaN")

    default:
      throw MalformedJSONError.malformed("unexpected token")
    }
  }
}
