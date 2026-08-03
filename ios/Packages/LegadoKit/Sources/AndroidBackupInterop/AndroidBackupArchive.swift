import ArchiveZIPFoundation
import Foundation
import SourceFormat

public struct AndroidBackupContents: Equatable, Sendable {
    public var bookSources: [BookSourceDTO]
    public var replacementRules: [AndroidReplaceRuleDTO]
    public var books: [AndroidBookDTO]
    public var bookGroups: [AndroidBookGroupDTO]
    public var bookmarks: [AndroidBookmarkDTO]

    public init(
        bookSources: [BookSourceDTO] = [],
        replacementRules: [AndroidReplaceRuleDTO] = [],
        books: [AndroidBookDTO] = [],
        bookGroups: [AndroidBookGroupDTO] = [],
        bookmarks: [AndroidBookmarkDTO] = []
    ) {
        self.bookSources = bookSources
        self.replacementRules = replacementRules
        self.books = books
        self.bookGroups = bookGroups
        self.bookmarks = bookmarks
    }
}

public enum AndroidBackupArchive {
    public static let fileName = "backup.zip"
    public static let bookSourcesMember = "bookSource.json"
    public static let replacementRulesMember = "replaceRule.json"
    public static let booksMember = "bookshelf.json"
    public static let bookGroupsMember = "bookGroup.json"
    public static let bookmarksMember = "bookmark.json"

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
}
