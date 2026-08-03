import RuleRuntime
import Testing
import XPathKanna

@Suite("XPathKannaAdapterTests")
struct XPathKannaAdapterTests {
  private let backend = KannaXPathSelectorBackend()

  @Test func projectsElementsTextAndAttributesWithoutKannaTypes() throws {
    let html = """
      <html><body><ul>
        <li data-id="a">Alpha</li><li data-id="b">Beta</li>
      </ul></body></html>
      """

    let elements = try backend.select(
      html: html,
      expression: "//li[@data-id='b']"
    )
    #expect(elements.map(\.kind) == [.element])
    #expect(elements[0].rendered.contains("Beta"))
    #expect(elements[0].tag == "li")

    let text = try backend.select(html: html, expression: "//li/text()")
    #expect(text.map(\.stringValue) == ["Alpha", "Beta"])
    #expect(text.allSatisfy { $0.kind == .text && $0.tag == "JX_TEXT" })

    let attributes = try backend.select(
      html: html,
      expression: "//li/@data-id"
    )
    #expect(attributes.map(\.stringValue) == ["a", "b"])
    #expect(attributes.allSatisfy { $0.kind == .attribute && $0.tag == nil })
  }

  @Test func projectsScalarResultsAndMissingNodes() throws {
    let html = "<html><body><p>one</p><p>two</p></body></html>"
    let count = try backend.select(html: html, expression: "count(//p)")
    #expect(count == [
      XPathSelectionProjection(
        kind: .scalar,
        stringValue: "2",
        rendered: "2",
        tag: nil
      )
    ])
    #expect(try backend.select(html: html, expression: "//missing").isEmpty)
  }
}
