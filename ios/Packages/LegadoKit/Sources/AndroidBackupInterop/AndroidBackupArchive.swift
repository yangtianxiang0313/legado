import ArchiveZIPFoundation
import Foundation
import SourceFormat

public struct AndroidBackupContents: Equatable, Sendable {
    public var bookSources: [BookSourceDTO]
    public var replacementRules: [AndroidReplaceRuleDTO]
    public var books: [AndroidBookDTO]
    public var bookGroups: [AndroidBookGroupDTO]
    public var bookmarks: [AndroidBookmarkDTO]
    public var readRecords: [AndroidReadRecordDTO]
    public var searchHistory: [AndroidSearchHistoryDTO]
    public var ruleSubscriptions: [AndroidRuleSubscriptionDTO]
    public var rssSources: [AndroidRSSSourceDTO]
    public var rssStars: [AndroidRSSStarDTO]
    public var httpTextToSpeechEngines: [AndroidHTTPTextToSpeechDTO]
    public var localTextTOCRules: [AndroidLocalTextTOCRuleDTO]
    public var readerConfigs: [AndroidReaderConfigDTO]
    public var sharedReaderConfig: AndroidReaderConfigDTO?
    public var dictionaryRules: [AndroidDictionaryRuleDTO]
    public var keyboardAssists: [AndroidKeyboardAssistDTO]
    public var themeConfigs: [AndroidThemeConfigDTO]
    public var directLinkUploadRule: AndroidDirectLinkUploadRuleDTO?
    public var sharedPreferences: AndroidSharedPreferencesDocument?
    public var serverProfilesPayload: Data?

    public init(
        bookSources: [BookSourceDTO] = [],
        replacementRules: [AndroidReplaceRuleDTO] = [],
        books: [AndroidBookDTO] = [],
        bookGroups: [AndroidBookGroupDTO] = [],
        bookmarks: [AndroidBookmarkDTO] = [],
        readRecords: [AndroidReadRecordDTO] = [],
        searchHistory: [AndroidSearchHistoryDTO] = [],
        ruleSubscriptions: [AndroidRuleSubscriptionDTO] = [],
        rssSources: [AndroidRSSSourceDTO] = [],
        rssStars: [AndroidRSSStarDTO] = [],
        httpTextToSpeechEngines: [AndroidHTTPTextToSpeechDTO] = [],
        localTextTOCRules: [AndroidLocalTextTOCRuleDTO] = [],
        readerConfigs: [AndroidReaderConfigDTO] = [],
        sharedReaderConfig: AndroidReaderConfigDTO? = nil,
        dictionaryRules: [AndroidDictionaryRuleDTO] = [],
        keyboardAssists: [AndroidKeyboardAssistDTO] = [],
        themeConfigs: [AndroidThemeConfigDTO] = [],
        directLinkUploadRule: AndroidDirectLinkUploadRuleDTO? = nil,
        sharedPreferences: AndroidSharedPreferencesDocument? = nil,
        serverProfilesPayload: Data? = nil
    ) {
        self.bookSources = bookSources
        self.replacementRules = replacementRules
        self.books = books
        self.bookGroups = bookGroups
        self.bookmarks = bookmarks
        self.readRecords = readRecords
        self.searchHistory = searchHistory
        self.ruleSubscriptions = ruleSubscriptions
        self.rssSources = rssSources
        self.rssStars = rssStars
        self.httpTextToSpeechEngines = httpTextToSpeechEngines
        self.localTextTOCRules = localTextTOCRules
        self.readerConfigs = readerConfigs
        self.sharedReaderConfig = sharedReaderConfig
        self.dictionaryRules = dictionaryRules
        self.keyboardAssists = keyboardAssists
        self.themeConfigs = themeConfigs
        self.directLinkUploadRule = directLinkUploadRule
        self.sharedPreferences = sharedPreferences
        self.serverProfilesPayload = serverProfilesPayload
    }
}

