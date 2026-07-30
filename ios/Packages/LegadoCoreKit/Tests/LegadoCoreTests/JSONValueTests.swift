import Foundation
import XCTest

@testable import LegadoCore

final class JSONValueTests: XCTestCase {
  func testRoundTripPreservesEveryJSONKind() throws {
    let value = JSONValue.object([
      "null": .null,
      "bool": .bool(false),
      "number": .number(try JSONNumber(validating: "9007199254740993")),
      "string": .string("9007199254740993"),
      "array": .array([.number(JSONNumber(0)), .string("")]),
      "object": .object([:]),
    ])

    let data = try JSONEncoder().encode(value)
    XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
  }

  func testMissingNullEmptyAndValueRemainDistinct() throws {
    let data = Data(#"{"null":null,"emptyString":"","emptyArray":[],"emptyObject":{},"value":0}"#.utf8)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

    guard case .object(let object) = decoded else {
      return XCTFail("Expected object")
    }
    XCTAssertNil(object["missing"])
    XCTAssertEqual(object["null"], .null)
    XCTAssertEqual(object["emptyString"], .string(""))
    XCTAssertEqual(object["emptyArray"], .array([]))
    XCTAssertEqual(object["emptyObject"], .object([:]))
    XCTAssertEqual(object["value"], .number(JSONNumber(0)))
  }

  func testBooleanDoesNotDecodeAsNumber() throws {
    let decoded = try JSONDecoder().decode(JSONValue.self, from: Data("true".utf8))
    XCTAssertEqual(decoded, .bool(true))
  }

  func testExactCodecPreservesNumbersBeyondFoundationRanges() throws {
    let input = Data(
      #"{"hugeExponent":1e500,"hugeInteger":12345678901234567890123456789012345678901234567890,"preciseDecimal":0.123456789012345678901234567890123456789}"#
        .utf8
    )

    let decoded = try JSONValueCodec.decode(input)
    let encoded = try JSONValueCodec.encode(decoded)

    XCTAssertEqual(encoded, input)
  }

  func testJSONNumberRejectsInvalidGrammarAndDuplicateObjectKeys() throws {
    for token in ["+1", "01", ".1", "1.", "1e", "NaN", "Infinity"] {
      XCTAssertThrowsError(try JSONNumber(validating: token), "Expected rejection for \(token)")
    }

    XCTAssertThrowsError(try JSONValueCodec.decode(Data(#"{"key":1,"key":2}"#.utf8)))
  }

  func testEquivalentNumberTokensCompareEqual() throws {
    XCTAssertEqual(try JSONNumber(validating: "1"), try JSONNumber(validating: "1.0"))
    XCTAssertEqual(try JSONNumber(validating: "1"), try JSONNumber(validating: "1e0"))
    XCTAssertEqual(try JSONNumber(validating: "-0"), try JSONNumber(validating: "0"))
  }
}
