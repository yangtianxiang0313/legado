import AppUseCases
import Foundation
import XCTest

final class SourceManagementPolicyTests: XCTestCase {
  func testSelectionOperationsStayWithinVisibleSources() {
    let visible = ["0", "1", "2", "3"]

    XCTAssertEqual(
      SourceManagementPolicy.selectAll(visibleIDs: visible),
      Set(visible)
    )
    XCTAssertEqual(
      SourceManagementPolicy.invertSelection(
        Set(["1", "3", "outside"]),
        visibleIDs: visible
      ),
      Set(["0", "2"])
    )
    XCTAssertEqual(
      SourceManagementPolicy.fillSelectionInterval(
        Set(["1", "3"]),
        visibleIDs: visible
      ),
      Set(["1", "2", "3"])
    )
    XCTAssertEqual(
      SourceManagementPolicy.fillSelectionInterval(
        [],
        visibleIDs: visible
      ),
      []
    )
  }

  func testBatchMutationMatchesAndroidOrderAndGroupRules() {
    let sources = [
      source("0", order: 10),
      source("1", order: 20),
      source("2", order: 30),
      source("3", order: 40),
    ]
    let selected = Set(["1", "3"])

    let disabled = SourceManagementPolicy.applying(
      .setEnabled(false),
      to: sources,
      selectedIDs: selected
    )
    XCTAssertFalse(disabled[1].importMetadata?.enabled ?? true)
    XCTAssertFalse(disabled[3].importMetadata?.enabled ?? true)
    XCTAssertTrue(disabled[0].importMetadata?.enabled ?? false)

    let topped = SourceManagementPolicy.applying(
      .moveToTop,
      to: sources,
      selectedIDs: selected
    )
    XCTAssertEqual(topped[1].importMetadata?.customOrder, 9)
    XCTAssertEqual(topped[3].importMetadata?.customOrder, 8)

    let grouped = SourceManagementPolicy.applying(
      .addGroup("new"),
      to: sources,
      selectedIDs: selected
    )
    XCTAssertEqual(grouped[1].group, "keep,remove,new")
    let removed = SourceManagementPolicy.applying(
      .removeGroup("remove"),
      to: grouped,
      selectedIDs: selected
    )
    XCTAssertEqual(removed[1].group, "keep,new")
  }

  func testExportPreservesUnknownDefinitionFieldsAndSelection() throws {
    var first = source("0", order: 10)
    first.rawDefinition = Data(
      #"{"bookSourceUrl":"old","unknown":{"keep":true}}"#.utf8
    )
    let data = try SourceManagementPolicy.exportData(
      [first, source("1", order: 20)],
      selectedIDs: ["0"]
    )
    let values = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    )

    XCTAssertEqual(values.count, 1)
    XCTAssertEqual(values[0]["bookSourceUrl"] as? String, "0")
    XCTAssertNotNil(values[0]["unknown"])
  }

  private func source(_ id: String, order: Int32) -> BookSourceDraft {
    BookSourceDraft(
      sourceURL: id,
      name: "Source \(id)",
      group: "keep,remove",
      importMetadata: .init(
        enabled: true,
        enabledExplore: true,
        lastUpdateTime: Int64(order),
        customOrder: order
      )
    )
  }
}
