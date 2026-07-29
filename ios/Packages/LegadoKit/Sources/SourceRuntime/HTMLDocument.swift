import Foundation

public struct HTMLNode: Sendable, Equatable {
  public let name: String
  public let attributes: [String: String]
  public let text: String
  public let children: [HTMLNode]

  public init(
    name: String,
    attributes: [String: String] = [:],
    text: String = "",
    children: [HTMLNode] = []
  ) {
    self.name = name
    self.attributes = attributes
    self.text = text
    self.children = children
  }

  public var normalizedText: String {
    text
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

public enum HTMLDocumentError: Error, Sendable, Equatable {
  case malformedHTML
  case unsupportedSelector(String)
}

public struct HTMLDocument: Sendable {
  public let root: HTMLNode

  public init(html: String) throws {
    let sanitized = Self.sanitize(html)
    let delegate = TreeBuilder()
    let parser = XMLParser(data: Data(sanitized.utf8))
    parser.delegate = delegate
    parser.shouldResolveExternalEntities = false
    guard parser.parse(), let root = delegate.root else {
      throw HTMLDocumentError.malformedHTML
    }
    self.root = root
  }

  public func select(_ selector: String, within node: HTMLNode? = nil) throws -> [HTMLNode] {
    let steps = try Self.selectorSteps(selector)
    let base = node ?? root
    var matches = Self.descendants(of: base).filter {
      Self.matches($0, steps[0].selector)
    }
    for step in steps.dropFirst() {
      let candidates: [HTMLNode]
      switch step.combinator {
      case .descendant:
        candidates = matches.flatMap {
          $0.children.flatMap(Self.descendants)
        }
      case .child:
        candidates = matches.flatMap(\.children)
      }
      matches = candidates.filter { Self.matches($0, step.selector) }
    }
    return matches
  }

  private enum SelectorCombinator {
    case descendant
    case child
  }

  private struct SelectorStep {
    let combinator: SelectorCombinator
    let selector: String
  }

  private static func selectorSteps(_ selector: String) throws -> [SelectorStep] {
    let normalized = selector.replacingOccurrences(
      of: #"\s*>\s*"#,
      with: " > ",
      options: .regularExpression
    )
    let tokens = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
    guard let first = tokens.first, first != ">" else {
      throw HTMLDocumentError.unsupportedSelector(selector)
    }
    var steps = [
      SelectorStep(combinator: .descendant, selector: first)
    ]
    var combinator = SelectorCombinator.descendant
    var expectsSelector = false
    for token in tokens.dropFirst() {
      if token == ">" {
        guard !expectsSelector else {
          throw HTMLDocumentError.unsupportedSelector(selector)
        }
        combinator = .child
        expectsSelector = true
      } else {
        steps.append(
          SelectorStep(combinator: combinator, selector: token)
        )
        combinator = .descendant
        expectsSelector = false
      }
    }
    guard !expectsSelector else {
      throw HTMLDocumentError.unsupportedSelector(selector)
    }
    return steps
  }

  private static func sanitize(_ html: String) -> String {
    var value = html.replacingOccurrences(
      of: #"<!doctype[^>]*>"#,
      with: "",
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

  private static func descendants(of node: HTMLNode) -> [HTMLNode] {
    [node] + node.children.flatMap(descendants)
  }

  private static func matches(_ node: HTMLNode, _ selector: String) -> Bool {
    var remainder = selector
    var requiredID: String?
    var requiredClass: String?
    if let index = remainder.firstIndex(of: "#") {
      requiredID = String(remainder[remainder.index(after: index)...])
      remainder = String(remainder[..<index])
    }
    if let index = remainder.firstIndex(of: ".") {
      requiredClass = String(remainder[remainder.index(after: index)...])
      remainder = String(remainder[..<index])
    } else if remainder.hasPrefix(".") {
      requiredClass = String(remainder.dropFirst())
      remainder = ""
    }
    if selector.hasPrefix("#") {
      requiredID = String(selector.dropFirst())
      remainder = ""
    } else if selector.hasPrefix(".") {
      requiredClass = String(selector.dropFirst())
      remainder = ""
    }
    let tagMatches = remainder.isEmpty || node.name == remainder.lowercased()
    let idMatches = requiredID == nil || node.attributes["id"] == requiredID
    let classes = Set(node.attributes["class", default: ""].split(separator: " ").map(String.init))
    let classMatches = requiredClass == nil || classes.contains(requiredClass!)
    return tagMatches && idMatches && classMatches
  }
}

private final class MutableNode {
  let name: String
  let attributes: [String: String]
  var text = ""
  var children: [MutableNode] = []

  init(name: String, attributes: [String: String]) {
    self.name = name
    self.attributes = attributes
  }

  func freeze() -> HTMLNode {
    HTMLNode(
      name: name,
      attributes: attributes,
      text: text,
      children: children.map { $0.freeze() }
    )
  }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
  var stack: [MutableNode] = []
  var root: HTMLNode?

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    let node = MutableNode(name: elementName.lowercased(), attributes: attributeDict)
    stack.last?.children.append(node)
    stack.append(node)
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    stack.last?.text += string
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    guard let node = stack.popLast() else { return }
    if let parent = stack.last {
      parent.text += node.text
    } else {
      root = node.freeze()
    }
  }
}
