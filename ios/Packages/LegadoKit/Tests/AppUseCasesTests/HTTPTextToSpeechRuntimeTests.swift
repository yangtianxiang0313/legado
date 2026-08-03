import AppUseCases
import Foundation
import SourceRuntime
import XCTest

final class HTTPTextToSpeechRuntimeTests: XCTestCase {
  func testBuiltInBaiduTemplateCompilesPostBodyAndAudio() async throws {
    let transport = HTTPTextToSpeechTransport(contentType: "audio/wav")
    let engine = HTTPTextToSpeechEngine(
      id: -100,
      name: "百度",
      url: #"http://tts.baidu.com/text2audio,{"method":"POST","body":"tex={{java.encodeURI(java.encodeURI(speakText))}}&spd={{(speakSpeed + 5) / 10 + 4}}&per=3"}"#,
      contentType: "audio/wav",
      header: #"{"X-Engine":"android"}"#,
      enabledCookieJar: true
    )
    let loader = SourceRuntimeHTTPTextToSpeechAudioLoader(
      transport: transport
    )

    let audio = try await loader.load(
      engine: engine,
      text: "你好 世界",
      speed: 10
    )

    XCTAssertEqual(audio, Data([0x49, 0x44, 0x33]))
    let recorded = await transport.requests()
    let request = try XCTUnwrap(recorded.first)
    XCTAssertEqual(request.method, .post)
    XCTAssertEqual(request.url.absoluteString, "http://tts.baidu.com/text2audio")
    XCTAssertEqual(request.headers.values(for: "X-Engine"), ["android"])
    let body = String(decoding: request.body?.bytes ?? Data(), as: UTF8.self)
    XCTAssertTrue(body.contains("tex=%25E4%25BD%25A0%25E5%25A5%25BD%2B%25E4%25B8%2596%25E7%2595%258C"))
    XCTAssertTrue(body.contains("spd=5.5"))
  }

  func testCookieJarIsSharedAcrossAudioRequests() async throws {
    let transport = HTTPTextToSpeechTransport(contentType: "audio/mpeg")
    let store = SourceCookieStore()
    let pipeline = HTTPTextToSpeechPipeline(
      definition: HTTPTextToSpeechRuntimeDefinition(
        id: 7,
        urlTemplate: "https://tts.example.com/audio?text={{speakText}}",
        contentTypePattern: "audio/.*",
        enabledCookieJar: true
      ),
      transport: transport,
      cookieStore: store
    )

    _ = try await pipeline.load(text: "一", speed: 10)
    _ = try await pipeline.load(text: "二", speed: 10)

    let requests = await transport.requests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[1].headers.values(for: "cookie"), ["session=tts"])
  }

  func testRejectsAndroidJSONErrorResponse() async throws {
    let transport = HTTPTextToSpeechTransport(
      contentType: "application/json",
      body: Data(#"{"message":"quota"}"#.utf8)
    )
    let pipeline = HTTPTextToSpeechPipeline(
      definition: HTTPTextToSpeechRuntimeDefinition(
        id: 8,
        urlTemplate: "https://tts.example.com/audio",
        contentTypePattern: "audio/.*"
      ),
      transport: transport
    )

    do {
      _ = try await pipeline.load(text: "正文", speed: 10)
      XCTFail("expected JSON error")
    } catch let error as HTTPTextToSpeechPipelineError {
      XCTAssertEqual(
        error,
        .jsonErrorResponse(#"{"message":"quota"}"#)
      )
    }
  }
}

private actor HTTPTextToSpeechTransport: HTTPTransport {
  private let contentType: String
  private let body: Data
  private var recorded: [HTTPRequest] = []

  init(
    contentType: String,
    body: Data = Data([0x49, 0x44, 0x33])
  ) {
    self.contentType = contentType
    self.body = body
  }

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    recorded.append(request)
    return try HTTPResponse(
      statusCode: 200,
      effectiveURL: request.url,
      headers: HTTPHeaders([
        try HTTPHeader(name: "Content-Type", value: contentType)
      ]),
      body: HTTPBody(body),
      responseCookies: recorded.count == 1 ? [
        HTTPResponseCookie(
          originURL: request.url,
          name: "session",
          value: "tts",
          isPersistent: false
        )
      ] : []
    )
  }

  func requests() -> [HTTPRequest] { recorded }
}
