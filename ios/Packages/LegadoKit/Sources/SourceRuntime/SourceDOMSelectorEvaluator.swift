import Foundation

public enum SourceDOMSelectorError: Error, Sendable, Equatable {
  case malformedCSS(String)
  case malformedXPath(String)
  case malformedDocument
  case missingRedirectURL
  case unsupportedRule(String)
}

public enum SourceDOMNodeKind: String, Sendable, Equatable {
  case xpathElement = "xpath_element"
  case xpathValue = "xpath_value"
}

/// A library-neutral projection of a DOM result. Parser implementation types
/// never cross the SourceRuntime boundary.
public struct SourceDOMNodeProjection: Sendable, Equatable {
  public let kind: SourceDOMNodeKind
  public let asString: String
  public let rendered: String
  public let tag: String?

  public init(
    kind: SourceDOMNodeKind,
    asString: String,
    rendered: String,
    tag: String?
  ) {
    self.kind = kind
    self.asString = asString
    self.rendered = rendered
    self.tag = tag
  }
}

/// Bounded Android-Legado compatibility kernel for DOM-backed source rules.
///
/// The supported surface is intentionally defined by published Android
/// Goldens. Unsupported selector syntax fails explicitly instead of silently
/// claiming parity with a full CSS or XPath implementation.
public struct SourceDOMSelectorEvaluator: Sendable {
  public let content: String

  public init(content: String) {
    self.content = content
  }

  public func getString(
    _ rule: String,
    isURL: Bool = false,
    redirectURL: URL? = nil
  ) throws -> String {
    let values = try stringValues(rule)
    guard isURL else { return values.joined(separator: "\n") }
    guard let redirectURL else {
      throw SourceDOMSelectorError.missingRedirectURL
    }
    guard let first = values.first else {
      return redirectURL.absoluteString
    }
    return try resolve(first, relativeTo: redirectURL)
  }

  public func getStringList(
    _ rule: String,
    isURL: Bool = false,
    redirectURL: URL? = nil
  ) throws -> [String] {
    let values = try stringValues(rule).filter { !$0.isEmpty }
    guard isURL else { return values }
    guard let redirectURL else {
      throw SourceDOMSelectorError.missingRedirectURL
    }
    return stableUnique(
      try values.map { try resolve($0, relativeTo: redirectURL) }
    )
  }

  public func getString(
    _ rule: String,
    isURL: Bool,
    urlContext: SourceRuleURLContext
  ) throws -> String {
    let value = try stringValues(rule).first ?? ""
    return isURL ? urlContext.absoluteString(value) : value
  }

  public func getStringList(
    _ rule: String,
    isURL: Bool,
    urlContext: SourceRuleURLContext
  ) throws -> [String] {
    let values = try stringValues(rule).filter { !$0.isEmpty }
    return isURL ? urlContext.absoluteList(values) : values
  }

  public func getElements(_ rule: String) throws -> [SourceDOMNodeProjection] {
    switch backend(for: rule) {
    case .css(let normalized):
      let document = try DOMDocument(html: content)
      let nodes = try cssNodes(normalized, document: document)
      return nodes.map {
        SourceDOMNodeProjection(
          kind: .xpathElement,
          asString: $0.compactOuterHTML,
          rendered: $0.compactOuterHTML,
          tag: $0.name
        )
      }
    case .xpath(let normalized):
      return try xpathValues(normalized).map(\.projection)
    }
  }

  private enum Backend {
    case css(String)
    case xpath(String)
  }

  private enum XPathValue {
    case element(DOMNode)
    case text(String)
    case attribute(String)

    var string: String {
      switch self {
      case .element(let node):
        node.compactOuterHTML
      case .text(let value), .attribute(let value):
        value
      }
    }

    var projection: SourceDOMNodeProjection {
      switch self {
      case .element(let node):
        SourceDOMNodeProjection(
          kind: .xpathElement,
          asString: node.compactOuterHTML,
          rendered: node.compactOuterHTML,
          tag: node.name
        )
      case .text(let value):
        SourceDOMNodeProjection(
          kind: .xpathElement,
          asString: value,
          rendered: value,
          tag: "JX_TEXT"
        )
      case .attribute(let value):
        SourceDOMNodeProjection(
          kind: .xpathValue,
          asString: value,
          rendered: value,
          tag: nil
        )
      }
    }
  }

  private enum CSSCombination: String, CaseIterable {
    case concatenate = "&&"
    case fallback = "||"
    case interleave = "%%"
  }

  private func stringValues(_ rule: String) throws -> [String] {
    switch backend(for: rule) {
    case .css(let normalized):
      return try cssStringValues(normalized)
    case .xpath(let normalized):
      return try xpathValues(normalized).map(\.string)
    }
  }

