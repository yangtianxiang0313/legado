@preconcurrency import SwiftSoup
import Foundation
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
        let filtered = element.copy() as! Element
        try filtered.select("script, style").remove()

        return HTMLSelectionProjection(
            tag: element.tagName(),
            text: jsoupCompatibleText(element),
            ownText: element.ownText(),
            textNodes: element.textNodes().compactMap {
                let value = $0.text().trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                return value.isEmpty ? nil : value
            },
            outerHTML: jsoupCompatibleOuterHTML(
                try element.outerHtml()
            ),
            outerHTMLWithoutScriptAndStyle: jsoupCompatibleOuterHTML(
                try filtered.outerHtml()
            ),
            attributes: attributes,
            children: try element.children().array().map(project)
        )
    }

    private func jsoupCompatibleText(_ element: Element) -> String {
        var fragments: [String] = []
        appendText(of: element, to: &fragments)
        return fragments.joined()
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appendText(
        of element: Element,
        to fragments: inout [String]
    ) {
        for index in 0..<element.childNodeSize() {
            let node = element.childNode(index)
            if let textNode = node as? TextNode {
                fragments.append(textNode.text())
                continue
            }
            guard let child = node as? Element else { continue }
            let separatesText = child.isBlock()
                || child.tagName().lowercased() == "br"
            if separatesText {
                fragments.append(" ")
            }
            appendText(of: child, to: &fragments)
            if separatesText {
                fragments.append(" ")
            }
        }
    }

    private func jsoupCompatibleOuterHTML(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"[ \t]*\n[ \t]*(?=<(?:a|b|em|i|span|strong|u)\b)"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
    }
}
