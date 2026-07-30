import XCTest

@testable import LegadoCore

final class StableIDsTests: XCTestCase {
  func testIDsUseSingleValueCodableRepresentation() throws {
    try assertRoundTrip(BookID(rawValue: "book-1"), expectedJSON: #""book-1""#)
    try assertRoundTrip(SourceID(rawValue: "https://source.example"), expectedJSON: #""https://source.example""#)
    try assertRoundTrip(ChapterID(rawValue: "chapter-1"), expectedJSON: #""chapter-1""#)
    try assertRoundTrip(TraceID(rawValue: "trace-1"), expectedJSON: #""trace-1""#)
  }

  func testIDsAndCoreValuesAreSendable() {
    requireSendable(BookID.self)
    requireSendable(SourceID.self)
    requireSendable(ChapterID.self)
    requireSendable(TraceID.self)
    requireSendable(JSONValue.self)
    requireSendable(AppIssue.self)
    requireSendable(Trace.self)
  }

  private func assertRoundTrip<Value: Codable & Equatable>(
    _ value: Value,
    expectedJSON: String
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let data = try encoder.encode(value)
    XCTAssertEqual(String(decoding: data, as: UTF8.self), expectedJSON)
    XCTAssertEqual(try JSONDecoder().decode(Value.self, from: data), value)
  }

  private func requireSendable<Value: Sendable>(_: Value.Type) {}
}
