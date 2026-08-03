import Foundation

public struct HTTPTextToSpeechEngine: Codable, Identifiable, Equatable, Sendable {
  public let id: Int64
  public var name: String
  public var url: String
  public var contentType: String?
  public var concurrentRate: String?
  public var loginURL: String?
  public var loginUI: String?
  public var header: String?
  public var jsLib: String?
  public var enabledCookieJar: Bool?
  public var loginCheckJS: String?
  public var lastUpdateTime: Int64

  public init(
    id: Int64,
    name: String,
    url: String,
    contentType: String? = nil,
    concurrentRate: String? = "0",
    loginURL: String? = nil,
    loginUI: String? = nil,
    header: String? = nil,
    jsLib: String? = nil,
    enabledCookieJar: Bool? = false,
    loginCheckJS: String? = nil,
    lastUpdateTime: Int64 = 0
  ) {
    self.id = id
    self.name = name
    self.url = url
    self.contentType = contentType
    self.concurrentRate = concurrentRate
    self.loginURL = loginURL
    self.loginUI = loginUI
    self.header = header
    self.jsLib = jsLib
    self.enabledCookieJar = enabledCookieJar
    self.loginCheckJS = loginCheckJS
    self.lastUpdateTime = lastUpdateTime
  }
}

public protocol HTTPTextToSpeechRepository: Sendable {
  func httpTextToSpeechEngines() async throws -> [HTTPTextToSpeechEngine]
  func upsertHTTPTextToSpeechEngine(_ engine: HTTPTextToSpeechEngine) async throws
}
