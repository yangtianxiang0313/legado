import Foundation
import Observation
import SourceFormat

public struct BookSourceImportMetadata: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var enabledExplore: Bool
  public var lastUpdateTime: Int64
  public var customOrder: Int32

  public init(
    enabled: Bool = true,
    enabledExplore: Bool = true,
    lastUpdateTime: Int64 = 0,
    customOrder: Int32 = 0
  ) {
    self.enabled = enabled
    self.enabledExplore = enabledExplore
    self.lastUpdateTime = lastUpdateTime
    self.customOrder = customOrder
  }
}

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
  public var importMetadata: BookSourceImportMetadata?
  public var rawDefinition: Data?
  /// Runtime user state. Kept outside the encoded source definition so
  /// importing or replacing a source cannot overwrite it.
  public var userVariable: String = ""

  public var id: String { sourceURL }

  private enum CodingKeys: String, CodingKey {
    case sourceURL
    case name
    case loginURL
    case group
    case comment
    case searchURL
    case exploreURL
    case searchRule
    case exploreRule
    case bookInfoRule
    case tocRule
    case contentRule
    case importMetadata
    case rawDefinition
  }

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
    contentRule: String = "",
    importMetadata: BookSourceImportMetadata? = nil,
    rawDefinition: Data? = nil
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
    self.importMetadata = importMetadata
    self.rawDefinition = rawDefinition
  }
}

public enum SourceDraftDefinitionCodec {
  public static func hydrate(
    _ source: BookSourceDraft
  ) -> BookSourceDraft {
    guard
      let rawDefinition = source.rawDefinition,
      let edit = try? BookSourceEditorCodec.project(
        rawDefinition
      )
    else {
      return source
    }
    var hydrated = source
    if hydrated.searchRule.isEmpty {
      hydrated.searchRule = edit.searchRule
    }
    if hydrated.exploreRule.isEmpty {
      hydrated.exploreRule = edit.exploreRule
    }
    if hydrated.bookInfoRule.isEmpty {
      hydrated.bookInfoRule = edit.bookInfoRule
    }
    if hydrated.tocRule.isEmpty {
      hydrated.tocRule = edit.tocRule
    }
    if hydrated.contentRule.isEmpty {
      hydrated.contentRule = edit.contentRule
    }
    return hydrated
  }

  public static func synchronize(
    _ source: BookSourceDraft
  ) throws -> BookSourceDraft {
    let metadata = source.importMetadata ?? .init()
    let edit = BookSourceEditableDefinition(
      sourceURL: source.sourceURL,
      name: source.name,
      group: source.group,
      comment: source.comment,
      loginURL: source.loginURL,
      searchURL: source.searchURL,
      exploreURL: source.exploreURL,
      searchRule: source.searchRule,
      exploreRule: source.exploreRule,
      bookInfoRule: source.bookInfoRule,
      tocRule: source.tocRule,
      contentRule: source.contentRule,
      enabled: metadata.enabled,
      enabledExplore: metadata.enabledExplore,
      lastUpdateTime: metadata.lastUpdateTime,
      customOrder: metadata.customOrder
    )
    var synchronized = source
    synchronized.rawDefinition =
      try BookSourceEditorCodec.applying(
        edit,
        to: source.rawDefinition
      )
    return synchronized
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
  func saveSources(_ sources: [BookSourceDraft]) async throws
  func replaceSources(_ sources: [BookSourceDraft]) async throws
  func resetSources() async throws
  func loadSourceUserVariables() async throws -> [String: String]
  func saveSourceUserVariable(
    _ variable: String?,
    sourceID: String
  ) async throws
}

public extension SourceCatalogRepository {
  func saveSources(_ sources: [BookSourceDraft]) async throws {
    for source in sources {
      try await saveSource(source)
    }
  }

  func loadSourceUserVariables() async throws -> [String: String] {
    [:]
  }

  func saveSourceUserVariable(
    _ variable: String?,
    sourceID: String
  ) async throws {}
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
      var loaded = try await repository.loadSources()
      let variables = try await repository.loadSourceUserVariables()
      for index in loaded.indices {
        loaded[index] = SourceDraftDefinitionCodec.hydrate(
          loaded[index]
        )
        loaded[index].userVariable =
          variables[loaded[index].sourceURL] ?? ""
      }
      sources = loaded
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
  public func saveUserVariable(
    _ variable: String,
    sourceID: String
  ) async -> Bool {
    do {
      try await repository.saveSourceUserVariable(
        variable,
        sourceID: sourceID
      )
      guard let index = sources.firstIndex(where: {
        $0.sourceURL == sourceID
      }) else {
        errorMessage = "书源不存在"
        return false
      }
      sources[index].userVariable = variable
      errorMessage = nil
      return true
    } catch {
      errorMessage = "无法保存书源变量"
      return false
    }
  }

  @discardableResult
  public func save(_ source: BookSourceDraft) async -> Bool {
    do {
      try await repository.saveSource(
        try SourceDraftDefinitionCodec.synchronize(source)
      )
      await reload()
      return true
    } catch {
      errorMessage = "无法保存书源"
      return false
    }
  }

  @discardableResult
  public func importSources(_ sources: [BookSourceDraft]) async -> Bool {
    do {
      try await repository.saveSources(
        try sources.map(
          SourceDraftDefinitionCodec.synchronize
        )
      )
      await reload()
      return true
    } catch {
      errorMessage = "无法导入书源"
      return false
    }
  }

  @discardableResult
  public func apply(
    _ mutation: SourceBulkMutation,
    selectedIDs: Set<String>
  ) async -> Bool {
    do {
      let updated = SourceManagementPolicy.applying(
        mutation,
        to: sources,
        selectedIDs: selectedIDs
      )
      let synchronized = try updated.map(
        SourceDraftDefinitionCodec.synchronize
      )
      try await repository.replaceSources(synchronized)
      sources = synchronized
      errorMessage = nil
      return true
    } catch {
      errorMessage = "无法更新书源"
      return false
    }
  }

  @discardableResult
  public func delete(selectedIDs: Set<String>) async -> Bool {
    do {
      let updated = sources.filter {
        !selectedIDs.contains($0.sourceURL)
      }
      try await repository.replaceSources(updated)
      sources = updated
      errorMessage = nil
      return true
    } catch {
      errorMessage = "无法删除书源"
      return false
    }
  }

  public func exportData(selectedIDs: Set<String>) throws -> Data {
    try SourceManagementPolicy.exportData(
      sources,
      selectedIDs: selectedIDs
    )
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
