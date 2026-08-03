import HTMLSwiftSoup
import RuleRuntime
import XCTest

final class HTMLSwiftSoupTests: XCTestCase {
    func testComplexCSSSelectionRepairsBrowserTolerantHTML() throws {
        let html = """
            <html><body>
              <ul class="books">
                <li data-kind="novel"><a class="title" href="/book/1">第一本 <em>书</em></a>
                <li class="hidden" data-kind="novel"><a class="title" href="/book/2">隐藏</a>
                <li data-kind="comic"><a class="title" href="/book/3">漫画</a>
              </ul>
            </body></html>
            """

        let result = try SwiftSoupHTMLSelectorBackend().select(
            html: html,
            selector: "ul.books > li[data-kind='novel']:not(.hidden) a.title"
        )

        XCTAssertEqual(
            result,
            [
                HTMLSelectionProjection(
                    tag: "a",
                    text: "第一本 书",
                    ownText: "第一本",
                    textNodes: ["第一本"],
                    outerHTML: "<a class=\"title\" href=\"/book/1\">第一本 <em>书</em></a>",
                    attributes: [
                        "class": "title",
                        "href": "/book/1",
                    ],
                    children: [
                        HTMLSelectionProjection(
                            tag: "em",
                            text: "书",
                            ownText: "书",
                            textNodes: ["书"],
                            outerHTML: "<em>书</em>",
                            attributes: [:]
                        )
                    ]
                )
            ]
        )
    }

    func testInvalidSelectorDoesNotLeakSwiftSoupError() {
        XCTAssertThrowsError(
            try SwiftSoupHTMLSelectorBackend().select(
                html: "<p>内容</p>",
                selector: "p["
            )
        ) { error in
            XCTAssertEqual(
                error as? SwiftSoupHTMLSelectorError,
                .selectionFailed(selector: "p[")
            )
        }
    }

    func testJsoupCompatibleUnquotedUnicodeAttributeOperand() throws {
        let result = try SwiftSoupHTMLSelectorBackend().select(
            html: """
                <a title="論語/學而第一" href="/wiki/論語/學而第一">學而第一</a>
                <a title="孟子/梁惠王上" href="/wiki/孟子/梁惠王上">梁惠王上</a>
                """,
            selector: "a[title^=論語/]"
        )

        XCTAssertEqual(result.map(\.text), ["學而第一"])
    }
}
