import Foundation

public enum AndroidSharedPreferenceValue: Equatable, Sendable {
  case string(String)
  case int(Int32)
  case long(Int64)
  case float(Float)
  case boolean(Bool)
}

public struct AndroidSharedPreferencesDocument: Equatable, Sendable {
  public var values: [String: AndroidSharedPreferenceValue]

  public init(values: [String: AndroidSharedPreferenceValue] = [:]) {
    self.values = values
  }

  public subscript(key: String) -> AndroidSharedPreferenceValue? {
    get { values[key] }
    set { values[key] = newValue }
  }
}

public enum AndroidSharedPreferencesCodecError: Error, Equatable, Sendable {
  case invalidDocument
  case duplicateKey(String)
  case unsupportedElement(String)
  case invalidValue(name: String)
}

public enum AndroidSharedPreferencesCodec {
  public static func decode(
    _ data: Data
  ) throws -> AndroidSharedPreferencesDocument {
    let delegate = ParserDelegate()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    parser.shouldProcessNamespaces = false
    parser.shouldReportNamespacePrefixes = false
    parser.shouldResolveExternalEntities = false
    guard parser.parse(), delegate.failure == nil else {
      throw delegate.failure ?? .invalidDocument
    }
    guard delegate.sawMap, delegate.depth == 0,
      delegate.currentStringName == nil
    else {
      throw AndroidSharedPreferencesCodecError.invalidDocument
    }
    return AndroidSharedPreferencesDocument(values: delegate.values)
  }

  public static func encode(
    _ document: AndroidSharedPreferencesDocument
  ) -> Data {
    var lines = [
      #"<?xml version='1.0' encoding='utf-8' standalone='yes' ?>"#,
      "<map>",
    ]
    for key in document.values.keys.sorted() {
      guard let value = document.values[key] else { continue }
      let name = escapeAttribute(key)
      switch value {
      case .string(let string):
        lines.append("    <string name=\"\(name)\">\(escapeText(string))</string>")
      case .int(let integer):
        lines.append("    <int name=\"\(name)\" value=\"\(integer)\" />")
      case .long(let integer):
        lines.append("    <long name=\"\(name)\" value=\"\(integer)\" />")
      case .float(let number):
        lines.append("    <float name=\"\(name)\" value=\"\(number)\" />")
      case .boolean(let boolean):
        lines.append(
          "    <boolean name=\"\(name)\" value=\"\(boolean ? "true" : "false")\" />"
        )
      }
    }
    lines.append("</map>")
    lines.append("")
    return Data(lines.joined(separator: "\n").utf8)
  }

  private static func escapeText(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }

  private static func escapeAttribute(_ value: String) -> String {
    escapeText(value)
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }
}

public struct AndroidWebDAVBackupConfiguration: Equatable, Sendable {
  public static let serverAddressKey = "web_dav_url"
  public static let usernameKey = "web_dav_account"
  public static let passwordKey = "web_dav_password"
  public static let directoryNameKey = "webDavDir"
  public static let remoteServerIDKey = "remoteServerId"
  public static let syncBookProgressKey = "syncBookProgress"
  public static let webDAVDeviceNameKey = "webDavDeviceName"
  public static let onlyLatestBackupKey = "onlyLatestBackup"

  public let serverAddress: String?
  public let username: String?
  /// Android may store AES/Base64 or its plaintext fallback here. It must not
  /// be treated as a usable password until an explicit resolver validates it.
  public let unresolvedPasswordPayload: String?
  public let directoryName: String?
  public let remoteServerID: Int64?
  public let syncBookProgress: Bool?
  public let webDAVDeviceName: String?
  public let onlyLatestBackup: Bool?

  public init(
    serverAddress: String?,
    username: String?,
    unresolvedPasswordPayload: String?,
    directoryName: String?,
    remoteServerID: Int64? = nil,
    syncBookProgress: Bool? = nil,
    webDAVDeviceName: String? = nil,
    onlyLatestBackup: Bool? = nil
  ) {
    self.serverAddress = serverAddress
    self.username = username
    self.unresolvedPasswordPayload = unresolvedPasswordPayload
    self.directoryName = directoryName
    self.remoteServerID = remoteServerID
    self.syncBookProgress = syncBookProgress
    self.webDAVDeviceName = webDAVDeviceName
    self.onlyLatestBackup = onlyLatestBackup
  }

  public init(document: AndroidSharedPreferencesDocument) {
    self.init(
      serverAddress: document.string(Self.serverAddressKey),
      username: document.string(Self.usernameKey),
      unresolvedPasswordPayload: document.string(Self.passwordKey),
      directoryName: document.string(Self.directoryNameKey),
      remoteServerID: document.integer(Self.remoteServerIDKey),
      syncBookProgress: document.boolean(Self.syncBookProgressKey),
      webDAVDeviceName: document.string(Self.webDAVDeviceNameKey),
      onlyLatestBackup: document.boolean(Self.onlyLatestBackupKey)
    )
  }

  public var isPresent: Bool {
    serverAddress != nil
      || username != nil
      || unresolvedPasswordPayload != nil
      || directoryName != nil
      || syncBookProgress != nil
      || webDAVDeviceName != nil
      || onlyLatestBackup != nil
  }
}

