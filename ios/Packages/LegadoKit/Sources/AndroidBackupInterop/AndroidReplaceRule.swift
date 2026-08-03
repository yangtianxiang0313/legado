import Foundation
import LegadoCore
import SourceFormat

public enum AndroidReplaceRuleFormatError: Error, Equatable, Sendable {
  case expectedObject
  case expectedArray
}

public struct AndroidReplaceRuleDTO: Equatable, Sendable {
  public static let knownFieldNames: Set<String> = [
    "id",
    "name",
    "group",
    "pattern",
    "replacement",
    "scope",
    "scopeTitle",
    "scopeContent",
    "excludeScope",
    "isEnabled",
    "isRegex",
    "timeoutMillisecond",
    "order",
  ]

  public let rawFields: [String: JSONValue]

  public init(jsonValue: JSONValue) throws {
    guard case .object(let fields) = jsonValue else {
      throw AndroidReplaceRuleFormatError.expectedObject
    }
    rawFields = fields
  }

  public init(
    id: Int64,
    name: String,
    group: String? = nil,
    pattern: String,
    replacement: String,
    scope: String? = nil,
    scopeTitle: Bool = false,
    scopeContent: Bool = true,
    excludeScope: String? = nil,
    isEnabled: Bool = true,
    isRegex: Bool = true,
    timeoutMillisecond: Int64 = 3_000,
    order: Int32 = .min,
    unknownFields: [String: JSONValue] = [:]
  ) {
    var fields = unknownFields.filter {
      !Self.knownFieldNames.contains($0.key)
    }
    fields["id"] = .number(JSONNumber(id))
    fields["name"] = .string(name)
    fields["pattern"] = .string(pattern)
    fields["replacement"] = .string(replacement)
    fields["scopeTitle"] = .bool(scopeTitle)
    fields["scopeContent"] = .bool(scopeContent)
    fields["isEnabled"] = .bool(isEnabled)
    fields["isRegex"] = .bool(isRegex)
    fields["timeoutMillisecond"] = .number(JSONNumber(timeoutMillisecond))
    fields["order"] = .number(JSONNumber(Int64(order)))
    if let group { fields["group"] = .string(group) }
    if let scope { fields["scope"] = .string(scope) }
    if let excludeScope { fields["excludeScope"] = .string(excludeScope) }
    rawFields = fields
  }

  public var jsonValue: JSONValue { .object(rawFields) }

  public var unknownFields: [String: JSONValue] {
    rawFields.filter { !Self.knownFieldNames.contains($0.key) }
  }

  public var id: SourceField<Int64> { integer("id") }
  public var name: SourceField<String> { string("name") }
  public var group: SourceField<String> { string("group") }
  public var pattern: SourceField<String> { string("pattern") }
  public var replacement: SourceField<String> { string("replacement") }
  public var scope: SourceField<String> { string("scope") }
  public var scopeTitle: SourceField<Bool> { boolean("scopeTitle") }
  public var scopeContent: SourceField<Bool> { boolean("scopeContent") }
  public var excludeScope: SourceField<String> { string("excludeScope") }
  public var isEnabled: SourceField<Bool> { boolean("isEnabled") }
  public var isRegex: SourceField<Bool> { boolean("isRegex") }
  public var timeoutMillisecond: SourceField<Int64> {
    integer("timeoutMillisecond")
  }
  public var order: SourceField<Int64> { integer("order") }

  private func string(_ name: String) -> SourceField<String> {
    project(name) { value in
      guard case .string(let string) = value else { return nil }
      return string
    }
  }

  private func boolean(_ name: String) -> SourceField<Bool> {
    project(name) { value in
      guard case .bool(let boolean) = value else { return nil }
      return boolean
    }
  }

  private func integer(_ name: String) -> SourceField<Int64> {
    project(name) { value in
      guard case .number(let number) = value else { return nil }
      return Int64(number.rawToken)
    }
  }

  private func project<Value: Equatable & Sendable>(
    _ name: String,
    transform: (JSONValue) -> Value?
  ) -> SourceField<Value> {
    guard let raw = rawFields[name] else { return .missing }
    if case .null = raw { return .null }
    guard let value = transform(raw) else { return .typeMismatch(raw) }
    return .value(value)
  }
}

public enum AndroidReplaceRuleCodec {
  public static func decodeMany(
    _ data: Data,
    maximumDepth: Int = 128
  ) throws -> [AndroidReplaceRuleDTO] {
    let value = try JSONValueCodec.decode(data, maximumDepth: maximumDepth)
    guard case .array(let values) = value else {
      throw AndroidReplaceRuleFormatError.expectedArray
    }
    return try values.map(AndroidReplaceRuleDTO.init(jsonValue:))
  }

  public static func encodeMany(
    _ rules: [AndroidReplaceRuleDTO]
  ) throws -> Data {
    try JSONValueCodec.encode(.array(rules.map(\.jsonValue)))
  }
}