public enum AndroidBackupArchive {
    public static let fileName = "backup.zip"
    public static let bookSourcesMember = "bookSource.json"
    public static let replacementRulesMember = "replaceRule.json"
    public static let booksMember = "bookshelf.json"
    public static let bookGroupsMember = "bookGroup.json"
    public static let bookmarksMember = "bookmark.json"
    public static let readRecordsMember = "readRecord.json"
    public static let searchHistoryMember = "searchHistory.json"
    public static let ruleSubscriptionsMember = "sourceSub.json"
    public static let rssSourcesMember = "rssSources.json"
    public static let rssStarsMember = "rssStar.json"
    public static let httpTextToSpeechMember = "httpTTS.json"
    public static let localTextTOCRulesMember = "txtTocRule.json"
    public static let readerConfigsMember = "readConfig.json"
    public static let sharedReaderConfigMember = "shareReadConfig.json"
    public static let dictionaryRulesMember = "dictRule.json"
    public static let keyboardAssistsMember = "keyboardAssists.json"
    public static let themeConfigsMember = "themeConfig.json"
    public static let sharedPreferencesMember = "config.xml"
    public static let serverProfilesMember = "servers.json"
    public static let directLinkUploadRuleMember = "directLinkUploadRule.json"

    public static func write(
        _ contents: AndroidBackupContents,
        to archiveURL: URL
    ) throws {
        var members: [ArchiveZIPFoundation.Member] = []
        if !contents.bookSources.isEmpty {
            members.append(
                .init(
                    path: bookSourcesMember,
                    data: try BookSourceCodec.encodeMany(contents.bookSources)
                )
            )
        }
        if !contents.replacementRules.isEmpty {
            members.append(
                .init(
                    path: replacementRulesMember,
                    data: try AndroidReplaceRuleCodec.encodeMany(
                        contents.replacementRules
                    )
                )
            )
        }
        if !contents.books.isEmpty {
            members.append(
                .init(path: booksMember, data: try AndroidBookCodec.encodeMany(contents.books))
            )
        }
        if !contents.bookGroups.isEmpty {
            members.append(
                .init(
                    path: bookGroupsMember,
                    data: try AndroidBookGroupCodec.encodeMany(contents.bookGroups)
                )
            )
        }
        if !contents.bookmarks.isEmpty {
            members.append(
                .init(
                    path: bookmarksMember,
                    data: try AndroidBookmarkCodec.encodeMany(contents.bookmarks)
                )
            )
        }
        if !contents.readRecords.isEmpty {
            members.append(
                .init(
                    path: readRecordsMember,
                    data: try AndroidReadRecordCodec.encodeMany(contents.readRecords)
                )
            )
        }
        if !contents.searchHistory.isEmpty {
            members.append(
                .init(
                    path: searchHistoryMember,
                    data: try AndroidSearchHistoryCodec.encodeMany(contents.searchHistory)
                )
            )
        }
        if !contents.ruleSubscriptions.isEmpty {
            members.append(
                .init(
                    path: ruleSubscriptionsMember,
                    data: try AndroidRuleSubscriptionCodec.encodeMany(
                        contents.ruleSubscriptions
                    )
                )
            )
        }
        if !contents.rssSources.isEmpty {
            members.append(
                .init(
                    path: rssSourcesMember,
                    data: try AndroidRSSCodec.encodeSources(contents.rssSources)
                )
            )
        }
        if !contents.rssStars.isEmpty {
            members.append(
                .init(
                    path: rssStarsMember,
                    data: try AndroidRSSCodec.encodeStars(contents.rssStars)
                )
            )
        }
        if !contents.httpTextToSpeechEngines.isEmpty {
            members.append(
                .init(
                    path: httpTextToSpeechMember,
                    data: try AndroidHTTPTextToSpeechCodec.encodeMany(
                        contents.httpTextToSpeechEngines
                    )
                )
            )
        }
        if !contents.localTextTOCRules.isEmpty {
            members.append(
                .init(
                    path: localTextTOCRulesMember,
                    data: try AndroidLocalTextTOCRuleCodec.encodeMany(
                        contents.localTextTOCRules
                    )
                )
            )
        }
        if !contents.readerConfigs.isEmpty {
            members.append(
                .init(
                    path: readerConfigsMember,
                    data: try AndroidReaderConfigCodec.encodeList(
                        contents.readerConfigs
                    )
                )
            )
        }
        if let sharedReaderConfig = contents.sharedReaderConfig {
            members.append(
                .init(
                    path: sharedReaderConfigMember,
                    data: try AndroidReaderConfigCodec.encodeShared(
                        sharedReaderConfig
                    )
                )
            )
        }
        if !contents.dictionaryRules.isEmpty {
            members.append(
                .init(
                    path: dictionaryRulesMember,
                    data: try AndroidDictionaryRuleCodec.encodeMany(
                        contents.dictionaryRules
                    )
                )
            )
        }
        if !contents.keyboardAssists.isEmpty {
            members.append(
                .init(
                    path: keyboardAssistsMember,
                    data: try AndroidKeyboardAssistCodec.encodeMany(
                        contents.keyboardAssists
                    )
                )
            )
        }
        if !contents.themeConfigs.isEmpty {
            members.append(
                .init(
                    path: themeConfigsMember,
                    data: try AndroidThemeConfigCodec.encodeMany(
                        contents.themeConfigs
                    )
                )
            )
        }
        if let directLinkUploadRule = contents.directLinkUploadRule {
            members.append(
                .init(
                    path: directLinkUploadRuleMember,
                    data: try AndroidDirectLinkUploadRuleCodec.encode(
                        directLinkUploadRule
                    )
                )
            )
        }
        if let sharedPreferences = contents.sharedPreferences {
            members.append(
                .init(
                    path: sharedPreferencesMember,
                    data: AndroidSharedPreferencesCodec.encode(sharedPreferences)
                )
            )
        }
        if let serverProfilesPayload = contents.serverProfilesPayload {
            members.append(
                .init(path: serverProfilesMember, data: serverProfilesPayload)
            )
        }
        try ArchiveZIPFoundation.create(members: members, at: archiveURL)
    }

