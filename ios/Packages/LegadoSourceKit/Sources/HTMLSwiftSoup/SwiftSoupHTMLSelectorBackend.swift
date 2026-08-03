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
            return try document.select(
                jsoupCompatibleSelector(selector)
            ).array().map(project)
        } catch {
            throw SwiftSoupHTMLSelectorError.selectionFailed(selector: selector)
        }
    }

    /// Jsoup accepts unquoted attribute values such as `[title^=論語/]`, while
    /// SwiftSoup rejects the slash. Legado sources rely on Jsoup's tolerant form.
    private func jsoupCompatibleSelector(_ selector: String) -> String {
        var result = ""
        var cursor = selector.startIndex

        while let opening = selector[cursor...].firstIndex(of: "[") {
            result += selector[cursor..<opening]
            guard let closing = selector[opening...].firstIndex(of: "]") else {
                result += selector[opening...]
                return result
            }

            let bodyStart = selector.index(after: opening)
            let body = String(selector[bodyStart..<closing])
            result += "[" + normalizedAttributeBody(body) + "]"
            cursor = selector.index(after: closing)
        }

        result += selector[cursor...]
        return result
    }

    private func normalizedAttributeBody(_ body: String) -> String {
        let operators = ["^=", "$=", "*=", "~=", "|=", "="]
        guard let match = operators.compactMap({ operation -> (String, Range<String.Index>)? in
            body.range(of: operation).map { (operation, $0) }
        }).min(by: { $0.1.lowerBound < $1.1.lowerBound }) else {
            return body
        }

        let operand = body[match.1.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !operand.isEmpty,
              operand.first != "\"",
              operand.first != "'"
        else {
            return body
        }

        let prefix = body[..<match.1.upperBound]
        let escaped = operand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\(prefix)\"\(escaped)\""
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
