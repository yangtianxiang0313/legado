import Foundation
import LibraryDomain
import Observation
import SourceRuntime

public enum SearchScopeSelection: Equatable, Sendable {
  case all
  case groups([String])
  case source(name: String, identifier: String)

  public init(serialized: String) {
    let value = serialized.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !value.isEmpty else {
      self = .all
      return
    }
    if let separator = value.range(of: "::") {
      self = .source(
        name: String(value[..<separator.lowerBound]),
        identifier: String(value[separator.upperBound...])
      )
      return
    }
    let groups = value.split(separator: ",").map(String.init)
    self = groups.isEmpty ? .all : .groups(groups)
  }

  public var serialized: String {
    switch self {
    case .all:
      ""
    case .groups(let groups):
      groups.joined(separator: ",")
    case .source(let name, let identifier):
      "\(name)::\(identifier)"
    }
  }

  public var displayNames: [String] {
    switch self {
    case .all:
      []
    case .groups(let groups):
      groups
    case .source(let name, _):
      [name]
    }
  }

  public var isAll: Bool {
    if case .all = self { return true }
    return false
  }

  public var isSource: Bool {
    if case .source = self { return true }
    return false
  }

  public mutating func remove(displayName: String) {
    switch self {
    case .all:
      return
    case .groups(let groups):
      let remaining = groups.filter { $0 != displayName }
      self = remaining.isEmpty ? .all : .groups(remaining)
    case .source(let name, _):
      if name == displayName {
        self = .all
      }
    }
  }

  public func includes(_ source: SearchSourceDescriptor) -> Bool {
    switch self {
    case .all:
      true
    case .groups(let groups):
      groups.contains(source.group)
    case .source(_, let identifier):
      identifier == source.id
    }
  }
}

public struct SearchScopeMenuState: Equatable, Sendable {
  public let scope: SearchScopeSelection
  public let selected: [String]
  public let available: [String]

  public init(
    scope: SearchScopeSelection,
    groups: [String]
  ) {
    let uniqueGroups = groups.reduce(into: [String]()) {
      if !$0.contains($1) { $0.append($1) }
    }
    switch scope {
    case .all:
      self.scope = .all
      self.selected = []
      self.available = uniqueGroups
    case .groups(let selected):
      let valid = selected.filter(uniqueGroups.contains)
      if valid.isEmpty {
        self.scope = .all
        self.selected = []
        self.available = uniqueGroups
      } else {
        self.scope = .groups(valid)
        self.selected = valid
        self.available = uniqueGroups.filter { !valid.contains($0) }
      }
    case .source:
      self.scope = scope
      self.selected = scope.displayNames
      self.available = uniqueGroups
    }
  }

  public var allChecked: Bool {
    scope.isAll
  }
}

public enum SearchLoadingState: Equatable, Sendable {
  case idle
  case loading

  public var showsProgress: Bool {
    self == .loading
  }

  public var showsStop: Bool {
    self == .loading
  }
}

public struct SearchResult: Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let author: String
  public let kind: String
  public let lastChapter: String
  public let intro: String
  public let bookURL: String
  public let coverURL: String?
  public let origin: String
  public let originName: String
  public let originCount: Int

  public init(
    id: String,
    name: String,
    author: String,
    kind: String,
    lastChapter: String,
    intro: String,
    bookURL: String,
    coverURL: String?,
    origin: String,
    originName: String,
    originCount: Int
  ) {
    self.id = id
    self.name = name
    self.author = author
    self.kind = kind
    self.lastChapter = lastChapter
    self.intro = intro
    self.bookURL = bookURL
    self.coverURL = coverURL
    self.origin = origin
    self.originName = originName
    self.originCount = originCount
  }
}

public struct SearchSourceDescriptor: Sendable, Equatable {
  public let id: String
  public let name: String
  public let group: String
  public let definition: SourceSearchDefinition

  public init(
    id: String,
    name: String,
    group: String,
    definition: SourceSearchDefinition
  ) {
    self.id = id
    self.name = name
    self.group = group
    self.definition = definition
  }
}

