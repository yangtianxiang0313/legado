public enum ReaderContentReadResult: Equatable, Sendable {
  case content(String)
  case failure(message: String?)
}

public struct ReaderContentAcquisitionContext: Equatable, Sendable {
  public let chapterExists: Bool
  public let cachedContent: String?
  public let isLocalBook: Bool
  public let localReadResult: ReaderContentReadResult?
  public let sourceAvailable: Bool

  public init(
    chapterExists: Bool,
    cachedContent: String?,
    isLocalBook: Bool,
    localReadResult: ReaderContentReadResult?,
    sourceAvailable: Bool
  ) {
    self.chapterExists = chapterExists
    self.cachedContent = cachedContent
    self.isLocalBook = isLocalBook
    self.localReadResult = localReadResult
    self.sourceAvailable = sourceAvailable
  }
}

public enum ReaderContentAcquisitionAction: Equatable, Sendable {
  case finish
  case loadSource
}

public struct ReaderContentAcquisitionPlan: Equatable, Sendable {
  public let action: ReaderContentAcquisitionAction
  public let chapterLoaded: Bool
  public let initialContent: String?
  public let sourcePresent: Bool

  public init(
    action: ReaderContentAcquisitionAction,
    chapterLoaded: Bool,
    initialContent: String?,
    sourcePresent: Bool
  ) {
    self.action = action
    self.chapterLoaded = chapterLoaded
    self.initialContent = initialContent
    self.sourcePresent = sourcePresent
  }
}

public enum ReaderContentState: String, Equatable, Sendable {
  case missing
  case text
}

public struct ReaderContentAcquisitionOutcome: Equatable, Sendable {
  public let initialContent: String?
  public let contentAfterLoad: String?
  public let chapterLoaded: Bool
  public let sourcePresent: Bool
  public let sourceDelegated: Bool
  public let downloadFailureCount: Int
  public let downloadMarkedSuccess: Bool
  public let loadingCleared: Bool

  public init(
    initialContent: String?,
    contentAfterLoad: String?,
    chapterLoaded: Bool,
    sourcePresent: Bool,
    sourceDelegated: Bool,
    downloadFailureCount: Int,
    downloadMarkedSuccess: Bool,
    loadingCleared: Bool
  ) {
    self.initialContent = initialContent
    self.contentAfterLoad = contentAfterLoad
    self.chapterLoaded = chapterLoaded
    self.sourcePresent = sourcePresent
    self.sourceDelegated = sourceDelegated
    self.downloadFailureCount = downloadFailureCount
    self.downloadMarkedSuccess = downloadMarkedSuccess
    self.loadingCleared = loadingCleared
  }

  public var initialContentState: ReaderContentState {
    Self.state(of: initialContent)
  }

  public var cachedContentAfterLoad: ReaderContentState {
    Self.state(of: contentAfterLoad)
  }

  private static func state(of content: String?) -> ReaderContentState {
    guard let content, !content.isEmpty else { return .missing }
    return .text
  }
}

public enum AndroidReaderContentAcquisitionPolicy {
  public static func plan(
    for context: ReaderContentAcquisitionContext
  ) -> ReaderContentAcquisitionPlan {
    guard context.chapterExists else {
      return ReaderContentAcquisitionPlan(
        action: .finish,
        chapterLoaded: false,
        initialContent: nil,
        sourcePresent: false
      )
    }

    if let cachedContent = nonEmpty(context.cachedContent) {
      return ReaderContentAcquisitionPlan(
        action: .finish,
        chapterLoaded: true,
        initialContent: cachedContent,
        sourcePresent: context.sourceAvailable
      )
    }

    if context.isLocalBook {
      return ReaderContentAcquisitionPlan(
        action: .finish,
        chapterLoaded: true,
        initialContent: localContent(from: context.localReadResult),
        sourcePresent: false
      )
    }

    return ReaderContentAcquisitionPlan(
      action: context.sourceAvailable ? .loadSource : .finish,
      chapterLoaded: true,
      initialContent: nil,
      sourcePresent: context.sourceAvailable
    )
  }

  public static func complete(
    _ plan: ReaderContentAcquisitionPlan,
    sourceResult: ReaderContentReadResult? = nil
  ) -> ReaderContentAcquisitionOutcome {
    guard plan.action == .loadSource else {
      return outcome(
        plan: plan,
        content: plan.initialContent,
        delegated: false,
        failureCount: 0,
        markedSuccess: false
      )
    }

    switch sourceResult {
    case .content(let content):
      return outcome(
        plan: plan,
        content: content,
        delegated: true,
        failureCount: 0,
        markedSuccess: true
      )
    case .failure, nil:
      return outcome(
        plan: plan,
        content: nil,
        delegated: true,
        failureCount: 1,
        markedSuccess: false
      )
    }
  }

  private static func outcome(
    plan: ReaderContentAcquisitionPlan,
    content: String?,
    delegated: Bool,
    failureCount: Int,
    markedSuccess: Bool
  ) -> ReaderContentAcquisitionOutcome {
    ReaderContentAcquisitionOutcome(
      initialContent: plan.initialContent,
      contentAfterLoad: content,
      chapterLoaded: plan.chapterLoaded,
      sourcePresent: plan.sourcePresent,
      sourceDelegated: delegated,
      downloadFailureCount: failureCount,
      downloadMarkedSuccess: markedSuccess,
      loadingCleared: true
    )
  }

  private static func nonEmpty(_ content: String?) -> String? {
    guard let content, !content.isEmpty else { return nil }
    return content
  }

  private static func localContent(
    from result: ReaderContentReadResult?
  ) -> String? {
    switch result {
    case .content(let content):
      return nonEmpty(content)
    case .failure(let message):
      return "获取本地书籍内容失败\n\(message ?? "null")"
    case nil:
      return nil
    }
  }
}
