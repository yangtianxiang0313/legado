import Foundation

public enum JSONValueCodecError: Error, Equatable, Sendable {
  case invalidUTF8
  case unexpectedEnd
  case unexpectedToken(offset: Int)
  case duplicateObjectKey(String)
  case trailingContent(offset: Int)
  case nestingLimitExceeded
}

public enum JSONValueCodec {
  public static func decode(_ data: Data, maximumDepth: Int = 128) throws -> JSONValue {
    guard String(data: data, encoding: .utf8) != nil else { throw JSONValueCodecError.invalidUTF8 }
    var parser = Parser(bytes: Array(data), maximumDepth: maximumDepth)
    return try parser.parseDocument()
  }

  public static func encode(_ value: JSONValue) throws -> Data {
    var output = ""
    try append(value, to: &output)
    return Data(output.utf8)
  }

  private static func append(_ value: JSONValue, to output: inout String) throws {
    switch value {
    case .null:
      output += "null"
    case .bool(let value):
      output += value ? "true" : "false"
    case .number(let value):
      output += value.rawToken
    case .string(let value):
      output += try encodedString(value)
    case .array(let values):
      output += "["
      for (index, value) in values.enumerated() {
        if index > 0 { output += "," }
        try append(value, to: &output)
      }
      output += "]"
    case .object(let object):
      output += "{"
      for (index, key) in object.keys.sorted().enumerated() {
        if index > 0 { output += "," }
        output += try encodedString(key)
        output += ":"
        try append(object[key]!, to: &output)
      }
      output += "}"
    }
  }

  private static func encodedString(_ value: String) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }
}

private struct Parser {
  let bytes: [UInt8]
  let maximumDepth: Int
  var index = 0

  mutating func parseDocument() throws -> JSONValue {
    skipWhitespace()
    let value = try parseValue(depth: 0)
    skipWhitespace()
    guard index == bytes.count else { throw JSONValueCodecError.trailingContent(offset: index) }
    return value
  }

  private mutating func parseValue(depth: Int) throws -> JSONValue {
    guard index < bytes.count else { throw JSONValueCodecError.unexpectedEnd }
    switch bytes[index] {
    case 34:
      return .string(try parseString())
    case 45, 48...57:
      return .number(try parseNumber())
    case 91:
      return try parseArray(depth: depth)
    case 123:
      return try parseObject(depth: depth)
    case 102:
      try consume("false")
      return .bool(false)
    case 110:
      try consume("null")
      return .null
    case 116:
      try consume("true")
      return .bool(true)
    default:
      throw JSONValueCodecError.unexpectedToken(offset: index)
    }
  }

  private mutating func parseArray(depth: Int) throws -> JSONValue {
    guard depth < maximumDepth else { throw JSONValueCodecError.nestingLimitExceeded }
    index += 1
    skipWhitespace()
    var values: [JSONValue] = []
    if consumeIfPresent(93) { return .array(values) }
    while true {
      skipWhitespace()
      values.append(try parseValue(depth: depth + 1))
      skipWhitespace()
      if consumeIfPresent(93) { return .array(values) }
      try require(44)
    }
  }

  private mutating func parseObject(depth: Int) throws -> JSONValue {
    guard depth < maximumDepth else { throw JSONValueCodecError.nestingLimitExceeded }
    index += 1
    skipWhitespace()
    var object: [String: JSONValue] = [:]
    if consumeIfPresent(125) { return .object(object) }
    while true {
      skipWhitespace()
      guard index < bytes.count, bytes[index] == 34 else {
        throw JSONValueCodecError.unexpectedToken(offset: index)
      }
      let key = try parseString()
      guard object[key] == nil else { throw JSONValueCodecError.duplicateObjectKey(key) }
      skipWhitespace()
      try require(58)
      skipWhitespace()
      object[key] = try parseValue(depth: depth + 1)
      skipWhitespace()
      if consumeIfPresent(125) { return .object(object) }
      try require(44)
    }
  }

  private mutating func parseString() throws -> String {
    let start = index
    index += 1
    while index < bytes.count {
      let byte = bytes[index]
      if byte == 34 {
        index += 1
        do {
          return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
        } catch {
          throw JSONValueCodecError.unexpectedToken(offset: start)
        }
      }
      if byte < 32 { throw JSONValueCodecError.unexpectedToken(offset: index) }
      if byte == 92 {
        index += 1
        guard index < bytes.count else { throw JSONValueCodecError.unexpectedEnd }
      }
      index += 1
    }
    throw JSONValueCodecError.unexpectedEnd
  }

  private mutating func parseNumber() throws -> JSONNumber {
    let start = index
    while index < bytes.count, isNumberByte(bytes[index]) { index += 1 }
    return try JSONNumber(validating: String(decoding: bytes[start..<index], as: UTF8.self))
  }

  private mutating func consume(_ literal: String) throws {
    let expected = Array(literal.utf8)
    guard index + expected.count <= bytes.count, Array(bytes[index..<(index + expected.count)]) == expected else {
      throw JSONValueCodecError.unexpectedToken(offset: index)
    }
    index += expected.count
  }

  private mutating func require(_ byte: UInt8) throws {
    guard consumeIfPresent(byte) else { throw JSONValueCodecError.unexpectedToken(offset: index) }
  }

  private mutating func consumeIfPresent(_ byte: UInt8) -> Bool {
    guard index < bytes.count, bytes[index] == byte else { return false }
    index += 1
    return true
  }

  private mutating func skipWhitespace() {
    while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
  }

  private func isNumberByte(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || [43, 45, 46, 69, 101].contains(byte)
  }
}
