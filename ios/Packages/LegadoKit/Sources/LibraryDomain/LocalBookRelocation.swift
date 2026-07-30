public struct BookID: Equatable, Hashable, Codable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

public enum LocalBookLocationKind: String, Equatable, Hashable, Sendable {
  case original
  case defaultDirectory
  case importDirectory
}

public struct LocalBookLocationReference:
  Equatable, Hashable, Sendable
{
  public let kind: LocalBookLocationKind
  public let opaqueReference: String

  public init(
    kind: LocalBookLocationKind,
    opaqueReference: String
  ) {
    self.kind = kind
    self.opaqueReference = opaqueReference
  }
}

public struct LocalBookChapterID: Equatable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

public struct LocalBook: Equatable, Sendable {
  public let id: BookID
  public let location: LocalBookLocationReference
  public let chapters: [LocalBookChapterID]

  public init(
    id: BookID,
    location: LocalBookLocationReference,
    chapters: [LocalBookChapterID]
  ) {
    self.id = id
    self.location = location
    self.chapters = chapters
  }
}

public struct LocalBookLocationCandidate: Equatable, Sendable {
  public let location: LocalBookLocationReference
  public let matchesOriginalFileName: Bool

  public init(
    location: LocalBookLocationReference,
    matchesOriginalFileName: Bool
  ) {
    self.location = location
    self.matchesOriginalFileName = matchesOriginalFileName
  }
}

public struct LocalBookRelocationCache: Equatable, Sendable {
  public let failedLocations: Set<LocalBookLocationReference>

  public init(
    failedLocations: Set<LocalBookLocationReference> = []
  ) {
    self.failedLocations = failedLocations
  }

  public func recordingFailure(
    at location: LocalBookLocationReference
  ) -> Self {
    var next = failedLocations
    next.insert(location)
    return Self(failedLocations: next)
  }
}

public struct LocalBookRelocationResult: Equatable, Sendable {
  public let book: LocalBook
  public let returnedLocation: LocalBookLocationReference
  public let returnedLocationIsReadable: Bool
  public let retiredLocation: LocalBookLocationReference?
  public let cache: LocalBookRelocationCache

  public init(
    book: LocalBook,
    returnedLocation: LocalBookLocationReference,
    returnedLocationIsReadable: Bool,
    retiredLocation: LocalBookLocationReference?,
    cache: LocalBookRelocationCache
  ) {
    self.book = book
    self.returnedLocation = returnedLocation
    self.returnedLocationIsReadable = returnedLocationIsReadable
    self.retiredLocation = retiredLocation
    self.cache = cache
  }

  public var isRelocated: Bool {
    retiredLocation != nil
  }
}

public enum LocalBookRelocator {
  public static func resolve(
    book: LocalBook,
    originalLocationIsReadable: Bool,
    orderedCandidates: [LocalBookLocationCandidate],
    cache: LocalBookRelocationCache
  ) -> LocalBookRelocationResult {
    if originalLocationIsReadable {
      return unchanged(
        book: book,
        isReadable: true,
        cache: cache
      )
    }
    if cache.failedLocations.contains(book.location) {
      return unchanged(
        book: book,
        isReadable: false,
        cache: cache
      )
    }
    if let match = orderedCandidates.first(where: {
      $0.matchesOriginalFileName
    }) {
      return LocalBookRelocationResult(
        book: LocalBook(
          id: book.id,
          location: match.location,
          chapters: []
        ),
        returnedLocation: match.location,
        returnedLocationIsReadable: true,
        retiredLocation: book.location,
        cache: cache
      )
    }
    return unchanged(
      book: book,
      isReadable: false,
      cache: cache.recordingFailure(at: book.location)
    )
  }

  private static func unchanged(
    book: LocalBook,
    isReadable: Bool,
    cache: LocalBookRelocationCache
  ) -> LocalBookRelocationResult {
    LocalBookRelocationResult(
      book: book,
      returnedLocation: book.location,
      returnedLocationIsReadable: isReadable,
      retiredLocation: nil,
      cache: cache
    )
  }
}

public enum LocalBookChapterReload {
  public static func rebuild(
    book: LocalBook,
    chapters: [LocalBookChapterID]
  ) -> LocalBook {
    LocalBook(
      id: book.id,
      location: book.location,
      chapters: chapters
    )
  }
}
