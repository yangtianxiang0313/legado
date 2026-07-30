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
    public let tocURL: String?
    public let bookRequestExpression: String
    public let coverURL: String?
    public let originName: String
    public let sourceID: String
    public let variables: [String: String]

    public init(
        name: String,
        author: String,
        kind: String,
        lastChapter: String,
        intro: String,
        bookURL: String,
        tocURL: String? = nil,
        bookRequestExpression: String? = nil,
        coverURL: String?,
        originName: String,
        sourceID: String = "",
        variables: [String: String] = [:]
    ) {
        self.name = name
        self.author = author
        self.kind = kind
        self.lastChapter = lastChapter
        self.intro = intro
        self.bookURL = bookURL
        self.tocURL = tocURL
        self.bookRequestExpression = bookRequestExpression ?? bookURL
        self.coverURL = coverURL
        self.originName = originName
        self.sourceID = sourceID
        self.variables = variables
    }

    public static func == (
        lhs: SearchBookRoute,
        rhs: SearchBookRoute
    ) -> Bool {
        lhs.name == rhs.name
            && lhs.author == rhs.author
            && lhs.kind == rhs.kind
            && lhs.lastChapter == rhs.lastChapter
            && lhs.intro == rhs.intro
            && lhs.bookURL == rhs.bookURL
            && lhs.tocURL == rhs.tocURL
            && lhs.bookRequestExpression == rhs.bookRequestExpression
            && lhs.coverURL == rhs.coverURL
            && lhs.originName == rhs.originName
            && lhs.sourceID == rhs.sourceID
            && lhs.variables == rhs.variables
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(author)
        hasher.combine(kind)
        hasher.combine(lastChapter)
        hasher.combine(intro)
        hasher.combine(bookURL)
        hasher.combine(tocURL)
        hasher.combine(bookRequestExpression)
        hasher.combine(coverURL)
        hasher.combine(originName)
        hasher.combine(sourceID)
        for key in variables.keys.sorted() {
            hasher.combine(key)
            hasher.combine(variables[key])
        }
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
