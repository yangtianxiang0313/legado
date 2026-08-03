public enum XPathSelectionKind: String, Sendable, Equatable {
  case element
  case text
  case attribute
  case scalar
}

public struct XPathSelectionProjection: Sendable, Equatable {
  public let kind: XPathSelectionKind
  public let stringValue: String
  public let rendered: String
  public let tag: String?

  public init(
    kind: XPathSelectionKind,
    stringValue: String,
    rendered: String,
    tag: String?
  ) {
    self.kind = kind
    self.stringValue = stringValue
    self.rendered = rendered
    self.tag = tag
  }
}

public protocol XPathSelectorBackend: Sendable {
  func select(
    html: String,
    expression: String
  ) throws -> [XPathSelectionProjection]
}
