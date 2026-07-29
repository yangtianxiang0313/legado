import Foundation

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
}

/// Portable response behavior observed from Android's non-WebView
/// `AnalyzeUrl.getStrResponseAwait`. Charset and compression negotiation stay
/// outside this slice until separately characterized.
public enum SourceStringResponseNormalizer {
  private static let declaration = #"<?xml version="1.0"?>"#

  public static func normalize(
    _ response: HTTPResponse
  ) throws -> SourceStringResponse {
    guard let decoded = String(data: response.body.bytes, encoding: .utf8) else {
      throw SourceStringResponseError.invalidUTF8
    }
    let contentType = response.headers.values(for: "content-type").last
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
