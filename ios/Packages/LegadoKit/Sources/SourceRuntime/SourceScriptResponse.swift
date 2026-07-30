import Foundation

public struct SourceScriptResponse: Equatable, Sendable {
  public let url: HTTPURL
  public let body: String

  public init(url: HTTPURL, body: String) {
    self.url = url
    self.body = body
  }

  public var scriptValue: SourceScriptValue {
    .object([
      "url": .string(url.absoluteString),
      "body": .string(body),
    ])
  }

  public init(projecting value: SourceScriptValue) throws {
    guard
      case .object(let object) = value,
      case .string(let rawURL) = object["url"],
      case .string(let body) = object["body"],
      let url = try? HTTPURL(rawURL)
    else {
      throw SourceScriptIssue(code: .invalidResult)
    }
    self.init(url: url, body: body)
  }
}

public struct SourceScriptResponseEvaluator: Sendable {
  public let runtime: any SourceScriptRuntime
  public let sessionID: SourceScriptSessionID

  public init(
    runtime: any SourceScriptRuntime,
    sessionID: SourceScriptSessionID
  ) {
    self.runtime = runtime
    self.sessionID = sessionID
  }

  public func evaluate(
    script: String,
    response: SourceScriptResponse,
    host: (any SourceScriptHosting)? = nil
  ) async throws -> SourceScriptResponse {
    guard
      !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return response
    }
    let value = try await runtime.evaluate(
      SourceScriptRequest(
        sessionID: sessionID,
        purpose: .responseCheck,
        script: script,
        result: response.scriptValue,
        baseURL: response.url.absoluteString
      ),
      host: host
    )
    return try SourceScriptResponse(projecting: value)
  }
}
