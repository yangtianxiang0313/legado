import Foundation
import LegadoCore
import RuleRuntime
import SourceNetworkComposition
import SourceRuntime
import SourceRuntimeComposition

enum RealSourceInteropConformanceError: Error, CustomStringConvertible {
  case invalidFixture
  case selectedBookMissing
  case selectedChapterMissing
  case stageFailed(stage: String, cause: String)

  var description: String {
    switch self {
    case .invalidFixture: "invalid_real_source_fixture"
    case .selectedBookMissing: "selected_book_missing"
    case .selectedChapterMissing: "selected_chapter_missing"
    case .stageFailed(let stage, let cause):
      "real_source_stage_failed[\(stage)]: \(cause)"
    }
  }
}

enum RealSourceInteropConformanceRunner {
  static func runLive(fixtureDirectory: URL) async throws -> Data {
    try await run(
      fixtureDirectory: fixtureDirectory,
      transport: SourceNetworkComposition.makeTransport(),
      htmlSelectorBackend:
        SourceRuntimeComposition.makeHTMLSelectorBackend()
    )
  }

  static func run(
    fixtureDirectory: URL,
    transport: any HTTPTransport
  ) async throws -> Data {
    try await run(
      fixtureDirectory: fixtureDirectory,
      transport: transport,
      htmlSelectorBackend:
        SourceRuntimeComposition.makeHTMLSelectorBackend()
    )
  }

  static func run(
    fixtureDirectory: URL,
    transport: any HTTPTransport,
    htmlSelectorBackend: any HTMLSelectorBackend
  ) async throws -> Data {
    let sourceData = try Data(
      contentsOf: fixtureDirectory.appendingPathComponent("source.json")
    )
    let input = try input(
      Data(
        contentsOf: fixtureDirectory.appendingPathComponent("input.json")
      )
    )
    let compiled = try BookSourceRuntimeCompiler.compile(sourceData)
    let definition = compiled.definition

    let search = try await stage("search") {
      try await SourceSearchPipeline(
        definition: definition,
        transport: transport,
        htmlSelectorBackend: htmlSelectorBackend
      ).search(SourceSearchInput(keyword: input.keyword, page: 1))
    }
    guard let selected = search.books.first(where: {
      $0.name == input.bookTitle
    }) else {
      throw RealSourceInteropConformanceError.selectedBookMissing
    }
    let seed = try sourceBook(selected, definition: definition)
    let detail = try await stage("book_info") {
      try await SourceBookInfoPipeline(
        definition: definition,
        transport: transport,
        htmlSelectorBackend: htmlSelectorBackend
      ).load(book: seed.book, infoHTML: seed.infoHTML)
    }
    let toc: SourceTOCExecution
    do {
      toc = try await SourceTOCPipeline(
        definition: definition,
        transport: transport,
        htmlSelectorBackend: htmlSelectorBackend
      ).chapters(
        book: detail.book,
        infoHTML: detail.response.body
      )
    } catch {
      throw RealSourceInteropConformanceError.stageFailed(
        stage: "toc",
        cause: String(describing: error)
      )
    }
    guard let chapter = toc.chapters.first(where: {
      $0.title == input.chapterTitle
    }) else {
      throw RealSourceInteropConformanceError.selectedChapterMissing
    }
    let content = try await stage("content") {
      try await SourceContentPipeline(
        definition: definition,
        transport: transport,
        htmlSelectorBackend: htmlSelectorBackend
      ).content(
        endpoint: chapter.endpoint,
        bookVariables: toc.book.variables,
        chapterVariables: chapter.variables
      )
    }

    let cases: [JSONValue] = [
      caseValue(
        id: "real-search",
        operation: "search",
        result: .object([
          "books": .array(search.books.prefix(5).map(bookValue)),
        ])
      ),
      caseValue(
        id: "real-book-info",
        operation: "book_info",
        result: bookValue(detail.book)
      ),
      caseValue(
        id: "real-toc",
        operation: "chapters",
        result: .object([
          "chapters": .array(
            toc.chapters.prefix(32).enumerated().map(chapterValue)
          ),
        ])
      ),
      caseValue(
        id: "real-content",
        operation: "content",
        result: .object([
          "chapter_title": .string(content.content.title ?? chapter.title),
          "chapter_url": .string(chapter.endpoint.logicalURL.absoluteString),
          "content_characters": number(content.content.content.utf16.count),
          "content_sample": .string(
            String(content.content.content.prefix(240))
          ),
        ])
      ),
    ]
    return try JSONValueCodec.encode(
      .object([
        "schema_version": number(1),
        "fixture_id": .string("rs-wikisource-public-domain-001"),
        "engine": .object([
          "platform": .string("ios"),
          "compatibility_profile": .string("android-legado-v1"),
          "revision": .string("source-runtime-product-v1"),
        ]),
        "result": .object([
          "type": .string("real_source_capture"),
          "value": .object([
            "portable_known_projection": .object([
              "cases": .array(cases),
            ]),
          ]),
        ]),
        "issues": .array([]),
      ])
    )
  }

