import Foundation
import Observation
import SourceRuntime

public struct ExploreSourceSummary:
  Identifiable, Hashable, Sendable
{
  public let id: String
  public let name: String
  public let group: String

  public init(id: String, name: String, group: String) {
    self.id = id
    self.name = name
    self.group = group
  }
}

public struct ExploreCategoryItem:
  Identifiable, Hashable, Sendable
{
  public let id: String
  public let title: String
  public let urlTemplate: String?

  public init(
    id: String,
    title: String,
    urlTemplate: String?
  ) {
    self.id = id
    self.title = title
    self.urlTemplate = urlTemplate
  }
}

public struct ExploreSourceDescriptor: Sendable, Equatable {
  public let summary: ExploreSourceSummary
  public let definition: SourceExploreDefinition

  public init(
    summary: ExploreSourceSummary,
    definition: SourceExploreDefinition
  ) {
    self.summary = summary
    self.definition = definition
  }
}

public protocol ExploreBooksExecuting: Sendable {
  var sources: [ExploreSourceSummary] { get }

  func categories(sourceID: String) throws
    -> [ExploreCategoryItem]

  func loadPage(
    sourceID: String,
    category: ExploreCategoryItem,
    page: Int
  ) async throws -> [SearchResult]
}

public enum ExploreFlowError: Error, Equatable, Sendable {
  case sourceUnavailable
  case categoryUnavailable
}

public struct SourceExploreBooksExecutor:
  ExploreBooksExecuting, Sendable
{
  private let descriptors: [ExploreSourceDescriptor]
  private let transport: any HTTPTransport

  public init(
    descriptors: [ExploreSourceDescriptor],
    transport: any HTTPTransport
  ) {
    self.descriptors = descriptors
    self.transport = transport
  }

  public var sources: [ExploreSourceSummary] {
    descriptors.map(\.summary)
  }

  public func categories(sourceID: String) throws
    -> [ExploreCategoryItem]
  {
    guard
      let descriptor = descriptors.first(where: {
        $0.summary.id == sourceID
      })
    else {
      throw ExploreFlowError.sourceUnavailable
    }
    return try SourceExplorePipeline(
      definition: descriptor.definition,
      transport: transport
    ).categories().enumerated().map { index, category in
      ExploreCategoryItem(
        id: "\(sourceID)#\(index)#\(category.title)",
        title: category.title,
        urlTemplate: category.urlTemplate
      )
    }
  }

  public func loadPage(
    sourceID: String,
    category: ExploreCategoryItem,
    page: Int
  ) async throws -> [SearchResult] {
    guard
      let descriptor = descriptors.first(where: {
        $0.summary.id == sourceID
      })
    else {
      throw ExploreFlowError.sourceUnavailable
    }
    let execution = try await SourceExplorePipeline(
      definition: descriptor.definition,
      transport: transport
    ).explore(
      SourceExploreInput(
        category: SourceExploreCategory(
          title: category.title,
          urlTemplate: category.urlTemplate
        ),
        page: page
      )
    )
    return execution.books.map { book in
      SearchResult(
        id: book.bookURL,
        name: book.name,
        author: book.author,
        kind: book.kind,
        lastChapter: book.lastChapter,
        intro: book.intro,
        bookURL: book.bookURL,
        bookRequestExpression: book.bookRequestExpression,
        coverURL: book.coverURL,
        origin: book.origin,
        originName: book.originName,
        originCount: 1
      )
    }
  }
}

@MainActor
@Observable
public final class ExploreSession {
  public let source: ExploreSourceSummary
  public private(set) var categories: [ExploreCategoryItem]
  public private(set) var selectedCategory: ExploreCategoryItem?
  public private(set) var results: [SearchResult]
  public private(set) var loadingState: SearchLoadingState
  public private(set) var errorMessage: String?
  public private(set) var nextPage: Int
  public private(set) var canLoadMore: Bool

  private let executor: any ExploreBooksExecuting
  private var requestTask: Task<Void, Never>?
  private var requestGeneration = 0
  private var started = false

  public init(
    source: ExploreSourceSummary,
    executor: any ExploreBooksExecuting
  ) {
    self.source = source
    self.executor = executor
    self.categories = []
    self.results = []
    self.loadingState = .idle
    self.errorMessage = nil
    self.nextPage = 1
    self.canLoadMore = true
  }

  public func start() {
    guard !started else { return }
    started = true
    do {
      categories = try executor.categories(sourceID: source.id)
      guard let first = categories.first else {
        errorMessage = "该书源没有可用分类"
        canLoadMore = false
        return
      }
      selectCategory(first)
    } catch {
      errorMessage = "分类加载失败"
      canLoadMore = false
    }
  }

  public func selectCategory(_ category: ExploreCategoryItem) {
    guard categories.contains(category) else { return }
    requestGeneration += 1
    requestTask?.cancel()
    loadingState = .idle
    selectedCategory = category
    results = []
    nextPage = 1
    canLoadMore = true
    errorMessage = nil
    loadNextPage()
  }

  public func loadNextPage() {
    guard
      loadingState == .idle,
      canLoadMore,
      let selectedCategory
    else { return }
    let requestedPage = nextPage
    requestGeneration += 1
    let generation = requestGeneration
    loadingState = .loading
    errorMessage = nil
    requestTask = Task {
      do {
        let page = try await executor.loadPage(
          sourceID: source.id,
          category: selectedCategory,
          page: requestedPage
        )
        try Task.checkCancellation()
        guard generation == requestGeneration else { return }
        let known = Set(results.map(\.id))
        results.append(
          contentsOf: page.filter { !known.contains($0.id) }
        )
        nextPage = requestedPage + 1
        canLoadMore = !page.isEmpty
        loadingState = .idle
      } catch is CancellationError {
        if generation == requestGeneration {
          loadingState = .idle
        }
      } catch {
        if generation == requestGeneration {
          errorMessage = "书单加载失败，请稍后重试"
          loadingState = .idle
        }
      }
    }
  }

  public func retry() {
    guard selectedCategory != nil else {
      started = false
      start()
      return
    }
    canLoadMore = true
    loadNextPage()
  }

  public func stop() {
    requestGeneration += 1
    requestTask?.cancel()
    requestTask = nil
    loadingState = .idle
  }
}
