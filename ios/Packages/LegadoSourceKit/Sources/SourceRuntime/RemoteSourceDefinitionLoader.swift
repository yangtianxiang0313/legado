import Foundation

public enum RemoteSourceDefinitionLoadError: Error, Equatable, Sendable {
  case invalidURL
  case unsuccessfulStatus(Int)
  case emptyResponse
}

public struct RemoteSourceDefinitionLoader: Sendable {
  private static let requestWithoutUserAgentSuffix = "#requestWithoutUA"

  private let transport: any HTTPTransport

  public init(transport: any HTTPTransport) {
    self.transport = transport
  }

  public func load(_ input: String) async throws -> Data {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let suppressesUserAgent = trimmed.hasSuffix(
      Self.requestWithoutUserAgentSuffix
    )
    let address = suppressesUserAgent
      ? String(trimmed.dropLast(Self.requestWithoutUserAgentSuffix.count))
      : trimmed
    guard let url = try? HTTPURL(address) else {
      throw RemoteSourceDefinitionLoadError.invalidURL
    }
    let headers = try HTTPHeaders(
      suppressesUserAgent
        ? [HTTPHeader(name: "User-Agent", value: "null")]
        : []
    )
    let response = try await transport.execute(
      HTTPRequest(method: .get, url: url, headers: headers)
    )
    guard (200...299).contains(response.statusCode) else {
      throw RemoteSourceDefinitionLoadError.unsuccessfulStatus(
        response.statusCode
      )
    }
    guard !response.body.bytes.isEmpty else {
      throw RemoteSourceDefinitionLoadError.emptyResponse
    }
    return response.body.bytes
  }
}