  private static func input(_ data: Data) throws -> (
    keyword: String,
    bookTitle: String,
    chapterTitle: String
  ) {
    guard
      case .object(let value) = try JSONValueCodec.decode(data),
      case .string(let keyword)? = value["keyword"],
      case .string(let bookTitle)? = value["book_title"],
      case .string(let chapterTitle)? = value["chapter_title"]
    else {
      throw RealSourceInteropConformanceError.invalidFixture
    }
    return (keyword, bookTitle, chapterTitle)
  }

  private static func stage<Value>(
    _ name: String,
    operation: () async throws -> Value
  ) async throws -> Value {
    do {
      return try await operation()
    } catch {
      throw RealSourceInteropConformanceError.stageFailed(
        stage: name,
        cause: String(describing: error)
      )
    }
  }

  private static func sourceBook(
    _ book: SourceSearchBook,
    definition: SourceSearchDefinition
  ) throws -> (book: SourceBook, infoHTML: String?) {
    guard let sourceURL = URL(string: definition.sourceURL) else {
      throw RealSourceInteropConformanceError.invalidFixture
    }
    return (
      SourceBook(
        name: book.name,
        author: nilIfEmpty(book.author),
        intro: nilIfEmpty(book.intro),
        kind: nilIfEmpty(book.kind),
        wordCount: nilIfEmpty(book.wordCount),
        lastChapter: nilIfEmpty(book.lastChapter),
        bookEndpoint: try SourceEndpoint(
          resolving: book.bookRequestExpression,
          relativeTo: sourceURL
        ),
        coverURL: book.coverURL.flatMap(URL.init(string:)),
        tocEndpoint: nil,
        variables: book.variables
      ),
      book.infoHTML
    )
  }

  private static func caseValue(
    id: String,
    operation: String,
    result: JSONValue
  ) -> JSONValue {
    .object([
      "id": .string(id),
      "issue": .null,
      "operation": .string(operation),
      "result": result,
    ])
  }

  private static func bookValue(_ book: SourceSearchBook) -> JSONValue {
    .object([
      "name": .string(book.name),
      "author": .string(book.author),
      "intro": .string(book.intro),
      "kind": nullable(book.kind),
      "last_chapter": .string(book.lastChapter),
      "book_url": .string(book.bookURL),
      "cover_url": nullable(book.coverURL),
    ])
  }

  private static func bookValue(_ book: SourceBook) -> JSONValue {
    .object([
      "name": .string(book.name),
      "author": .string(book.author ?? ""),
      "intro": nullable(book.intro),
      "kind": nullable(book.kind),
      "last_chapter": .string(book.lastChapter ?? ""),
      "book_url": .string(book.bookURL.absoluteString),
      "cover_url": nullable(book.coverURL?.absoluteString),
      "toc_url": nullable(book.tocURL?.absoluteString),
    ])
  }

  private static func chapterValue(
    _ offset: Int,
    _ chapter: SourceChapter
  ) -> JSONValue {
    .object([
      "index": number(offset),
      "title": .string(chapter.title),
      "url": .string(chapter.endpoint.logicalURL.absoluteString),
      "is_vip": .bool(chapter.isVIP),
      "is_pay": .bool(chapter.isPay),
      "is_volume": .bool(chapter.isVolume),
    ])
  }

  private static func nullable(_ value: String?) -> JSONValue {
    guard let value = nilIfEmpty(value) else { return .null }
    return .string(value)
  }

  private static func nilIfEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  private static func number(_ value: Int) -> JSONValue {
    .number(JSONNumber(Int64(value)))
  }
}
