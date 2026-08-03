import AndroidBackupInterop
import ArchiveZIPFoundation
import Foundation
import LegadoCore
import SourceFormat
import Testing

@Test func androidBackupBookSourcesRoundTripLosslessly() throws {
    let source = try BookSourceCodec.decode(
        Data(
            #"{"bookSourceUrl":"https://oracle.invalid/source","bookSourceName":"Oracle Source","bookSourceGroup":"oracle","bookSourceType":0,"customOrder":0,"enabled":true,"enabledCookieJar":false,"enabledExplore":false,"lastUpdateTime":0,"respondTime":180000,"searchUrl":"https://oracle.invalid/search?key={{key}}","weight":0,"futureField":{"enabled":true}}"#.utf8
        )
    )
    let archiveURL = temporaryArchiveURL()
    defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

    try AndroidBackupArchive.writeBookSources([source], to: archiveURL)

    #expect(archiveURL.lastPathComponent == AndroidBackupArchive.fileName)
    #expect(
        try ArchiveZIPFoundation.descriptors(at: archiveURL) == [
            .init(
                path: "bookSource.json",
                isCompressed: true,
                uncompressedSize: UInt64(
                    try #require(
                        ArchiveZIPFoundation.read(
                            "bookSource.json",
                            from: archiveURL
                        )
                    ).count
                )
            )
        ]
    )
    let restored = try #require(
        AndroidBackupArchive.readBookSources(from: archiveURL).first
    )
    #expect(restored.bookSourceUrl == .value("https://oracle.invalid/source"))
    #expect(restored.bookSourceName == .value("Oracle Source"))
    #expect(restored.unknownFields["futureField"] != nil)
    #expect(try BookSourceCodec.encode(restored) == BookSourceCodec.encode(source))
}

@Test func androidBackupOmitsEmptyBookSourceMember() throws {
    let archiveURL = temporaryArchiveURL()
    defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

    try AndroidBackupArchive.writeBookSources([], to: archiveURL)

    #expect(try ArchiveZIPFoundation.descriptors(at: archiveURL).isEmpty)
    #expect(try AndroidBackupArchive.readBookSources(from: archiveURL).isEmpty)
}

@Test func androidReplacementRulesRoundTripLosslessly() throws {
    let originalJSON = Data(
        #"[{"id":9223372036854775000,"name":"Oracle Replace","group":"oracle","pattern":"foo(.*)","replacement":"bar$1","scope":"https://ios-oracle.invalid/.*","scopeTitle":false,"scopeContent":true,"excludeScope":"/excluded","isEnabled":true,"isRegex":true,"timeoutMillisecond":4500,"order":17,"futureRuleField":{"mode":"preserve"}}]"#.utf8
    )
    let rules = try AndroidReplaceRuleCodec.decodeMany(originalJSON)
    let rule = try #require(rules.first)
    #expect(rule.id == .value(9_223_372_036_854_775_000))
    #expect(rule.name == .value("Oracle Replace"))
    #expect(rule.timeoutMillisecond == .value(4_500))
    #expect(rule.unknownFields["futureRuleField"] != nil)
    let encoded = try AndroidReplaceRuleCodec.encodeMany(rules)
    #expect(try AndroidReplaceRuleCodec.decodeMany(encoded) == rules)
    #expect(String(decoding: encoded, as: UTF8.self).contains("9223372036854775000"))
}

@Test func combinedAndroidBackupCarriesBookSourcesAndReplacementRules() throws {
    let source = try BookSourceCodec.decode(
        Data(#"{"bookSourceUrl":"https://oracle.invalid/source","bookSourceName":"Oracle Source"}"#.utf8)
    )
    let rule = AndroidReplaceRuleDTO(
        id: 7_001,
        name: "Oracle Replace",
        pattern: "oracle-pattern",
        replacement: "oracle-replacement",
        timeoutMillisecond: 4_500,
        order: 17,
        unknownFields: ["future": .bool(true)]
    )
    let archiveURL = temporaryArchiveURL()
    defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

    try AndroidBackupArchive.write(
        .init(bookSources: [source], replacementRules: [rule]),
        to: archiveURL
    )

    #expect(
        try ArchiveZIPFoundation.descriptors(at: archiveURL).map(\.path) == [
            "bookSource.json",
            "replaceRule.json",
        ]
    )
    #expect(try AndroidBackupArchive.readBookSources(from: archiveURL) == [source])
    #expect(try AndroidBackupArchive.readReplacementRules(from: archiveURL) == [rule])
}