    public static func writeBookSources(
        _ sources: [BookSourceDTO],
        to archiveURL: URL
    ) throws {
        try write(.init(bookSources: sources), to: archiveURL)
    }

    public static func readBookSources(
        from archiveURL: URL,
        maximumMemberBytes: UInt64 = 32 * 1_024 * 1_024
    ) throws -> [BookSourceDTO] {
        guard let data = try ArchiveZIPFoundation.read(
            bookSourcesMember,
            from: archiveURL,
            maximumBytes: maximumMemberBytes
        ) else {
            return []
        }
        return try BookSourceCodec.decodeMany(data)
    }

    public static func decodeBookSources(
        _ data: Data
    ) throws -> [BookSourceDTO] {
        try BookSourceCodec.decodeMany(data)
    }

    public static func encodeBookSources(
        _ sources: [BookSourceDTO]
    ) throws -> Data {
        try BookSourceCodec.encodeMany(sources)
    }

    public static func readReplacementRules(
        from archiveURL: URL,
        maximumMemberBytes: UInt64 = 32 * 1_024 * 1_024
    ) throws -> [AndroidReplaceRuleDTO] {
        guard let data = try ArchiveZIPFoundation.read(
            replacementRulesMember,
            from: archiveURL,
            maximumBytes: maximumMemberBytes
        ) else {
            return []
        }
        return try AndroidReplaceRuleCodec.decodeMany(data)
    }

    public static func readBooks(
        from archiveURL: URL,
        maximumMemberBytes: UInt64 = 64 * 1_024 * 1_024
    ) throws -> [AndroidBookDTO] {
        guard let data = try ArchiveZIPFoundation.read(
            booksMember, from: archiveURL, maximumBytes: maximumMemberBytes
        ) else { return [] }
        return try AndroidBookCodec.decodeMany(data)
    }

    public static func readBookGroups(
        from archiveURL: URL,
        maximumMemberBytes: UInt64 = 32 * 1_024 * 1_024
    ) throws -> [AndroidBookGroupDTO] {
        guard let data = try ArchiveZIPFoundation.read(
            bookGroupsMember, from: archiveURL, maximumBytes: maximumMemberBytes
        ) else { return [] }
        return try AndroidBookGroupCodec.decodeMany(data)
    }

