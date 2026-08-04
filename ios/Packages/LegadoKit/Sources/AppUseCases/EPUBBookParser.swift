import Foundation
import LibraryDomain

public struct EPUBBookDocument: Equatable, Sendable {
  public let title: String
  public let author: String
  public let chapters: [LocalTextChapter]

  public init(title: String, author: String, chapters: [LocalTextChapter]) {
    self.title = title
    self.author = author
    self.chapters = chapters
  }
}

public enum LocalBookPayload: Sendable {
  case text(Data)
  case epub([String: Data])

  var byteCount: Int {
    switch self {
    case .text(let data): data.count
    case .epub(let members): members.values.reduce(0) { $0 + $1.count }
    }
  }
}

public enum EPUBBookFailure: Error, Equatable, Sendable {
  case missingContainer
  case missingPackageDocument
  case malformedPackageDocument
  case emptySpine
  case missingContent(String)
}

public struct AndroidEPUBDeletedTags: OptionSet, Equatable, Sendable {
  public let rawValue: Int64

  public init(rawValue: Int64) { self.rawValue = rawValue }

  public static let headings = Self(rawValue: 2)
  public static let rubyAnnotation = Self(rawValue: 4)
}

/// EPUB 语义解析保持为纯数据边界。ZIP、文件权限与 WebDAV 均由 App 适配层负责，
/// 因而本地文件和远程下载可以复用同一份解析逻辑。
public enum EPUBBookParser {
  public static func parse(
    members: [String: Data],
    fallbackTitle: String,
    deletedTags: AndroidEPUBDeletedTags = []
  ) throws -> EPUBBookDocument {
    guard let containerData = members["META-INF/container.xml"] else {
      throw EPUBBookFailure.missingContainer
    }
    let container = ContainerXMLDelegate()
    guard parseXML(containerData, delegate: container),
      let packagePath = container.packagePath
    else {
      throw EPUBBookFailure.missingPackageDocument
    }
    guard let packageData = members[packagePath] else {
      throw EPUBBookFailure.missingPackageDocument
    }
    let package = PackageXMLDelegate()
    guard parseXML(packageData, delegate: package) else {
      throw EPUBBookFailure.malformedPackageDocument
    }

    let packageDirectory = directory(of: packagePath)
    let navigation = try navigationEntries(
      package: package,
      packageDirectory: packageDirectory,
      members: members
    )
    let ordered = navigation.isEmpty
      ? package.spine.compactMap { id in
          package.manifest[id].map {
            NavigationEntry(
              title: "",
              href: resolve($0.href, relativeTo: packageDirectory)
            )
          }
        }
      : navigation
    guard !ordered.isEmpty else { throw EPUBBookFailure.emptySpine }

    let chapters = try ordered.enumerated().map { index, entry in
      let resourcePath = entry.href
      guard let content = members[resourcePath] else {
        throw EPUBBookFailure.missingContent(resourcePath)
      }
      let extracted = XHTMLTextDelegate.extract(
        content,
        deletedTags: deletedTags
      )
      let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
      let fallback = extracted.title.isEmpty
        ? resourcePath.split(separator: "/").last.map(String.init) ?? "第 \(index + 1) 章"
        : extracted.title
      return LocalTextChapter(
        title: title.isEmpty ? fallback : title,
        content: extracted.body
      )
    }

    return EPUBBookDocument(
      title: package.title.nilIfBlank ?? removingExtension(fallbackTitle),
      author: package.author.nilIfBlank ?? "",
      chapters: chapters
    )
  }

  private static func navigationEntries(
    package: PackageXMLDelegate,
    packageDirectory: String,
    members: [String: Data]
  ) throws -> [NavigationEntry] {
    if let nav = package.manifest.values.first(where: {
      $0.properties.split(separator: " ").contains("nav")
    }) {
      let path = resolve(nav.href, relativeTo: packageDirectory)
      if let data = members[path] {
        let delegate = NavigationXMLDelegate(mode: .xhtml)
        if parseXML(data, delegate: delegate), !delegate.entries.isEmpty {
          let base = directory(of: path)
          return delegate.entries.map {
            NavigationEntry(
              title: $0.title,
              href: resolve($0.href, relativeTo: base)
            )
          }
        }
      }
    }
    if let ncx = package.manifest.values.first(where: {
      $0.mediaType == "application/x-dtbncx+xml"
    }) {
      let path = resolve(ncx.href, relativeTo: packageDirectory)
      if let data = members[path] {
        let delegate = NavigationXMLDelegate(mode: .ncx)
        if parseXML(data, delegate: delegate), !delegate.entries.isEmpty {
          let base = directory(of: path)
          return delegate.entries.map {
            NavigationEntry(
              title: $0.title,
              href: resolve($0.href, relativeTo: base)
            )
          }
        }
      }
    }
    return []
  }

  private static func parseXML(
    _ data: Data,
    delegate: XMLParserDelegate
  ) -> Bool {
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true
    parser.delegate = delegate
    return parser.parse()
  }

  private static func resolve(_ href: String, relativeTo base: String) -> String {
    let raw = href.components(separatedBy: "#")[0]
      .removingPercentEncoding ?? href.components(separatedBy: "#")[0]
    var components = base.split(separator: "/").map(String.init)
    for component in raw.split(separator: "/", omittingEmptySubsequences: true) {
      switch component {
      case ".": continue
      case "..": if !components.isEmpty { components.removeLast() }
      default: components.append(String(component))
      }
    }
    return components.joined(separator: "/")
  }

  private static func directory(of path: String) -> String {
    path.split(separator: "/").dropLast().joined(separator: "/")
  }

