import LegadoCore
import XCTest

@testable import TestSupport

final class CanonicalJSONComparatorTests: XCTestCase {
  func testObjectKeyOrderDoesNotCreateDifference() throws {
    let expected = try json(#"{"b":2,"a":1}"#)
    let actual = try json(#"{"a":1,"b":2}"#)

    XCTAssertEqual(CanonicalJSONComparator.compare(expected: expected, actual: actual), .equal)
  }

  func testFirstDifferenceUsesStableRFC6901Escaping() throws {
    let expected = try json(#"{"result":{"a/b":{"~key":1,"z":false}}}"#)
    let actual = try json(#"{"result":{"a/b":{"~key":"1","z":false}}}"#)

    XCTAssertEqual(
      CanonicalJSONComparator.compare(expected: expected, actual: actual),
      .different(.init(kind: .typeMismatch, jsonPointer: "/result/a~1b/~0key"))
    )
  }

  func testArrayLengthDifferencePointsAtFirstMissingIndex() throws {
    let expected = try json(#"{"items":[1,2]}"#)
    let actual = try json(#"{"items":[1]}"#)

    XCTAssertEqual(
      CanonicalJSONComparator.compare(expected: expected, actual: actual),
      .different(.init(kind: .actualMissing, jsonPointer: "/items/1"))
    )
  }

  func testEquivalentJSONNumbersWithDifferentTokensAreNotCanonicalBytes() throws {
    let expected = try json(#"{"number":1}"#)
    let actual = try json(#"{"number":1.0}"#)

    XCTAssertEqual(
      CanonicalJSONComparator.compare(expected: expected, actual: actual),
      .different(.init(kind: .valueMismatch, jsonPointer: "/number"))
    )
  }

  func testMultipleDifferencesAlwaysReturnLexicallyFirstObjectPath() throws {
    let expected = try json(#"{"b":0,"a":{"z":0,"a":0}}"#)
    let actual = try json(#"{"b":1,"a":{"z":1,"a":1}}"#)
    let result = CanonicalJSONComparator.compare(expected: expected, actual: actual)

    XCTAssertEqual(
      result,
      .different(.init(kind: .valueMismatch, jsonPointer: "/a/a"))
    )
    XCTAssertEqual(result, CanonicalJSONComparator.compare(expected: expected, actual: actual))
  }

  private func json(_ source: String) throws -> JSONValue {
    try JSONValueCodec.decode(Data(source.utf8))
  }
}
