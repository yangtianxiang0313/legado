import Foundation

struct ManagedBookFile {
    let reference: String
    let fileName: String
    let data: Data
}

enum ManagedBookFileStore {
    static func importSelectedURL(_ source: URL) throws -> ManagedBookFile {
        let accessed = source.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                source.stopAccessingSecurityScopedResource()
            }
        }
        return try persist(
            data: Data(contentsOf: source),
            fileName: source.lastPathComponent
        )
    }

    static func persist(
        data: Data,
        fileName: String
    ) throws -> ManagedBookFile {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Legado/ImportedBooks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let safeName = fileName.replacingOccurrences(
            of: "/",
            with: "_"
        )
        let target = directory.appendingPathComponent(
            "\(stableDigest(fileName: safeName, data: data))-\(safeName)"
        )
        try data.write(to: target, options: .atomic)
        return ManagedBookFile(
            reference: target.absoluteString,
            fileName: safeName,
            data: data
        )
    }

    private static func stableDigest(
        fileName: String,
        data: Data
    ) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in Data(fileName.utf8) + data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
