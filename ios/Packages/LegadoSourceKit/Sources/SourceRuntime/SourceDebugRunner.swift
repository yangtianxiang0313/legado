import Foundation
import RuleRuntime

public enum SourceDebugOperation: String, Codable, Sendable {
  case search
  case explore
  case bookInfo = "book_info"
  case toc
  case content
}

public struct SourceDebugRoute: Equatable, Sendable {
  public let operation: SourceDebugOperation
  public let payload: String

  public init(operation: SourceDebugOperation, payload: String) {
    self.operation = operation
    self.payload = payload
  }

  public static func parse(_ input: String) -> SourceDebugRoute {
    let lowercased = input.lowercased()
    if lowercased.hasPrefix("http://")
      || lowercased.hasPrefix("https://")
    {
      return SourceDebugRoute(operation: .bookInfo, payload: input)
    }
    if let separator = input.range(of: "::") {
      return SourceDebugRoute(
        operation: .explore,
        payload: String(input[separator.upperBound...])
      )
    }
    if input.hasPrefix("++") {
      return SourceDebugRoute(
        operation: .toc,
        payload: String(input.dropFirst(2))
      )
    }
    if input.hasPrefix("--") {
      return SourceDebugRoute(
        operation: .content,
        payload: String(input.dropFirst(2))
      )
    }
    return SourceDebugRoute(operation: .search, payload: input)
  }
}

public enum SourceDebugOutcome: String, Codable, Sendable {
  case completed
  case failed
}

public struct SourceDebugField: Codable, Equatable, Sendable {
  public let name: String
  public let value: String

  public init(_ name: String, _ value: String) {
    self.name = name
    self.value = value
  }
}

public struct SourceDebugNetworkExchange:
  Codable,
  Equatable,
  Sendable
{
  public let method: String
  public let requestURL: String
  public let requestHeaderNames: [String]
  public let requestBodyByteCount: Int
  public let statusCode: Int?
  public let responseURL: String?
  public let responseBodyByteCount: Int?
  public let responsePreview: String?
  public let failure: String?

  public init(
    request: HTTPRequest,
    response: HTTPResponse? = nil,
    failure: String? = nil
  ) {
    method = request.method.rawValue
    requestURL = request.url.absoluteString
    requestHeaderNames = Array(
      Set(request.headers.fields.map(\.name))
    ).sorted()
    requestBodyByteCount = request.body?.bytes.count ?? 0
    statusCode = response?.statusCode
    responseURL = response?.effectiveURL.absoluteString
    responseBodyByteCount = response?.body.bytes.count
    responsePreview = response.map {
      String(
        String(decoding: $0.body.bytes, as: UTF8.self)
          .prefix(2_000)
      )
    }
    self.failure = failure
  }
}

public struct SourceDebugFailure: Codable, Equatable, Sendable {
  public let type: String
  public let message: String
  public let runtimeStage: String?
  public let runtimeCode: String?

  public init(
    type: String,
    message: String,
    runtimeStage: String? = nil,
    runtimeCode: String? = nil
  ) {
    self.type = type
    self.message = message
    self.runtimeStage = runtimeStage
    self.runtimeCode = runtimeCode
  }
}

public struct SourceDebugStageReport:
  Codable,
  Equatable,
  Sendable
{
  public let stage: SourceDebugOperation
  public let outcome: SourceDebugOutcome
  public let network: [SourceDebugNetworkExchange]
  public let fields: [SourceDebugField]
  public let failure: SourceDebugFailure?

  public init(
    stage: SourceDebugOperation,
    outcome: SourceDebugOutcome,
    network: [SourceDebugNetworkExchange] = [],
    fields: [SourceDebugField] = [],
    failure: SourceDebugFailure? = nil
  ) {
    self.stage = stage
    self.outcome = outcome
    self.network = network
    self.fields = fields
    self.failure = failure
  }
}

public struct SourceDebugReport: Codable, Equatable, Sendable {
  public let input: String
  public let entryOperation: SourceDebugOperation
  public let outcome: SourceDebugOutcome
  public let stages: [SourceDebugStageReport]

  public init(
    input: String,
    entryOperation: SourceDebugOperation,
    outcome: SourceDebugOutcome,
    stages: [SourceDebugStageReport]
  ) {
    self.input = input
    self.entryOperation = entryOperation
    self.outcome = outcome
    self.stages = stages
  }
}

public enum SourceDebugRunnerError: Error, Equatable, Sendable {
  case emptyBookList
  case emptyChapterList
  case invalidBookURL
}

