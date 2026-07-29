public struct ReadingPosition: Equatable, Hashable, Sendable {
  public let chapterIndex: Int
  public let characterOffset: Int

  public init(chapterIndex: Int, characterOffset: Int) {
    self.chapterIndex = chapterIndex
    self.characterOffset = characterOffset
  }
}

public struct ReadingProgress: Equatable, Hashable, Sendable {
  public let position: ReadingPosition
  public let chapterTitle: String?
  public let updatedAtMilliseconds: Int64

  public init(
    position: ReadingPosition,
    chapterTitle: String?,
    updatedAtMilliseconds: Int64
  ) {
    self.position = position
    self.chapterTitle = chapterTitle
    self.updatedAtMilliseconds = updatedAtMilliseconds
  }
}
