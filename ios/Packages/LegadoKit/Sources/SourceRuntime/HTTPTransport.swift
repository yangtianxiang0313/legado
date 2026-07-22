import LegadoCore

public protocol HTTPTransport: Sendable {
  func execute(_ request: HTTPRequest) async throws -> HTTPResponse
}

public enum HTTPTransportFailure: String, Error, CaseIterable, Codable, Sendable {
  case invalidRequest = "invalid_request"
  case connectionFailed = "connection_failed"
  case timeout
  case invalidResponse = "invalid_response"
  case responseTooLarge = "response_too_large"
}

public struct HTTPTransportBoundary: Sendable {
  private let transport: any HTTPTransport

  public init(transport: any HTTPTransport) {
    self.transport = transport
  }

  public func execute(
    _ request: HTTPRequest,
    sourceID: SourceID?,
    trace: TraceRecorder
  ) async throws -> HTTPResponse {
    await trace.entered(.transport)
    do {
      try Task.checkCancellation()
      let response = try await transport.execute(request)
      try Task.checkCancellation()
      await trace.completed(.transport)
      return response
    } catch let cancellation as CancellationError {
      await trace.cancelled(.transport)
      throw cancellation
    } catch {
      do {
        try Task.checkCancellation()
      } catch let cancellation as CancellationError {
        await trace.cancelled(.transport)
        throw cancellation
      }

      let issue = map(error, sourceID: sourceID, traceID: trace.id)
      await trace.failed(.transport, code: issue.code)
      throw issue
    }
  }

  private func map(_ error: any Error, sourceID: SourceID?, traceID: TraceID) -> AppIssue {
    if let issue = error as? AppIssue {
      return issue
    }

    let failure = error as? HTTPTransportFailure
    let code: IssueCode
    let retryable: Bool
    let recovery: Recovery
    switch failure {
    case .timeout:
      code = .timeout
      retryable = true
      recovery = .retry
    case .responseTooLarge:
      code = .responseTooLarge
      retryable = false
      recovery = .editSource
    case .connectionFailed:
      code = .transportFailed
      retryable = true
      recovery = .retry
    case .invalidRequest, .invalidResponse, .none:
      code = .transportFailed
      retryable = false
      recovery = .none
    }
    return AppIssue(
      code: code,
      stage: .transport,
      sourceID: sourceID,
      traceID: traceID,
      retryable: retryable,
      recovery: recovery
    )
  }
}
