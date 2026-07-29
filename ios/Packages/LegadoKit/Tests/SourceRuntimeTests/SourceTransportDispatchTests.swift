import Foundation
import XCTest

@testable import SourceRuntime

final class SourceTransportDispatchTests: XCTestCase {
  func testCompilerPreservesRawPOSTAndAddsAndroidJSONContentType() throws {
    let inherited = [
      try SourceHeaderField(name: "X-Source", value: "dispatch-contract")
    ]
    let raw = try SourceTransportDispatchCompiler.compile(
      SourceTransportDispatchInput(
        url: "http://sourcelab.test/transport/post-raw",
        method: .post,
        body: "raw=星河&kept=true",
        inheritedHeaders: inherited,
        optionHeaders: [
          try SourceHeaderField(
            name: "Content-Type",
            value: "text/plain; charset=utf-8"
          )
        ],
        returnKind: .response
      )
    )
    XCTAssertEqual(raw.body, "raw=星河&kept=true")
    XCTAssertEqual(
      raw.request?.headers.values(for: "content-type"),
      ["text/plain; charset=utf-8"]
    )

    let json = try SourceTransportDispatchCompiler.compile(
      SourceTransportDispatchInput(
        url: "http://sourcelab.test/transport/post-json",
        method: .post,
        body: #"{"keyword":"星河","page":1}"#,
        inheritedHeaders: inherited,
        returnKind: .response
      )
    )
    XCTAssertEqual(
      json.request?.headers.values(for: "content-type"),
      ["application/json; charset=UTF-8"]
    )
    XCTAssertEqual(
      json.canonicalHeaders.map(\.name),
      ["content-type", "x-source"]
    )
  }

  func testDataURIShortCircuitsTransportForBothByteViews() async throws {
    let transport = RecordingDispatchTransport(responses: [:])
    let plan = try SourceTransportDispatchCompiler.compile(
      SourceTransportDispatchInput(
        url: "data:application/octet-stream;base64,U291cmNlTGFiLeaYn+aysQ==",
        inheritedHeaders: [
          try SourceHeaderField(name: "X-Source", value: "dispatch-contract")
        ],
        returnKind: .dataURI
      )
    )
    let value = try await SourceTransportDispatcher(
      transport: transport
    ).dispatch(plan)
    guard case .dataURI(let projection) = value else {
      return XCTFail("expected data URI projection")
    }
    XCTAssertEqual(projection.byteArray, projection.inputStreamBytes)
    XCTAssertEqual(
      projection.byteArray.base64EncodedString(),
      "U291cmNlTGFiLeaYn+aysQ=="
    )
    let requestCount = await transport.requestCount()
    XCTAssertEqual(requestCount, 0)
    XCTAssertNil(plan.request)
  }

  func testNetworkResponseKindsUseInjectedTransport() async throws {
    let response = try HTTPResponse(
      statusCode: 206,
      effectiveURL: HTTPURL(
        "http://sourcelab.test/transport/get-response"
      ),
      body: HTTPBody(Data("typed-星河\n".utf8))
    )
    let transport = RecordingDispatchTransport(
      responses: [response.effectiveURL.absoluteString: response]
    )
    let dispatcher = SourceTransportDispatcher(transport: transport)
    let base = SourceTransportDispatchInput(
      url: response.effectiveURL.absoluteString,
      inheritedHeaders: [
        try SourceHeaderField(name: "X-Source", value: "dispatch-contract")
      ],
      returnKind: .response
    )

    guard case .response(let raw) = try await dispatcher.dispatch(
      SourceTransportDispatchCompiler.compile(base)
    ) else {
      return XCTFail("expected response projection")
    }
    XCTAssertEqual(raw.statusCode, 206)
    XCTAssertEqual(raw.bytes, response.body.bytes)

    let typed = try SourceTransportDispatchCompiler.compile(
      SourceTransportDispatchInput(
        url: response.effectiveURL.absoluteString,
        inheritedHeaders: base.inheritedHeaders,
        returnKind: .typedString(type: "application/octet-stream")
      )
    )
    guard case .hexString(let hex) = try await dispatcher.dispatch(typed) else {
      return XCTFail("expected hex projection")
    }
    XCTAssertEqual(hex.bodyHex, "74797065642de6989fe6b2b30a")

    let bytes = try SourceTransportDispatchCompiler.compile(
      SourceTransportDispatchInput(
        url: response.effectiveURL.absoluteString,
        returnKind: .byteArray
      )
    )
    guard case .byteArray(let byteArray) = try await dispatcher.dispatch(bytes)
    else {
      return XCTFail("expected bytes")
    }
    XCTAssertEqual(byteArray, response.body.bytes)

    let stream = try SourceTransportDispatchCompiler.compile(
      SourceTransportDispatchInput(
        url: response.effectiveURL.absoluteString,
        returnKind: .inputStream
      )
    )
    guard case .inputStream(let streamBytes) = try await dispatcher.dispatch(stream)
    else {
      return XCTFail("expected stream bytes")
    }
    XCTAssertEqual(streamBytes, response.body.bytes)
    let requestCount = await transport.requestCount()
    XCTAssertEqual(requestCount, 4)
  }

  func testMediaAndClientPoliciesRemainOutsideTransport() async throws {
    let transport = RecordingDispatchTransport(responses: [:])
    let dispatcher = SourceTransportDispatcher(transport: transport)
    let media = try SourceTransportDispatchCompiler.compile(
      SourceTransportDispatchInput(
        url: "http://sourcelab.test/transport/media",
        inheritedHeaders: [
          try SourceHeaderField(name: "X-Source", value: "dispatch-contract")
        ],
        optionHeaders: [
          try SourceHeaderField(name: "X-Media", value: "source-lab")
        ],
        returnKind: .mediaModels
      )
    )
    guard case .mediaModels(let models) = try await dispatcher.dispatch(media)
    else {
      return XCTFail("expected media models")
    }
    XCTAssertEqual(models.imageURL, models.mediaURL)
    XCTAssertEqual(
      models.imageHeaders.map(\.name),
      ["X-Media", "X-Source"]
    )

    let policy = try SourceTransportDispatchCompiler.compile(
      SourceTransportDispatchInput(
        url: "http://sourcelab.test/transport/client-policy",
        inheritedHeaders: [
          try SourceHeaderField(
            name: "proxy",
            value: "http://127.0.0.1:18080"
          ),
          try SourceHeaderField(name: "X-Policy", value: "source"),
        ],
        returnKind: .clientPolicy,
        readTimeoutMilliseconds: 750
      )
    )
    guard case .clientPolicy(let projected) =
      try await dispatcher.dispatch(policy)
    else {
      return XCTFail("expected client policy")
    }
    XCTAssertTrue(projected.proxyConfigured)
    XCTAssertEqual(projected.proxyType, .http)
    XCTAssertEqual(projected.readTimeoutMilliseconds, 750)
    XCTAssertEqual(projected.callTimeoutMilliseconds, 60_000)
    XCTAssertEqual(projected.requestHeaders.map(\.name), ["X-Policy"])
    let requestCount = await transport.requestCount()
    XCTAssertEqual(requestCount, 0)
  }
}

private actor RecordingDispatchTransport: HTTPTransport {
  private let responses: [String: HTTPResponse]
  private var count = 0

  init(responses: [String: HTTPResponse]) {
    self.responses = responses
  }

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    count += 1
    guard let response = responses[request.url.absoluteString] else {
      throw HTTPTransportFailure.invalidRequest
    }
    return response
  }

  func requestCount() -> Int {
    count
  }
}
