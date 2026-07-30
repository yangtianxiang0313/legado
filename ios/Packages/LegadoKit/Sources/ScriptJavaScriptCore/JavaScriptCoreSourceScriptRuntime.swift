import Foundation
@preconcurrency import JavaScriptCore
import SourceRuntime

public actor JavaScriptCoreSourceScriptRuntime: SourceScriptRuntime {
  private final class Session {
    let context: JSContext

    init() {
      context = JSContext()!
    }
  }

  private var sessions: [SourceScriptSessionID: Session] = [:]

  public init() {}

  public func evaluate(
    _ request: SourceScriptRequest,
    host: (any SourceScriptHosting)?
  ) async throws -> SourceScriptValue {
    let session = session(for: request.sessionID)
    let context = session.context
    context.exception = nil

    let variables = try await variableSnapshot(
      host: host,
      sessionID: request.sessionID
    )
    context.setObject(
      foundationObject(variables),
      forKeyedSubscript: "__legadoVariables" as NSString
    )
    context.setObject(
      [],
      forKeyedSubscript: "__legadoPuts" as NSString
    )
    context.setObject(
      foundationObject(request.result),
      forKeyedSubscript: "result" as NSString
    )
    context.setObject(
      request.baseURL,
      forKeyedSubscript: "baseUrl" as NSString
    )
    for (name, value) in request.bindings {
      context.setObject(
        foundationObject(value),
        forKeyedSubscript: name as NSString
      )
    }
    context.evaluateScript(Self.hostPrelude)
    guard context.exception == nil else {
      context.exception = nil
      throw SourceScriptIssue(code: .executionFailed)
    }

    let evaluated = context.evaluateScript(request.script)
    let exception = context.exception
    let pendingPuts = pendingPuts(in: context)
    context.exception = nil
    try await flush(
      pendingPuts,
      host: host,
      sessionID: request.sessionID
    )
    guard exception == nil, let evaluated else {
      throw SourceScriptIssue(code: .executionFailed)
    }
    return try sourceValue(evaluated)
  }

  private func session(for id: SourceScriptSessionID) -> Session {
    if let session = sessions[id] {
      return session
    }
    let session = Session()
    sessions[id] = session
    return session
  }

  private func variableSnapshot(
    host: (any SourceScriptHosting)?,
    sessionID: SourceScriptSessionID
  ) async throws -> SourceScriptValue {
    guard let host else { return .object([:]) }
    let value = try await host.execute(
      .snapshotVariables,
      sessionID: sessionID
    )
    guard case .object = value else {
      throw SourceScriptIssue(code: .hostCommandDenied)
    }
    return value
  }

  private func pendingPuts(
    in context: JSContext
  ) -> [(String, String)] {
    guard
      let values = context.objectForKeyedSubscript("__legadoPuts")?
        .toArray() as? [[Any]]
    else {
      return []
    }
    return values.compactMap { entry in
      guard entry.count == 2 else { return nil }
      return (String(describing: entry[0]), String(describing: entry[1]))
    }
  }

  private func flush(
    _ values: [(String, String)],
    host: (any SourceScriptHosting)?,
    sessionID: SourceScriptSessionID
  ) async throws {
    guard let host else { return }
    for (name, value) in values {
      _ = try await host.execute(
        .putVariable(name: name, value: value),
        sessionID: sessionID
      )
    }
  }

  private func foundationObject(_ value: SourceScriptValue) -> Any {
    switch value {
    case .undefined, .null:
      return NSNull()
    case .bool(let value):
      return value
    case .number(let value):
      return value
    case .string(let value):
      return value
    case .array(let values):
      return values.map(foundationObject)
    case .object(let values):
      return values.mapValues(foundationObject)
    }
  }

  private func sourceValue(_ value: JSValue) throws -> SourceScriptValue {
    if value.isUndefined {
      return .undefined
    }
    if value.isNull {
      return .null
    }
    if value.isBoolean {
      return .bool(value.toBool())
    }
    if value.isNumber {
      let number = value.toDouble()
      guard number.isFinite else {
        throw SourceScriptIssue(code: .invalidResult)
      }
      return .number(number)
    }
    if value.isString {
      return .string(value.toString())
    }
    if value.isArray {
      guard let values = value.toArray() else {
        throw SourceScriptIssue(code: .invalidResult)
      }
      return .array(try values.map(sourceValue))
    }
    if value.isObject {
      guard let values = value.toDictionary() else {
        throw SourceScriptIssue(code: .invalidResult)
      }
      var result: [String: SourceScriptValue] = [:]
      for (key, entry) in values {
        result[String(describing: key)] = try sourceValue(entry)
      }
      return .object(result)
    }
    throw SourceScriptIssue(code: .invalidResult)
  }

  private func sourceValue(_ value: Any) throws -> SourceScriptValue {
    guard let context = JSContext(),
      let value = JSValue(object: value, in: context)
    else {
      throw SourceScriptIssue(code: .invalidResult)
    }
    return try sourceValue(value)
  }

  private static let hostPrelude = """
    var java = Object.freeze({
      get: function(name) {
        var key = String(name);
        return Object.prototype.hasOwnProperty.call(__legadoVariables, key)
          ? __legadoVariables[key]
          : "";
      },
      put: function(name, value) {
        var key = String(name);
        var text = value == null ? "" : String(value);
        __legadoPuts.push([key, text]);
        __legadoVariables[key] = text;
        return text;
      }
    });
    """
}
