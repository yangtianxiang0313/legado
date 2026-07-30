import CoreFoundation
import Foundation
import zlib

public struct SourceStringResponse: Equatable, Sendable {
  public let body: String
  public let finalURL: HTTPURL

  public init(body: String, finalURL: HTTPURL) {
    self.body = body
    self.finalURL = finalURL
  }
}

public enum SourceStringResponseError: Error, Equatable, Sendable {
  case invalidUTF8
  case unsupportedCharset(String)
  case decompressionFailed
  case tooManyRedirects
}

public struct SourceRedirectPolicy: Equatable, Sendable {
  public let maximumFollowUps: Int

  public init(maximumFollowUps: Int = 20) {
    self.maximumFollowUps = maximumFollowUps
  }

  public func validate(followUpCount: Int) throws {
    guard followUpCount <= maximumFollowUps else {
      throw SourceStringResponseError.tooManyRedirects
    }
  }
}

/// Portable response behavior observed from Android's non-WebView
/// `AnalyzeUrl.getStrResponseAwait` and `ResponseBody.text`.
public enum SourceStringResponseNormalizer {
  private static let declaration = #"<?xml version="1.0"?>"#
  private static let gb18030 = String.Encoding(
    rawValue: CFStringConvertEncodingToNSStringEncoding(
      CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
    )
  )

  public static func normalize(
    _ response: HTTPResponse
  ) throws -> SourceStringResponse {
    let contentType = response.headers.values(for: "content-type").last
    let contentEncoding = response.headers.values(for: "content-encoding").last
    var bytes = response.body.bytes
    if contentEncoding?.caseInsensitiveCompare("gzip") == .orderedSame {
      bytes = try inflate(bytes, windowBits: Int32(MAX_WBITS + 16))
    }
    if contentType?.lowercased() == "application/zip" {
      bytes = try firstZIPEntry(bytes)
    }
    bytes = removeUTF8BOM(bytes)
    let decoded = try decode(bytes, contentType: contentType)
    let body: String
    if
      contentType.map(isXMLContentType) == true,
      !startsWithXMLDeclarationAfterASCIISpace(decoded)
    {
      body = declaration + decoded
    } else {
      body = decoded
    }
    return SourceStringResponse(body: body, finalURL: response.effectiveURL)
  }

  private static func decode(
    _ data: Data,
    contentType: String?
  ) throws -> String {
    if let charset = contentType.flatMap(declaredCharset) {
      return try decode(data, charset: charset)
    }
    if let value = String(data: data, encoding: .utf8) {
      return value
    }
    if let charset = detectedHTMLCharset(data) {
      return try decode(data, charset: charset)
    }
    throw SourceStringResponseError.invalidUTF8
  }

  private static func decode(
    _ data: Data,
    charset: String
  ) throws -> String {
    switch charset.lowercased() {
    case "utf-8", "utf8":
      return String(decoding: data, as: UTF8.self)
    case "gbk", "gb2312", "gb18030", "gb-18030":
      return decodeGB18030Lossy(data)
    default:
      throw SourceStringResponseError.unsupportedCharset(charset)
    }
  }

