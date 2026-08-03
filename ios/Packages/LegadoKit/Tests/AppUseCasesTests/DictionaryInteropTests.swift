import AppUseCases
import Foundation
import SourceRuntime
import XCTest

final class DictionaryInteropTests: XCTestCase {
  func testRuntimeSubstitutesKeyAndAppliesShowRule() async throws {
    let transport = DictionaryTransport()
    let executor = SourceRuntimeDictionaryLookupExecutor(
      pipeline: DictionaryLookupPipeline(transport: transport)
    )
    let content = try await executor.lookup(
      word: "星 河",
      rule: DictionaryRule(
        name: "JSON",
        urlRule: "https://dict.example.test/search?q={{key}}",
        showRule: "$.definition"
      )
    )

    XCTAssertEqual(content, "银河系中的恒星")
    let requestedURL = await transport.lastURL()
    XCTAssertEqual(
      requestedURL,
      "https://dict.example.test/search?q=%E6%98%9F+%E6%B2%B3"
    )
  }

  @MainActor
  func testStoreLoadsOnlyEnabledRulesInAndroidOrder() async {
    let repository = DictionaryRepositoryStub(values: [
      .init(name: "后", urlRule: "https://b", sortNumber: 9),
      .init(name: "停用", urlRule: "https://x", isEnabled: false, sortNumber: 0),
      .init(name: "先", urlRule: "https://a", sortNumber: 1),
    ])
    let store = DictionaryLookupStore(
      repository: repository,
      executor: DictionaryExecutorStub()
    )

    await store.reload()
    await store.lookup("词")

    XCTAssertEqual(store.rules.map(\.name), ["先", "后"])
    XCTAssertEqual(store.selectedRuleName, "先")
    XCTAssertEqual(store.result, "先:词")
  }
}

private actor DictionaryTransport: HTTPTransport {
  private var url: String?
  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    url = request.url.absoluteString
    return try HTTPResponse(
      statusCode: 200,
      effectiveURL: request.url,
      headers: HTTPHeaders(),
      body: HTTPBody(Data(#"{"definition":"银河系中的恒星"}"#.utf8))
    )
  }
  func lastURL() -> String? { url }
}

private struct DictionaryExecutorStub: DictionaryLookupExecuting {
  func lookup(word: String, rule: DictionaryRule) async throws -> String {
    "\(rule.name):\(word)"
  }
}

private actor DictionaryRepositoryStub: DictionaryRuleRepository {
  let values: [DictionaryRule]
  init(values: [DictionaryRule]) { self.values = values }
  func dictionaryRules() async throws -> [DictionaryRule] { values }
  func restoreAndroidDictionaryRules(_ values: [DictionaryRule]) async throws {}
}
