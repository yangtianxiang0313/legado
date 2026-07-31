import AppUseCases
import Foundation

/// iOS adapter for Android's per-book reader image cache directory.
actor ReaderImageFileStore: ReaderImageDataStore {
    private let directory: URL

    init() {
        let cacheRoot = (
            try? FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        ) ?? FileManager.default.temporaryDirectory
        directory = cacheRoot.appendingPathComponent(
            "Legado/ReaderImages",
            isDirectory: true
        )
    }

    func data(for key: ReaderImageCacheKey) async -> [UInt8]? {
        guard let data = try? Data(contentsOf: fileURL(for: key)) else {
            return nil
        }
        return Array(data)
    }

    func store(_ value: [UInt8], for key: ReaderImageCacheKey) async {
        let target = fileURL(for: key)
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(value).write(to: target, options: .atomic)
        } catch {
            // Cache persistence is an optimization: a write failure must not
            // prevent the already decoded image from rendering in this session.
        }
    }

    private func fileURL(for key: ReaderImageCacheKey) -> URL {
        directory
            .appendingPathComponent(digest(key.bookID.rawValue), isDirectory: true)
            .appendingPathComponent("\(digest(key.sourceURL)).bin")
    }

    private func digest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
