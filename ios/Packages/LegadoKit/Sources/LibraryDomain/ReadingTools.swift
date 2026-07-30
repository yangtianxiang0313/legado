public struct ReadingBookmark: Identifiable, Equatable, Hashable, Sendable {
  public let id: String
  public let bookID: BookID
  public let chapterID: ChapterID
  public let chapterIndex: Int
  public let characterOffset: Int
  public let chapterTitle: String
  public let excerpt: String
  public let createdAtMilliseconds: Int64

  public init(
    id: String,
    bookID: BookID,
    chapterID: ChapterID,
    chapterIndex: Int,
    characterOffset: Int,
    chapterTitle: String,
    excerpt: String,
    createdAtMilliseconds: Int64
  ) {
    self.id = id
    self.bookID = bookID
    self.chapterID = chapterID
    self.chapterIndex = max(0, chapterIndex)
    self.characterOffset = max(0, characterOffset)
    self.chapterTitle = chapterTitle
    self.excerpt = excerpt
    self.createdAtMilliseconds = createdAtMilliseconds
  }

  public static func stableID(
    bookID: BookID,
    chapterID: ChapterID,
    characterOffset: Int
  ) -> String {
    "\(bookID.rawValue)\u{1F}\(chapterID.rawValue)\u{1F}"
      + "\(max(0, characterOffset))"
  }
}

public struct ReaderSearchResult: Identifiable, Equatable, Sendable {
  public let id: String
  public let bookID: BookID
  public let chapterID: ChapterID
  public let chapterIndex: Int
  public let chapterTitle: String
  public let characterOffset: Int
  public let queryOffsetInExcerpt: Int
  public let excerpt: String

  public init(
    bookID: BookID,
    chapterID: ChapterID,
    chapterIndex: Int,
    chapterTitle: String,
    characterOffset: Int,
    queryOffsetInExcerpt: Int,
    excerpt: String
  ) {
    self.id = "\(chapterID.rawValue)#\(max(0, characterOffset))"
    self.bookID = bookID
    self.chapterID = chapterID
    self.chapterIndex = max(0, chapterIndex)
    self.chapterTitle = chapterTitle
    self.characterOffset = max(0, characterOffset)
    self.queryOffsetInExcerpt = max(0, queryOffsetInExcerpt)
    self.excerpt = excerpt
  }
}
