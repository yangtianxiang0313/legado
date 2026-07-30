import Foundation

struct SourceLoginCheckEvaluator: Sendable {
  let definition: SourceSearchDefinition
  let scriptRuntime: (any SourceScriptRuntime)?
  let scriptSessionID: SourceScriptSessionID

  func evaluate(
    _ response: SourceStringResponse,
    resolver: SourceVariableResolver
  ) async throws -> SourceStringResponse {
    guard
      let script = definition.loginCheckScript?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !script.isEmpty
    else {
      return response
    }
    guard let scriptRuntime else {
      throw SourceScriptIssue(code: .capabilityDenied)
    }
    let transformed = try await SourceScriptResponseEvaluator(
      runtime: scriptRuntime,
      sessionID: scriptSessionID
    ).evaluate(
      script: script,
      response: SourceScriptResponse(
        url: response.finalURL,
        body: response.body
      ),
      host: SourceVariableScriptHost(resolver: resolver)
    )
    return SourceStringResponse(
      body: transformed.body,
      finalURL: transformed.url
    )
  }
}
