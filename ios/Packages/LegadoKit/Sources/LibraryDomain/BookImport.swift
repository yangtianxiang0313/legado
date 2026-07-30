import Foundation

public enum BookImportOriginKind: String, Equatable, Sendable {
  case existingShortCircuit = "existing_short_circuit"
  case exactBase = "exact_base"
  case pattern
  case localFile = "local_file"
  case archive
}

public struct ImportedBook: Equatable, Sendable {
  public let id: BookID
  public let name: String
  public let author: String
  public let originName: String
  public let originKind: BookImportOriginKind
  public let isLocal: Bool
  public let isArchive: Bool
  public let chapterCount: Int

  public init(
    id: BookID,
    name: String,
    author: String,
    originName: String,
    originKind: BookImportOriginKind,
    isLocal: Bool,
    isArchive: Bool,
    chapterCount: Int
  ) {
    self.id = id
    self.name = name
    self.author = author
    self.originName = originName
    self.originKind = originKind
    self.isLocal = isLocal
    self.isArchive = isArchive
    self.chapterCount = chapterCount
  }

  public func replacingChapterCount(_ chapterCount: Int) -> Self {
    Self(
      id: id,
      name: name,
      author: author,
      originName: originName,
      originKind: originKind,
      isLocal: isLocal,
      isArchive: isArchive,
      chapterCount: chapterCount
    )
  }
}

public enum RemoteBookSourceMatch: Equatable, Sendable {
  case exactBase
  case pattern
  case invalidPattern
  case none
}

public struct RemoteBookSourceCandidate: Equatable, Sendable {
  public let sourceID: String
  public let sourceName: String
  public let match: RemoteBookSourceMatch
  public let isEnabled: Bool

  public init(
    sourceID: String,
    sourceName: String,
    match: RemoteBookSourceMatch,
    isEnabled: Bool = true
  ) {
    self.sourceID = sourceID
    self.sourceName = sourceName
    self.match = match
    self.isEnabled = isEnabled
  }
}

public enum RemoteBookImportOutcome: String, Equatable, Sendable {
  case existing
  case added
  case skipped
  case failed
}

public enum RemoteBookSourceSelection: String, Equatable, Sendable {
  case existingShortCircuit = "existing_short_circuit"
  case exactBase = "exact_base"
  case pattern
  case none
}

public struct RemoteBookImportResult: Equatable, Sendable {
  public let outcome: RemoteBookImportOutcome
  public let sourceSelection: RemoteBookSourceSelection
  public let networkRequestCount: Int
  public let book: ImportedBook?

  public init(
    outcome: RemoteBookImportOutcome,
    sourceSelection: RemoteBookSourceSelection,
    networkRequestCount: Int,
    book: ImportedBook?
  ) {
    self.outcome = outcome
    self.sourceSelection = sourceSelection
    self.networkRequestCount = networkRequestCount
    self.book = book
  }
}

public enum RemoteBookImporter {
  public static func resolve(
    existingBook: ImportedBook?,
    orderedSources: [RemoteBookSourceCandidate],
    fetchedBook: ImportedBook?
  ) -> RemoteBookImportResult {
    if let existingBook {
      return RemoteBookImportResult(
        outcome: .existing,
        sourceSelection: .existingShortCircuit,
        networkRequestCount: 0,
        book: existingBook
      )
    }

    let enabled = orderedSources.filter(\.isEnabled)
    let selected =
      enabled.first(where: { $0.match == .exactBase })
      ?? enabled.first(where: { $0.match == .pattern })
    guard let selected else {
      return RemoteBookImportResult(
        outcome: .skipped,
        sourceSelection: .none,
        networkRequestCount: 0,
        book: nil
      )
    }
    let selection: RemoteBookSourceSelection =
      selected.match == .exactBase ? .exactBase : .pattern
    guard let fetchedBook else {
      return RemoteBookImportResult(
        outcome: .failed,
        sourceSelection: selection,
        networkRequestCount: 1,
        book: nil
      )
    }
    return RemoteBookImportResult(
      outcome: .added,
      sourceSelection: selection,
      networkRequestCount: 1,
      book: ImportedBook(
        id: fetchedBook.id,
        name: fetchedBook.name,
        author: fetchedBook.author,
        originName: selected.sourceName,
        originKind: selection == .exactBase ? .exactBase : .pattern,
        isLocal: false,
        isArchive: false,
        chapterCount: fetchedBook.chapterCount
      )
    )
  }
}