@Test func androidLibraryDocumentsRoundTripLosslessly() throws {
    let booksJSON = Data(
        #"[{"author":"Oracle Author","bookUrl":"https://ios-oracle.invalid/book","durChapterIndex":3,"durChapterPos":27,"futureBookField":9223372036854775000,"group":8,"name":"Oracle Book","readConfig":{"reverseToc":true,"splitLongChapter":false,"futureConfig":"keep"}}]"#.utf8
    )
    let groupsJSON = Data(
        #"[{"bookSort":2,"enableRefresh":false,"futureGroupField":true,"groupId":8,"groupName":"Oracle Group","order":4,"show":true}]"#.utf8
    )
    let bookmarksJSON = Data(
        #"[{"bookAuthor":"Oracle Author","bookName":"Oracle Book","bookText":"selected","chapterIndex":3,"chapterName":"Chapter Four","chapterPos":27,"content":"context","futureBookmarkField":"keep","time":1700000000123}]"#.utf8
    )

    let books = try AndroidBookCodec.decodeMany(booksJSON)
    let groups = try AndroidBookGroupCodec.decodeMany(groupsJSON)
    let bookmarks = try AndroidBookmarkCodec.decodeMany(bookmarksJSON)
    let book = try #require(books.first)
    #expect(book.bookURL == .value("https://ios-oracle.invalid/book"))
    #expect(book.group == .value(8))
    #expect(book.currentChapterIndex == .value(3))
    #expect(book.readConfig == .value([
        "reverseToc": .bool(true),
        "splitLongChapter": .bool(false),
        "futureConfig": .string("keep"),
    ]))
    #expect(book.unknownFields["futureBookField"] != nil)
    #expect(try AndroidBookCodec.decodeMany(AndroidBookCodec.encodeMany(books)) == books)
    #expect(try AndroidBookGroupCodec.decodeMany(AndroidBookGroupCodec.encodeMany(groups)) == groups)
    #expect(try AndroidBookmarkCodec.decodeMany(AndroidBookmarkCodec.encodeMany(bookmarks)) == bookmarks)
}

@Test func combinedAndroidLibraryBackupCarriesAllCoreMembers() throws {
    let book = AndroidBookDTO(
        bookURL: "https://ios-oracle.invalid/book",
        tocURL: "https://ios-oracle.invalid/book/toc",
        origin: "https://ios-oracle.invalid/source",
        originName: "iOS Oracle Source",
        name: "iOS Oracle Book",
        author: "Oracle Author",
        group: 8,
        latestChapterTitle: "Chapter Ten",
        latestChapterTime: 1_700_000_000_000,
        totalChapterCount: 10,
        currentChapterTitle: "Chapter Four",
        currentChapterIndex: 3,
        currentChapterPosition: 27,
        lastReadTime: 1_700_000_000_123,
        order: 6,
        readConfig: ["reverseToc": .bool(true), "splitLongChapter": .bool(false)]
    )
    let group = AndroidBookGroupDTO(groupID: 8, groupName: "Oracle Group", order: 4)
    let bookmark = AndroidBookmarkDTO(
        time: 1_700_000_000_123,
        bookName: "iOS Oracle Book",
        bookAuthor: "Oracle Author",
        chapterIndex: 3,
        chapterPosition: 27,
        chapterName: "Chapter Four",
        bookText: "selected",
        content: "context"
    )
    let archiveURL = temporaryArchiveURL()
    defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

    try AndroidBackupArchive.write(
        .init(books: [book], bookGroups: [group], bookmarks: [bookmark]),
        to: archiveURL
    )

    #expect(Set(try ArchiveZIPFoundation.descriptors(at: archiveURL).map(\.path)) == Set([
        "bookshelf.json", "bookGroup.json", "bookmark.json",
    ]))
    #expect(try AndroidBackupArchive.readBooks(from: archiveURL) == [book])
    #expect(try AndroidBackupArchive.readBookGroups(from: archiveURL) == [group])
    #expect(try AndroidBackupArchive.readBookmarks(from: archiveURL) == [bookmark])
}

@Test func archiveContainerRejectsTraversalAndDuplicateMembers() throws {
    let archiveURL = temporaryArchiveURL()
    defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

    #expect(throws: ArchiveZIPFoundation.ContainerError.invalidMemberPath("../bookSource.json")) {
        try ArchiveZIPFoundation.create(
            members: [.init(path: "../bookSource.json", data: Data())],
            at: archiveURL
        )
    }
    #expect(throws: ArchiveZIPFoundation.ContainerError.duplicateMemberPath("bookSource.json")) {
        try ArchiveZIPFoundation.create(
            members: [
                .init(path: "bookSource.json", data: Data()),
                .init(path: "bookSource.json", data: Data()),
            ],
            at: archiveURL
        )
    }
}

private func temporaryArchiveURL() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory.appendingPathComponent(AndroidBackupArchive.fileName)
}