  private static func removingExtension(_ value: String) -> String {
    guard let dot = value.lastIndex(of: ".") else { return value }
    return String(value[..<dot])
  }
}

private struct ManifestItem {
  let href: String
  let mediaType: String
  let properties: String
}

private struct NavigationEntry {
  let title: String
  let href: String
}

private final class ContainerXMLDelegate: NSObject, XMLParserDelegate {
  var packagePath: String?

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    if elementName.lowercased() == "rootfile" {
      packagePath = attributeDict["full-path"]
    }
  }
}

private final class PackageXMLDelegate: NSObject, XMLParserDelegate {
  var title = ""
  var author = ""
  var manifest: [String: ManifestItem] = [:]
  var spine: [String] = []
  private var capturedElement: String?
  private var capturedText = ""

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    let attributes = attributeDict
    switch elementName.lowercased() {
    case "title", "creator":
      capturedElement = elementName.lowercased()
      capturedText = ""
    case "item":
      if let id = attributes["id"], let href = attributes["href"] {
        manifest[id] = ManifestItem(
          href: href,
          mediaType: attributes["media-type"] ?? "",
          properties: attributes["properties"] ?? ""
        )
      }
    case "itemref":
      if let id = attributes["idref"] { spine.append(id) }
    default: break
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if capturedElement != nil { capturedText += string }
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    guard capturedElement == elementName.lowercased() else { return }
    let value = capturedText.trimmingCharacters(in: .whitespacesAndNewlines)
    if elementName.lowercased() == "title", title.isEmpty { title = value }
    if elementName.lowercased() == "creator", author.isEmpty { author = value }
    capturedElement = nil
    capturedText = ""
  }
}

private final class NavigationXMLDelegate: NSObject, XMLParserDelegate {
  enum Mode { case xhtml, ncx }

  let mode: Mode
  var entries: [NavigationEntry] = []
  private var href: String?
  private var text = ""
  private var capturesText = false

  init(mode: Mode) { self.mode = mode }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    let attributes = attributeDict
    let element = elementName.lowercased()
    if mode == .xhtml, element == "a", let value = attributes["href"] {
      href = value
      text = ""
      capturesText = true
    } else if mode == .ncx, element == "text" {
      text = ""
      capturesText = true
    } else if mode == .ncx, element == "content" {
      href = attributes["src"]
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if capturesText { text += string }
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let element = elementName.lowercased()
    if mode == .xhtml, element == "a" {
      appendEntryIfReady()
    } else if mode == .ncx, element == "text" {
      capturesText = false
    } else if mode == .ncx, element == "navpoint" {
      appendEntryIfReady()
    }
  }

  private func appendEntryIfReady() {
    defer {
      href = nil
      text = ""
      capturesText = false
    }
    guard let href, !href.isEmpty else { return }
    entries.append(
      NavigationEntry(
        title: text.trimmingCharacters(in: .whitespacesAndNewlines),
        href: href
      )
    )
  }
}

private final class XHTMLTextDelegate: NSObject, XMLParserDelegate {
  struct Result { let title: String; let body: String }

  private var title = ""
  private var body: [String] = []
  private var inTitle = false
  private var inBody = false
  private var ignoredDepth = 0
  private let deletedTags: AndroidEPUBDeletedTags

  init(deletedTags: AndroidEPUBDeletedTags) {
    self.deletedTags = deletedTags
  }

  static func extract(
    _ data: Data,
    deletedTags: AndroidEPUBDeletedTags
  ) -> Result {
    let delegate = XHTMLTextDelegate(deletedTags: deletedTags)
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true
    parser.delegate = delegate
    if !parser.parse() {
      var fallback = String(decoding: data, as: UTF8.self)
      if deletedTags.contains(.rubyAnnotation) {
        fallback = fallback.replacingOccurrences(
          of: #"(?is)<(?:rp|rt)\b[^>]*>.*?</(?:rp|rt)>"#,
          with: "",
          options: .regularExpression
        )
      }
      if deletedTags.contains(.headings) {
        fallback = fallback.replacingOccurrences(
          of: #"(?is)<h[1-6]\b[^>]*>.*?</h[1-6]>"#,
          with: "",
          options: .regularExpression
        )
      }
      fallback = fallback
        .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
      return Result(title: "", body: normalize(fallback))
    }
    return Result(title: normalize(delegate.title), body: normalize(delegate.body.joined()))
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    let element = elementName.lowercased()
    if element == "title" { inTitle = true }
    if element == "body" { inBody = true }
    if inBody, shouldIgnore(element) { ignoredDepth += 1 }
    if inBody, ignoredDepth == 0,
      ["br", "p", "div", "section", "article", "h1", "h2", "h3", "li"]
        .contains(element)
    {
      body.append("\n")
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if inTitle { title += string }
    if inBody, ignoredDepth == 0 { body.append(string) }
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let element = elementName.lowercased()
    if element == "title" { inTitle = false }
    if inBody, shouldIgnore(element) { ignoredDepth -= 1 }
    if element == "body" { inBody = false }
  }

  private func shouldIgnore(_ element: String) -> Bool {
    if element == "script" || element == "style" { return true }
    if deletedTags.contains(.rubyAnnotation), element == "rp" || element == "rt" {
      return true
    }
    if deletedTags.contains(.headings),
      ["h1", "h2", "h3", "h4", "h5", "h6"].contains(element)
    {
      return true
    }
    return false
  }

  private static func normalize(_ value: String) -> String {
    value
      .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "\\n[ \\t]+", with: "\n", options: .regularExpression)
      .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private extension String {
  var nilIfBlank: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
