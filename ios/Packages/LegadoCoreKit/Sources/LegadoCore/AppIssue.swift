public struct IssueCode: RawRepresentable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let invalidInput = Self(rawValue: "invalid_input")
  public static let invalidSource = Self(rawValue: "invalid_source")
  public static let invalidURLTemplate = Self(rawValue: "invalid_url_template")
  public static let invalidRule = Self(rawValue: "invalid_rule")
  public static let capabilityDenied = Self(rawValue: "capability_denied")
  public static let transportFailed = Self(rawValue: "transport_failed")
  public static let timeout = Self(rawValue: "timeout")
  public static let responseTooLarge = Self(rawValue: "response_too_large")
  public static let decodingFailed = Self(rawValue: "decoding_failed")
  public static let ruleFailed = Self(rawValue: "rule_failed")
  public static let scriptFailed = Self(rawValue: "script_failed")
  public static let webViewFailed = Self(rawValue: "web_view_failed")
  public static let resourceLimitExceeded = Self(rawValue: "resource_limit_exceeded")
  public static let internalFailure = Self(rawValue: "internal_failure")
}

extension IssueCode: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(rawValue: try container.decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public enum Recovery: String, Codable, Sendable {
  case none
  case retry
  case editSource = "edit_source"
  case reauthenticate
  case chooseAnotherSource = "choose_another_source"
  case changeProfile = "change_profile"
}

public struct AppIssue: Error, Codable, Equatable, Sendable {
  public let code: IssueCode
  public let stage: SourceStage?
  public let sourceID: SourceID?
  public let traceID: TraceID
  public let retryable: Bool
  public let recovery: Recovery

  public init(
    code: IssueCode,
    stage: SourceStage?,
    sourceID: SourceID?,
    traceID: TraceID,
    retryable: Bool,
    recovery: Recovery
  ) {
    self.code = code
    self.stage = stage
    self.sourceID = sourceID
    self.traceID = traceID
    self.retryable = retryable
    self.recovery = recovery
  }
}

public func withAppIssueBoundary<Value: Sendable>(
  operation: () async throws -> Value,
  map: (any Error) -> AppIssue
) async throws -> Value {
  do {
    return try await operation()
  } catch let cancellation as CancellationError {
    throw cancellation
  } catch {
    try Task.checkCancellation()
    if let issue = error as? AppIssue {
      throw issue
    }
    throw map(error)
  }
}
