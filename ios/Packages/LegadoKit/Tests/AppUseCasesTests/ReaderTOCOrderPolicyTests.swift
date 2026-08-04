import AppUseCases
import LibraryDomain
import Testing

@Suite("Reader TOC order policy")
struct ReaderTOCOrderPolicyTests {
  @Test func reversesAndReindexesWithoutChangingChapterIdentity() {
    let bookID = BookID(rawValue: "book")
    let chapters = [
      chapter("one", index: 0, bookID: bookID),
      chapter("two", index: 1, bookID: bookID),
      chapter("three", index: 2, bookID: bookID),
    ]

    let projected = ReaderTOCOrderPolicy.ordered(chapters, reversed: true)

    #expect(projected.map(\.id.rawValue) == ["three", "two", "one"])
    #expect(projected.map(\.index) == [0, 1, 2])
    #expect(projected.map(\.title) == ["three", "two", "one"])
    #expect(projected.map(\.url) == ["/three", "/two", "/one"])
  }

  @Test func sourceOrderIsDeterministicBeforeProjection() {
    let bookID = BookID(rawValue: "book")
    let chapters = [
      chapter("three", index: 2, bookID: bookID),
      chapter("one", index: 0, bookID: bookID),
      chapter("two", index: 1, bookID: bookID),
    ]

    #expect(
      ReaderTOCOrderPolicy.ordered(chapters, reversed: false)
        .map(\.id.rawValue) == ["one", "two", "three"]
    )
  }

  @Test func sourceMigrationKeepsTheSelectedChapterAfterReversal() {
    let bookID = BookID(rawValue: "book")
    let chapters = [
      chapter("one", index: 0, bookID: bookID),
      chapter("two", index: 1, bookID: bookID),
      chapter("three", index: 2, bookID: bookID),
    ]
    let projection = ReaderTOCOrderPolicy.migrating(
      chapters,
      progress: ReadingProgress(
        position: ReadingPosition(chapterIndex: 0, characterOffset: 17),
        chapterTitle: "one",
        updatedAtMilliseconds: 99
      ),
      reversed: true
    )

    #expect(projection.chapters.map(\.id.rawValue) == ["three", "two", "one"])
    #expect(projection.progress.position.chapterIndex == 2)
    #expect(projection.progress.position.characterOffset == 17)
    #expect(projection.progress.chapterTitle == "one")
  }

  private func chapter(
    _ value: String,
    index: Int,
    bookID: BookID
  ) -> BookChapter {
    BookChapter(
      id: ChapterID(rawValue: value),
      bookID: bookID,
      sourceID: "source",
      index: index,
      title: value,
      url: "/\(value)"
    )
  }
}
