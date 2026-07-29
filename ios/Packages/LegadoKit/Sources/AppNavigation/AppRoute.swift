public enum RootRoute: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case shelf = "root.shelf"
    case explore = "root.explore"
    case rss = "root.rss"
    case settings = "root.settings"

    public var id: String {
        rawValue
    }
}

public enum AppRoute: String, Codable, Hashable, Identifiable, Sendable {
    case searchBooks = "search.books"

    public var id: String {
        rawValue
    }
}

public enum AppNavigationProjection: String, Codable, Hashable, Sendable {
    case compactStack
    case regularSplit
}
