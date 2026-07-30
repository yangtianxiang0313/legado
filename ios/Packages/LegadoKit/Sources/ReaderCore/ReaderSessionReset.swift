import Foundation

public struct ReaderSessionSource: Equatable, Sendable {
  public let url: String
  public let imageStyle: String?

  public init(url: String, imageStyle: String?) {
    self.url = url
    self.imageStyle = imageStyle
  }
}

public struct ReaderSessionResetInput: Equatable, Sendable {
  public let bookIdentity: String
  public let bookName: String
  public let chapterCount: Int
  public let storedChapterIndex: Int
  public let storedChapterPosition: Int
  public let isLocalBook: Bool
  public let bookImageStyle: String?
  public let source: ReaderSessionSource?
  public let readDurations: [Int]

  public init(
    bookIdentity: String,
    bookName: String,
    chapterCount: Int,
    storedChapterIndex: Int,
    storedChapterPosition: Int,
    isLocalBook: Bool,
    bookImageStyle: String?,
    source: ReaderSessionSource?,
    readDurations: [Int]
  ) {
    self.bookIdentity = bookIdentity
    self.bookName = bookName
    self.chapterCount = chapterCount
    self.storedChapterIndex = storedChapterIndex
    self.storedChapterPosition = storedChapterPosition
    self.isLocalBook = isLocalBook
    self.bookImageStyle = bookImageStyle
    self.source = source
    self.readDurations = readDurations
  }
}

public enum ReaderSessionResetEffect: Equatable, Sendable {
  case refreshMenu
  case refreshPageAnimation(updateRecorder: Bool)
}

public struct ReaderSessionResetSnapshot: Equatable, Sendable {
  public let bookIdentity: String
  public let chapterCount: Int
  public let runtimeChapterIndex: Int
  public let runtimeChapterPosition: Int
  public let storedChapterIndex: Int
  public let storedChapterPosition: Int
  public let isLocalBook: Bool
  public let sourceURL: String?
  public let bookImageStyle: String?
  public let readRecordBookName: String
  public let readRecordTime: Int
  public let effects: [ReaderSessionResetEffect]

  public init(
    bookIdentity: String,
    chapterCount: Int,
    runtimeChapterIndex: Int,
    runtimeChapterPosition: Int,
    storedChapterIndex: Int,
    storedChapterPosition: Int,
    isLocalBook: Bool,
    sourceURL: String?,
    bookImageStyle: String?,
    readRecordBookName: String,
    readRecordTime: Int,
    effects: [ReaderSessionResetEffect]
  ) {
    self.bookIdentity = bookIdentity
    self.chapterCount = chapterCount
    self.runtimeChapterIndex = runtimeChapterIndex
    self.runtimeChapterPosition = runtimeChapterPosition
    self.storedChapterIndex = storedChapterIndex
    self.storedChapterPosition = storedChapterPosition
    self.isLocalBook = isLocalBook
    self.sourceURL = sourceURL
    self.bookImageStyle = bookImageStyle
    self.readRecordBookName = readRecordBookName
    self.readRecordTime = readRecordTime
    self.effects = effects
  }

  public let contentProcessorPresent = true
  public let textChaptersCleared = true
  public let temporaryProgressCleared = true
  public let loadingChaptersCleared = true
  public let downloadStatePreserved = true
}

public enum AndroidReaderSessionResetPolicy {
  public static func reset(
    _ input: ReaderSessionResetInput
  ) -> ReaderSessionResetSnapshot {
    let upperBound = input.chapterCount - 1
    let runtimeIndex = max(0, min(input.storedChapterIndex, upperBound))
    let resolvedSource = input.isLocalBook ? nil : input.source
    let explicitStyle = nonBlank(input.bookImageStyle)
    let resolvedStyle =
      explicitStyle ?? nonBlank(resolvedSource?.imageStyle)

    return ReaderSessionResetSnapshot(
      bookIdentity: input.bookIdentity,
      chapterCount: input.chapterCount,
      runtimeChapterIndex: runtimeIndex,
      runtimeChapterPosition: input.storedChapterPosition,
      storedChapterIndex: input.storedChapterIndex,
      storedChapterPosition: input.storedChapterPosition,
      isLocalBook: input.isLocalBook,
      sourceURL: resolvedSource?.url,
      bookImageStyle: resolvedStyle,
      readRecordBookName: input.bookName,
      readRecordTime: input.readDurations.reduce(0, +),
      effects: [
        .refreshMenu,
        .refreshPageAnimation(updateRecorder: false),
      ]
    )
  }

  private static func nonBlank(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty
    else {
      return nil
    }
    return value
  }
}
