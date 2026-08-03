import AppUseCases
import Foundation
import SourceRuntime
import XCTest

final class DictionaryJSoupCompatibilityTests: XCTestCase {
  func testFrozenBaiduScriptUsesDOMTransformPort() async throws {
    let transformer = DictionaryDOMTransformerStub()
    let pipeline = DictionaryLookupPipeline(
      transport: DictionaryHTMLTransport(),
      domTransformer: transformer
    )
    let script = #"""
    @js:var jsoup = org.jsoup.Jsoup.parse(result)
    jsoup.select("script,#word-header,#term-header,.more-button,.disactive,#download-wrapper,#upload-dialog,#right-panel,#success-dialog,.toast-wrap,div[style^=color],.baike-feedback,#cishumean-wrapper,#syn_ant_wrapper,#baike-wrapper").remove()
    jsoup.select("#content-panel").html()
    """#

    let result = try await pipeline.lookup(
      word: "星河",
      rule: DictionaryRuntimeRule(
        name: "百度汉语",
        urlRule: "https://dict.baidu.test/s?wd={{key}}",
        showRule: script
      )
    )

    XCTAssertEqual(result.content, "<div>干净释义</div>")
    XCTAssertEqual(transformer.resultSelector, "#content-panel")
    XCTAssertTrue(transformer.removingSelector?.contains("#right-panel") == true)
  }

  func testUnrecognizedJavaBridgeScriptStillFailsExplicitly() async throws {
    let pipeline = DictionaryLookupPipeline(
      transport: DictionaryHTMLTransport(),
      domTransformer: DictionaryDOMTransformerStub()
    )
    do {
      _ = try await pipeline.lookup(
        word: "词",
        rule: DictionaryRuntimeRule(
          name: "其他",
          urlRule: "https://dict.test?q={{key}}",
          showRule: "@js:org.example.Unknown.run(result)"
        )
      )
      XCTFail("expected capability denial")
    } catch let issue as SourceScriptIssue {
      XCTAssertEqual(issue.code, .capabilityDenied)
    }
  }
}

private final class DictionaryDOMTransformerStub:
  DictionaryDOMTransforming, @unchecked Sendable
{
  var removingSelector: String?
  var resultSelector: String?

  func innerHTML(
    html: String,
    removing selector: String,
    selecting resultSelector: String
  ) throws -> String {
    removingSelector = selector
    self.resultSelector = resultSelector
    return "<div>干净释义</div>"
  }
}

private struct DictionaryHTMLTransport: HTTPTransport {
  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    try HTTPResponse(
      statusCode: 200,
      effectiveURL: request.url,
      headers: HTTPHeaders(),
      body: HTTPBody(Data("<html><div id='content-panel'>raw</div></html>".utf8))
    )
  }
}
