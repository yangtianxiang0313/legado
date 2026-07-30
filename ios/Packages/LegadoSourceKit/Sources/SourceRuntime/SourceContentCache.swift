import CryptoKit
import Foundation

public struct SourceCacheBook: Hashable, Sendable {
  public let url: String
  public let name: String
  public let isLocalText: Bool

  public init(url: String, name: String, isLocalText: Bool = false) {
    self.url = url
    self.name = name
    self.isLocalText = isLocalText
  }
}

public struct SourceCacheChapter: Hashable, Sendable {
  public let url: String
  public let title: String
  public let index: Int
  public let isVolume: Bool

  public init(
    url: String,
    title: String,
    index: Int,
    isVolume: Bool = false
  ) {
    self.url = url
    self.title = title
    self.index = index
    self.isVolume = isVolume
  }
}

public actor SourceContentCache {
  private let root: URL
  private let fileManager: FileManager

  public init(
    root: URL,
    fileManager: FileManager = FileManager()
  ) {
    self.root = root
    self.fileManager = fileManager
  }

  public func hasContent(
    book: SourceCacheBook,
    chapter: SourceCacheChapter
  ) -> Bool {
    if book.isLocalText {
      return true
    }
    if chapter.isVolume, chapter.url.hasPrefix(chapter.title) {
      return true
    }
    return fileManager.fileExists(
      atPath: contentURL(book: book, chapter: chapter).path
    )
  }

  public func saveText(
    _ content: String,
    book: SourceCacheBook,
    chapter: SourceCacheChapter
  ) throws {
    guard !content.isEmpty else {
      return
    }
    let destination = contentURL(book: book, chapter: chapter)
    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(content.utf8).write(to: destination, options: .atomic)
  }

  public func text(
    book: SourceCacheBook,
    chapter: SourceCacheChapter
  ) throws -> String? {
    let source = contentURL(book: book, chapter: chapter)
    guard fileManager.fileExists(atPath: source.path) else {
      return nil
    }
    return String(
      decoding: try Data(contentsOf: source),
      as: UTF8.self
    )
  }

  public func deleteText(
    book: SourceCacheBook,
    chapter: SourceCacheChapter
  ) throws {
    let target = contentURL(book: book, chapter: chapter)
    guard fileManager.fileExists(atPath: target.path) else {
      return
    }
    try fileManager.removeItem(at: target)
  }

  public func chapterFiles(book: SourceCacheBook) throws -> [String] {
    let directory = bookDirectory(book)
    guard fileManager.fileExists(atPath: directory.path) else {
      return []
    }
    return try fileManager
      .contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasSuffix(".nb") }
      .sorted()
  }

  public func clear(book: SourceCacheBook) throws {
    let directory = bookDirectory(book)
    guard fileManager.fileExists(atPath: directory.path) else {
      return
    }
    try fileManager.removeItem(at: directory)
  }

  public func writeImage(
    _ data: Data,
    sourceURL: String,
    book: SourceCacheBook
  ) throws {
    let destination = imageURL(book: book, sourceURL: sourceURL)
    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: destination, options: .atomic)
  }

  public func imageExists(
    sourceURL: String,
    book: SourceCacheBook
  ) -> Bool {
    fileManager.fileExists(
      atPath: imageURL(book: book, sourceURL: sourceURL).path
    )
  }

  public func hasImageContent(
    book: SourceCacheBook,
    chapter: SourceCacheChapter
  ) throws -> Bool {
    guard hasContent(book: book, chapter: chapter),
      let content = try text(book: book, chapter: chapter)
    else {
      return false
    }
    for source in Self.imageSources(in: content) {
      let image = imageURL(book: book, sourceURL: source)
      guard fileManager.fileExists(atPath: image.path) else {
        return false
      }
      let data = try Data(contentsOf: image)
      guard Self.isSupportedImage(data) else {
        try? fileManager.removeItem(at: image)
        return false
      }
    }
    return true
  }

  public nonisolated static func chapterFileName(
    index: Int,
    title: String
  ) -> String {
    String(format: "%05d-%@.nb", index, md5Middle16(title))
  }

  public nonisolated static func md5Middle16(_ value: String) -> String {
    let digest = Insecure.MD5.hash(data: Data(value.utf8))
    let full = digest.map { String(format: "%02x", $0) }.joined()
    return String(full.dropFirst(8).prefix(16))
  }

  private func contentURL(
    book: SourceCacheBook,
    chapter: SourceCacheChapter
  ) -> URL {
    bookDirectory(book).appendingPathComponent(
      Self.chapterFileName(index: chapter.index, title: chapter.title)
    )
  }

  private func imageURL(
    book: SourceCacheBook,
    sourceURL: String
  ) -> URL {
    let rawSuffix = URL(string: sourceURL)?.pathExtension.lowercased()
    let suffix: String
    if let rawSuffix,
      !rawSuffix.isEmpty,
      rawSuffix.allSatisfy({ $0.isLetter || $0.isNumber })
    {
      suffix = rawSuffix
    } else {
      suffix = "jpg"
    }
    return bookDirectory(book)
      .appendingPathComponent("images", isDirectory: true)
      .appendingPathComponent(
        "\(Self.md5Middle16(sourceURL)).\(suffix)"
      )
  }

  private func bookDirectory(_ book: SourceCacheBook) -> URL {
    let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|\n\r\t")
    let sanitized = book.name.unicodeScalars
      .filter { !invalid.contains($0) }
      .map(String.init)
      .joined()
    let prefix = String(sanitized.prefix(9))
    return root.appendingPathComponent(
      prefix + Self.md5Middle16(book.url),
      isDirectory: true
    )
  }

  private nonisolated static func imageSources(in content: String) -> [String] {
    guard let expression = try? NSRegularExpression(
      pattern: #"<img\b[^>]*\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,
      options: [.caseInsensitive]
    ) else {
      return []
    }
    let range = NSRange(content.startIndex..., in: content)
    return expression.matches(in: content, range: range).compactMap { match in
      for index in 1...3 {
        let candidate = match.range(at: index)
        if candidate.location != NSNotFound,
          let range = Range(candidate, in: content)
        {
          return String(content[range])
        }
      }
      return nil
    }
  }

  private nonisolated static func isSupportedImage(_ data: Data) -> Bool {
    let bytes = [UInt8](data.prefix(12))
    if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47])
      || bytes.starts(with: [0xFF, 0xD8, 0xFF])
      || bytes.starts(with: [0x47, 0x49, 0x46, 0x38])
      || (
        bytes.count >= 12
          && Array(bytes[0..<4]) == [0x52, 0x49, 0x46, 0x46]
          && Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50]
      )
    {
      return true
    }
    guard let text = String(data: data, encoding: .utf8),
      text.range(of: #"<svg\b"#, options: .regularExpression) != nil
    else {
      return false
    }
    return positiveSVGAttribute("width", in: text)
      && positiveSVGAttribute("height", in: text)
      || positiveSVGViewBox(in: text)
  }

  private nonisolated static func positiveSVGAttribute(
    _ name: String,
    in text: String
  ) -> Bool {
    let pattern = #"\b\#(name)\s*=\s*["']\s*([0-9]+(?:\.[0-9]+)?)"#
    guard let expression = try? NSRegularExpression(
      pattern: pattern,
      options: [.caseInsensitive]
    ) else {
      return false
    }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = expression.firstMatch(in: text, range: range),
      let valueRange = Range(match.range(at: 1), in: text),
      let value = Double(text[valueRange])
    else {
      return false
    }
    return value > 0
  }

  private nonisolated static func positiveSVGViewBox(in text: String) -> Bool {
    let pattern =
      #"\bviewBox\s*=\s*["']\s*[-0-9.]+\s+[-0-9.]+\s+([0-9.]+)\s+([0-9.]+)"#
    guard let expression = try? NSRegularExpression(
      pattern: pattern,
      options: [.caseInsensitive]
    ) else {
      return false
    }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = expression.firstMatch(in: text, range: range),
      let widthRange = Range(match.range(at: 1), in: text),
      let heightRange = Range(match.range(at: 2), in: text),
      let width = Double(text[widthRange]),
      let height = Double(text[heightRange])
    else {
      return false
    }
    return width > 0 && height > 0
  }
}

