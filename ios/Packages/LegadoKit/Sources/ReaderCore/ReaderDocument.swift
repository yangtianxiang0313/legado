import LibraryDomain

public struct ReaderPosition: Equatable, Sendable {
  public let bookID: BookID
  public let chapterID: ChapterID
  public let chapterIndex: Int
  public let characterOffset: Int

  public init(
    bookID: BookID,
    chapterID: ChapterID,
    chapterIndex: Int,
    characterOffset: Int
  ) {
    self.bookID = bookID
    self.chapterID = chapterID
    self.chapterIndex = max(0, chapterIndex)
    self.characterOffset = max(0, characterOffset)
  }
}

public struct ReaderDocument: Equatable, Sendable {
  public let position: ReaderPosition
  public let title: String
  public let content: String
  public let imageStyle: String?

  public init(
    position: ReaderPosition,
    title: String,
    content: String,
    imageStyle: String? = nil
  ) {
    self.position = position
    self.title = title
    self.content = content
    self.imageStyle = imageStyle
  }
}

public enum ReaderTOCCompletion: Equatable, Sendable {
  case canceled
  case accepted
}

public enum ReaderTOCProducer: Equatable, Sendable {
  case nullPayload
  case emptyPayload
  case chapter
  case bookmark
  case reverse
}

public struct ReaderTOCSelection: Equatable, Sendable {
  public let chapterIndex: Int
  public let characterOffset: Int
  public let chapterChanged: Bool

  public init(
    chapterIndex: Int,
    characterOffset: Int,
    chapterChanged: Bool
  ) {
    self.chapterIndex = max(0, chapterIndex)
    self.characterOffset = max(0, characterOffset)
    self.chapterChanged = chapterChanged
  }
}

public enum ReaderTOCHandoffPolicy {
  public static func selection(
    completion: ReaderTOCCompletion,
    producer: ReaderTOCProducer,
    selectedIndex: Int? = nil,
    currentIndex: Int? = nil,
    characterOffset: Int? = nil
  ) -> ReaderTOCSelection? {
    guard completion == .accepted, producer != .nullPayload else {
      return nil
    }

    switch producer {
    case .nullPayload:
      return nil
    case .emptyPayload:
      return ReaderTOCSelection(
        chapterIndex: 0,
        characterOffset: 0,
        chapterChanged: false
      )
    case .chapter:
      let selected = max(0, selectedIndex ?? 0)
      return ReaderTOCSelection(
        chapterIndex: selected,
        characterOffset: 0,
        chapterChanged: selected != max(0, currentIndex ?? 0)
      )
    case .bookmark:
      return ReaderTOCSelection(
        chapterIndex: selectedIndex ?? 0,
        characterOffset: characterOffset ?? 0,
        chapterChanged: false
      )
    case .reverse:
      return ReaderTOCSelection(
        chapterIndex: currentIndex ?? 0,
        characterOffset: 0,
        chapterChanged: false
      )
    }
  }
}
