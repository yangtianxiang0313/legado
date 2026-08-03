import Foundation
import LibraryDomain
import XCTest

final class LocalTextTOCRuleInteropTests: XCTestCase {
  func testImportedEnabledRuleWithMostMatchesDrivesChapters() throws {
    let data = Data("序章\nintro\n@@ Alpha\none\n@@ Beta\ntwo".utf8)
    let document = try LocalTextBookParser.parse(
      data,
      splitLongChapters: false,
      tocRules: [
        .init(id: 1, name: "standard", rule: "^序章$", serialNumber: 0),
        .init(id: 2, name: "custom", rule: "^@@ .+$", serialNumber: 1),
        .init(
          id: 3,
          name: "disabled",
          rule: "^(?:序章|@@ .+)$",
          serialNumber: 2,
          isEnabled: false
        ),
      ]
    )

    XCTAssertEqual(document.chapters.map(\.title), ["前言", "@@ Alpha", "@@ Beta"])
  }

  func testAndroidReverseScanLetsLowerSerialRuleWinEqualMatchCount() throws {
    let data = Data("# One\na\n@ One\nb\n# Two\nc\n@ Two\nd".utf8)
    let document = try LocalTextBookParser.parse(
      data,
      splitLongChapters: false,
      tocRules: [
        .init(id: 1, name: "hash", rule: "^# .+$", serialNumber: 0),
        .init(id: 2, name: "at", rule: "^@ .+$", serialNumber: 1),
      ]
    )

    XCTAssertEqual(document.chapters.map(\.title), ["# One", "# Two"])
    XCTAssertTrue(document.chapters[0].content.contains("@ One"))
  }
}
