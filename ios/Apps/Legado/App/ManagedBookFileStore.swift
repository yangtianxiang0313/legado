import Foundation
import AppUseCases
import ZIPFoundation

struct ManagedBookFile {
    let reference: String
    let fileName: String
    let data: Data
}

private struct ManagedArchiveEntry {
    let path: String
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

    static func epubMembers(from file: ManagedBookFile) throws -> [String: Data] {
        Dictionary(
            uniqueKeysWithValues: try archiveEntries(from: file).map {
                ($0.path, $0.data)
            }
        )
    }

    static func localArchiveItems(
        from file: ManagedBookFile
    ) throws -> (
        items: [LocalArchiveImportItem],
        skipped: [LocalArchiveSkippedEntry]
    ) {
        let archived = try archiveEntries(from: file)
        let plan = try LocalArchiveImportPlanner.plan(
            members: archived.map {
                LocalArchiveMember(path: $0.path, byteCount: $0.data.count)
            }
        )
        let byPath = Dictionary(
            uniqueKeysWithValues: archived.map { ($0.path, $0.data) }
        )
        let items = try plan.entries.map { entry in
            guard let data = byPath[entry.path] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let managed = try persist(data: data, fileName: entry.fileName)
            let payload: LocalBookPayload
            switch entry.format {
            case .text:
                payload = .text(data)
            case .epub:
                payload = .epub(try epubMembers(from: managed))
            }
            return LocalArchiveImportItem(
                entry: entry,
                managedReference: managed.reference,
                payload: payload
            )
        }
        return (items, plan.skipped)
    }

    private static func archiveEntries(
        from file: ManagedBookFile
    ) throws -> [ManagedArchiveEntry] {
        guard let url = URL(string: file.reference), url.isFileURL else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let archive = try Archive(url: url, accessMode: .read)
        var paths = Set<String>()
        var result: [ManagedArchiveEntry] = []
        var totalBytes: UInt64 = 0
        for entry in archive where entry.type == .file {
            guard isSafeArchivePath(entry.path), paths.insert(entry.path).inserted else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard entry.uncompressedSize <= 32 * 1_024 * 1_024 else {
                throw CocoaError(.fileReadTooLarge)
            }
            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(
                entry.uncompressedSize
            )
            guard !overflow, nextTotal <= 128 * 1_024 * 1_024 else {
                throw CocoaError(.fileReadTooLarge)
            }
            totalBytes = nextTotal
            var data = Data()
            data.reserveCapacity(Int(entry.uncompressedSize))
            _ = try archive.extract(entry) { data.append($0) }
            result.append(ManagedArchiveEntry(path: entry.path, data: data))
        }
        return result
    }

    private static func isSafeArchivePath(_ path: String) -> Bool {
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return !path.isEmpty
            && !path.hasPrefix("/")
            && !path.hasSuffix("/")
            && !components.contains { $0.isEmpty || $0 == "." || $0 == ".." }
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
