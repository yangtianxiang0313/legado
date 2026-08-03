import ArchiveZIPFoundation
import Foundation
import SourceFormat

public struct AndroidBackupContents: Equatable, Sendable {
    public var bookSources: [BookSourceDTO]
    public var replacementRules: [AndroidReplaceRuleDTO]

    public init(
        bookSources: [BookSourceDTO] = [],
        replacementRules: [AndroidReplaceRuleDTO] = []
    ) {
        self.bookSources = bookSources
        self.replacementRules = replacementRules
    }
}

public enum AndroidBackupArchive {
    public static let fileName = "backup.zip"
    public static let bookSourcesMember = "bookSource.json"
    public static let replacementRulesMember = "replaceRule.json"

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
}
