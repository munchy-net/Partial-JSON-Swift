import Testing
import Foundation
@testable import PartialJSONSwift

// MARK: - Helpers ------------------------------------------------------------

/// Return `Allow.all` minus the specified flag.
private func allow(excluding flag: Allow) -> Allow {
    var set: Allow = .all
    set.subtract(flag)
    return set
}

// MARK: - String fragments ---------------------------------------------------
@Test func partialString() throws {
    #expect(try parseJSON("\"", allow: .str) as! String == "")
    #expect(try parseJSON("\" \\x12", allow: .str) as! String == " ")
    #expect(throws: PartialJSONError.self) {
        _ = try parseJSON("\"", allow: allow(excluding: .str))
    }
}

// MARK: - Array fragments ----------------------------------------------------
@Test func partialArray() throws {
    let emptyArr = try parseJSON("[\"", allow: .arr) as! [Any]
    #expect(emptyArr.isEmpty)

    let arrWithStr = try parseJSON("[\"", allow: [.arr, .str]) as! [Any]
    #expect(arrWithStr.count == 1 && (arrWithStr[0] as? String) == "")

    #expect(throws: PartialJSONError.self) { _ = try parseJSON("[", allow: .str) }
    #expect(throws: PartialJSONError.self) { _ = try parseJSON("[\"", allow: .str) }
    #expect(throws: PartialJSONError.self) { _ = try parseJSON("[\"\"", allow: .str) }
    #expect(throws: PartialJSONError.self) { _ = try parseJSON("[\"\",", allow: .str) }
}

// MARK: - Object fragments ---------------------------------------------------
@Test func partialObject() throws {
    let emptyObj = try parseJSON("{\"\": \"", allow: .obj) as! [String: Any]
    #expect(emptyObj.isEmpty)

    let objWithStr = try parseJSON("{\"\": \"", allow: [.obj, .str]) as! [String: Any]
    #expect((objWithStr[""] as? String) == "")

    let srcs = ["{", "{\"", "{\"\"", "{\"\":", "{\"\":\"", "{\"\":\"\""]
    for s in srcs {
        #expect(throws: PartialJSONError.self) { _ = try parseJSON(s, allow: .str) }
    }
}

// MARK: - Singleton literals -------------------------------------------------
@Test func partialSingletons() throws {
    #expect(try parseJSON("n", allow: .null) is NSNull)
    #expect(throws: MalformedJSONError.self) { _ = try parseJSON("n", allow: allow(excluding: .null)) }

    #expect(try parseJSON("t", allow: .bool) as! Bool == true)
    #expect(throws: MalformedJSONError.self) { _ = try parseJSON("t", allow: allow(excluding: .bool)) }

    #expect(try parseJSON("f", allow: .bool) as! Bool == false)
    #expect(throws: MalformedJSONError.self) { _ = try parseJSON("f", allow: allow(excluding: .bool)) }

    #expect(try parseJSON("I", allow: .infinity) as! Double == .infinity)
    #expect(throws: MalformedJSONError.self) { _ = try parseJSON("I", allow: allow(excluding: .infinity)) }

    #expect(try parseJSON("-I", allow: ._infinity) as! Double == -.infinity)
    #expect(throws: MalformedJSONError.self) { _ = try parseJSON("-I", allow: allow(excluding: ._infinity)) }

    let nanVal = try parseJSON("N", allow: .nan) as! Double
    #expect(nanVal.isNaN)
    #expect(throws: MalformedJSONError.self) { _ = try parseJSON("N", allow: allow(excluding: .nan)) }
}

// MARK: - Number fragments ---------------------------------------------------
@Test func partialNumber() throws {
    #expect(try parseJSON("0", allow: allow(excluding: .num)) as! Int == 0)
    #expect(try parseJSON("-1.25e+4", allow: allow(excluding: .num)) as! Double == -1.25e4)

    #expect(try parseJSON("-1.25e+", allow: .num) as! Double == -1.25)
    #expect(try parseJSON("-1.25e", allow: .num) as! Double == -1.25)
}
