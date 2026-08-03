import HTMLSwiftSoup
import RuleRuntime
import XPathKanna

public enum SourceRuntimeComposition {
    public static func makeHTMLSelectorBackend()
        -> any HTMLSelectorBackend & XPathSelectorBackend
    {
        CompositeDOMSelectorBackend()
    }
}

private struct CompositeDOMSelectorBackend:
    HTMLSelectorBackend, XPathSelectorBackend
{
    private let html = SwiftSoupHTMLSelectorBackend()
    private let xpath = KannaXPathSelectorBackend()

    func select(
        html: String,
        selector: String
    ) throws -> [HTMLSelectionProjection] {
        try self.html.select(html: html, selector: selector)
    }

    func select(
        html: String,
        expression: String
    ) throws -> [XPathSelectionProjection] {
        try xpath.select(html: html, expression: expression)
    }
}