  private func backend(for rule: String) -> Backend {
    if rule.lowercased().hasPrefix("@xpath:") {
      return .xpath(String(rule.dropFirst(7)))
    }
    if rule.hasPrefix("//") {
      return .xpath(rule)
    }
    if rule.lowercased().hasPrefix("@css:") {
      return .css(String(rule.dropFirst(5)))
    }
    return .css(rule)
  }

  private func cssStringValues(_ rule: String) throws -> [String] {
    let document = try DOMDocument(html: content)
    for operation in CSSCombination.allCases
    where rule.contains(operation.rawValue) {
      let components = rule.components(separatedBy: operation.rawValue)
      guard components.count > 1 else { continue }
      let groups = try components.map {
        try cssSingleStringValues($0, document: document)
      }
      switch operation {
      case .concatenate:
        return stableUnique(groups.flatMap { $0 })
      case .fallback:
        return groups.first(where: { !$0.isEmpty }) ?? []
      case .interleave:
        let count = groups.map(\.count).max() ?? 0
        return stableUnique(
          (0..<count).flatMap { index in
            groups.compactMap {
              $0.indices.contains(index) ? $0[index] : nil
            }
          }
        )
      }
    }
    return try cssSingleStringValues(rule, document: document)
  }

  private func cssSingleStringValues(
    _ rule: String,
    document: DOMDocument
  ) throws -> [String] {
    let parts = rule.split(separator: "@", omittingEmptySubsequences: false)
      .map(String.init)
    guard let selector = parts.first, !selector.isEmpty else {
      throw SourceDOMSelectorError.unsupportedRule(rule)
    }
    var nodes = try document.select(selector)
    var terminal: String?
    for step in parts.dropFirst() {
      if step.hasPrefix("children.") {
        let token = String(step.dropFirst("children.".count))
        nodes = try applyIndexes(token, to: nodes.flatMap(\.elementChildren))
      } else if step.hasPrefix("tag.") {
        let raw = String(step.dropFirst("tag.".count))
        let parsed = try selectorAndIndexes(raw)
        nodes = try nodes.flatMap {
          try document.select(parsed.selector, within: $0)
        }
        if let indexes = parsed.indexes {
          nodes = try applyIndexes(indexes, to: nodes)
        }
      } else {
        terminal = step
      }
    }
    let values: [String]
    switch terminal?.lowercased() {
    case nil:
      values = nodes.map(\.compactOuterHTML)
    case "text":
      values = nodes.map(\.normalizedText)
    case "owntext":
      values = nodes.map(\.normalizedOwnText)
    case "textnodes":
      values = nodes.map(\.normalizedTextNodes)
    case "html":
      values = nodes.map { $0.prettyOuterHTML(removingScriptAndStyle: true) }
    case "all":
      values = nodes.map { $0.prettyOuterHTML(removingScriptAndStyle: false) }
    case let attribute?:
      values = nodes.compactMap { $0.attributes[attribute] }
    }
    return stableUnique(values)
  }

  private func cssNodes(
    _ rule: String,
    document: DOMDocument
  ) throws -> [DOMNode] {
    guard
      !rule.contains("&&"),
      !rule.contains("||"),
      !rule.contains("%%")
    else {
      throw SourceDOMSelectorError.unsupportedRule(rule)
    }
    let parts = rule.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 1 else {
      throw SourceDOMSelectorError.unsupportedRule(rule)
    }
    return try document.select(rule)
  }

  private func selectorAndIndexes(
    _ raw: String
  ) throws -> (selector: String, indexes: String?) {
    guard let opening = raw.lastIndex(of: "[") else {
      return (raw, nil)
    }
    guard raw.last == "]", opening < raw.index(before: raw.endIndex) else {
      throw SourceDOMSelectorError.malformedCSS(raw)
    }
    return (
      String(raw[..<opening]),
      String(raw[raw.index(after: opening)..<raw.index(before: raw.endIndex)])
    )
  }

