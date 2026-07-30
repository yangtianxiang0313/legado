import Foundation

public struct ChapterID: RawRepresentable, Hashable, Codable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(sourceID: String, chapterURL: String) {
    self.rawValue = "\(sourceID)|\(chapterURL)"
  }
}

public struct BookChapter: Identifiable, Hashable, Sendable {
  public let id: ChapterID
  public let bookID: BookID
  public let sourceID: String
  public let index: Int
  public let title: String
  public let url: String
  public let requestExpression: String
  public let isPay: Bool
  public let isVIP: Bool
  public let isVolume: Bool
  public let variables: [String: String]

  public init(
    id: ChapterID,
    bookID: BookID,
    sourceID: String,
    index: Int,
    title: String,
    url: String,
    requestExpression: String? = nil,
    isPay: Bool = false,
    isVIP: Bool = false,
    isVolume: Bool = false,
    variables: [String: String] = [:]
  ) {
    self.id = id
    self.bookID = bookID
    self.sourceID = sourceID
    self.index = max(0, index)
    self.title = title
    self.url = url
    self.requestExpression = requestExpression ?? url
    self.isPay = isPay
    self.isVIP = isVIP
    self.isVolume = isVolume
    self.variables = variables
  }

  public static func == (lhs: BookChapter, rhs: BookChapter) -> Bool {
    lhs.id == rhs.id
      && lhs.bookID == rhs.bookID
      && lhs.sourceID == rhs.sourceID
      && lhs.index == rhs.index
      && lhs.title == rhs.title
      && lhs.url == rhs.url
      && lhs.requestExpression == rhs.requestExpression
      && lhs.isPay == rhs.isPay
      && lhs.isVIP == rhs.isVIP
      && lhs.isVolume == rhs.isVolume
      && lhs.variables == rhs.variables
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(bookID)
    hasher.combine(sourceID)
    hasher.combine(index)
    hasher.combine(title)
    hasher.combine(url)
    hasher.combine(requestExpression)
    hasher.combine(isPay)
    hasher.combine(isVIP)
    hasher.combine(isVolume)
    for key in variables.keys.sorted() {
      hasher.combine(key)
      hasher.combine(variables[key])
    }
  }
}

public enum ChapterTOCFailure: String, Error, Codable, Sendable {
  case missingSource = "missing_source"
  case empty
  case fetchFailed = "fetch_failed"
}

public enum ChapterTOCUpdate: Equatable, Sendable {
  case replaced(previousCount: Int, chapters: [BookChapter])
  case preserved(failure: ChapterTOCFailure, chapters: [BookChapter])

  public var chapters: [BookChapter] {
    switch self {
    case .replaced(_, let chapters), .preserved(_, let chapters):
      chapters
    }
  }

  public var updateError: Bool {
    if case .preserved = self { return true }
    return false
  }
}

public enum ChapterTOCUpdatePolicy {
  public static func shelfUpdate(
    existing: [BookChapter],
    fetched: [BookChapter]?,
    failure: ChapterTOCFailure? = nil
  ) -> ChapterTOCUpdate {
    if let failure {
      return .preserved(failure: failure, chapters: existing)
    }
    guard let fetched, !fetched.isEmpty else {
      return .preserved(failure: .empty, chapters: existing)
    }
    return .replaced(
      previousCount: existing.count,
      chapters: fetched.sorted { lhs, rhs in
        if lhs.index == rhs.index { return lhs.id.rawValue < rhs.id.rawValue }
        return lhs.index < rhs.index
      }
    )
  }
}

public struct ReaderTOCRefreshDecision: Equatable, Sendable {
  public let shouldRequest: Bool
  public let acceptedChapters: [BookChapter]?

  public init(
    shouldRequest: Bool,
    acceptedChapters: [BookChapter]?
  ) {
    self.shouldRequest = shouldRequest
    self.acceptedChapters = acceptedChapters
  }
}

public enum ReaderTOCRefreshPolicy {
  public static let throttleSeconds: TimeInterval = 10 * 60

  public static func decide(
    existing: [BookChapter],
    fetched: [BookChapter]?,
    elapsedSinceLastCheck: TimeInterval
  ) -> ReaderTOCRefreshDecision {
    guard elapsedSinceLastCheck >= throttleSeconds else {
      return ReaderTOCRefreshDecision(
        shouldRequest: false,
        acceptedChapters: nil
      )
    }
    guard let fetched, fetched.count > existing.count else {
      return ReaderTOCRefreshDecision(
        shouldRequest: true,
        acceptedChapters: nil
      )
    }
    return ReaderTOCRefreshDecision(
      shouldRequest: true,
      acceptedChapters: fetched
    )
  }
}