/// Runs the same production pipelines used by search, explore, book detail,
/// TOC and reader content. The runner only orchestrates and records them; it
/// does not implement a second parser for debug mode.
public struct SourceDebugRunner: Sendable {
  private let definition: SourceSearchDefinition
  private let exploreDefinition: SourceExploreDefinition?
  private let transport: any HTTPTransport
  private let cookieStore: SourceCookieStore
  private let dynamicWebPagePort: (any SourceDynamicWebPagePort)?
  private let scriptRuntime: (any SourceScriptRuntime)?
  private let htmlSelectorBackend: (any HTMLSelectorBackend)?

  public init(
    definition: SourceSearchDefinition,
    exploreDefinition: SourceExploreDefinition? = nil,
    transport: any HTTPTransport,
    cookieStore: SourceCookieStore = SourceCookieStore(),
    dynamicWebPagePort: (any SourceDynamicWebPagePort)? = nil,
    scriptRuntime: (any SourceScriptRuntime)? = nil,
    htmlSelectorBackend: (any HTMLSelectorBackend)? = nil
  ) {
    self.definition = definition
    self.exploreDefinition = exploreDefinition
    self.transport = transport
    self.cookieStore = cookieStore
    self.dynamicWebPagePort = dynamicWebPagePort
    self.scriptRuntime = scriptRuntime
    self.htmlSelectorBackend = htmlSelectorBackend
  }

  public func run(_ input: String) async -> SourceDebugReport {
    let route = SourceDebugRoute.parse(input)
    let recorder = SourceDebugTransportRecorder(transport)
    var stages: [SourceDebugStageReport] = []
    var currentStage = route.operation
    var exchangeOffset = 0

    do {
      var bookSeed: SourceDebugBookSeed?
      var resolvedBook: SourceBook?
      var tocExecution: SourceTOCExecution?

      switch route.operation {
      case .search:
        currentStage = .search
        let execution = try await search(
          route.payload,
          transport: recorder
        )
        stages.append(
          await stage(
            .search,
            recorder: recorder,
            offset: &exchangeOffset,
            fields: bookListFields(execution.books)
          )
        )
        guard let first = execution.books.first else {
          throw SourceDebugRunnerError.emptyBookList
        }
        bookSeed = try sourceBook(from: first)
      case .explore:
        currentStage = .explore
        let execution = try await explore(
          route.payload,
          transport: recorder
        )
        stages.append(
          await stage(
            .explore,
            recorder: recorder,
            offset: &exchangeOffset,
            fields: bookListFields(execution.books)
          )
        )
        guard let first = execution.books.first else {
          throw SourceDebugRunnerError.emptyBookList
        }
        bookSeed = try sourceBook(from: first)
      case .bookInfo:
        bookSeed = SourceDebugBookSeed(
          book: try sourceBook(url: route.payload),
          infoHTML: nil
        )
      case .toc:
        currentStage = .toc
        let execution = try await toc(
          route.payload,
          transport: recorder
        )
        tocExecution = execution
        resolvedBook = execution.book
        stages.append(
          await stage(
            .toc,
            recorder: recorder,
            offset: &exchangeOffset,
            fields: chapterFields(execution.chapters)
          )
        )
      case .content:
        break
      }

      if let bookSeed {
        currentStage = .bookInfo
        let execution = try await bookInfo(
          bookSeed,
          transport: recorder
        )
        resolvedBook = execution.book
        stages.append(
          await stage(
            .bookInfo,
            recorder: recorder,
            offset: &exchangeOffset,
            fields: bookFields(execution.book)
          )
        )

        currentStage = .toc
        let toc = try await toc(
          execution,
          transport: recorder
        )
        tocExecution = toc
        resolvedBook = toc.book
        stages.append(
          await stage(
            .toc,
            recorder: recorder,
            offset: &exchangeOffset,
            fields: chapterFields(toc.chapters)
          )
        )
      }

      let contentURL: String
      let nextContentURL: String?
      let bookVariables: [String: String]
      let chapterVariables: [String: String]
      if route.operation == .content {
        contentURL = route.payload
        nextContentURL = nil
        bookVariables = [:]
        chapterVariables = [:]
      } else {
        guard
          let tocExecution,
          let firstIndex = firstReadableChapterIndex(
            tocExecution.chapters
          )
        else {
          throw SourceDebugRunnerError.emptyChapterList
        }
        let chapter = tocExecution.chapters[firstIndex]
        contentURL = chapter.endpoint.requestExpression
        nextContentURL = tocExecution.chapters
          .dropFirst(firstIndex + 1)
          .first?
          .endpoint.requestExpression
        bookVariables =
          resolvedBook?.variables
          ?? tocExecution.book.variables
        chapterVariables = chapter.variables
      }

      currentStage = .content
      let content = try await content(
        contentURL,
        nextURL: nextContentURL,
        bookVariables: bookVariables,
        chapterVariables: chapterVariables,
        transport: recorder
      )
      stages.append(
        await stage(
          .content,
          recorder: recorder,
          offset: &exchangeOffset,
          fields: [
            SourceDebugField(
              "character_count",
              String(content.content.content.count)
            ),
            SourceDebugField(
              "preview",
              String(content.content.content.prefix(500))
            ),
          ]
        )
      )
      return SourceDebugReport(
        input: input,
        entryOperation: route.operation,
        outcome: .completed,
        stages: stages
      )
    } catch {
      let network = await recorder.exchanges(from: exchangeOffset)
      stages.append(
        SourceDebugStageReport(
          stage: currentStage,
          outcome: .failed,
          network: network,
          failure: failure(error)
        )
      )
      return SourceDebugReport(
        input: input,
        entryOperation: route.operation,
        outcome: .failed,
        stages: stages
      )
    }
  }