  private func applyIndexes(
    _ expression: String,
    to nodes: [DOMNode]
  ) throws -> [DOMNode] {
    if expression.contains(":") {
      let tokens = expression.split(
        separator: ":",
        omittingEmptySubsequences: false
      )
      guard (2...3).contains(tokens.count) else {
        throw SourceDOMSelectorError.malformedCSS(expression)
      }
      guard
        let rawStart = Int(tokens[0]),
        let rawEnd = Int(tokens[1])
      else {
        throw SourceDOMSelectorError.malformedCSS(expression)
      }
      let start = normalizedIndex(rawStart, count: nodes.count)
      let end = normalizedIndex(rawEnd, count: nodes.count)
      guard let start, let end else { return [] }
      let step = tokens.count == 3 ? Int(tokens[2]) : nil
      let stride = step ?? (start <= end ? 1 : -1)
      guard stride != 0 else {
        throw SourceDOMSelectorError.malformedCSS(expression)
      }
      var output: [DOMNode] = []
      var index = start
      if stride > 0 {
        while index <= end {
          output.append(nodes[index])
          index += stride
        }
      } else {
        while index >= end {
          output.append(nodes[index])
          index += stride
        }
      }
      return output
    }
    if expression.hasPrefix("!") {
      let excluded = Set(
        try expression.dropFirst().split(separator: ",").map {
          guard let value = Int($0) else {
            throw SourceDOMSelectorError.malformedCSS(expression)
          }
          return normalizedIndex(value, count: nodes.count)
        }.compactMap { $0 }
      )
      return nodes.enumerated().compactMap {
        excluded.contains($0.offset) ? nil : $0.element
      }
    }
    let indexes = try expression.split(separator: ",").map { token -> Int in
      guard let value = Int(token) else {
        throw SourceDOMSelectorError.malformedCSS(expression)
      }
      return value
    }
    return indexes.compactMap {
      guard let index = normalizedIndex($0, count: nodes.count) else {
        return nil
      }
      return nodes[index]
    }
  }

  private func normalizedIndex(_ index: Int, count: Int) -> Int? {
    let normalized = index < 0 ? count + index : index
    return (0..<count).contains(normalized) ? normalized : nil
  }

  private func xpathValues(_ rule: String) throws -> [XPathValue] {
    if rule.contains(":") {
      return []
    }
    guard
      !rule.contains("["),
      rule.hasPrefix("//")
    else {
      throw SourceDOMSelectorError.malformedXPath(rule)
    }
    let pattern =
      #"^//([A-Za-z][A-Za-z0-9_-]*)(?:/(text\(\)|@([A-Za-z_:][A-Za-z0-9_:\-]*)))?$"#
    guard
      let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(
        in: rule,
        range: NSRange(rule.startIndex..., in: rule)
      ),
      match.range == NSRange(rule.startIndex..., in: rule),
      let tagRange = Range(match.range(at: 1), in: rule)
    else {
      throw SourceDOMSelectorError.malformedXPath(rule)
    }
    let document = try DOMDocument(html: content)
    let nodes = try document.select(String(rule[tagRange]))
    if match.range(at: 2).location == NSNotFound {
      return nodes.map(XPathValue.element)
    }
    if let attributeRange = Range(match.range(at: 3), in: rule) {
      let attribute = String(rule[attributeRange])
      return nodes.compactMap {
        $0.attributes[attribute].map(XPathValue.attribute)
      }
    }
    return nodes.flatMap { node in
      node.directTextFragments.compactMap {
        let normalized = normalizeWhitespace($0)
        return normalized.isEmpty ? nil : .text(normalized)
      }
    }
  }

  private func resolve(_ value: String, relativeTo base: URL) throws -> String {
    guard
      !value.isEmpty,
      let url = URL(string: value, relativeTo: base)?.absoluteURL
    else {
      return base.absoluteString
    }
    return url.absoluteString
  }

  private func stableUnique<T: Hashable>(_ values: [T]) -> [T] {
    var seen: Set<T> = []
    return values.filter { seen.insert($0).inserted }
  }
}

private enum DOMContent {
  case text(String)
  case element(DOMNode)
}

private final class DOMNode {
  let name: String
  let attributes: [String: String]
  var contents: [DOMContent] = []

  init(name: String, attributes: [String: String]) {
    self.name = name.lowercased()
    self.attributes = Dictionary(
      uniqueKeysWithValues: attributes.map {
        ($0.key.lowercased(), $0.value)
      }
    )
  }

  var elementChildren: [DOMNode] {
    contents.compactMap {
      guard case .element(let child) = $0 else { return nil }
      return child
    }
  }

  var directTextFragments: [String] {
    contents.compactMap {
      guard case .text(let value) = $0 else { return nil }
      return value
    }
  }

  var normalizedOwnText: String {
    directTextFragments.map(normalizeWhitespace)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  var normalizedTextNodes: String {
    directTextFragments.map(normalizeWhitespace)
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
  }

  var normalizedText: String {
    guard name != "script", name != "style" else { return "" }
    return contents.flatMap { content -> [String] in
      switch content {
      case .text(let value):
        return [normalizeWhitespace(value)]
      case .element(let child):
        return [child.normalizedText]
      }
    }.filter { !$0.isEmpty }.joined(separator: " ")
  }

  var compactOuterHTML: String {
    let body = contents.map { content -> String in
      switch content {
      case .text(let value):
        return escapeText(value)
      case .element(let child):
        return child.compactOuterHTML
      }
    }.joined()
    return "<\(name)\(renderedAttributes)>\(body)</\(name)>"
  }

  func prettyOuterHTML(removingScriptAndStyle: Bool) -> String {
    var lines: [String] = []
    var current = ""
    for content in contents {
      switch content {
      case .text(let value):
        current += escapeText(value)
      case .element(let child):
        if removingScriptAndStyle,
          child.name == "script" || child.name == "style"
        {
          continue
        }
        if child.name == "script" || child.name == "style" {
          if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(
              current.trimmingCharacters(in: .whitespacesAndNewlines)
            )
          }
          current = child.compactOuterHTML
        } else {
          current += child.compactOuterHTML
        }
      }
    }
    if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      lines.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    let body = lines.map { " " + $0 }.joined(separator: "\n")
    return "<\(name)\(renderedAttributes)>\n\(body)\n</\(name)>"
  }

