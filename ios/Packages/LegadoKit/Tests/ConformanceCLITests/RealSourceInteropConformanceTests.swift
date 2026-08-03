import Foundation
import LegadoCore
import SourceRuntime
import Testing
@testable import ConformanceCLI

@Suite("RealSourceInteropConformanceTests")
struct RealSourceInteropConformanceTests {
  @Test("runs search detail toc and content through product pipelines")
  func runsFourStageProductPipeline() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(sourceJSON.utf8).write(
      to: directory.appendingPathComponent("source.json")
    )
    try Data(
      #"{"keyword":"論語","book_title":"論語","chapter_title":"學而第一"}"#.utf8
    ).write(to: directory.appendingPathComponent("input.json"))
    let transport = SequentialRealSourceTransport()

    let data: Data
    do {
      data = try await RealSourceInteropConformanceRunner.run(
        fixtureDirectory: directory,
        transport: transport
      )
    } catch {
      Issue.record(
        "pipeline failed after \(await transport.requestCount) requests: \(error)"
      )
      return
    }
    let value = try JSONValueCodec.decode(data)
    guard
      case .object(let root) = value,
      case .object(let result)? = root["result"],
      case .object(let resultValue)? = result["value"],
      case .object(let portable)? = resultValue["portable_known_projection"],
      case .array(let cases)? = portable["cases"]
    else {
      Issue.record("missing portable real-source projection")
      return
    }

    #expect(cases.compactMap(caseID) == [
      "real-search", "real-book-info", "real-toc", "real-content",
    ])
    #expect(await transport.requestCount == 3)
    guard
      case .object(let contentCase) = cases[3],
      case .object(let content)? = contentCase["result"],
      case .string(let title)? = content["chapter_title"],
      case .number(let count)? = content["content_characters"],
      case .string(let sample)? = content["content_sample"]
    else {
      Issue.record("missing content projection")
      return
    }
    #expect(title == "論語/學而第一")
    #expect(sample == "　　學而時習之，不亦說乎？")
    #expect(count == JSONNumber(Int64("　　學而時習之，不亦說乎？".utf16.count)))
  }

  private func caseID(_ value: JSONValue) -> String? {
    guard
      case .object(let object) = value,
      case .string(let id)? = object["id"]
    else { return nil }
    return id
  }

  private var sourceJSON: String {
    #"{"bookSourceUrl":"https://zh.wikisource.org","bookSourceName":"Fixture","enabled":true,"enabledExplore":false,"searchUrl":"https://zh.wikisource.org/w/api.php?action=query&list=search&srsearch={{key}}&format=json","ruleSearch":{"bookList":"$.query.search","name":"$.title","author":"","intro":"$.snippet","kind":"","lastChapter":"","bookUrl":"$.title##^##https://zh.wikisource.org/wiki/","coverUrl":""},"ruleBookInfo":{"name":"@CSS:#firstHeading@text","author":"","intro":"@CSS:#mw-content-text .mw-parser-output > p@text","kind":"","lastChapter":"","coverUrl":"","tocUrl":"@CSS:link[rel=canonical]@href"},"ruleToc":{"chapterList":"@CSS:a[title^=論語/]","chapterName":"@CSS:a@text","chapterUrl":"@CSS:a@href"},"ruleContent":{"title":"@CSS:#firstHeading@text","content":"@CSS:#mw-content-text .mw-parser-output@text"}}"#
  }
}

private actor SequentialRealSourceTransport: HTTPTransport {
  private(set) var requestCount = 0

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    let index = requestCount
    requestCount += 1
    let body: String
    let effectiveURL: String
    switch index {
    case 0:
      body = #"{"query":{"search":[{"title":"論語","snippet":"公版"}]}}"#
      effectiveURL = request.url.absoluteString
    case 1:
      body = """
        <html><head><link rel="canonical" href="https://zh.wikisource.org/wiki/%E8%AB%96%E8%AA%9E"></head>
        <body><h1 id="firstHeading">論語</h1><div id="mw-content-text"><div class="mw-parser-output"><p>孔子弟子記錄</p><a title="論語/序說" href="/wiki/論語/序說">序說</a><a title="論語/學而第一" href="/wiki/論語/學而第一">學而第一</a></div></div></body></html>
        """
      effectiveURL = "https://zh.wikisource.org/wiki/論語"
    case 2:
      body = """
        <html><body><h1 id="firstHeading">論語/學而第一</h1><div id="mw-content-text"><div class="mw-parser-output">學而時習之，不亦說乎？</div></div></body></html>
        """
      effectiveURL = "https://zh.wikisource.org/wiki/論語/學而第一"
    default:
      body = ""
      effectiveURL = request.url.absoluteString
    }
    return try HTTPResponse(
      statusCode: 200,
      effectiveURL: HTTPURL(effectiveURL),
      body: HTTPBody(Data(body.utf8))
    )
  }
}
