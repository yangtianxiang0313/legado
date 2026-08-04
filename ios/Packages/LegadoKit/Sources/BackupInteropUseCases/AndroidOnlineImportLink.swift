import Foundation

public enum AndroidOnlineImportTarget: String, Equatable, Sendable {
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

  public init(target: AndroidOnlineImportTarget, sourceURL: String) {
    self.target = target
    self.sourceURL = sourceURL
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
