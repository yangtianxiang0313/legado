import Foundation

public enum JSONNumberError: Error, Equatable, Sendable {
  case invalidSyntax
  case exponentOutOfRange
}

public struct JSONNumber: Sendable {
  public let rawToken: String

  private let normalized: Normalized

  public init(validating rawToken: String) throws {
    self.rawToken = rawToken
    self.normalized = try Self.normalize(rawToken)
  }

  public init(_ value: Int64) {
    let token = String(value)
    self.rawToken = token
    self.normalized = try! Self.normalize(token)
  }
}

extension JSONNumber: Equatable {
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.normalized == rhs.normalized
  }
}

extension JSONNumber: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(Int64.self) {
      self.init(value)
      return
    }
    if let value = try? container.decode(UInt64.self) {
      try self.init(validating: String(value))
      return
    }
    let value = try container.decode(Decimal.self)
    try self.init(validating: NSDecimalNumber(decimal: value).stringValue)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    if let value = Int64(rawToken) {
      try container.encode(value)
      return
    }
    if let value = UInt64(rawToken) {
      try container.encode(value)
      return
    }
    guard
      let decimal = Decimal(string: rawToken, locale: Locale(identifier: "en_US_POSIX")),
      let bridged = try? JSONNumber(validating: NSDecimalNumber(decimal: decimal).stringValue),
      bridged == self
    else {
      throw EncodingError.invalidValue(
        self,
        .init(codingPath: encoder.codingPath, debugDescription: "JSON number exceeds the exact Codable bridge range")
      )
    }
    try container.encode(decimal)
  }
}

extension JSONNumber {
  fileprivate struct Normalized: Equatable, Sendable {
    let negative: Bool
    let significand: String
    let decimalExponent: Int
  }

  fileprivate static func normalize(_ token: String) throws -> Normalized {
    let bytes = Array(token.utf8)
    guard !bytes.isEmpty else { throw JSONNumberError.invalidSyntax }
    var index = 0
    let negative = bytes[index] == 45
    if negative { index += 1 }
    guard index < bytes.count else { throw JSONNumberError.invalidSyntax }

    let integerStart = index
    if bytes[index] == 48 {
      index += 1
      if index < bytes.count, isDigit(bytes[index]) { throw JSONNumberError.invalidSyntax }
    } else {
      guard (49...57).contains(bytes[index]) else { throw JSONNumberError.invalidSyntax }
      while index < bytes.count, isDigit(bytes[index]) { index += 1 }
    }
    let integerEnd = index

    var fractionStart = index
    if index < bytes.count, bytes[index] == 46 {
      index += 1
      fractionStart = index
      while index < bytes.count, isDigit(bytes[index]) { index += 1 }
      guard index > fractionStart else { throw JSONNumberError.invalidSyntax }
    }
    let fractionEnd = index

    var explicitExponent = 0
    if index < bytes.count, [69, 101].contains(bytes[index]) {
      index += 1
      var exponentNegative = false
      if index < bytes.count, [43, 45].contains(bytes[index]) {
        exponentNegative = bytes[index] == 45
        index += 1
      }
      let exponentStart = index
      while index < bytes.count, isDigit(bytes[index]) { index += 1 }
      guard index > exponentStart else { throw JSONNumberError.invalidSyntax }
      guard let magnitude = Int(String(decoding: bytes[exponentStart..<index], as: UTF8.self)) else {
        throw JSONNumberError.exponentOutOfRange
      }
      explicitExponent = exponentNegative ? -magnitude : magnitude
    }
    guard index == bytes.count else { throw JSONNumberError.invalidSyntax }

    var digits = Array(bytes[integerStart..<integerEnd])
    digits.append(contentsOf: bytes[fractionStart..<fractionEnd])
    while digits.first == 48 { digits.removeFirst() }
    guard !digits.isEmpty else { return Normalized(negative: false, significand: "0", decimalExponent: 0) }

    let (initialExponent, underflow) = explicitExponent.subtractingReportingOverflow(fractionEnd - fractionStart)
    guard !underflow else { throw JSONNumberError.exponentOutOfRange }
    var decimalExponent = initialExponent
    while digits.last == 48 {
      digits.removeLast()
      let (next, overflow) = decimalExponent.addingReportingOverflow(1)
      guard !overflow else { throw JSONNumberError.exponentOutOfRange }
      decimalExponent = next
    }
    return Normalized(
      negative: negative,
      significand: String(decoding: digits, as: UTF8.self),
      decimalExponent: decimalExponent
    )
  }

  fileprivate static func isDigit(_ byte: UInt8) -> Bool {
    (48...57).contains(byte)
  }
}
