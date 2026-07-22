import LegadoCore

public enum SourceFormatError: String, Error, Equatable, Sendable {
  case expectedObject = "expected_object"
}

public enum SourceField<Value: Equatable & Sendable>: Equatable, Sendable {
  case missing
  case null
  case value(Value)
  case typeMismatch(JSONValue)
}

public protocol LosslessSourceDocument: Equatable, Sendable {
  var jsonValue: JSONValue { get }
  var rawFields: [String: JSONValue] { get }
  var unknownFields: [String: JSONValue] { get }

  func rawValue(for jsonName: String) -> JSONValue?
}

struct SourceObjectStorage: Equatable, Sendable {
  let fields: [String: JSONValue]

  init(jsonValue: JSONValue) throws {
    guard case .object(let fields) = jsonValue else {
      throw SourceFormatError.expectedObject
    }
    self.fields = fields
  }

  init(fields: [String: JSONValue]) {
    self.fields = fields
  }

  var jsonValue: JSONValue {
    .object(fields)
  }

  func string(_ jsonName: String) -> SourceField<String> {
    project(jsonName) { raw in
      guard case .string(let value) = raw else { return nil }
      return value
    }
  }

  func boolean(_ jsonName: String) -> SourceField<Bool> {
    project(jsonName) { raw in
      guard case .bool(let value) = raw else { return nil }
      return value
    }
  }

  func int32(_ jsonName: String) -> SourceField<Int32> {
    project(jsonName) { raw in
      guard case .number(let number) = raw else { return nil }
      return Int32(number.rawToken)
    }
  }

  func int64(_ jsonName: String) -> SourceField<Int64> {
    project(jsonName) { raw in
      guard case .number(let number) = raw else { return nil }
      return Int64(number.rawToken)
    }
  }

  func object<Value: Equatable & Sendable>(
    _ jsonName: String,
    transform: ([String: JSONValue]) -> Value
  ) -> SourceField<Value> {
    project(jsonName) { raw in
      guard case .object(let fields) = raw else { return nil }
      return transform(fields)
    }
  }

  func rawValue(for jsonName: String) -> JSONValue? {
    fields[jsonName]
  }

  func unknownFields(excluding knownFieldNames: Set<String>) -> [String: JSONValue] {
    fields.filter { !knownFieldNames.contains($0.key) }
  }

  private func project<Value: Equatable & Sendable>(
    _ jsonName: String,
    transform: (JSONValue) -> Value?
  ) -> SourceField<Value> {
    guard let raw = fields[jsonName] else { return .missing }
    if case .null = raw { return .null }
    guard let value = transform(raw) else { return .typeMismatch(raw) }
    return .value(value)
  }
}
