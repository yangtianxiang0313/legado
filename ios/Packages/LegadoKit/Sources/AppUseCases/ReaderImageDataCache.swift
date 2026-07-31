import LibraryDomain

/// Reader-image cache semantics aligned with Android's book-scoped image cache.
///
/// The cache intentionally stores decoded bytes before image rendering. This lets
/// the UI choose its own renderer while avoiding repeated network/download work.
public struct ReaderImageCacheKey: Hashable, Sendable {
  public let bookID: BookID
  public let sourceURL: String

  public init(bookID: BookID, sourceURL: String) {
    self.bookID = bookID
    self.sourceURL = sourceURL
  }
}

public actor ReaderImageDataCache {
  private var cachedValues: [ReaderImageCacheKey: [UInt8]] = [:]
  private var loadingTasks: [ReaderImageCacheKey: Task<[UInt8]?, Never>] = [:]

  public init() {}

  /// Returns a book-scoped cached value or coalesces simultaneous loads for it.
  public func value(
    for key: ReaderImageCacheKey,
    load: @escaping @MainActor @Sendable () async -> [UInt8]?
  ) async -> [UInt8]? {
    if let cached = cachedValues[key] {
      return cached
    }
    if let loading = loadingTasks[key] {
      return await loading.value
    }

    let loading = Task { @MainActor in
      await load()
    }
    loadingTasks[key] = loading
    let value = await loading.value
    loadingTasks[key] = nil
    if let value {
      cachedValues[key] = value
    }
    return value
  }

  public func removeAll() {
    cachedValues.removeAll()
  }
}