public struct AndroidApplicationBackupPreferences: Equatable, Sendable {
  public static let showDiscoveryKey = "showDiscovery"
  public static let showRSSKey = "showRss"
  public static let bookshelfSortKey = "bookshelfSort"
  public static let defaultHomePageKey = "defaultHomePage"
  public static let enableReadRecordKey = "enableReadRecord"
  public static let searchScopeKey = "searchScope"
  public static let searchGroupKey = "searchGroup"
  public static let ttsFollowSystemKey = "ttsFollowSys"
  public static let ttsSpeechRateKey = "ttsSpeechRate"

  public let showsDiscovery: Bool?
  public let showsRSS: Bool?
  public let bookshelfSort: Int64?
  public let defaultHomePage: String?
  public let enablesReadRecord: Bool?
  public let searchScope: String?
  public let searchGroup: String?
  public let ttsFollowsSystemRate: Bool?
  public let ttsSpeechRate: Int64?

  public init(
    showsDiscovery: Bool? = nil,
    showsRSS: Bool? = nil,
    bookshelfSort: Int64? = nil,
    defaultHomePage: String? = nil,
    enablesReadRecord: Bool? = nil,
    searchScope: String? = nil,
    searchGroup: String? = nil,
    ttsFollowsSystemRate: Bool? = nil,
    ttsSpeechRate: Int64? = nil
  ) {
    self.showsDiscovery = showsDiscovery
    self.showsRSS = showsRSS
    self.bookshelfSort = bookshelfSort
    self.defaultHomePage = defaultHomePage
    self.enablesReadRecord = enablesReadRecord
    self.searchScope = searchScope
    self.searchGroup = searchGroup
    self.ttsFollowsSystemRate = ttsFollowsSystemRate
    self.ttsSpeechRate = ttsSpeechRate
  }

  public init(document: AndroidSharedPreferencesDocument) {
    self.init(
      showsDiscovery: document.boolean(Self.showDiscoveryKey),
      showsRSS: document.boolean(Self.showRSSKey),
      bookshelfSort: document.integer(Self.bookshelfSortKey),
      defaultHomePage: document.string(Self.defaultHomePageKey),
      enablesReadRecord: document.boolean(Self.enableReadRecordKey),
      searchScope: document.string(Self.searchScopeKey),
      searchGroup: document.string(Self.searchGroupKey),
      ttsFollowsSystemRate: document.boolean(Self.ttsFollowSystemKey),
      ttsSpeechRate: document.integer(Self.ttsSpeechRateKey)
    )
  }

  public var isPresent: Bool {
    showsDiscovery != nil || showsRSS != nil || bookshelfSort != nil
      || defaultHomePage != nil
      || enablesReadRecord != nil
      || searchScope != nil || searchGroup != nil
      || ttsFollowsSystemRate != nil || ttsSpeechRate != nil
  }
}

private extension AndroidSharedPreferencesDocument {
  func string(_ key: String) -> String? {
    guard case .string(let value)? = values[key] else { return nil }
    return value
  }


  func integer(_ key: String) -> Int64? {
    switch values[key] {
    case .int(let value): Int64(value)
    case .long(let value): value
    default: nil
    }
  }

  func boolean(_ key: String) -> Bool? {
    guard case .boolean(let value)? = values[key] else { return nil }
    return value
  }
}

private final class ParserDelegate: NSObject, XMLParserDelegate {
  var values: [String: AndroidSharedPreferenceValue] = [:]
  var failure: AndroidSharedPreferencesCodecError?
  var sawMap = false
  var depth = 0
  var currentStringName: String?
  var currentStringValue = ""

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    guard failure == nil else { return }
    depth += 1
    if depth == 1 {
      guard elementName == "map" else {
        failure = .invalidDocument
        parser.abortParsing()
        return
      }
      sawMap = true
      return
    }
    guard depth == 2, sawMap, let name = attributeDict["name"],
      !name.isEmpty
    else {
      failure = .invalidDocument
      parser.abortParsing()
      return
    }
    guard values[name] == nil, currentStringName == nil else {
      failure = .duplicateKey(name)
      parser.abortParsing()
      return
    }
    if elementName == "string" {
      currentStringName = name
      currentStringValue = ""
      return
    }
    guard let rawValue = attributeDict["value"] else {
      failure = .invalidValue(name: name)
      parser.abortParsing()
      return
    }
    let value: AndroidSharedPreferenceValue?
    switch elementName {
    case "int":
      value = Int32(rawValue).map(AndroidSharedPreferenceValue.int)
    case "long":
      value = Int64(rawValue).map(AndroidSharedPreferenceValue.long)
    case "float":
      value = Float(rawValue).map(AndroidSharedPreferenceValue.float)
    case "boolean" where rawValue == "true":
      value = .boolean(true)
    case "boolean" where rawValue == "false":
      value = .boolean(false)
    case "boolean":
      value = nil
    default:
      failure = .unsupportedElement(elementName)
      parser.abortParsing()
      return
    }
    guard let value else {
      failure = .invalidValue(name: name)
      parser.abortParsing()
      return
    }
    values[name] = value
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard currentStringName != nil else {
      if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return
      }
      failure = .invalidDocument
      parser.abortParsing()
      return
    }
    currentStringValue += string
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    guard failure == nil else { return }
    if elementName == "string" {
      guard let name = currentStringName, depth == 2 else {
        failure = .invalidDocument
        parser.abortParsing()
        return
      }
      values[name] = .string(currentStringValue)
      currentStringName = nil
      currentStringValue = ""
    }
    depth -= 1
    if depth < 0 {
      failure = .invalidDocument
      parser.abortParsing()
    }
  }
}