public protocol SearchBooksExecuting: Sendable {
  func search(
    query: String,
    scope: SearchScopeSelection
  ) async throws -> [SearchResult]
}

public struct SourceSearchBooksExecutor: SearchBooksExecuting, Sendable {
  private let sources: [SearchSourceDescriptor]
  private let transport: any HTTPTransport

  public init(
    sources: [SearchSourceDescriptor],
    transport: any HTTPTransport
  ) {
    self.sources = sources
    self.transport = transport
  }

  public func search(
    query: String,
    scope: SearchScopeSelection
  ) async throws -> [SearchResult] {
    let selected = sources.filter(scope.includes)
    var batches: [[SearchBookCandidate]] = []
    var metadata: [String: SourceSearchBook] = [:]
    var lastError: (any Error)?

    for source in selected {
      do {
        let execution = try await SourceSearchPipeline(
          definition: source.definition,
          transport: transport
        ).search(SourceSearchInput(keyword: query, page: 1))
        batches.append(
          execution.books.map {
            metadata[$0.bookURL] = $0
            return SearchBookCandidate(
              name: $0.name,
              author: $0.author,
              bookURL: $0.bookURL,
              origin: $0.origin,
              originOrder: $0.originOrder
            )
          }
        )
      } catch {
        lastError = error
      }
    }

    if batches.isEmpty, let lastError {
      throw lastError
    }
    return SearchBookSearchState.aggregate(
      batches: batches,
      keyword: query,
      precision: false
    ).map { aggregate in
      let candidate = aggregate.representative
      let sourceBook = metadata[candidate.bookURL]
      return SearchResult(
        id: candidate.bookURL,
        name: candidate.name,
        author: candidate.author,
        kind: sourceBook?.kind ?? "",
        lastChapter: sourceBook?.lastChapter ?? "",
        intro: sourceBook?.intro ?? "",
        bookURL: candidate.bookURL,
        coverURL: sourceBook?.coverURL,
        origin: candidate.origin,
        originName: sourceBook?.originName ?? candidate.origin,
        originCount: aggregate.origins.count
      )
    }
  }
}

@MainActor
@Observable
public final class SearchSession {
  public var query: String
  public private(set) var scope: SearchScopeSelection
  public private(set) var results: [SearchResult]
  public private(set) var loadingState: SearchLoadingState
  public private(set) var errorMessage: String?

  private let groups: [String]
  private let executor: any SearchBooksExecuting
  private var searchTask: Task<Void, Never>?

  public init(
    query: String = "",
    scope: SearchScopeSelection = .all,
    groups: [String],
    executor: any SearchBooksExecuting
  ) {
    self.query = query
    self.groups = groups
    self.executor = executor
    let menu = SearchScopeMenuState(scope: scope, groups: groups)
    self.scope = menu.scope
    self.results = []
    self.loadingState = .idle
    self.errorMessage = nil
  }

  public var scopeMenu: SearchScopeMenuState {
    SearchScopeMenuState(scope: scope, groups: groups)
  }

  public func selectAllSources() {
    scope = .all
  }

  public func selectGroup(_ group: String) {
    scope = .groups([group])
  }

  public func removeScope(_ displayName: String) {
    scope.remove(displayName: displayName)
  }

  public func search() {
    searchTask?.cancel()
    let trimmed = query.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !trimmed.isEmpty else {
      results = []
      loadingState = .idle
      errorMessage = nil
      return
    }
    loadingState = .loading
    errorMessage = nil
    let selectedScope = scope
    searchTask = Task {
      do {
        let value = try await executor.search(
          query: trimmed,
          scope: selectedScope
        )
        try Task.checkCancellation()
        results = value
        loadingState = .idle
      } catch is CancellationError {
        loadingState = .idle
      } catch {
        results = []
        errorMessage = "搜索失败，请稍后重试"
        loadingState = .idle
      }
    }
  }

  public func stop() {
    searchTask?.cancel()
    searchTask = nil
    loadingState = .idle
  }
}
