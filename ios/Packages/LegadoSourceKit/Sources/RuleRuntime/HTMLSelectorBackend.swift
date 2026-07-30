public struct HTMLSelectionProjection: Equatable, Sendable {
  public let tag: String
  public let text: String
  public let ownText: String
  public let textNodes: [String]
  public let outerHTML: String
  public let outerHTMLWithoutScriptAndStyle: String
  public let attributes: [String: String]
  public let children: [HTMLSelectionProjection]

  public init(
    tag: String,
    text: String,
    ownText: String,
    textNodes: [String] = [],
    outerHTML: String,
    outerHTMLWithoutScriptAndStyle: String? = nil,
    attributes: [String: String],
    children: [HTMLSelectionProjection] = []
  ) {
    self.tag = tag
    self.text = text
    self.ownText = ownText
    self.textNodes = textNodes
    self.outerHTML = outerHTML
    self.outerHTMLWithoutScriptAndStyle =
      outerHTMLWithoutScriptAndStyle ?? outerHTML
    self.attributes = attributes
    self.children = children
  }
}

public protocol HTMLSelectorBackend: Sendable {
  func select(
    html: String,
    selector: String
  ) throws -> [HTMLSelectionProjection]
}