    public static func readBookmarks(
        from archiveURL: URL,
        maximumMemberBytes: UInt64 = 32 * 1_024 * 1_024
    ) throws -> [AndroidBookmarkDTO] {
        guard let data = try ArchiveZIPFoundation.read(
            bookmarksMember, from: archiveURL, maximumBytes: maximumMemberBytes
        ) else { return [] }
        return try AndroidBookmarkCodec.decodeMany(data)
    }

    public static func readReadRecords(
        from archiveURL: URL,
        maximumMemberBytes: UInt64 = 32 * 1_024 * 1_024
    ) throws -> [AndroidReadRecordDTO] {
        guard let data = try ArchiveZIPFoundation.read(
            readRecordsMember, from: archiveURL, maximumBytes: maximumMemberBytes
        ) else { return [] }
        return try AndroidReadRecordCodec.decodeMany(data)
    }

    public static func readSearchHistory(
        from archiveURL: URL,
        maximumMemberBytes: UInt64 = 32 * 1_024 * 1_024
    ) throws -> [AndroidSearchHistoryDTO] {
        guard let data = try ArchiveZIPFoundation.read(
            searchHistoryMember, from: archiveURL, maximumBytes: maximumMemberBytes
        ) else { return [] }
        return try AndroidSearchHistoryCodec.decodeMany(data)
    }

    public static func readRuleSubscriptions(
        from archiveURL: URL,
        maximumMemberBytes: UInt64 = 32 * 1_024 * 1_024
    ) throws -> [AndroidRuleSubscriptionDTO] {
        guard let data = try ArchiveZIPFoundation.read(
            ruleSubscriptionsMember,
            from: archiveURL,
            maximumBytes: maximumMemberBytes
        ) else { return [] }
        return try AndroidRuleSubscriptionCodec.decodeMany(data)
    }

    public static func readRSSSources(
        from archiveURL: URL,
        maximumMemberBytes: UInt64 = 64 * 1_024 * 1_024
    ) throws -> [AndroidRSSSourceDTO] {
        guard let data = try ArchiveZIPFoundation.read(
            rssSourcesMember, from: archiveURL, maximumBytes: maximumMemberBytes
        ) else { return [] }
        return try AndroidRSSCodec.decodeSources(data)
    }

    public static func readRSSStars(
        from archiveURL: URL,
        maximumMemberBytes: UInt64 = 64 * 1_024 * 1_024
    ) throws -> [AndroidRSSStarDTO] {
        guard let data = try ArchiveZIPFoundation.read(
            rssStarsMember, from: archiveURL, maximumBytes: maximumMemberBytes
        ) else { return [] }
        return try AndroidRSSCodec.decodeStars(data)
    }

    public static func readHTTPTextToSpeechEngines(
        from archiveURL: URL,
        maximumMemberBytes: UInt64 = 32 * 1_024 * 1_024
    ) throws -> [AndroidHTTPTextToSpeechDTO] {
        guard let data = try ArchiveZIPFoundation.read(
            httpTextToSpeechMember,
            from: archiveURL,
            maximumBytes: maximumMemberBytes
        ) else { return [] }
        return try AndroidHTTPTextToSpeechCodec.decodeMany(data)
    }

    public static func readLocalTextTOCRules(
        from archiveURL: URL,
        maximumMemberBytes: UInt64 = 32 * 1_024 * 1_024
    ) throws -> [AndroidLocalTextTOCRuleDTO] {
        guard let data = try ArchiveZIPFoundation.read(
            localTextTOCRulesMember,
            from: archiveURL,
            maximumBytes: maximumMemberBytes
        ) else { return [] }
        return try AndroidLocalTextTOCRuleCodec.decodeMany(data)
    }

    public static func readReaderConfigs(
        from archiveURL: URL,
        maximumMemberBytes: UInt64 = 32 * 1_024 * 1_024
    ) throws -> [AndroidReaderConfigDTO] {
        guard let data = try ArchiveZIPFoundation.read(
            readerConfigsMember, from: archiveURL, maximumBytes: maximumMemberBytes
        ) else { return [] }
        return try AndroidReaderConfigCodec.decodeList(data)
    }

