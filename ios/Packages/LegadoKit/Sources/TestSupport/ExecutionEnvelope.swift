import Foundation
import LegadoCore
import SourceRuntime

public enum ExecutionPlatform: String, Codable, Sendable {
  case android
  case ios
}

public struct ExecutionEngine: Codable, Equatable, Sendable {
  public let platform: ExecutionPlatform
  public let revision: String
  public let compatibilityProfile: String

  public init(platform: ExecutionPlatform, revision: String, compatibilityProfile: String) {
    self.platform = platform
    self.revision = revision
    self.compatibilityProfile = compatibilityProfile
  }

  enum CodingKeys: String, CodingKey {
    case platform
    case revision
    case compatibilityProfile = "compatibility_profile"
  }
}

public struct ExecutionDecode: Codable, Equatable, Sendable {
  public let charset: String
  public let evidence: [String]
  public let lossy: Bool

  public init(charset: String, evidence: [String], lossy: Bool) {
    self.charset = charset
    self.evidence = evidence
    self.lossy = lossy
  }
}

public enum StageOutcome: String, Codable, Sendable {
  case completed
  case failed
  case cancelled
}

public enum ExecutionEnvelopeValidationError: String, Error, Equatable, Sendable {
  case invalidStageOutcome = "invalid_stage_outcome"
}

public struct ExecutionStage: Codable, Equatable, Sendable {
  public let stage: SourceStage
  public let outcome: StageOutcome
  public let issueCode: IssueCode?

  public init(stage: SourceStage, outcome: StageOutcome, issueCode: IssueCode? = nil) throws {
    guard (outcome == .failed) == (issueCode != nil) else {
      throw ExecutionEnvelopeValidationError.invalidStageOutcome
    }
    self.stage = stage
    self.outcome = outcome
    self.issueCode = issueCode
  }

  public init?(event: TraceEvent) {
    switch event.kind {
    case .entered:
      return nil
    case .completed:
      self.outcome = .completed
    case .failed:
      self.outcome = .failed
    case .cancelled:
      self.outcome = .cancelled
    }
    self.stage = event.stage
    self.issueCode = event.issueCode
  }

  enum CodingKeys: String, CodingKey {
    case stage
    case outcome
    case issueCode = "issue_code"
  }
}

public struct ExecutionResult: Codable, Equatable, Sendable {
  public let type: String
  public let value: JSONValue

  public init(type: String, value: JSONValue) {
    self.type = type
    self.value = value
  }

  public init(type: String, exactJSON: Data) throws {
    self.type = type
    self.value = try JSONValueCodec.decode(exactJSON)
  }
}

public struct ExecutionIssue: Codable, Equatable, Sendable {
  public let code: IssueCode
  public let stage: SourceStage?

  public init(code: IssueCode, stage: SourceStage?) {
    self.code = code
    self.stage = stage
  }
}

public struct ExecutionEnvelope: Equatable, Sendable {
  public let schemaVersion: Int
  public let fixtureID: String
  public let engine: ExecutionEngine
  public let requestPlan: [HTTPRequestEnvelope]
  public let decode: ExecutionDecode?
  public let stages: [ExecutionStage]
  public let result: ExecutionResult
  public let issues: [ExecutionIssue]

  public init(
    fixtureID: String,
    engine: ExecutionEngine,
    requestPlan: [HTTPRequestEnvelope],
    decode: ExecutionDecode?,
    stages: [ExecutionStage],
    result: ExecutionResult,
    issues: [ExecutionIssue]
  ) {
    self.schemaVersion = 1
    self.fixtureID = fixtureID
    self.engine = engine
    self.requestPlan = requestPlan
    self.decode = decode
    self.stages = stages
    self.result = result
    self.issues = issues
  }
}

