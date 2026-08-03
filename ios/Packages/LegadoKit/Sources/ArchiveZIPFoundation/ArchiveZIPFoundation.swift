import Foundation
import ZIPFoundation

public enum ArchiveZIPFoundation {
    public static let implementationName = "ZIPFoundation"

    public struct Member: Sendable, Equatable {
        public let path: String
        public let data: Data

        public init(path: String, data: Data) {
            self.path = path
            self.data = data
        }
    }

    public struct Descriptor: Sendable, Equatable {
        public let path: String
        public let isCompressed: Bool
        public let uncompressedSize: UInt64

        public init(
            path: String,
            isCompressed: Bool,
            uncompressedSize: UInt64
        ) {
            self.path = path
            self.isCompressed = isCompressed
            self.uncompressedSize = uncompressedSize
        }
    }

    public enum ContainerError: Error, Sendable, Equatable {
        case invalidMemberPath(String)
        case duplicateMemberPath(String)
        case memberTooLarge(String)
        case nonFileMember(String)
    }

    public static func create(
        members: [Member],
        at url: URL
    ) throws {
        var paths = Set<String>()
        for member in members {
            try validate(member.path)
            guard paths.insert(member.path).inserted else {
                throw ContainerError.duplicateMemberPath(member.path)
            }
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let archive = try Archive(url: url, accessMode: .create)
        for member in members.sorted(by: { $0.path < $1.path }) {
            try archive.addEntry(
                with: member.path,
                type: .file,
                uncompressedSize: Int64(member.data.count),
                modificationDate: Date(timeIntervalSince1970: 315_532_800),
                compressionMethod: .deflate
            ) { position, size in
                let lower = Int(position)
                let upper = min(lower + size, member.data.count)
                return member.data.subdata(in: lower..<upper)
            }
        }
    }

    public static func descriptors(at url: URL) throws -> [Descriptor] {
        let archive = try Archive(url: url, accessMode: .read)
        var paths = Set<String>()
        return try archive.map { entry in
            try validate(entry.path)
            guard paths.insert(entry.path).inserted else {
                throw ContainerError.duplicateMemberPath(entry.path)
            }
            guard entry.type == .file else {
                throw ContainerError.nonFileMember(entry.path)
            }
            return Descriptor(
                path: entry.path,
                isCompressed: entry.isCompressed,
                uncompressedSize: entry.uncompressedSize
            )
        }.sorted(by: { $0.path < $1.path })
    }

    public static func read(
        _ path: String,
        from url: URL,
        maximumBytes: UInt64 = 32 * 1_024 * 1_024
    ) throws -> Data? {
        try validate(path)
        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive[path] else { return nil }
        guard entry.type == .file else {
            throw ContainerError.nonFileMember(path)
        }
        guard entry.uncompressedSize <= maximumBytes else {
            throw ContainerError.memberTooLarge(path)
        }
        var data = Data()
        data.reserveCapacity(Int(entry.uncompressedSize))
        _ = try archive.extract(entry) { chunk in
            data.append(chunk)
        }
        return data
    }

    private static func validate(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard
            !path.isEmpty,
            !path.hasPrefix("/"),
            !path.hasSuffix("/"),
            !components.contains(where: {
                $0.isEmpty || $0 == Substring(".") || $0 == Substring("..")
            })
        else {
            throw ContainerError.invalidMemberPath(path)
        }
    }
}