public enum SourceCacheFailureKind: Equatable, Sendable {
  case ordinary
  case concurrent
}

public struct SourceCacheFailureTransition: Equatable, Sendable {
  public let errorCount: Int
  public let waitingDuringBackoff: Bool
  public let requeued: Bool

  public init(
    errorCount: Int,
    waitingDuringBackoff: Bool,
    requeued: Bool
  ) {
    self.errorCount = errorCount
    self.waitingDuringBackoff = waitingDuringBackoff
    self.requeued = requeued
  }
}

public struct SourceCacheQueueSnapshot: Equatable, Sendable {
  public let waitingIndices: [Int]
  public let downloadingIndices: [Int]
  public let isRunning: Bool
  public let isStopped: Bool

  public var waitingCount: Int { waitingIndices.count }
  public var downloadingCount: Int { downloadingIndices.count }
}

public actor SourceCacheQueueModel {
  public let bookURL: String

  private var waiting: Set<Int> = []
  private var downloading: Set<Int> = []
  private var successes: Set<String> = []
  private var errorCounts: [String: Int] = [:]
  private var explicitlyStopped = false
  private var waitingRetry = false

  public init(bookURL: String) {
    self.bookURL = bookURL
  }

  public func addDownload(_ range: ClosedRange<Int>) {
    explicitlyStopped = false
    for index in range where !downloading.contains(index) {
      waiting.insert(index)
    }
  }

  public func stop() {
    explicitlyStopped = true
    waiting.removeAll()
  }

  public func beginAttempt(_ index: Int) {
    waiting.remove(index)
    downloading.insert(index)
  }

  public func recordFailure(
    index: Int,
    key: String,
    kind: SourceCacheFailureKind
  ) -> SourceCacheFailureTransition {
    waitingRetry = true
    if kind == .ordinary {
      errorCounts[key, default: 0] += 1
    }
    let count = errorCounts[key, default: 0]
    let shouldRequeue =
      !explicitlyStopped && (kind == .concurrent || count < 3)
    downloading.remove(index)
    waitingRetry = false
    if shouldRequeue {
      waiting.insert(index)
    }
    return SourceCacheFailureTransition(
      errorCount: count,
      waitingDuringBackoff: true,
      requeued: shouldRequeue
    )
  }

  public func beginFailure(
    index: Int,
    key: String,
    kind: SourceCacheFailureKind
  ) -> Int {
    waitingRetry = true
    if kind == .ordinary {
      errorCounts[key, default: 0] += 1
    }
    return errorCounts[key, default: 0]
  }

  @discardableResult
  public func finishFailure(
    index: Int,
    key: String,
    kind: SourceCacheFailureKind
  ) -> Bool {
    let count = errorCounts[key, default: 0]
    let shouldRequeue =
      !explicitlyStopped && (kind == .concurrent || count < 3)
    downloading.remove(index)
    waitingRetry = false
    if shouldRequeue {
      waiting.insert(index)
    }
    return shouldRequeue
  }

  public func setErrorCount(_ count: Int, for key: String) {
    if count > 0 {
      errorCounts[key] = count
    } else {
      errorCounts.removeValue(forKey: key)
    }
  }

  public func completeSuccess(index: Int, key: String) {
    waiting.remove(index)
    downloading.remove(index)
    errorCounts.removeValue(forKey: key)
    successes.insert(key)
  }

  public func cancel(index: Int) {
    downloading.remove(index)
    if !explicitlyStopped {
      waiting.insert(index)
    }
  }

  public func errorCount(for key: String) -> Int {
    errorCounts[key, default: 0]
  }

  public func containsSuccess(_ key: String) -> Bool {
    successes.contains(key)
  }

  public func containsWaiting(_ index: Int) -> Bool {
    waiting.contains(index)
  }

  public func containsDownloading(_ index: Int) -> Bool {
    downloading.contains(index)
  }

  public func snapshot() -> SourceCacheQueueSnapshot {
    let running = !waiting.isEmpty || !downloading.isEmpty || waitingRetry
    return SourceCacheQueueSnapshot(
      waitingIndices: waiting.sorted(),
      downloadingIndices: downloading.sorted(),
      isRunning: running,
      isStopped: !running
    )
  }

  public func prepareWaitingRetryWithoutQueuedWork() {
    waiting.removeAll()
    downloading.removeAll()
    waitingRetry = true
  }

  public func shouldRemainRegistered() -> Bool {
    !waiting.isEmpty || !downloading.isEmpty
  }
}

public actor SourceCacheQueueRegistry {
  private var models: [String: SourceCacheQueueModel] = [:]

  public init() {}

  public func model(for bookURL: String) -> SourceCacheQueueModel {
    if let model = models[bookURL] {
      return model
    }
    let model = SourceCacheQueueModel(bookURL: bookURL)
    models[bookURL] = model
    return model
  }

  public func contains(_ bookURL: String) -> Bool {
    models[bookURL] != nil
  }

  public func finish(_ bookURL: String) async {
    guard let model = models[bookURL],
      !(await model.shouldRemainRegistered())
    else {
      return
    }
    models.removeValue(forKey: bookURL)
  }

  public func removeAll() {
    models.removeAll()
  }
}
