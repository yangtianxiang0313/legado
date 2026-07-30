public struct ReaderSessionCloseState: Equatable, Sendable {
  public var callbackID: String?
  public var message: String?
  public var preDownloadIsActive: Bool
  public var downloadChildrenAreActive: Bool
  public var mainChildrenAreActive: Bool
  public var downloadedChapterCount: Int
  public var downloadFailureCount: Int
  public var imageCacheEntryCount: Int
  public var loadingChapterIndices: [Int]
  public var previousLayoutListenerIsAttached: Bool
  public var currentLayoutListenerIsAttached: Bool
  public var nextLayoutListenerIsAttached: Bool

  public init(
    callbackID: String?,
    message: String?,
    preDownloadIsActive: Bool,
    downloadChildrenAreActive: Bool,
    mainChildrenAreActive: Bool,
    downloadedChapterCount: Int,
    downloadFailureCount: Int,
    imageCacheEntryCount: Int,
    loadingChapterIndices: [Int],
    previousLayoutListenerIsAttached: Bool,
    currentLayoutListenerIsAttached: Bool,
    nextLayoutListenerIsAttached: Bool
  ) {
    self.callbackID = callbackID
    self.message = message
    self.preDownloadIsActive = preDownloadIsActive
    self.downloadChildrenAreActive = downloadChildrenAreActive
    self.mainChildrenAreActive = mainChildrenAreActive
    self.downloadedChapterCount = downloadedChapterCount
    self.downloadFailureCount = downloadFailureCount
    self.imageCacheEntryCount = imageCacheEntryCount
    self.loadingChapterIndices = loadingChapterIndices
    self.previousLayoutListenerIsAttached =
      previousLayoutListenerIsAttached
    self.currentLayoutListenerIsAttached =
      currentLayoutListenerIsAttached
    self.nextLayoutListenerIsAttached = nextLayoutListenerIsAttached
  }
}

public enum ReaderSessionCloseEffect: Equatable, Sendable {
  case clearCallback
  case clearMessage
  case cancelPreDownload
  case cancelDownloadChildren
  case cancelMainChildren
  case clearDownloadedChapters
  case clearDownloadFailures
  case clearImageCache
  case cancelCurrentLayout
}

public struct ReaderSessionCloseOutcome: Equatable, Sendable {
  public let state: ReaderSessionCloseState
  public let effects: [ReaderSessionCloseEffect]

  public init(
    state: ReaderSessionCloseState,
    effects: [ReaderSessionCloseEffect]
  ) {
    self.state = state
    self.effects = effects
  }
}

public enum AndroidReaderSessionClosePolicy {
  public static func close(
    _ original: ReaderSessionCloseState,
    invokingCallbackID: String
  ) -> ReaderSessionCloseOutcome {
    var state = original
    var effects: [ReaderSessionCloseEffect] = []
    if state.callbackID == invokingCallbackID {
      state.callbackID = nil
      effects.append(.clearCallback)
    }
    state.message = nil
    state.preDownloadIsActive = false
    state.downloadChildrenAreActive = false
    state.mainChildrenAreActive = false
    state.downloadedChapterCount = 0
    state.downloadFailureCount = 0
    state.imageCacheEntryCount = 0
    state.currentLayoutListenerIsAttached = false
    effects.append(contentsOf: [
      .clearMessage,
      .cancelPreDownload,
      .cancelDownloadChildren,
      .cancelMainChildren,
      .clearDownloadedChapters,
      .clearDownloadFailures,
      .clearImageCache,
      .cancelCurrentLayout,
    ])
    return ReaderSessionCloseOutcome(state: state, effects: effects)
  }
}
