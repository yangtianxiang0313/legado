@preconcurrency import SwiftSoup
import RuleRuntime

public enum SwiftSoupHTMLSelectorError: Error, Equatable, Sendable {
    case selectionFailed(selector: String)
}

public struct SwiftSoupHTMLSelectorBackend: HTMLSelectorBackend, Sendable {
    public init() {}

    public func select(
        html: String,
        selector: String
    ) throws -> [HTMLSelectionProjection] {
        do {
            let document = try SwiftSoup.parse(html)
            return try document.select(selector).array().map(project)
        } catch {
            throw SwiftSoupHTMLSelectorError.selectionFailed(selector: selector)
        }
    }

    private func project(_ element: Element) throws -> HTMLSelectionProjection {
        let attributes = (element.getAttributes()?.asList() ?? []).reduce(
            into: [String: String]()
        ) { result, attribute in
            result[attribute.getKey()] = attribute.getValue()
        }

        return HTMLSelectionProjection(
            tag: element.tagName(),
            text: try element.text(),
            ownText: element.ownText(),
            outerHTML: try element.outerHtml(),
            attributes: attributes
        )
    }
}
