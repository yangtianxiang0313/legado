public struct SourceMigrationUserState: Equatable, Sendable {
  public var groupID: Int64
  public var order: Int64
  public var customCoverURL: String?
  public var customIntro: String?
  public var customTag: String?
  public var canUpdate: Bool
  public var reverseTOC: Bool

  public init(
    groupID: Int64 = 0,
    order: Int64 = 0,
    customCoverURL: String? = nil,
    customIntro: String? = nil,
    customTag: String? = nil,
    canUpdate: Bool = true,
    reverseTOC: Bool = false
  ) {
    self.groupID = groupID
    self.order = order
    self.customCoverURL = customCoverURL
    self.customIntro = customIntro
    self.customTag = customTag
    self.canUpdate = canUpdate
    self.reverseTOC = reverseTOC
  }
}

public struct SourceMigrationBook: Equatable, Sendable {
  public let id: BookID
  public let sourceURL: String
  public let title: String
  public let author: String
  public var progress: ReadingProgress?
  public var totalChapterCount: Int
  public var userState: SourceMigrationUserState
  public var hasUpdateError: Bool

  public init(
    id: BookID,
    sourceURL: String,
    title: String,
    author: String,
    progress: ReadingProgress? = nil,
    totalChapterCount: Int = 0,
    userState: SourceMigrationUserState = .init(),
    hasUpdateError: Bool = false
  ) {
    self.id = id
    self.sourceURL = sourceURL
    self.title = title
    self.author = author
    self.progress = progress
    self.totalChapterCount = totalChapterCount
    self.userState = userState
    self.hasUpdateError = hasUpdateError
  }
}

public struct SourceMigrationChapter: Equatable, Sendable {
  public let id: ChapterID
  public let title: String
  public let index: Int

  public init(id: ChapterID, title: String, index: Int) {
    self.id = id
    self.title = title
    self.index = index
  }
}
