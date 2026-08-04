import Foundation

public enum AndroidSharePayloadKind: String, Codable, Equatable, Sendable {
  case text
  case url
  case file
}

public struct AndroidSharePayload: Equatable, Sendable {
  public let kind: AndroidSharePayloadKind
  public let data: Data
  public let suggestedName: String?

  public init(
    kind: AndroidSharePayloadKind,
    data: Data,
    suggestedName: String? = nil
  ) {
    self.kind = kind
    self.data = data
    self.suggestedName = suggestedName
  }
}

public enum AndroidShareInboxError: Error, Equatable, Sendable {
  case appGroupUnavailable
  case payloadTooLarge
  case invalidToken
  case missingPayload
}

public struct AndroidShareInbox {
  public static let applicationGroupIdentifier =
    "group.com.yangtianxiang.legado.app"
  public static let maximumPayloadBytes = 32 * 1_024 * 1_024

  private let rootURL: URL
  private let maximumBytes: Int
  private let fileManager: FileManager

  public init(
    containerURL: URL,
    maximumPayloadBytes: Int = AndroidShareInbox.maximumPayloadBytes,
    fileManager: FileManager = .default
  ) {
    rootURL = containerURL.appendingPathComponent(
      "AndroidShareInbox",
      isDirectory: true
    )
    maximumBytes = maximumPayloadBytes
    self.fileManager = fileManager
  }

  public static func applicationGroup(
    fileManager: FileManager = .default
  ) throws -> AndroidShareInbox {
    guard let containerURL = fileManager.containerURL(
      forSecurityApplicationGroupIdentifier: applicationGroupIdentifier
    ) else {
      throw AndroidShareInboxError.appGroupUnavailable
    }
    return AndroidShareInbox(
      containerURL: containerURL,
      fileManager: fileManager
    )
  }

  @discardableResult
  public func store(_ payload: AndroidSharePayload) throws -> String {
    guard payload.data.count <= maximumBytes else {
      throw AndroidShareInboxError.payloadTooLarge
    }
    try fileManager.createDirectory(
      at: rootURL,
      withIntermediateDirectories: true
    )
    let token = UUID().uuidString.lowercased()
    let temporaryURL = rootURL.appendingPathComponent(
      ".\(token).tmp",
      isDirectory: true
    )
    let destinationURL = rootURL.appendingPathComponent(token, isDirectory: true)
    do {
      try fileManager.createDirectory(
        at: temporaryURL,
        withIntermediateDirectories: false
      )
      try payload.data.write(
        to: temporaryURL.appendingPathComponent("payload.bin"),
        options: .atomic
      )
      let metadata = Metadata(
        kind: payload.kind,
        suggestedName: payload.suggestedName
      )
      try JSONEncoder().encode(metadata).write(
        to: temporaryURL.appendingPathComponent("metadata.json"),
        options: .atomic
      )
      try fileManager.moveItem(at: temporaryURL, to: destinationURL)
      return token
    } catch {
      try? fileManager.removeItem(at: temporaryURL)
      throw error
    }
  }

  public func consume(token: String) throws -> AndroidSharePayload {
    let canonicalToken = try Self.canonicalToken(token)
    let directoryURL = rootURL.appendingPathComponent(
      canonicalToken,
      isDirectory: true
    )
    guard fileManager.fileExists(atPath: directoryURL.path) else {
      throw AndroidShareInboxError.missingPayload
    }
    let metadata = try JSONDecoder().decode(
      Metadata.self,
      from: Data(contentsOf: directoryURL.appendingPathComponent("metadata.json"))
    )
    let payloadURL = directoryURL.appendingPathComponent("payload.bin")
    let values = try payloadURL.resourceValues(forKeys: [.fileSizeKey])
    guard (values.fileSize ?? 0) <= maximumBytes else {
      throw AndroidShareInboxError.payloadTooLarge
    }
    let data = try Data(contentsOf: payloadURL, options: [.mappedIfSafe])
    guard data.count <= maximumBytes else {
      throw AndroidShareInboxError.payloadTooLarge
    }
    let payload = AndroidSharePayload(
      kind: metadata.kind,
      data: data,
      suggestedName: metadata.suggestedName
    )
    try fileManager.removeItem(at: directoryURL)
    return payload
  }

  public func pendingTokens() throws -> [String] {
    guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
    return try fileManager.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ).compactMap { url -> (String, Date)? in
      guard let token = try? Self.canonicalToken(url.lastPathComponent) else {
        return nil
      }
      let date = try? url.resourceValues(
        forKeys: [.contentModificationDateKey]
      ).contentModificationDate
      return (token, date ?? .distantPast)
    }.sorted { $0.1 < $1.1 }.map(\.0)
  }

  public static func openURL(token: String) throws -> URL {
    let canonicalToken = try canonicalToken(token)
    var components = URLComponents()
    components.scheme = "legado"
    components.host = "import"
    components.path = "/inbox"
    components.queryItems = [URLQueryItem(name: "token", value: canonicalToken)]
    guard let url = components.url else {
      throw AndroidShareInboxError.invalidToken
    }
    return url
  }

  public static func token(from url: URL) -> String? {
    guard let components = URLComponents(
      url: url,
      resolvingAgainstBaseURL: false
    ), components.scheme?.lowercased() == "legado",
      components.host?.lowercased() == "import",
      components.path.lowercased() == "/inbox",
      let token = components.queryItems?.first(where: { $0.name == "token" })?
        .value,
      let canonical = try? canonicalToken(token)
    else { return nil }
    return canonical
  }

  private static func canonicalToken(_ token: String) throws -> String {
    guard let uuid = UUID(uuidString: token),
      uuid.uuidString.lowercased() == token.lowercased()
    else { throw AndroidShareInboxError.invalidToken }
    return uuid.uuidString.lowercased()
  }

  private struct Metadata: Codable {
    let kind: AndroidSharePayloadKind
    let suggestedName: String?
  }
}
