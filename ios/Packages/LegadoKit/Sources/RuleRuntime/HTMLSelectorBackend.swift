public struct HTMLSelectionProjection: Equatable, Sendable {
  public let tag: String
  public let text: String
  public let ownText: String
  public let outerHTML: String
  public let attributes: [String: String]

  public init(
    tag: String,
    text: String,
    ownText: String,
    outerHTML: String,
    attributes: [String: String]
  ) {
    self.tag = tag
    self.text = text
    self.ownText = ownText
    self.outerHTML = outerHTML
    self.attributes = attributes
  }
}

public protocol HTMLSelectorBackend: Sendable {
  func select(
    html: String,
    selector: String
  ) throws -> [HTMLSelectionProjection]
}