  private var renderedAttributes: String {
    attributes.keys.sorted().map {
      " \($0)=\"\(escapeAttribute(attributes[$0, default: ""]))\""
    }.joined()
  }
}

private struct DOMDocument {
  let root: DOMNode

  init(html: String) throws {
    let builder = DOMTreeBuilder()
    let parser = XMLParser(data: Data(Self.sanitize(html).utf8))
    parser.delegate = builder
    parser.shouldResolveExternalEntities = false
    guard parser.parse(), let root = builder.root else {
      throw SourceDOMSelectorError.malformedDocument
    }
    self.root = root
  }

  func select(_ selector: String, within node: DOMNode? = nil) throws -> [DOMNode] {
    guard
      !selector.isEmpty,
      !selector.contains("["),
      !selector.contains("]"),
      !selector.contains(" "),
      !selector.contains(">")
    else {
      throw SourceDOMSelectorError.malformedCSS(selector)
    }
    let base = node ?? root
    return descendants(of: base).filter { matches($0, selector: selector) }
  }

  private func descendants(of node: DOMNode) -> [DOMNode] {
    [node] + node.elementChildren.flatMap(descendants)
  }

  private func matches(_ node: DOMNode, selector: String) -> Bool {
    var tag = ""
    var identifier: String?
    var requiredClass: String?
    var buffer = ""
    var mode: Character = "t"
    func commit() {
      guard !buffer.isEmpty else { return }
      switch mode {
      case "#": identifier = buffer
      case ".": requiredClass = buffer
      default: tag = buffer
      }
      buffer = ""
    }
    for character in selector {
      if character == "#" || character == "." {
        commit()
        mode = character
      } else {
        buffer.append(character)
      }
    }
    commit()
    let classes = Set(
      node.attributes["class", default: ""].split(whereSeparator: \.isWhitespace)
        .map(String.init)
    )
    return (tag.isEmpty || node.name == tag.lowercased())
      && (identifier == nil || node.attributes["id"] == identifier)
      && (requiredClass == nil || classes.contains(requiredClass!))
  }

  private static func sanitize(_ html: String) -> String {
    var value = html.replacingOccurrences(
      of: #"<!doctype[^>]*>"#,
      with: "",
      options: [.regularExpression, .caseInsensitive]
    )
    value = value.replacingOccurrences(
      of: #"<li([^>]*)>([^<]*)(?=<li(?:\s|>)|</(?:ul|ol)>)"#,
      with: #"<li$1>$2</li>"#,
      options: [.regularExpression, .caseInsensitive]
    )
    for tag in ["meta", "img", "input", "br", "hr", "link"] {
      value = value.replacingOccurrences(
        of: #"<\#(tag)\b([^>]*?)(?<!/)>"#,
        with: #"<\#(tag)$1/>"#,
        options: [.regularExpression, .caseInsensitive]
      )
    }
    return value
  }
}

private final class DOMTreeBuilder: NSObject, XMLParserDelegate {
  var stack: [DOMNode] = []
  var root: DOMNode?

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    let node = DOMNode(name: qName ?? elementName, attributes: attributeDict)
    stack.last?.contents.append(.element(node))
    stack.append(node)
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard let node = stack.last else { return }
    if case .text(let previous)? = node.contents.last {
      node.contents[node.contents.count - 1] = .text(previous + string)
    } else {
      node.contents.append(.text(string))
    }
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    guard let node = stack.popLast() else { return }
    if stack.isEmpty {
      root = node
    }
  }
}

private func normalizeWhitespace(_ value: String) -> String {
  value.replacingOccurrences(
    of: #"\s+"#,
    with: " ",
    options: .regularExpression
  ).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func escapeText(_ value: String) -> String {
  value.replacingOccurrences(of: "&", with: "&amp;")
    .replacingOccurrences(of: "<", with: "&lt;")
    .replacingOccurrences(of: ">", with: "&gt;")
}

private func escapeAttribute(_ value: String) -> String {
  escapeText(value).replacingOccurrences(of: "\"", with: "&quot;")
}