  private func search(
    _ keyword: String,
    transport: any HTTPTransport
  ) async throws -> SourceSearchExecution {
    try await SourceSearchPipeline(
      definition: definition,
      transport: transport,
      cookieStore: cookieStore,
      dynamicWebPagePort: dynamicWebPagePort,
      scriptRuntime: scriptRuntime,
      htmlSelectorBackend: htmlSelectorBackend
    ).search(SourceSearchInput(keyword: keyword, page: 1))
  }

  private func explore(
    _ url: String,
    transport: any HTTPTransport
  ) async throws -> SourceSearchExecution {
    guard let exploreDefinition else {
      throw SourceExplorePipelineError.disabled
    }
    return try await SourceExplorePipeline(
      definition: exploreDefinition,
      transport: transport,
      cookieStore: cookieStore,
      dynamicWebPagePort: dynamicWebPagePort,
      scriptRuntime: scriptRuntime,
      htmlSelectorBackend: htmlSelectorBackend
    ).explore(
      SourceExploreInput(
        category: SourceExploreCategory(
          title: "debug",
          urlTemplate: url
        ),
        page: 1
      )
    )
  }

  private func bookInfo(
    _ seed: SourceDebugBookSeed,
    transport: any HTTPTransport
  ) async throws -> SourceBookInfoExecution {
    try await SourceBookInfoPipeline(
      definition: definition,
      transport: transport,
      cookieStore: cookieStore,
      dynamicWebPagePort: dynamicWebPagePort,
      scriptRuntime: scriptRuntime,
      htmlSelectorBackend: htmlSelectorBackend
    ).load(book: seed.book, infoHTML: seed.infoHTML)
  }

  private func toc(
    _ bookInfo: SourceBookInfoExecution,
    transport: any HTTPTransport
  ) async throws -> SourceTOCExecution {
    try await SourceTOCPipeline(
      definition: definition,
      transport: transport,
      cookieStore: cookieStore,
      dynamicWebPagePort: dynamicWebPagePort,
      scriptRuntime: scriptRuntime,
      htmlSelectorBackend: htmlSelectorBackend
    ).chapters(
      book: bookInfo.book,
      infoHTML: bookInfo.response.body
    )
  }

  private func toc(
    _ url: String,
    transport: any HTTPTransport
  ) async throws -> SourceTOCExecution {
    try await SourceTOCPipeline(
      definition: definition,
      transport: transport,
      cookieStore: cookieStore,
      dynamicWebPagePort: dynamicWebPagePort,
      scriptRuntime: scriptRuntime,
      htmlSelectorBackend: htmlSelectorBackend
    ).chapters(tocURL: url)
  }

  private func content(
    _ url: String,
    nextURL: String?,
    bookVariables: [String: String],
    chapterVariables: [String: String],
    transport: any HTTPTransport
  ) async throws -> SourceContentExecution {
    try await SourceContentPipeline(
      definition: definition,
      transport: transport,
      cookieStore: cookieStore,
      dynamicWebPagePort: dynamicWebPagePort,
      scriptRuntime: scriptRuntime,
      htmlSelectorBackend: htmlSelectorBackend
    ).content(
      chapterURL: url,
      nextChapterURL: nextURL,
      bookVariables: bookVariables,
      chapterVariables: chapterVariables
    )
  }

