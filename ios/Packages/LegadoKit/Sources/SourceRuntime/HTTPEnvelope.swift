import CryptoKit
import Foundation

public struct HTTPBodyEnvelope: Codable, Equatable, Sendable {
  public let byteCount: Int
  public let sha256: String

  public init(body: HTTPBody) {
    self.byteCount = body.bytes.count
    self.sha256 = Self.hex(SHA256.hash(data: body.bytes))
  }

  private static func hex(_ digest: SHA256.Digest) -> String {
    let alphabet = Array("0123456789abcdef".utf8)
    var bytes: [UInt8] = []
    bytes.reserveCapacity(64)
    for byte in digest {
      bytes.append(alphabet[Int(byte >> 4)])
      bytes.append(alphabet[Int(byte & 0x0F)])
    }
    return String(decoding: bytes, as: UTF8.self)
  }
}

public struct HTTPRequestEnvelope: Codable, Equatable, Sendable {
  public let method: HTTPMethod
  public let url: String
  public let headers: [HTTPHeader]
  public let body: HTTPBodyEnvelope?
  public let timeoutMilliseconds: UInt64?

  public init(request: HTTPRequest) {
    self.method = request.method
    self.url = request.url.absoluteString
    self.headers = request.headers.canonicalFields
    self.body = request.body.map(HTTPBodyEnvelope.init)
    self.timeoutMilliseconds = request.timeout?.milliseconds
  }
}

public struct HTTPResponseEnvelope: Codable, Equatable, Sendable {
  public let statusCode: Int
  public let effectiveURL: String
  public let headers: [HTTPHeader]
  public let body: HTTPBodyEnvelope

  public init(response: HTTPResponse) {
    self.statusCode = response.statusCode
    self.effectiveURL = response.effectiveURL.absoluteString
    self.headers = response.headers.canonicalFields
    self.body = HTTPBodyEnvelope(body: response.body)
  }
}

public enum HTTPEnvelopeCodec {
  public static func encode(_ request: HTTPRequest) throws -> Data {
    try encoder().encode(HTTPRequestEnvelope(request: request))
  }

  public static func encode(_ response: HTTPResponse) throws -> Data {
    try encoder().encode(HTTPResponseEnvelope(response: response))
  }

  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}