extension ExecutionEnvelope: Codable {
  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case fixtureID = "fixture_id"
    case engine
    case requestPlan = "request_plan"
    case decode
    case stages
    case result
    case issues
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    self.fixtureID = try container.decode(String.self, forKey: .fixtureID)
    self.engine = try container.decode(ExecutionEngine.self, forKey: .engine)
    self.requestPlan = try container.decode([HTTPRequestEnvelope].self, forKey: .requestPlan)
    self.decode = try container.decodeIfPresent(ExecutionDecode.self, forKey: .decode)
    self.stages = try container.decode([ExecutionStage].self, forKey: .stages)
    self.result = try container.decode(ExecutionResult.self, forKey: .result)
    self.issues = try container.decode([ExecutionIssue].self, forKey: .issues)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(fixtureID, forKey: .fixtureID)
    try container.encode(engine, forKey: .engine)
    try container.encode(requestPlan, forKey: .requestPlan)
    try container.encode(decode, forKey: .decode)
    try container.encode(stages, forKey: .stages)
    try container.encode(result, forKey: .result)
    try container.encode(issues, forKey: .issues)
  }
}

public enum ExecutionEnvelopeCodec {
  public static func artifactData(_ envelope: ExecutionEnvelope) throws -> Data {
    try JSONValueCodec.encode(value(envelope, includeProvenance: true))
  }

  public static func comparisonData(_ envelope: ExecutionEnvelope) throws -> Data {
    try JSONValueCodec.encode(value(envelope, includeProvenance: false))
  }

  private static func value(_ envelope: ExecutionEnvelope, includeProvenance: Bool) throws -> JSONValue {
    var engine: [String: JSONValue] = [
      "compatibility_profile": .string(envelope.engine.compatibilityProfile)
    ]
    if includeProvenance {
      engine["platform"] = .string(envelope.engine.platform.rawValue)
      engine["revision"] = .string(envelope.engine.revision)
    }
    return normalize(
      .object([
        "schema_version": try number(envelope.schemaVersion),
        "fixture_id": .string(envelope.fixtureID),
        "engine": .object(engine),
        "request_plan": .array(try envelope.requestPlan.map(requestValue)),
        "decode": envelope.decode.map(decodeValue) ?? .null,
        "stages": .array(try envelope.stages.map(stageValue)),
        "result": resultValue(envelope.result),
        "issues": .array(envelope.issues.map(issueValue)),
      ])
    )
  }

  private static func requestValue(_ request: HTTPRequestEnvelope) throws -> JSONValue {
    .object([
      "method": .string(request.method.rawValue),
      "url": .string(request.url),
      "headers": .array(request.headers.map(headerValue)),
      "body": request.body.map(bodyValue) ?? .null,
      "timeout_ms": try request.timeoutMilliseconds.map { try number($0) } ?? .null,
    ])
  }

  private static func headerValue(_ header: HTTPHeader) -> JSONValue {
    .object(["name": .string(header.name), "value": .string(header.value)])
  }

  private static func bodyValue(_ body: HTTPBodyEnvelope) -> JSONValue {
    .object([
      "byte_count": .number(JSONNumber(Int64(body.byteCount))),
      "sha256": .string(body.sha256),
    ])
  }

  private static func decodeValue(_ decode: ExecutionDecode) -> JSONValue {
    .object([
      "charset": .string(decode.charset),
      "evidence": .array(decode.evidence.map(JSONValue.string)),
      "lossy": .bool(decode.lossy),
    ])
  }

  private static func stageValue(_ stage: ExecutionStage) throws -> JSONValue {
    .object([
      "stage": .string(stage.stage.rawValue),
      "outcome": .string(stage.outcome.rawValue),
      "issue_code": stage.issueCode.map { .string($0.rawValue) } ?? .null,
    ])
  }

  private static func resultValue(_ result: ExecutionResult) -> JSONValue {
    .object(["type": .string(result.type), "value": result.value])
  }

  private static func issueValue(_ issue: ExecutionIssue) -> JSONValue {
    .object([
      "code": .string(issue.code.rawValue),
      "stage": issue.stage.map { .string($0.rawValue) } ?? .null,
    ])
  }

  private static func number<Value: BinaryInteger>(_ value: Value) throws -> JSONValue {
    .number(try JSONNumber(validating: String(value)))
  }

  private static func normalize(_ value: JSONValue) -> JSONValue {
    switch value {
    case .string(let string):
      .string(string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
    case .array(let values):
      .array(values.map(normalize))
    case .object(let object):
      .object(object.mapValues(normalize))
    case .null, .bool, .number:
      value
    }
  }
}
