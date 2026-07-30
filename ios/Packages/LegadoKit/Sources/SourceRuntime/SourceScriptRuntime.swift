import Foundation

public struct SourceScriptSessionID:
  RawRepresentable, Hashable, Codable, Sendable
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Values that may cross the SourceRuntime → script-backend boundary.
///
/// `undefined` stays distinct from `null` because Android/Rhino scripts use
/// that distinction for missing bindings and return values.
public enum SourceScriptValue: Equatable, Sendable {
  case undefined
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([SourceScriptValue])
  case object([String: SourceScriptValue])
}

public struct SourceScriptRequest: Equatable, Sendable {
  public let sessionID: SourceScriptSessionID
  public let script: String
  public let result: SourceScriptValue
  public let baseURL: String?
  public let bindings: [String: SourceScriptValue]

  public init(
    sessionID: SourceScriptSessionID,
    script: String,
    result: SourceScriptValue = .undefined,
    baseURL: String? = nil,
    bindings: [String: SourceScriptValue] = [:]
  ) {
    self.sessionID = sessionID
    self.script = script
    self.result = result
    self.baseURL = baseURL
    self.bindings = bindings
  }
}

/// Closed host-command surface. New side effects must add an explicit case,
/// Android characterization and policy decision instead of exposing a Swift
/// product object directly to JavaScript.
public enum SourceScriptHostCommand: Equatable, Sendable {
  case snapshotVariables
  case getVariable(name: String)
  case putVariable(name: String, value: String)
}

public protocol SourceScriptHosting: Sendable {
  func execute(
    _ command: SourceScriptHostCommand,
    sessionID: SourceScriptSessionID
  ) async throws -> SourceScriptValue
}

public protocol SourceScriptRuntime: Sendable {
  func evaluate(
    _ request: SourceScriptRequest,
    host: (any SourceScriptHosting)?
  ) async throws -> SourceScriptValue
}

public enum SourceScriptIssueCode: String, Equatable, Sendable {
  case capabilityDenied = "capability_denied"
  case executionFailed = "execution_failed"
  case invalidResult = "invalid_result"
  case hostCommandDenied = "host_command_denied"
}

/// Stable and deliberately redacted script failure. The original script,
/// exception and host values belong only in a sanitized trace.
public struct SourceScriptIssue: Error, Equatable, Sendable {
  public let code: SourceScriptIssueCode

  public init(code: SourceScriptIssueCode) {
    self.code = code
  }
}

public struct SourceScriptUnavailableRuntime: SourceScriptRuntime {
  public init() {}

  public func evaluate(
    _ request: SourceScriptRequest,
    host: (any SourceScriptHosting)?
  ) async throws -> SourceScriptValue {
    throw SourceScriptIssue(code: .capabilityDenied)
  }
}

/// Minimal Android-aligned `java.get` / `java.put` bridge. It delegates scope
/// selection to SourceVariableResolver, so scripts cannot bypass the existing
/// chapter → book/ruleData → source ownership rules.
public struct SourceVariableScriptHost: SourceScriptHosting {
  public let resolver: SourceVariableResolver

  public init(resolver: SourceVariableResolver) {
    self.resolver = resolver
  }

  public func execute(
    _ command: SourceScriptHostCommand,
    sessionID: SourceScriptSessionID
  ) async throws -> SourceScriptValue {
    switch command {
    case .snapshotVariables:
      return .object(
        await resolver.snapshot().mapValues(SourceScriptValue.string)
      )
    case .getVariable(let name):
      return .string(await resolver.get(name))
    case .putVariable(let name, let value):
      return .string(await resolver.put(name, value: value))
    }
  }
}
