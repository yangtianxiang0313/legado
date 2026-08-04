import AndroidBackupInterop
import AppUseCases
import Foundation

public enum AndroidOnlineImportTarget: String, Equatable, Hashable, Sendable {
  case bookSource
  case rssSource
  case replaceRule
  case httpTTS
  case dictionaryRule
  case localTextTOCRule
  case addToBookshelf
  case readerConfig
  case theme
}

public struct AndroidOnlineImportRequest: Identifiable, Equatable, Sendable {
  public var id: String { target.rawValue + "\u{0}" + sourceURL }
  public let target: AndroidOnlineImportTarget
  public let sourceURL: String
  public let inlineData: Data?

  public init(
    target: AndroidOnlineImportTarget,
    sourceURL: String,
    inlineData: Data? = nil
  ) {
    self.target = target
    self.sourceURL = sourceURL
    self.inlineData = inlineData
  }
}

public enum AndroidAssociatedImportError: Error, Equatable, Sendable {
  case unrecognized
  case ambiguous
}

public enum AndroidAssociatedImportClassifier {
  public static func classifyJSON(_ data: Data) throws
    -> AndroidOnlineImportTarget
  {
    var matches: [AndroidOnlineImportTarget] = []
    if let values = try? SourceDefinitionImport.decode(data), !values.isEmpty {
      matches.append(.bookSource)
    }
    if let values = try? AndroidRSSCodec.decodeSources(data),
      values.contains(where: { !($0.string("sourceUrl") ?? "").isEmpty })
    { matches.append(.rssSource) }
    if let values = try? AndroidReplaceRuleCodec.decodeMany(data),
      values.contains(where: { $0.rawFields["pattern"] != nil })
    { matches.append(.replaceRule) }
    if let values = try? AndroidHTTPTextToSpeechCodec.decodeMany(data),
      values.contains(where: { !($0.string("url") ?? "").isEmpty })
    { matches.append(.httpTTS) }
    if let values = try? AndroidDictionaryRuleCodec.decodeMany(data),
      values.contains(where: { !($0.string("urlRule") ?? "").isEmpty })
    { matches.append(.dictionaryRule) }
    if let values = try? AndroidLocalTextTOCRuleCodec.decodeMany(data),
      values.contains(where: { !($0.string("rule") ?? "").isEmpty })
    { matches.append(.localTextTOCRule) }
    if let values = try? AndroidThemeConfigCodec.decodeMany(data),
      values.contains(where: { !($0.string("themeName") ?? "").isEmpty })
    { matches.append(.theme) }
    let unique = Array(Set(matches))
    guard !unique.isEmpty else { throw AndroidAssociatedImportError.unrecognized }
    guard unique.count == 1 else { throw AndroidAssociatedImportError.ambiguous }
    return unique[0]
  }
}

public enum AndroidOnlineImportLinkError: Error, Equatable, Sendable {
  case unsupportedScheme
  case unsupportedTarget
  case missingSourceURL
}

public enum AndroidOnlineImportLinkParser {
  public static func parse(_ url: URL) throws -> AndroidOnlineImportRequest {
    guard let components = URLComponents(
      url: url,
      resolvingAgainstBaseURL: false
    ), ["legado", "yuedu"].contains(components.scheme?.lowercased() ?? "")
    else {
      throw AndroidOnlineImportLinkError.unsupportedScheme
    }
    guard let sourceURL = components.queryItems?
      .first(where: { $0.name == "src" })?.value,
      !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw AndroidOnlineImportLinkError.missingSourceURL
    }

    let host = components.host?.lowercased() ?? ""
    let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let rawTarget: String
    if host == "import" {
      rawTarget = path
    } else if path.lowercased() == "importonline" {
      rawTarget = host
    } else {
      throw AndroidOnlineImportLinkError.unsupportedTarget
    }

    let target: AndroidOnlineImportTarget
    switch rawTarget.lowercased() {
    case "booksource": target = .bookSource
    case "rsssource": target = .rssSource
    case "replacerule", "replace": target = .replaceRule
    case "httptts": target = .httpTTS
    case "dictrule": target = .dictionaryRule
    case "texttocrule": target = .localTextTOCRule
    case "addtobookshelf": target = .addToBookshelf
    case "readconfig": target = .readerConfig
    case "theme": target = .theme
    default: throw AndroidOnlineImportLinkError.unsupportedTarget
    }
    return AndroidOnlineImportRequest(target: target, sourceURL: sourceURL)
  }
}
