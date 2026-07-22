import LegadoCore

public enum CanonicalDifferenceKind: String, Codable, Equatable, Sendable {
  case expectedMissing = "expected_missing"
  case actualMissing = "actual_missing"
  case typeMismatch = "type_mismatch"
  case valueMismatch = "value_mismatch"
}

public struct CanonicalDifference: Codable, Equatable, Sendable {
  public let kind: CanonicalDifferenceKind
  public let jsonPointer: String

  public init(kind: CanonicalDifferenceKind, jsonPointer: String) {
    self.kind = kind
    self.jsonPointer = jsonPointer
  }

  enum CodingKeys: String, CodingKey {
    case kind
    case jsonPointer = "json_pointer"
  }
}

public enum CanonicalComparison: Equatable, Sendable {
  case equal
  case different(CanonicalDifference)
}

public enum CanonicalJSONComparator {
  public static func compare(expected: JSONValue, actual: JSONValue) -> CanonicalComparison {
    guard let difference = firstDifference(expected: expected, actual: actual, pointer: "") else {
      return .equal
    }
    return .different(difference)
  }

  private static func firstDifference(
    expected: JSONValue,
    actual: JSONValue,
    pointer: String
  ) -> CanonicalDifference? {
    switch (expected, actual) {
    case (.null, .null):
      nil
    case (.bool(let expected), .bool(let actual)):
      expected == actual ? nil : difference(.valueMismatch, pointer)
    case (.number(let expected), .number(let actual)):
      expected.rawToken == actual.rawToken ? nil : difference(.valueMismatch, pointer)
    case (.string(let expected), .string(let actual)):
      expected == actual ? nil : difference(.valueMismatch, pointer)
    case (.array(let expected), .array(let actual)):
      firstArrayDifference(expected: expected, actual: actual, pointer: pointer)
    case (.object(let expected), .object(let actual)):
      firstObjectDifference(expected: expected, actual: actual, pointer: pointer)
    default:
      difference(.typeMismatch, pointer)
    }
  }

  private static func firstArrayDifference(
    expected: [JSONValue],
    actual: [JSONValue],
    pointer: String
  ) -> CanonicalDifference? {
    for index in 0..<min(expected.count, actual.count) {
      if let difference = firstDifference(
        expected: expected[index],
        actual: actual[index],
        pointer: appending(String(index), to: pointer)
      ) {
        return difference
      }
    }
    if expected.count > actual.count {
      return difference(.actualMissing, appending(String(actual.count), to: pointer))
    }
    if actual.count > expected.count {
      return difference(.expectedMissing, appending(String(expected.count), to: pointer))
    }
    return nil
  }

  private static func firstObjectDifference(
    expected: [String: JSONValue],
    actual: [String: JSONValue],
    pointer: String
  ) -> CanonicalDifference? {
    let keys = Set(expected.keys).union(actual.keys).sorted()
    for key in keys {
      let childPointer = appending(key, to: pointer)
      switch (expected[key], actual[key]) {
      case (.none, .some):
        return difference(.expectedMissing, childPointer)
      case (.some, .none):
        return difference(.actualMissing, childPointer)
      case (.some(let expected), .some(let actual)):
        if let difference = firstDifference(
          expected: expected,
          actual: actual,
          pointer: childPointer
        ) {
          return difference
        }
      case (.none, .none):
        break
      }
    }
    return nil
  }

  private static func difference(
    _ kind: CanonicalDifferenceKind,
    _ pointer: String
  ) -> CanonicalDifference {
    CanonicalDifference(kind: kind, jsonPointer: pointer)
  }

  private static func appending(_ component: String, to pointer: String) -> String {
    let escaped =
      component
      .replacingOccurrences(of: "~", with: "~0")
      .replacingOccurrences(of: "/", with: "~1")
    return pointer + "/" + escaped
  }
}
