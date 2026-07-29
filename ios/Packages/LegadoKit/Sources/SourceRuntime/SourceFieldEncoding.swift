import CoreFoundation
import Foundation

public enum SourceFieldEncodingError: Error, Equatable, Sendable {
  case unsupportedCharset(String)
  case unencodableValue(String)
}

public enum SourceFieldCompiler {
  public static func compile(
    _ text: String,
    charset: String? = nil
  ) throws -> [HTTPFormField] {
    var fields: [HTTPFormField] = []
    var positions: [String: Int] = [:]
    for rawField in text.split(
      separator: "&",
      omittingEmptySubsequences: false
    ) {
      let field = rawField.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !field.isEmpty else { continue }
      let rawParts = field.split(
        separator: "=",
        maxSplits: 1,
        omittingEmptySubsequences: false
      )
      let parts =
        rawParts
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      guard let key = parts.first else { continue }
      let rawValue = parts.count > 1 ? parts[1] : ""
      let value = try encode(rawValue, charset: charset)
      let compiled = HTTPFormField(key: key, value: value)
      if let index = positions[key] {
        fields[index] = compiled
      } else {
        positions[key] = fields.count
        fields.append(compiled)
      }
    }
    return fields
  }

  private static func encode(
    _ value: String,
    charset: String?
  ) throws -> String {
    guard let charset, !charset.isEmpty else {
      return hasValidFormEncoding(value)
        ? value
        : formEncode(Array(value.utf8))
    }
    if charset == "escape" {
      return escape(value)
    }
    guard charset.caseInsensitiveCompare("GBK") == .orderedSame else {
      throw SourceFieldEncodingError.unsupportedCharset(charset)
    }
    let encoding = String.Encoding(
      rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
      )
    )
    guard let data = value.data(using: encoding, allowLossyConversion: false) else {
      throw SourceFieldEncodingError.unencodableValue(value)
    }
    return formEncode(Array(data))
  }

  private static func formEncode(_ bytes: [UInt8]) -> String {
    let hexadecimal = Array("0123456789ABCDEF".utf8)
    var output: [UInt8] = []
    for byte in bytes {
      if isFormSafe(byte) {
        output.append(byte)
      } else if byte == 32 {
        output.append(43)
      } else {
        output.append(37)
        output.append(hexadecimal[Int(byte >> 4)])
        output.append(hexadecimal[Int(byte & 15)])
      }
    }
    return String(decoding: output, as: UTF8.self)
  }

  private static func escape(_ value: String) -> String {
    var result = ""
    for scalar in value.unicodeScalars {
      let code = scalar.value
      if (48...57).contains(code)
        || (65...90).contains(code)
        || (97...122).contains(code)
      {
        result.unicodeScalars.append(scalar)
      } else if code < 16 {
        result += "%0" + String(code, radix: 16)
      } else if code < 256 {
        result += "%" + String(code, radix: 16)
      } else {
        result += "%u" + String(code, radix: 16)
      }
    }
    return result
  }

  private static func hasValidFormEncoding(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    var index = 0
    while index < bytes.count {
      let byte = bytes[index]
      if isFormSafe(byte) || byte == 43 {
        index += 1
      } else if byte == 37,
        index + 2 < bytes.count,
        isHex(bytes[index + 1]),
        isHex(bytes[index + 2])
      {
        index += 3
      } else {
        return false
      }
    }
    return true
  }

  private static func isFormSafe(_ byte: UInt8) -> Bool {
    (48...57).contains(byte)
      || (65...90).contains(byte)
      || (97...122).contains(byte)
      || [42, 45, 46, 95].contains(byte)
  }

  private static func isHex(_ byte: UInt8) -> Bool {
    (48...57).contains(byte)
      || (65...70).contains(byte)
      || (97...102).contains(byte)
  }
}
