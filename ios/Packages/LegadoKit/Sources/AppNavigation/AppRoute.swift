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

public enum AppRoute: Codable, Hashable, Identifiable, Sendable {
    case searchBooks
    case bookDetail(SearchBookRoute)
    case chapterTOC(LibraryDomain.BookID)

    public var id: String {
        switch self {
        case .searchBooks:
            "search.books"
        case .bookDetail(let book):
            "book.detail:\(book.bookURL)"
        case .chapterTOC(let bookID):
            "book.toc:\(bookID.rawValue)"
        }
    }
}

public enum AppNavigationProjection: String, Codable, Hashable, Sendable {
    case compactStack
    case regularSplit
}
