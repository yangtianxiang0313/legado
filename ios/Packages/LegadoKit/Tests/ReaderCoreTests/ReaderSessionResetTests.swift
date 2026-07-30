import Testing
@testable import ReaderCore

@Suite("Reader session reset")
struct ReaderSessionResetTests {
  @Test("restores remote source, progress and accumulated read time")
  func restoresRemoteSession() {
    let result = AndroidReaderSessionResetPolicy.reset(
      input(
        chapterCount: 3,
        storedIndex: 1,
        storedPosition: 42,
        source: ReaderSessionSource(url: "source", imageStyle: "FULL"),
        readDurations: [120, 80]
      )
    )

    #expect(result.runtimeChapterIndex == 1)
    #expect(result.runtimeChapterPosition == 42)
    #expect(result.sourceURL == "source")
    #expect(result.bookImageStyle == "FULL")
    #expect(result.readRecordTime == 200)
  }

  @Test("clamps oversized chapter without mutating stored progress")
  func clampsOversizedIndex() {
    let result = AndroidReaderSessionResetPolicy.reset(
      input(chapterCount: 3, storedIndex: 99, storedPosition: 777)
    )

    #expect(result.runtimeChapterIndex == 2)
    #expect(result.storedChapterIndex == 99)
    #expect(result.runtimeChapterPosition == 777)
  }

  @Test("empty table of contents clamps to zero")
  func clampsEmptyTOC() {
    let result = AndroidReaderSessionResetPolicy.reset(
      input(chapterCount: 0, storedIndex: 9)
    )
    #expect(result.runtimeChapterIndex == 0)
  }

  @Test("local book clears a stale remote source")
  func clearsSourceForLocalBook() {
    let result = AndroidReaderSessionResetPolicy.reset(
      input(
        chapterCount: 2,
        storedIndex: -4,
        isLocal: true,
        source: ReaderSessionSource(url: "stale", imageStyle: "FULL")
      )
    )

    #expect(result.runtimeChapterIndex == 0)
    #expect(result.sourceURL == nil)
    #expect(result.bookImageStyle == nil)
  }

  @Test("missing remote source fails closed")
  func missingSourceFailsClosed() {
    let result = AndroidReaderSessionResetPolicy.reset(
      input(chapterCount: 2, storedIndex: 1, source: nil)
    )
    #expect(result.sourceURL == nil)
    #expect(result.bookImageStyle == nil)
  }

  @Test("explicit image style wins and volatile state is reset")
  func preservesExplicitStyleAndResetsVolatileState() {
    let result = AndroidReaderSessionResetPolicy.reset(
      input(
        chapterCount: 2,
        storedIndex: 0,
        bookImageStyle: "BOOK_STYLE",
        source: ReaderSessionSource(
          url: "source",
          imageStyle: "SOURCE_STYLE"
        )
      )
    )

    #expect(result.bookImageStyle == "BOOK_STYLE")
    #expect(result.textChaptersCleared)
    #expect(result.temporaryProgressCleared)
    #expect(result.loadingChaptersCleared)
    #expect(result.downloadStatePreserved)
    #expect(
      result.effects == [
        .refreshMenu,
        .refreshPageAnimation(updateRecorder: false),
      ]
    )
  }

  private func input(
    chapterCount: Int,
    storedIndex: Int,
    storedPosition: Int = 0,
    isLocal: Bool = false,
    bookImageStyle: String? = nil,
    source: ReaderSessionSource? = ReaderSessionSource(
      url: "source",
      imageStyle: nil
    ),
    readDurations: [Int] = []
  ) -> ReaderSessionResetInput {
    ReaderSessionResetInput(
      bookIdentity: "book",
      bookName: "Book",
      chapterCount: chapterCount,
      storedChapterIndex: storedIndex,
      storedChapterPosition: storedPosition,
      isLocalBook: isLocal,
      bookImageStyle: bookImageStyle,
      source: source,
      readDurations: readDurations
    )
  }
}
