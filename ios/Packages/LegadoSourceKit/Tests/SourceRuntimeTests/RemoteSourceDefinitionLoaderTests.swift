import Foundation
import SourceRuntime
import Testing

@Suite("RemoteSourceDefinitionLoaderTests")
struct RemoteSourceDefinitionLoaderTests {
  @Test func downloadsAndroidBookSourcePayload() async throws {
    let payload = Data(#"[{"bookSourceUrl":"https://source.test"}]"#.utf8)
    let transport = RemoteImportTransport(statusCode: 200, body: payload)

    let result = try await RemoteSourceDefinitionLoader(
      transport: transport
    ).load("  https://share.test/bookSource.json  ")

    #expect(result == payload)
    let request = try #require(await transport.lastRequest())
    #expect(request.method == .get)
    #expect(request.url.absoluteString == "https://share.test/bookSource.json")
    #expect(request.headers.values(for: "User-Agent").isEmpty)
  }

  @Test func requestWithoutUASuffixIsRemovedAndOverridesHeader() async throws {
    let transport = RemoteImportTransport(
      statusCode: 200,
      body: Data("[]".utf8)
    )

    _ = try await RemoteSourceDefinitionLoader(transport: transport).load(
      "https://share.test/sources#requestWithoutUA"
    )

    let request = try #require(await transport.lastRequest())
    #expect(request.url.absoluteString == "https://share.test/sources")
    #expect(request.headers.values(for: "User-Agent") == ["null"])
  }

  @Test func rejectsInvalidURLFailedStatusAndEmptyBody() async throws {
    let loader = RemoteSourceDefinitionLoader(
      transport: RemoteImportTransport(statusCode: 200, body: Data("[]".utf8))
    )
    await #expect(throws: RemoteSourceDefinitionLoadError.invalidURL) {
      try await loader.load("file:///tmp/bookSource.json")
    }

    await #expect(
      throws: RemoteSourceDefinitionLoadError.unsuccessfulStatus(404)
    ) {
      try await RemoteSourceDefinitionLoader(
        transport: RemoteImportTransport(statusCode: 404, body: Data("missing".utf8))
      ).load("https://share.test/missing")
    }

    await #expect(throws: RemoteSourceDefinitionLoadError.emptyResponse) {
      try await RemoteSourceDefinitionLoader(
        transport: RemoteImportTransport(statusCode: 200, body: Data())
      ).load("https://share.test/empty")
    }
  }
}

private actor RemoteImportTransport: HTTPTransport {
  private let statusCode: Int
  private let body: Data
  private var request: HTTPRequest?

  init(statusCode: Int, body: Data) {
    self.statusCode = statusCode
    self.body = body
  }

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    self.request = request
    return try HTTPResponse(
      statusCode: statusCode,
      effectiveURL: request.url,
      body: HTTPBody(body)
    )
  }

  func lastRequest() -> HTTPRequest? {
    request
  }
}
