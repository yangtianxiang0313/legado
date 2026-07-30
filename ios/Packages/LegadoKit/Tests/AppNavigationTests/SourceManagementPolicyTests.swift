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

  @MainActor
  func testSourceUserVariableSurvivesDefinitionReplacement()
    async throws
  {
    let repository = SourceVariableCatalogRepository()
    let catalog = SourceCatalog(repository: repository)
    await catalog.reload()

    let saved = await catalog.saveUserVariable(
      "user-state",
      sourceID: "source-1"
    )
    XCTAssertTrue(saved)
    var replacement = BookSourceDraft(
      sourceURL: "source-1",
      name: "Reimported"
    )
    replacement.userVariable = "must-not-enter-definition"
    try await repository.replaceSources([replacement])
    await catalog.reload()

    XCTAssertEqual(
      catalog.source(id: "source-1")?.userVariable,
      "user-state"
    )
    let encoded = try JSONEncoder().encode(replacement)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded)
        as? [String: Any]
    )
    XCTAssertNil(object["userVariable"])
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

private actor SourceVariableCatalogRepository:
  SourceCatalogRepository
{
  private var sources = [
    BookSourceDraft(sourceURL: "source-1", name: "Original")
  ]
  private var variables: [String: String] = [:]

  func loadSources() async throws -> [BookSourceDraft] {
    sources
  }

  func saveSource(_ source: BookSourceDraft) async throws {
    try await saveSources([source])
  }

  func saveSources(_ incoming: [BookSourceDraft]) async throws {
    for source in incoming {
      if let index = sources.firstIndex(where: {
        $0.sourceURL == source.sourceURL
      }) {
        sources[index] = source
      } else {
        sources.append(source)
      }
    }
  }

  func replaceSources(_ sources: [BookSourceDraft]) async throws {
    self.sources = sources
  }

  func resetSources() async throws {
    sources = []
  }

  func loadSourceUserVariables() async throws -> [String: String] {
    variables
  }

  func saveSourceUserVariable(
    _ variable: String?,
    sourceID: String
  ) async throws {
    variables[sourceID] = variable
  }
}
