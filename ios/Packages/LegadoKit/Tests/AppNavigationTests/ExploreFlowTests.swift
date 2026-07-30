import AppUseCases
import XCTest

final class ExploreFlowTests: XCTestCase {
  @MainActor
  func testSessionSelectsFirstCategoryAndAdvancesPages() async {
    let source = ExploreSourceSummary(
      id: "source://explore",
      name: "发现源",
      group: "测试"
    )
    let session = ExploreSession(
      source: source,
      executor: ExploreExecutor(source: source)
    )

    session.start()
    await waitUntil { session.loadingState == .idle }

    XCTAssertEqual(session.categories.map(\.title), ["精选", "完本"])
    XCTAssertEqual(session.selectedCategory?.title, "精选")
    XCTAssertEqual(session.results.map(\.name), ["第 1 页"])
    XCTAssertEqual(session.nextPage, 2)
    XCTAssertTrue(session.canLoadMore)

    session.loadNextPage()
    await waitUntil { session.loadingState == .idle }

    XCTAssertEqual(session.results.map(\.name), ["第 1 页", "第 2 页"])
    XCTAssertEqual(session.nextPage, 3)
  }

  @MainActor
  private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool
  ) async {
    for _ in 0..<100 where !condition() {
      await Task.yield()
    }
    XCTAssertTrue(condition())
  }
}

private struct ExploreExecutor: ExploreBooksExecuting {
  let source: ExploreSourceSummary

  var sources: [ExploreSourceSummary] { [source] }

  func categories(sourceID: String) throws -> [ExploreCategoryItem] {
    [
      ExploreCategoryItem(
        id: "\(sourceID)#featured",
        title: "精选",
        urlTemplate: "https://example.test/{{page}}"
      ),
      ExploreCategoryItem(
        id: "\(sourceID)#finished",
        title: "完本",
        urlTemplate: "https://example.test/finished/{{page}}"
      ),
    ]
  }

  func loadPage(
    sourceID: String,
    category: ExploreCategoryItem,
    page: Int
  ) async throws -> [SearchResult] {
    [
      SearchResult(
        id: "\(sourceID)/\(category.id)/\(page)",
        name: "第 \(page) 页",
        author: "作者",
        kind: "类型",
        lastChapter: "章节",
        intro: "简介",
        bookURL: "https://example.test/book/\(page)",
        coverURL: nil,
        origin: sourceID,
        originName: source.name,
        originCount: 1
      )
    ]
  }
}