  private static func declaredCharset(_ contentType: String) -> String? {
    for parameter in contentType.split(separator: ";").dropFirst() {
      let parts = parameter.split(
        separator: "=",
        maxSplits: 1,
        omittingEmptySubsequences: false
      )
      guard
        parts.count == 2,
        parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
          .caseInsensitiveCompare("charset") == .orderedSame
      else {
        continue
      }
      return parts[1]
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
    return nil
  }

  private static func detectedHTMLCharset(_ data: Data) -> String? {
    let prefix = data.prefix(4096)
    let ascii = String(
      decoding: prefix.map { byte in
        if (65...90).contains(byte) { return byte + 32 }
        return byte < 128 ? byte : 32
      },
      as: UTF8.self
    )
    guard let marker = ascii.range(of: "charset") else { return nil }
    var suffix = ascii[marker.upperBound...]
    suffix = suffix.drop(while: {
      $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n"
    })
    guard suffix.first == "=" else { return nil }
    suffix = suffix.dropFirst()
    suffix = suffix.drop(while: {
      $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n"
        || $0 == "\"" || $0 == "'"
    })
    let value = suffix.prefix(while: {
      $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
    })
    return value.isEmpty ? nil : String(value)
  }

  private static func decodeGB18030Lossy(_ data: Data) -> String {
    let bytes = Array(data)
    var result = ""
    var index = 0
    while index < bytes.count {
      let byte = bytes[index]
      if byte < 128 {
        result.unicodeScalars.append(UnicodeScalar(byte))
        index += 1
        continue
      }
      if
        index + 3 < bytes.count,
        (0x81...0xFE).contains(byte),
        (0x30...0x39).contains(bytes[index + 1]),
        (0x81...0xFE).contains(bytes[index + 2]),
        (0x30...0x39).contains(bytes[index + 3]),
        let decoded = String(
          data: Data(bytes[index..<(index + 4)]),
          encoding: gb18030
        )
      {
        result += decoded
        index += 4
        continue
      }
      if
        index + 1 < bytes.count,
        (0x81...0xFE).contains(byte),
        (0x40...0xFE).contains(bytes[index + 1]),
        bytes[index + 1] != 0x7F,
        let decoded = String(
          data: Data(bytes[index..<(index + 2)]),
          encoding: gb18030
        )
      {
        result += decoded
        index += 2
        continue
      }
      result.append("\u{FFFD}")
      index += 1
    }
    return result
  }

  private static func removeUTF8BOM(_ data: Data) -> Data {
    data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
  }

  private static func firstZIPEntry(_ data: Data) throws -> Data {
    let bytes = Array(data)
    guard bytes.count >= 30, littleEndian32(bytes, at: 0) == 0x0403_4B50 else {
      return Data()
    }
    let flags = littleEndian16(bytes, at: 6)
    guard flags & 0x0001 == 0 else {
      throw SourceStringResponseError.decompressionFailed
    }
    let method = littleEndian16(bytes, at: 8)
    let compressedSize = Int(littleEndian32(bytes, at: 18))
    let nameLength = Int(littleEndian16(bytes, at: 26))
    let extraLength = Int(littleEndian16(bytes, at: 28))
    let start = 30 + nameLength + extraLength
    guard start <= bytes.count else {
      throw SourceStringResponseError.decompressionFailed
    }
    let end: Int
    if compressedSize > 0 {
      guard start + compressedSize <= bytes.count else {
        throw SourceStringResponseError.decompressionFailed
      }
      end = start + compressedSize
    } else {
      end = bytes.count
    }
    let payload = Data(bytes[start..<end])
    switch method {
    case 0:
      return payload
    case 8:
      return try inflate(payload, windowBits: -Int32(MAX_WBITS))
    default:
      throw SourceStringResponseError.decompressionFailed
    }
  }

  private static func inflate(
    _ data: Data,
    windowBits: Int32
  ) throws -> Data {
    var stream = z_stream()
    guard
      inflateInit2_(
        &stream,
        windowBits,
        ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size)
      ) == Z_OK
    else {
      throw SourceStringResponseError.decompressionFailed
    }
    defer { inflateEnd(&stream) }
    return try data.withUnsafeBytes { input in
      stream.next_in = UnsafeMutablePointer<Bytef>(
        mutating: input.bindMemory(to: Bytef.self).baseAddress
      )
      stream.avail_in = uInt(input.count)
      var output = Data()
      while true {
        var buffer = [UInt8](repeating: 0, count: 32_768)
        let step = buffer.withUnsafeMutableBytes { destination -> (Int32, Int) in
          stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
          stream.avail_out = uInt(destination.count)
          let status = zlib.inflate(&stream, Z_NO_FLUSH)
          return (status, destination.count - Int(stream.avail_out))
        }
        output.append(contentsOf: buffer.prefix(step.1))
        if step.0 == Z_STREAM_END {
          return output
        }
        guard
          step.0 == Z_OK,
          step.1 > 0 || stream.avail_in > 0
        else {
          throw SourceStringResponseError.decompressionFailed
        }
      }
    }
  }

  private static func littleEndian16(_ bytes: [UInt8], at index: Int) -> UInt16 {
    UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
  }

  private static func littleEndian32(_ bytes: [UInt8], at index: Int) -> UInt32 {
    UInt32(bytes[index])
      | UInt32(bytes[index + 1]) << 8
      | UInt32(bytes[index + 2]) << 16
      | UInt32(bytes[index + 3]) << 24
  }

  private static func isXMLContentType(_ value: String) -> Bool {
    let prefixes = ["application/", "text/"]
    guard let prefix = prefixes.first(where: value.hasPrefix) else {
      return false
    }
    let subtype = value.dropFirst(prefix.count)
    var searchStart = subtype.startIndex
    while let range = subtype.range(
      of: "xml",
      range: searchStart..<subtype.endIndex
    ) {
      var stem = subtype[..<range.lowerBound]
      if stem.last == "+" {
        stem = stem.dropLast()
      }
      if stem.utf8.allSatisfy(isASCIIWord) {
        return true
      }
      searchStart = range.upperBound
    }
    return false
  }

  private static func startsWithXMLDeclarationAfterASCIISpace(
    _ value: String
  ) -> Bool {
    let trimmed = value.utf8.drop(while: { $0 <= 32 })
    let prefix = Array("<?xml".utf8)
    guard trimmed.count >= prefix.count else { return false }
    return zip(trimmed.prefix(prefix.count), prefix).allSatisfy {
      asciiLowercased($0.0) == $0.1
    }
  }

  private static func isASCIIWord(_ byte: UInt8) -> Bool {
    switch byte {
    case 48...57, 65...90, 95, 97...122:
      true
    default:
      false
    }
  }

  private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
    (65...90).contains(byte) ? byte + 32 : byte
  }
}
