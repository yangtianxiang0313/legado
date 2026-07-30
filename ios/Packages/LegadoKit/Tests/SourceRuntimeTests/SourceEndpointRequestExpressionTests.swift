import Foundation
import XCTest

@testable import SourceRuntime

final class SourceEndpointRequestExpressionTests: XCTestCase {
  func testRelativeURLResolutionPreservesRequestOption() throws {
    let base = URL(
      string: "http://sourcelab.test/books/star-river/toc"
    )!
    let expression =
      #"../chapter-1,{"method":"POST","body":"id=1","headers":{"X-Chapter":"one"},"retry":2}"#

    let endpoint = try SourceEndpoint(
      resolving: expression,
      relativeTo: base
    )

    XCTAssertEqual(
      endpoint.logicalURL.absoluteString,
      "http://sourcelab.test/books/chapter-1"
    )
    XCTAssertEqual(
      endpoint.requestExpression,
      #"http://sourcelab.test/books/chapter-1,{"method":"POST","body":"id=1","headers":{"X-Chapter":"one"},"retry":2}"#
    )
  }

  func testRequestPlanCompilesPreservedPOSTHeaderBodyAndRetry()
    throws
  {
    let endpoint = try SourceEndpoint(
      resolving:
        #"/content,{"method":"post","body":"{\"id\":1}","header":{"Content-Type":"application/json","X-Source":"chapter"},"retry":2}"#,
      relativeTo: URL(string: "http://sourcelab.test/toc")!
    )

    let plan = try endpoint.requestPlan()

    XCTAssertEqual(plan.request.method, .post)
    XCTAssertEqual(
      plan.request.url.absoluteString,
      "http://sourcelab.test/content"
    )
    XCTAssertEqual(plan.body, #"{"id":1}"#)
    XCTAssertEqual(plan.retry, 2)
    let headers = Dictionary(
      uniqueKeysWithValues: plan.optionHeaders.map {
        ($0.name.lowercased(), $0.value)
      }
    )
    XCTAssertEqual(headers["content-type"], "application/json")
    XCTAssertEqual(headers["x-source"], "chapter")
  }

  func testPlainEndpointUsesLogicalURLAsGETExpression() throws {
    let endpoint = try SourceEndpoint(
      resolving: "chapter-2",
      relativeTo: URL(
        string: "https://example.com/books/toc/"
      )!
    )

    XCTAssertEqual(
      endpoint.logicalURL.absoluteString,
      "https://example.com/books/toc/chapter-2"
    )
    XCTAssertEqual(
      try endpoint.requestPlan().request,
      HTTPRequest(
        method: .get,
        url: try HTTPURL(
          "https://example.com/books/toc/chapter-2"
        )
      )
    )
  }
}
