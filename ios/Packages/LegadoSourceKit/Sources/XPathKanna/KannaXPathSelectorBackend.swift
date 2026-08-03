import Foundation
import Kanna
import RuleRuntime

public enum KannaXPathSelectorError: Error, Equatable, Sendable {
  case malformedDocument
}

public struct KannaXPathSelectorBackend: XPathSelectorBackend, Sendable {
  public init() {}

  public func select(
    html: String,
    expression: String
  ) throws -> [XPathSelectionProjection] {
    let document: any HTMLDocument
    do {
      document = try HTML(html: html, encoding: .utf8)
    } catch {
      throw KannaXPathSelectorError.malformedDocument
    }

    let result = document.xpath(expression)
    switch result {
    case .none:
      return []
    case .Bool(let value):
      return [scalar(value ? "true" : "false")]
    case .Number(let value):
      return [scalar(Self.renderNumber(value))]
    case .String(let value):
      return [scalar(value)]
    case .NodeSet:
      return result.map { node in
        let value = node.text ?? node.content ?? ""
        if Self.isTextExpression(expression) {
          return XPathSelectionProjection(
            kind: .text,
            stringValue: value,
            rendered: value,
            tag: "JX_TEXT"
          )
        }
        if Self.isAttributeExpression(expression) {
          return XPathSelectionProjection(
            kind: .attribute,
            stringValue: value,
            rendered: value,
            tag: nil
          )
        }
        let rendered = node.toHTML ?? value
        return XPathSelectionProjection(
          kind: .element,
          stringValue: rendered,
          rendered: rendered,
          tag: node.tagName
        )
      }
    }
  }

  private static func isTextExpression(_ expression: String) -> Bool {
    expression.trimmingCharacters(in: .whitespacesAndNewlines)
      .hasSuffix("text()")
  }

  private static func isAttributeExpression(_ expression: String) -> Bool {
    expression.range(
      of: #"/@[A-Za-z_:][A-Za-z0-9_:\-]*\s*$"#,
      options: .regularExpression
    ) != nil
  }

  private static func renderNumber(_ value: Double) -> String {
    value.rounded() == value ? String(Int64(value)) : String(value)
  }

  private func scalar(_ value: String) -> XPathSelectionProjection {
    XPathSelectionProjection(
      kind: .scalar,
      stringValue: value,
      rendered: value,
      tag: nil
    )
  }
}