  private func sourceBook(
    from book: SourceSearchBook
  ) throws -> SourceDebugBookSeed {
    guard let sourceURL = URL(string: definition.sourceURL) else {
      throw SourceDebugRunnerError.invalidBookURL
    }
    return SourceDebugBookSeed(
      book: SourceBook(
        name: book.name,
        author: book.author,
        intro: book.intro,
        kind: book.kind,
        wordCount: book.wordCount,
        lastChapter: book.lastChapter,
        bookEndpoint: try SourceEndpoint(
          resolving: book.bookRequestExpression,
          relativeTo: sourceURL
        ),
        coverURL: book.coverURL.flatMap(URL.init(string:)),
        tocEndpoint: nil,
        variables: book.variables
      ),
      infoHTML: book.infoHTML
    )
  }

  private func sourceBook(url: String) throws -> SourceBook {
    guard let sourceURL = URL(string: definition.sourceURL) else {
      throw SourceDebugRunnerError.invalidBookURL
    }
    return SourceBook(
      name: "",
      author: nil,
      intro: nil,
      kind: nil,
      lastChapter: nil,
      bookEndpoint: try SourceEndpoint(
        resolving: url,
        relativeTo: sourceURL
      ),
      coverURL: nil,
      tocEndpoint: nil
    )
  }

  private func stage(
    _ operation: SourceDebugOperation,
    recorder: SourceDebugTransportRecorder,
    offset: inout Int,
    fields: [SourceDebugField]
  ) async -> SourceDebugStageReport {
    let network = await recorder.exchanges(from: offset)
    offset += network.count
    return SourceDebugStageReport(
      stage: operation,
      outcome: .completed,
      network: network,
      fields: fields
    )
  }

  private func bookListFields(
    _ books: [SourceSearchBook]
  ) -> [SourceDebugField] {
    var fields = [
      SourceDebugField("book_count", String(books.count))
    ]
    if let first = books.first {
      fields.append(SourceDebugField("first_name", first.name))
      fields.append(SourceDebugField("first_author", first.author))
      fields.append(SourceDebugField("first_url", first.bookURL))
    }
    return fields
  }

  private func bookFields(_ book: SourceBook) -> [SourceDebugField] {
    [
      SourceDebugField("name", book.name),
      SourceDebugField("author", book.author ?? ""),
      SourceDebugField("book_url", book.bookURL.absoluteString),
      SourceDebugField(
        "toc_url",
        book.tocURL?.absoluteString ?? ""
      ),
    ]
  }

  private func chapterFields(
    _ chapters: [SourceChapter]
  ) -> [SourceDebugField] {
    var fields = [
      SourceDebugField("chapter_count", String(chapters.count))
    ]
    if let first = chapters.first {
      fields.append(SourceDebugField("first_title", first.title))
      fields.append(
        SourceDebugField(
          "first_url",
          first.endpoint.requestExpression
        )
      )
    }
    return fields
  }

  private func firstReadableChapterIndex(
    _ chapters: [SourceChapter]
  ) -> Int? {
    chapters.firstIndex {
      !(
        $0.isVolume
          && $0.endpoint.requestExpression.hasPrefix($0.title)
      )
    }
  }

  private func failure(_ error: any Error) -> SourceDebugFailure {
    if let issue = error as? SourceRuntimeIssue {
      return SourceDebugFailure(
        type: String(reflecting: type(of: error)),
        message: String(describing: error),
        runtimeStage: issue.stage.rawValue,
        runtimeCode: issue.code.rawValue
      )
    }
    return SourceDebugFailure(
      type: String(reflecting: type(of: error)),
      message: String(describing: error)
    )
  }
}

private struct SourceDebugBookSeed {
  let book: SourceBook
  let infoHTML: String?
}

private actor SourceDebugTransportRecorder: HTTPTransport {
  private let transport: any HTTPTransport
  private var values: [SourceDebugNetworkExchange] = []

  init(_ transport: any HTTPTransport) {
    self.transport = transport
  }

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    do {
      let response = try await transport.execute(request)
      values.append(
        SourceDebugNetworkExchange(
          request: request,
          response: response
        )
      )
      return response
    } catch {
      values.append(
        SourceDebugNetworkExchange(
          request: request,
          failure: String(describing: error)
        )
      )
      throw error
    }
  }

  func exchanges(from offset: Int) -> [SourceDebugNetworkExchange] {
    guard values.indices.contains(offset) || offset == values.count else {
      return []
    }
    return Array(values.dropFirst(offset))
  }
}
