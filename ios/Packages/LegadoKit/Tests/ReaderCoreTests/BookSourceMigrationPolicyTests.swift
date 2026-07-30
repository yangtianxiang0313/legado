import LibraryDomain
import ReaderCore
import XCTest

final class BookSourceMigrationPolicyTests: XCTestCase {
  func testShelfMigrationCopiesUserStateAndBecomesDurable() throws {
    let result = try AndroidBookSourceMigrationPolicy.migrate(
      oldBook: oldBook(),
      candidate: candidate(),
      targetChapters: chapters(),
      inBookshelf: true
    )

    XCTAssertEqual(result.book.sourceURL, "source://new")
    XCTAssertEqual(result.book.progress?.position.chapterIndex, 1)
    XCTAssertEqual(result.book.progress?.position.characterOffset, 37)
    XCTAssertEqual(result.book.progress?.chapterTitle, "Chapter 1")
    XCTAssertEqual(result.book.userState.groupID, 5)
    XCTAssertFalse(result.book.userState.canUpdate)
    XCTAssertFalse(result.book.hasUpdateError)
    XCTAssertFalse(result.observation.oldBookPersisted)
    XCTAssertTrue(result.observation.newBookPersisted)
    XCTAssertEqual(result.observation.newChapterCount, 3)
    XCTAssertTrue(result.observation.updateErrorRemoved)
  }

  func testTransientMigrationDoesNotClearCandidateUpdateError() throws {
    let result = try AndroidBookSourceMigrationPolicy.migrate(
      oldBook: oldBook(),
      candidate: candidate(),
      targetChapters: chapters(),
      inBookshelf: false
    )

    XCTAssertFalse(result.observation.newBookPersisted)
    XCTAssertEqual(result.observation.newChapterCount, 0)
    XCTAssertEqual(result.observation.visibleChapterCount, 3)
    XCTAssertTrue(result.book.hasUpdateError)
    XCTAssertFalse(result.observation.updateErrorRemoved)
  }

  func testEmptyTargetTOCIsRejectedBeforeProductMutation() {
    XCTAssertThrowsError(
      try AndroidBookSourceMigrationPolicy.migrate(
        oldBook: oldBook(),
        candidate: candidate(),
        targetChapters: [],
        inBookshelf: true
      )
    ) { error in
      XCTAssertEqual(
        error as? BookSourceMigrationError,
        .emptyTargetTableOfContents(remappedIndex: 1)
      )
    }
  }

  private func oldBook() -> SourceMigrationBook {
    SourceMigrationBook(
      id: BookID(rawValue: "book://old"),
      sourceURL: "source://old",
      title: "Book",
      author: "Author",
      progress: ReadingProgress(
        position: ReadingPosition(
          chapterIndex: 1,
          characterOffset: 37
        ),
        chapterTitle: "Chapter 1",
        updatedAtMilliseconds: 123
      ),
      totalChapterCount: 3,
      userState: SourceMigrationUserState(
        groupID: 5,
        order: -7,
        customCoverURL: "cover://custom",
        customIntro: "intro",
        customTag: "tag",
        canUpdate: false,
        reverseTOC: true
      )
    )
  }

  private func candidate() -> SourceMigrationBook {
    SourceMigrationBook(
      id: BookID(rawValue: "book://new"),
      sourceURL: "source://new",
      title: "Book",
      author: "Author",
      totalChapterCount: 3,
      hasUpdateError: true
    )
  }

  private func chapters() -> [SourceMigrationChapter] {
    (0..<3).map {
      SourceMigrationChapter(
        id: ChapterID(rawValue: "chapter://\($0)"),
        title: "Chapter \($0)",
        index: $0
      )
    }
  }
}
