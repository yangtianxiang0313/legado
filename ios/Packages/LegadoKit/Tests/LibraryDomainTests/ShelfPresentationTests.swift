import LibraryDomain
import XCTest

final class ShelfPresentationTests: XCTestCase {
  func testAndroidShelfSortModesAndGroupOverride() {
    let books = [
      book("b", "张三", order: 20, updated: 300, read: 100),
      book("a", "阿明", order: 10, updated: 100, read: 400),
      book("c", "李四", order: 30, updated: 250, read: 260),
    ]

    XCTAssertEqual(
      ids(ShelfBookOrdering.sort(books, by: .recentlyRead)),
      ["a", "c", "b"]
    )
    XCTAssertEqual(
      ids(ShelfBookOrdering.sort(books, by: .recentlyUpdated)),
      ["b", "c", "a"]
    )
    XCTAssertEqual(
      ids(ShelfBookOrdering.sort(books, by: .name)),
      ["a", "c", "b"]
    )
    XCTAssertEqual(
      ids(ShelfBookOrdering.sort(books, by: .manual)),
      ["a", "b", "c"]
    )
    XCTAssertEqual(
      ids(ShelfBookOrdering.sort(books, by: .combinedTime)),
      ["a", "b", "c"]
    )
    XCTAssertEqual(
      ShelfGroupSortPreference(override: .manual)
        .resolved(global: .recentlyRead),
      .manual
    )
    XCTAssertEqual(
      ShelfGroupSortPreference(override: nil)
        .resolved(global: .recentlyUpdated),
      .recentlyUpdated
    )
  }

  func testEqualSortKeysRetainInputOrder() {
    let books = [
      book("first", "同名", order: 1, updated: 1, read: 1),
      book("second", "同名", order: 1, updated: 1, read: 1),
    ]

    for mode in ShelfSortMode.allCases {
      XCTAssertEqual(
        ids(ShelfBookOrdering.sort(books, by: mode)),
        ["first", "second"]
      )
    }
  }

  func testTOCGrowthNonGrowthAndReadClearMatchAndroid() {
    var status = ShelfChapterStatus(
      totalChapterCount: 3,
      currentChapterIndex: 1,
      latestCheckCount: 7,
      latestChapterTime: 10,
      lastReadTime: 20
    )

    XCTAssertEqual(
      status.observeTOC(chapterCount: 5, at: 30),
      .grew(by: 2)
    )
    XCTAssertEqual(status.latestCheckCount, 2)
    XCTAssertEqual(status.latestChapterTime, 30)
    XCTAssertEqual(status.unreadChapterCount, 3)

    XCTAssertEqual(
      status.observeTOC(chapterCount: 5, at: 40),
      .unchanged
    )
    XCTAssertEqual(status.latestCheckCount, 2)
    XCTAssertEqual(status.latestChapterTime, 30)

    XCTAssertEqual(
      status.observeTOC(chapterCount: 2, at: 50),
      .shrank(by: 3)
    )
    XCTAssertEqual(status.latestCheckCount, 2)
    XCTAssertEqual(status.latestChapterTime, 30)
    XCTAssertEqual(status.currentChapterIndex, 1)

    status.markRead(chapterIndex: 1, at: 60)
    XCTAssertEqual(status.latestCheckCount, 0)
    XCTAssertEqual(status.lastReadTime, 60)
    XCTAssertEqual(status.unreadChapterCount, 0)
  }

  private func book(
    _ id: String,
    _ name: String,
    order: Int64,
    updated: Int64,
    read: Int64
  ) -> ShelfPresentationBook {
    ShelfPresentationBook(
      id: BookID(rawValue: id),
      name: name,
      manualOrder: order,
      latestChapterTime: updated,
      lastReadTime: read
    )
  }

  private func ids(
    _ books: [ShelfPresentationBook]
  ) -> [String] {
    books.map(\.id.rawValue)
  }
}
