public enum ReaderMenuLayer: String, CaseIterable, Codable, Hashable, Sendable {
    case primary
    case appearance
    case more
    case search
    case replacementRules
    case bookSource
    case textSelection
}

public enum ReaderMenuAction: String, CaseIterable, Codable, Hashable, Sendable {
    case openBookInfo = "reader.openBookInfo"
    case previousChapter = "reader.previousChapter"
    case seekProgress = "reader.seekProgress"
    case nextChapter = "reader.nextChapter"
    case openTOC = "reader.openTOC"
    case openBookSource = "reader.openBookSource"
    case openChapterSource = "reader.openChapterSource"
    case openAppearance = "reader.openAppearance"
    case openMore = "reader.openMore"
    case toggleAutoPage = "reader.toggleAutoPage"
    case toggleTheme = "reader.toggleTheme"
    case updateBrightness = "reader.updateBrightness"
    case updateAppearance = "reader.updateAppearance"
    case openSearch = "reader.openSearch"
    case updateReadingSettings = "reader.updateReadingSettings"
    case openReplaceRules = "reader.openReplaceRules"
    case refreshCurrent = "reader.refreshCurrent"
    case refreshAfter = "reader.refreshAfter"
    case refreshAll = "reader.refreshAll"
    case cacheOffline = "reader.cacheOffline"
    case addBookmark = "reader.addBookmark"
    case startReadAloud = "reader.startReadAloud"
    case pauseReadAloud = "reader.pauseReadAloud"
    case resumeReadAloud = "reader.resumeReadAloud"
    case stopReadAloud = "reader.stopReadAloud"
    case editContent = "reader.editContent"
    case configurePageAnimation = "reader.configurePageAnimation"
    case openReadAloudSettings = "reader.openReadAloudSettings"
    case selectionReadAloud = "reader.selection.readAloud"
    case selectionAddBookmark = "reader.selection.addBookmark"
    case selectionReplace = "reader.selection.replace"
    case selectionSearchFullText = "reader.selection.searchFullText"
    case selectionLookupDictionary = "reader.selection.lookupDictionary"

    public var accessibilityIdentifier: String {
        "action.\(rawValue)"
    }
}

public enum ReaderMenuCatalog {
    public static let primary: [ReaderMenuAction] = [
        .openBookInfo,
        .previousChapter,
        .seekProgress,
        .nextChapter,
        .openTOC,
        .openBookSource,
        .openChapterSource,
        .openAppearance,
        .openMore,
        .toggleAutoPage,
    ]

    public static let appearance: [ReaderMenuAction] = [
        .toggleTheme,
        .updateBrightness,
        .updateAppearance,
    ]

    public static let more: [ReaderMenuAction] = [
        .openSearch,
        .updateReadingSettings,
        .openReplaceRules,
        .refreshCurrent,
        .refreshAfter,
        .refreshAll,
        .cacheOffline,
        .addBookmark,
        .startReadAloud,
        .pauseReadAloud,
        .resumeReadAloud,
        .stopReadAloud,
        .editContent,
        .configurePageAnimation,
        .openReadAloudSettings,
    ]

    public static let textSelection: [ReaderMenuAction] = [
        .selectionReadAloud,
        .selectionAddBookmark,
        .selectionReplace,
        .selectionSearchFullText,
        .selectionLookupDictionary,
    ]

    public static func actions(in layer: ReaderMenuLayer) -> [ReaderMenuAction] {
        switch layer {
        case .primary:
            primary
        case .appearance:
            appearance
        case .more:
            more
        case .search:
            []
        case .replacementRules:
            []
        case .bookSource:
            []
        case .textSelection:
            textSelection
        }
    }
}
