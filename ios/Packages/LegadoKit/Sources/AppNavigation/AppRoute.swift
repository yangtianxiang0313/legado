import LibraryDomain

public enum RootRoute: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case shelf = "root.shelf"
    case explore = "root.explore"
    case rss = "root.rss"
    case settings = "root.settings"

    public var id: String {
        rawValue
    }
}

public struct SearchBookRoute: Codable, Hashable, Sendable {
    public let name: String
    public let author: String
    public let kind: String
    public let lastChapter: String
    public let intro: String
    public let bookURL: String
    public let coverURL: String?
    public let originName: String
    public let sourceID: String

    public init(
        name: String,
        author: String,
        kind: String,
        lastChapter: String,
        intro: String,
        bookURL: String,
        coverURL: String?,
        originName: String,
        sourceID: String = ""
    ) {
        self.name = name
        self.author = author
        self.kind = kind
        self.lastChapter = lastChapter
        self.intro = intro
        self.bookURL = bookURL
        self.coverURL = coverURL
        self.originName = originName
        self.sourceID = sourceID
    }
}

public struct ExploreSourceRoute: Codable, Hashable, Sendable {
    public let sourceID: String
    public let title: String

    public init(sourceID: String, title: String) {
        self.sourceID = sourceID
        self.title = title
    }
}

public struct ReaderRoute: Codable, Hashable, Sendable {
    public let bookID: LibraryDomain.BookID
    public let chapterID: LibraryDomain.ChapterID
    public let characterOffset: Int

    public init(
        bookID: LibraryDomain.BookID,
        chapterID: LibraryDomain.ChapterID,
        characterOffset: Int = 0
    ) {
        self.bookID = bookID
        self.chapterID = chapterID
        self.characterOffset = max(0, characterOffset)
    }
}

public enum AppRoute: Codable, Hashable, Identifiable, Sendable {
  case searchBooks
  case exploreSource(ExploreSourceRoute)
  case bookDetail(SearchBookRoute)
  case chapterTOC(LibraryDomain.BookID)
  case reader(ReaderRoute)
  case sourceManagement
  case sourceEditor(String?)
  case sourceDebug(String)
  case sourceLogin(String)
  case sourceSearch(String)

    public var id: String {
        switch self {
        case .searchBooks:
            "search.books"
        case .exploreSource(let source):
            "explore.source:\(source.sourceID)"
        case .bookDetail(let book):
            "book.detail:\(book.bookURL)"
        case .chapterTOC(let bookID):
            "book.toc:\(bookID.rawValue)"
    case .reader(let target):
      "reader:\(target.bookID.rawValue):\(target.chapterID.rawValue)"
    case .sourceManagement:
      "source.management"
    case .sourceEditor(let sourceID):
      "source.editor:\(sourceID ?? "new")"
    case .sourceDebug(let sourceID):
      "source.debug:\(sourceID)"
    case .sourceLogin(let sourceID):
      "source.login:\(sourceID)"
    case .sourceSearch(let sourceID):
      "source.search:\(sourceID)"
    }
  }
}

public enum AppNavigationProjection: String, Codable, Hashable, Sendable {
    case compactStack
    case regularSplit
}
