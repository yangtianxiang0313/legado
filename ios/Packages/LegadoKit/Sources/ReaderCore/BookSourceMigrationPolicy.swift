import LibraryDomain

public enum BookSourceMigrationError: Error, Equatable, Sendable {
  case emptyTargetTableOfContents(remappedIndex: Int)
}

public struct BookSourceMigrationObservation: Equatable, Sendable {
  public let sourceIdentityChanged: Bool
  public let oldBookPersisted: Bool
  public let newBookPersisted: Bool
  public let oldChapterCount: Int
  public let newChapterCount: Int
  public let visibleChapterCount: Int
  public let updateErrorRemoved: Bool

  public init(
    sourceIdentityChanged: Bool,
    oldBookPersisted: Bool,
    newBookPersisted: Bool,
    oldChapterCount: Int,
    newChapterCount: Int,
    visibleChapterCount: Int,
    updateErrorRemoved: Bool
  ) {
    self.sourceIdentityChanged = sourceIdentityChanged
    self.oldBookPersisted = oldBookPersisted
    self.newBookPersisted = newBookPersisted
    self.oldChapterCount = oldChapterCount
    self.newChapterCount = newChapterCount
    self.visibleChapterCount = visibleChapterCount
    self.updateErrorRemoved = updateErrorRemoved
  }
}

public struct BookSourceMigrationResult: Equatable, Sendable {
  public let book: SourceMigrationBook
  public let chapters: [SourceMigrationChapter]
  public let observation: BookSourceMigrationObservation

  public init(
    book: SourceMigrationBook,
    chapters: [SourceMigrationChapter],
    observation: BookSourceMigrationObservation
  ) {
    self.book = book
    self.chapters = chapters
    self.observation = observation
  }
}

public enum AndroidBookSourceMigrationPolicy {
  public static func migrate(
    oldBook: SourceMigrationBook,
    candidate: SourceMigrationBook,
    targetChapters: [SourceMigrationChapter],
    inBookshelf: Bool
  ) throws -> BookSourceMigrationResult {
    let oldProgress = oldBook.progress
    let remap = try AndroidReaderTOCRemapPolicy.remap(
      ReaderTOCRemapInput(
        oldChapterIndex: oldProgress?.position.chapterIndex ?? 0,
        oldChapterTitle: oldProgress?.chapterTitle,
        oldChapterListSize: oldBook.totalChapterCount,
        newChapterTitles: targetChapters.map(\.title)
      )
    )
    guard
      !targetChapters.isEmpty,
      targetChapters.indices.contains(remap.selectedIndex)
    else {
      throw BookSourceMigrationError.emptyTargetTableOfContents(
        remappedIndex: remap.selectedIndex
      )
    }

    var migrated = candidate
    migrated.progress = ReadingProgress(
      position: ReadingPosition(
        chapterIndex: remap.selectedIndex,
        characterOffset: oldProgress?.position.characterOffset ?? 0
      ),
      chapterTitle: targetChapters[remap.selectedIndex].title,
      updatedAtMilliseconds: oldProgress?.updatedAtMilliseconds ?? 0
    )
    migrated.userState = oldBook.userState
    if inBookshelf {
      migrated.hasUpdateError = false
    }
    return BookSourceMigrationResult(
      book: migrated,
      chapters: targetChapters,
      observation: BookSourceMigrationObservation(
        sourceIdentityChanged: oldBook.sourceURL != candidate.sourceURL,
        oldBookPersisted: false,
        newBookPersisted: inBookshelf,
        oldChapterCount: 0,
        newChapterCount: inBookshelf ? targetChapters.count : 0,
        visibleChapterCount: targetChapters.count,
        updateErrorRemoved: inBookshelf && !migrated.hasUpdateError
      )
    )
  }
}
