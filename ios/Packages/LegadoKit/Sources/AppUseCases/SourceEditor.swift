import Foundation
import Observation

public struct BookSourceDraft: Codable, Equatable, Identifiable, Sendable {
  public var sourceURL: String
  public var name: String
  public var loginURL: String
  public var group: String
  public var comment: String
  public var searchURL: String
  public var exploreURL: String
  public var searchRule: String
  public var exploreRule: String
  public var bookInfoRule: String
  public var tocRule: String
  public var contentRule: String

  public var id: String { sourceURL }

  public init(
    sourceURL: String = "",
    name: String = "",
    loginURL: String = "",
    group: String = "",
    comment: String = "",
    searchURL: String = "",
    exploreURL: String = "",
    searchRule: String = "",
    exploreRule: String = "",
    bookInfoRule: String = "",
    tocRule: String = "",
    contentRule: String = ""
  ) {
    self.sourceURL = sourceURL
    self.name = name
    self.loginURL = loginURL
    self.group = group
    self.comment = comment
    self.searchURL = searchURL
    self.exploreURL = exploreURL
    self.searchRule = searchRule
    self.exploreRule = exploreRule
    self.bookInfoRule = bookInfoRule
    self.tocRule = tocRule
    self.contentRule = contentRule
  }
}

public enum SourceEditorAction: String, Codable, Sendable {
  case save
  case debug
  case login
  case search
  case finish
}

public enum SourceEditorDestination: String, Codable, Sendable {
  case dismiss
  case sourceDebug = "source_debug"
  case sourceLogin = "source_login"
  case singleSourceSearch = "single_source_search"
  case discardConfirmation = "discard_confirmation"
}

public enum SourceEditorResultCode: String, Codable, Sendable {
  case ok
  case canceled
  case other
}

public struct SourceEditorTransition: Equatable, Sendable {
  public let action: SourceEditorAction
  public let loginVisible: Bool
  public let dirty: Bool
  public let saveSucceeded: Bool
  public let requiresDiscardConfirmation: Bool
  public let destination: SourceEditorDestination?
  public let resultCode: SourceEditorResultCode?
  public let origin: String?
}

public enum SourceEditorPolicy {
  public static func transition(
    action: SourceEditorAction,
    original: BookSourceDraft,
    draft: BookSourceDraft
  ) -> SourceEditorTransition {
    let loginVisible = !draft.loginURL
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty
    let dirty = original != draft
    let actionAvailable = action != .login || loginVisible
    let valid =
      !draft.sourceURL.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty
      && !draft.name.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty
    let saveSucceeded =
      action != .finish && actionAvailable && valid

    let destination: SourceEditorDestination?
    switch action {
    case .finish:
      destination = dirty ? .discardConfirmation : .dismiss
    case .save:
      destination = saveSucceeded ? .dismiss : nil
    case .debug:
      destination = saveSucceeded ? .sourceDebug : nil
    case .login:
      destination = saveSucceeded ? .sourceLogin : nil
    case .search:
      destination = saveSucceeded ? .singleSourceSearch : nil
    }
    return SourceEditorTransition(
      action: action,
      loginVisible: loginVisible,
      dirty: dirty,
      saveSucceeded: saveSucceeded,
      requiresDiscardConfirmation: action == .finish && dirty,
      destination: destination,
      resultCode: action == .save && saveSucceeded ? .ok : nil,
      origin: saveSucceeded ? draft.sourceURL : nil
    )
  }
}

public enum SourceDebugRouteKind: String, Codable, Sendable {
  case bookInfo = "book_info"
  case explore
  case toc
  case content
  case search
}

public struct SourceDebugRoute: Equatable, Sendable {
  public let kind: SourceDebugRouteKind
  public let payload: String

  public var firstLogEvent: String {
    switch kind {
    case .bookInfo: "visit_book_info"
    case .explore: "visit_explore"
    case .toc: "visit_toc"
    case .content: "visit_content"
    case .search: "search_keyword"
    }
  }
}

public enum SourceDebugRouter {
  public static func route(for key: String) -> SourceDebugRoute {
    let lowercase = key.lowercased()
    if lowercase.hasPrefix("http://") || lowercase.hasPrefix("https://") {
      return SourceDebugRoute(kind: .bookInfo, payload: key)
    }
    if let separator = key.range(of: "::") {
      return SourceDebugRoute(
        kind: .explore,
        payload: String(key[separator.upperBound...])
      )
    }
    if key.hasPrefix("++") {
      return SourceDebugRoute(kind: .toc, payload: String(key.dropFirst(2)))
    }
    if key.hasPrefix("--") {
      return SourceDebugRoute(
        kind: .content,
        payload: String(key.dropFirst(2))
      )
    }
    return SourceDebugRoute(kind: .search, payload: key)
  }
}

public enum SourceEditCaller: String, Codable, Sendable {
  case bookDetail = "book_detail"
  case reader
}

public enum SourceEditEffect: String, Codable, Sendable {
  case reloadSource = "reload_source"
  case refreshBook = "refresh_book"
  case refreshMenu = "refresh_menu"
}

public enum SourceEditResultPolicy {
  public static func effects(
    caller: SourceEditCaller,
    result: SourceEditorResultCode
  ) -> [SourceEditEffect] {
    switch caller {
    case .bookDetail:
      result == .canceled ? [] : [.reloadSource, .refreshBook]
    case .reader:
      result == .ok ? [.reloadSource, .refreshMenu] : []
    }
  }
}

public protocol SourceCatalogRepository: Sendable {
  func loadSources() async throws -> [BookSourceDraft]
  func saveSource(_ source: BookSourceDraft) async throws
  func resetSources() async throws
}

@MainActor
@Observable
public final class SourceCatalog {
  public private(set) var sources: [BookSourceDraft] = []
  public private(set) var errorMessage: String?

  private let repository: any SourceCatalogRepository

  public init(repository: any SourceCatalogRepository) {
    self.repository = repository
  }

  public func reload() async {
    do {
      sources = try await repository.loadSources()
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      errorMessage = nil
    } catch {
      errorMessage = "无法读取书源"
    }
  }

  public func source(id: String?) -> BookSourceDraft? {
    guard let id else { return nil }
    return sources.first { $0.sourceURL == id }
  }

  @discardableResult
  public func save(_ source: BookSourceDraft) async -> Bool {
    do {
      try await repository.saveSource(source)
      await reload()
      return true
    } catch {
      errorMessage = "无法保存书源"
      return false
    }
  }

  public func reset() async {
    do {
      try await repository.resetSources()
      sources = []
      errorMessage = nil
    } catch {
      errorMessage = "无法重置书源"
    }
  }
}
