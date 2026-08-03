import ArchiveZIPFoundation
import Foundation
import SourceFormat

public enum AndroidBackupArchive {
    public static let fileName = "backup.zip"
    public static let bookSourcesMember = "bookSource.json"

    public static func writeBookSources(
        _ sources: [BookSourceDTO],
        to archiveURL: URL
    ) throws {
        let members: [ArchiveZIPFoundation.Member]
        if sources.isEmpty {
            members = []
        } else {
            members = [
                .init(
                    path: bookSourcesMember,
                    data: try BookSourceCodec.encodeMany(sources)
                )
            ]
        }
        try ArchiveZIPFoundation.create(members: members, at: archiveURL)
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
}