public struct ParsedLocalBookName: Equatable, Sendable {
  public let name: String
  public let author: String

  public init(name: String, author: String) {
    self.name = name
    self.author = author
  }
}

public enum LocalBookFileNameParser {
  public static func parse(_ fileName: String) -> ParsedLocalBookName {
    let stem = removingExtension(fileName)
    if
      let open = stem.firstIndex(of: "《"),
      let close = stem[stem.index(after: open)...].firstIndex(of: "》")
    {
      let name = String(stem[stem.index(after: open)..<close])
      let prefix = String(stem[..<open])
      let suffix = String(stem[stem.index(after: close)...])
      let markers = ["作者：", "作者:", "作者 "]
      if let marker = markers.first(where: { suffix.contains($0) }),
        let range = suffix.range(of: marker)
      {
        let author = prefix + suffix[range.upperBound...]
        return ParsedLocalBookName(
          name: name,
          author: String(author)
        )
      }
    }
    if let range = stem.range(of: " by ") {
      return ParsedLocalBookName(
        name: String(stem[..<range.lowerBound]),
        author: String(stem[range.upperBound...])
      )
    }
    return ParsedLocalBookName(name: stem, author: "")
  }

  private static func removingExtension(_ fileName: String) -> String {
    guard
      let dot = fileName.lastIndex(of: "."),
      dot != fileName.startIndex
    else {
      return fileName
    }
    return String(fileName[..<dot])
  }
}

public struct LocalBookArchiveEntry: Equatable, Sendable {
  public let name: String
  public let byteCount: Int

  public init(name: String, byteCount: Int) {
    self.name = name
    self.byteCount = byteCount
  }
}

public struct LocalBookImportInput: Equatable, Sendable {
  public let opaqueReference: String
  public let fileName: String
  public let byteCount: Int
  public let existingBook: ImportedBook?
  public let archiveEntries: [LocalBookArchiveEntry]?

  public init(
    opaqueReference: String,
    fileName: String,
    byteCount: Int,
    existingBook: ImportedBook? = nil,
    archiveEntries: [LocalBookArchiveEntry]? = nil
  ) {
    self.opaqueReference = opaqueReference
    self.fileName = fileName
    self.byteCount = byteCount
    self.existingBook = existingBook
    self.archiveEntries = archiveEntries
  }
}

public enum LocalBookImportOutcome: String, Equatable, Sendable {
  case added
  case updated
  case rejected
  case archiveAdded = "archive_added"
}

public enum LocalBookImportException: String, Equatable, Sendable {
  case emptyFile = "EmptyFileException"
}

public struct LocalBookImportResult: Equatable, Sendable {
  public let outcome: LocalBookImportOutcome
  public let books: [ImportedBook]
  public let databaseContainsInput: Bool
  public let exception: LocalBookImportException?

  public init(
    outcome: LocalBookImportOutcome,
    books: [ImportedBook],
    databaseContainsInput: Bool,
    exception: LocalBookImportException?
  ) {
    self.outcome = outcome
    self.books = books
    self.databaseContainsInput = databaseContainsInput
    self.exception = exception
  }
}

public struct LocalBookImportPolicy: Equatable, Sendable {
  public let supportedBookExtensions: Set<String>

  public init(
    supportedBookExtensions: Set<String> = [
      "txt", "epub", "umd", "pdf", "mobi", "azw3",
    ]
  ) {
    self.supportedBookExtensions = Set(
      supportedBookExtensions.map { $0.lowercased() }
    )
  }

  public func supports(_ fileName: String) -> Bool {
    supportedBookExtensions.contains(fileExtension(fileName))
  }

  public func isArchive(_ fileName: String) -> Bool {
    fileExtension(fileName) == "zip"
  }

