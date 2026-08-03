import AndroidBackupInterop
import ArchiveZIPFoundation
import Foundation
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