    public static func readSharedReaderConfig(
        from archiveURL: URL,
        maximumMemberBytes: UInt64 = 32 * 1_024 * 1_024
    ) throws -> AndroidReaderConfigDTO? {
        guard let data = try ArchiveZIPFoundation.read(
            sharedReaderConfigMember,
            from: archiveURL,
            maximumBytes: maximumMemberBytes
        ) else { return nil }
        return try AndroidReaderConfigCodec.decodeShared(data)
    }

    public static func readDictionaryRules(
        from archiveURL: URL,
        maximumMemberBytes: UInt64 = 32 * 1_024 * 1_024
    ) throws -> [AndroidDictionaryRuleDTO] {
        guard let data = try ArchiveZIPFoundation.read(
            dictionaryRulesMember,
            from: archiveURL,
            maximumBytes: maximumMemberBytes
        ) else { return [] }
        return try AndroidDictionaryRuleCodec.decodeMany(data)
    }

    public static func readKeyboardAssists(
        from archiveURL: URL,
        maximumMemberBytes: UInt64 = 32 * 1_024 * 1_024
    ) throws -> [AndroidKeyboardAssistDTO] {
        guard let data = try ArchiveZIPFoundation.read(
            keyboardAssistsMember,
            from: archiveURL,
            maximumBytes: maximumMemberBytes
        ) else { return [] }
        return try AndroidKeyboardAssistCodec.decodeMany(data)
    }

    public static func readThemeConfigs(
        from archiveURL: URL,
        maximumMemberBytes: UInt64 = 32 * 1_024 * 1_024
    ) throws -> [AndroidThemeConfigDTO] {
        guard let data = try ArchiveZIPFoundation.read(
            themeConfigsMember,
            from: archiveURL,
            maximumBytes: maximumMemberBytes
        ) else { return [] }
        return try AndroidThemeConfigCodec.decodeMany(data)
    }

    public static func readDirectLinkUploadRule(
        from archiveURL: URL,
        maximumMemberBytes: UInt64 = 32 * 1_024 * 1_024
    ) throws -> AndroidDirectLinkUploadRuleDTO? {
        guard let data = try ArchiveZIPFoundation.read(
            directLinkUploadRuleMember,
            from: archiveURL,
            maximumBytes: maximumMemberBytes
        ) else { return nil }
        return try AndroidDirectLinkUploadRuleCodec.decode(data)
    }

    public static func readSharedPreferences(
        from archiveURL: URL,
        maximumMemberBytes: UInt64 = 4 * 1_024 * 1_024
    ) throws -> AndroidSharedPreferencesDocument? {
        guard let data = try ArchiveZIPFoundation.read(
            sharedPreferencesMember,
            from: archiveURL,
            maximumBytes: maximumMemberBytes
        ) else { return nil }
        return try AndroidSharedPreferencesCodec.decode(data)
    }

    public static func readWebDAVBackupConfiguration(
        from archiveURL: URL,
        maximumMemberBytes: UInt64 = 4 * 1_024 * 1_024
    ) throws -> AndroidWebDAVBackupConfiguration? {
        guard let document = try readSharedPreferences(
            from: archiveURL,
            maximumMemberBytes: maximumMemberBytes
        ) else { return nil }
        let configuration = AndroidWebDAVBackupConfiguration(document: document)
        return configuration.isPresent ? configuration : nil
    }

    public static func readServerProfiles(
        from archiveURL: URL,
        backupPassword: String?,
        maximumMemberBytes: UInt64 = 4 * 1_024 * 1_024
    ) throws -> [AndroidServerProfileDTO] {
        guard let data = try ArchiveZIPFoundation.read(
            serverProfilesMember,
            from: archiveURL,
            maximumBytes: maximumMemberBytes
        ) else { return [] }
        return try AndroidServerProfileCodec.decodeArchivePayload(
            data,
            backupPassword: backupPassword
        )
    }
}