  private func fileExtension(_ fileName: String) -> String {
    guard let dot = fileName.lastIndex(of: ".") else { return "" }
    return String(fileName[fileName.index(after: dot)...]).lowercased()
  }
}

public enum LocalBookImporter {
  public static func importDocument(
    _ input: LocalBookImportInput,
    policy: LocalBookImportPolicy = .init()
  ) -> LocalBookImportResult {
    if let entries = input.archiveEntries {
      let books = entries.compactMap { entry -> ImportedBook? in
        guard entry.byteCount > 0, policy.supports(entry.name) else {
          return nil
        }
        let parsed = LocalBookFileNameParser.parse(entry.name)
        return ImportedBook(
          id: BookID(
            rawValue: "\(input.opaqueReference)#\(entry.name)"
          ),
          name: parsed.name,
          author: parsed.author,
          originName: entry.name,
          originKind: .archive,
          isLocal: true,
          isArchive: true,
          chapterCount: 0
        )
      }
      return LocalBookImportResult(
        outcome: .archiveAdded,
        books: books,
        databaseContainsInput: false,
        exception: nil
      )
    }
    guard input.byteCount > 0 else {
      return LocalBookImportResult(
        outcome: .rejected,
        books: [],
        databaseContainsInput: false,
        exception: .emptyFile
      )
    }
    let parsed = LocalBookFileNameParser.parse(input.fileName)
    let book = ImportedBook(
      id: input.existingBook?.id
        ?? BookID(rawValue: input.opaqueReference),
      name: parsed.name,
      author: parsed.author,
      originName: input.fileName,
      originKind: .localFile,
      isLocal: true,
      isArchive: false,
      chapterCount: 0
    )
    return LocalBookImportResult(
      outcome: input.existingBook == nil ? .added : .updated,
      books: [book],
      databaseContainsInput: true,
      exception: nil
    )
  }
}

public indirect enum LocalBookScanNode: Equatable, Sendable {
  case file(name: String)
  case directory(name: String, children: [LocalBookScanNode])
}

public struct LocalBookScanResult: Equatable, Sendable {
  public let discoveredNames: [String]
  public let batches: [[String]]

  public init(discoveredNames: [String], batches: [[String]]) {
    self.discoveredNames = discoveredNames
    self.batches = batches
  }
}

public enum LocalBookScanner {
  public static func scan(
    _ root: LocalBookScanNode,
    policy: LocalBookImportPolicy = .init()
  ) -> LocalBookScanResult {
    var batches: [[String]] = []
    visit(root, policy: policy, batches: &batches)
    return LocalBookScanResult(
      discoveredNames: batches.flatMap { $0 }.sorted(),
      batches: batches
    )
  }

  private static func visit(
    _ node: LocalBookScanNode,
    policy: LocalBookImportPolicy,
    batches: inout [[String]]
  ) {
    guard case .directory(_, let children) = node else { return }
    let local = children.compactMap { child -> String? in
      guard case .file(let name) = child else { return nil }
      return policy.supports(name) || policy.isArchive(name)
        ? name
        : nil
    }.sorted()
    if !local.isEmpty {
      batches.append(local)
    }
    for child in children {
      if case .directory = child {
        visit(child, policy: policy, batches: &batches)
      }
    }
  }
}

public protocol BookImportCatalogPort: Sendable {
  func book(forImportReference reference: String) async throws
    -> ImportedBook?
  func saveImportedBooks(_ books: [ImportedBook]) async throws
  func removeChapters(for bookID: BookID) async throws
}

public protocol RemoteBookImportPort: Sendable {
  func sourceCandidates(for bookURL: String) async throws
    -> [RemoteBookSourceCandidate]
  func fetchBook(
    at bookURL: String,
    source: RemoteBookSourceCandidate
  ) async throws -> ImportedBook
}

public protocol LocalBookDocumentPort: Sendable {
  func document(
    at opaqueReference: String
  ) async throws -> LocalBookImportInput
  func scanTree(
    at opaqueReference: String
  ) async throws -> LocalBookScanNode
}
