public struct Bookmark: Equatable, Hashable, Sendable {
  public let time: Int64
  public let bookName: String
  public let bookAuthor: String
  public let chapterIndex: Int
  public let chapterPosition: Int
  public let chapterName: String
  public let bookText: String
  public let content: String

  public init(
    time: Int64,
    bookName: String = "",
    bookAuthor: String = "",
    chapterIndex: Int = 0,
    chapterPosition: Int = 0,
    chapterName: String = "",
    bookText: String = "",
    content: String = ""
  ) {
    self.time = time
    self.bookName = bookName
    self.bookAuthor = bookAuthor
    self.chapterIndex = chapterIndex
    self.chapterPosition = chapterPosition
    self.chapterName = chapterName
    self.bookText = bookText
    self.content = content
  }
}
