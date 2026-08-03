import Foundation
import Observation
import SourceRuntime

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

@MainActor
public protocol HTTPTextToSpeechSelectionPersistence: AnyObject {
  func selectedHTTPTextToSpeechEngineID() -> Int64?
  func saveSelectedHTTPTextToSpeechEngineID(_ id: Int64?)
}

@MainActor
@Observable
public final class HTTPTextToSpeechEngineStore {
  public private(set) var engines: [HTTPTextToSpeechEngine] = []
  public private(set) var selectedEngineID: Int64?
  public private(set) var errorMessage: String?

  private let repository: any HTTPTextToSpeechRepository
  private let persistence: any HTTPTextToSpeechSelectionPersistence

  public init(
    repository: any HTTPTextToSpeechRepository,
    persistence: any HTTPTextToSpeechSelectionPersistence
  ) {
    self.repository = repository
    self.persistence = persistence
    selectedEngineID = persistence.selectedHTTPTextToSpeechEngineID()
  }

  public var selectedEngine: HTTPTextToSpeechEngine? {
    selectedEngineID.flatMap { id in engines.first { $0.id == id } }
  }

  public func reload() async {
    do {
      engines = try await repository.httpTextToSpeechEngines()
      if selectedEngineID != nil && selectedEngine == nil {
        select(nil)
      }
      errorMessage = nil
    } catch {
      errorMessage = "无法读取在线朗读引擎"
    }
  }

  public func select(_ id: Int64?) {
    guard id == nil || engines.contains(where: { $0.id == id }) else {
      return
    }
    selectedEngineID = id
    persistence.saveSelectedHTTPTextToSpeechEngineID(id)
  }
}

public protocol HTTPTextToSpeechAudioLoading: Sendable {
  func load(
    engine: HTTPTextToSpeechEngine,
    text: String,
    speed: Int
  ) async throws -> Data
}

public struct SourceRuntimeHTTPTextToSpeechAudioLoader:
  HTTPTextToSpeechAudioLoading, Sendable
{
  private let transport: any HTTPTransport
  private let cookieStore: SourceCookieStore
  private let scriptRuntime: (any SourceScriptRuntime)?

  public init(
    transport: any HTTPTransport,
    cookieStore: SourceCookieStore = SourceCookieStore(),
    scriptRuntime: (any SourceScriptRuntime)? = nil
  ) {
    self.transport = transport
    self.cookieStore = cookieStore
    self.scriptRuntime = scriptRuntime
  }

  public func load(
    engine: HTTPTextToSpeechEngine,
    text: String,
    speed: Int
  ) async throws -> Data {
    let audio = try await HTTPTextToSpeechPipeline(
      definition: HTTPTextToSpeechRuntimeDefinition(
        id: engine.id,
        urlTemplate: engine.url,
        contentTypePattern: engine.contentType,
        headers: try headers(engine.header),
        enabledCookieJar: engine.enabledCookieJar ?? false,
        scriptLibrary: engine.jsLib.map {
          SourceScriptLibrary(source: $0)
        }
      ),
      transport: transport,
      cookieStore: cookieStore,
      scriptRuntime: scriptRuntime
    ).load(text: text, speed: speed)
    return audio.data
  }

  private func headers(_ value: String?) throws -> [SourceHeaderField] {
    guard let value, !value.isEmpty else { return [] }
    let object = try JSONDecoder().decode(
      [String: String].self,
      from: Data(value.utf8)
    )
    return try object.sorted { $0.key < $1.key }.map {
      try SourceHeaderField(name: $0.key, value: $0.value)
    }
  }
}
