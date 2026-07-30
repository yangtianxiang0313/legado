import Foundation
import LegadoCore
import SourceFormat
import XCTest

final class BookSourceEditorCodecTests: XCTestCase {
  func testProjectionIncludesAllEditableRuleObjects()
    throws
  {
    let edit = try BookSourceEditorCodec.project(
      originalDefinition()
    )

    XCTAssertEqual(edit.sourceURL, "https://source.example")
    XCTAssertEqual(edit.name, "Original")
    XCTAssertEqual(edit.searchURL, "https://source.example/search")
    XCTAssertEqual(
      edit.searchRule,
      #"{"bookList":".book","futureNested":"kept","name":".name"}"#
    )
    XCTAssertEqual(
      edit.exploreRule,
      #"{"bookList":".explore"}"#
    )
    XCTAssertEqual(
      edit.bookInfoRule,
      #"{"name":"h1"}"#
    )
    XCTAssertEqual(
      edit.tocRule,
      #"{"chapterList":".chapter"}"#
    )
    XCTAssertEqual(
      edit.contentRule,
      ##"{"content":"#content"}"##
    )
  }

  func testWritebackChangesRulesAndPreservesUnknownFields()
    throws
  {
    let original = originalDefinition()
    var edit = try BookSourceEditorCodec.project(original)
    edit.name = "Edited"
    edit.group = "New Group"
    edit.enabled = false
    edit.customOrder = 99
    edit.searchRule =
      #"{"bookList":".result","name":".title","futureNested":"still-kept"}"#
    edit.contentRule = ""

    let updated = try BookSourceEditorCodec.applying(
      edit,
      to: original
    )
    let root = try object(updated)

    XCTAssertEqual(root["bookSourceName"], .string("Edited"))
    XCTAssertEqual(root["bookSourceGroup"], .string("New Group"))
    XCTAssertEqual(root["enabled"], .bool(false))
    XCTAssertEqual(
      root["futureRoot"],
      .object(["extension": .string("preserved")])
    )
    XCTAssertNil(root["ruleContent"])
    XCTAssertEqual(
      root["ruleSearch"],
      .object([
        "bookList": .string(".result"),
        "name": .string(".title"),
        "futureNested": .string("still-kept"),
      ])
    )
    XCTAssertEqual(
      try BookSourceEditorCodec.project(updated).searchRule,
      #"{"bookList":".result","futureNested":"still-kept","name":".title"}"#
    )
  }

  func testNewSourceCanBeCreatedAndInvalidRuleFailsClosed()
    throws
  {
    let edit = BookSourceEditableDefinition(
      sourceURL: "https://new.example",
      name: "New",
      searchRule: #"{"bookList":".book"}"#
    )
    let created = try BookSourceEditorCodec.applying(
      edit,
      to: nil
    )
    XCTAssertEqual(
      try object(created)["ruleSearch"],
      .object(["bookList": .string(".book")])
    )

    var invalid = edit
    invalid.tocRule = #"["not","an","object"]"#
    XCTAssertThrowsError(
      try BookSourceEditorCodec.applying(
        invalid,
        to: created
      )
    ) { error in
      XCTAssertEqual(
        error as? BookSourceEditorCodecError,
        .invalidRuleObject("ruleToc")
      )
    }
  }

  private func originalDefinition() -> Data {
    Data(
      #"""
      {
        "bookSourceUrl": "https://source.example",
        "bookSourceName": "Original",
        "bookSourceGroup": "Old Group",
        "searchUrl": "https://source.example/search",
        "exploreUrl": "全部::https://source.example/all",
        "enabled": true,
        "enabledExplore": true,
        "customOrder": 7,
        "lastUpdateTime": 42,
        "ruleSearch": {
          "bookList": ".book",
          "name": ".name",
          "futureNested": "kept"
        },
        "ruleExplore": {"bookList": ".explore"},
        "ruleBookInfo": {"name": "h1"},
        "ruleToc": {"chapterList": ".chapter"},
        "ruleContent": {"content": "#content"},
        "futureRoot": {"extension": "preserved"}
      }
      """#.utf8
    )
  }

  private func object(
    _ data: Data
  ) throws -> [String: JSONValue] {
    guard
      case .object(let object) =
        try JSONValueCodec.decode(data)
    else {
      throw SourceFormatError.expectedObject
    }
    return object
  }
}
