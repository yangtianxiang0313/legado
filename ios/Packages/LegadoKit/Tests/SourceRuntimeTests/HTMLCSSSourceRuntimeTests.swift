import Foundation
import XCTest

@testable import SourceRuntime

final class HTMLCSSSourceRuntimeTests: XCTestCase {
  private let origin = URL(string: "http://sourcelab.test")!

  func testRequestPlanUsesGETAbsoluteURLsAndEncodedSearchTerms() throws {
    let runtime = makeRuntime()
    let search = try runtime.searchRequest(keyword: "星河 & 回声")
    let detail = try runtime.request(
      for: URL(string: "/books/star-river/index.html", relativeTo: origin)!.absoluteURL
    )

    XCTAssertEqual(search.method, .get)
    XCTAssertEqual(
      search.url.absoluteString,
      "http://sourcelab.test/search.html?q=%E6%98%9F%E6%B2%B3%20%26%20%E5%9B%9E%E5%A3%B0"
    )
    XCTAssertEqual(search.headers, HTTPHeaders())
    XCTAssertNil(search.body)
    XCTAssertNil(search.timeout)
    XCTAssertEqual(detail.url.absoluteString, "http://sourcelab.test/books/star-river/index.html")
  }

  func testSearchProjectionMatchesAndroidGolden() throws {
    let runtime = makeRuntime()
    let books = try runtime.search(
      html: fixture("search-hit.html"),
      responseURL: URL(string: "/search.html?q=星河", relativeTo: origin)!.absoluteURL
    )

    XCTAssertEqual(
      books,
      [
        SourceBook(
          name: "星河纪事",
          author: "林舟",
          intro: "用于验证搜索、详情、目录与正文的完整链路。",
          kind: "科幻,冒险",
          lastChapter: "第二章 回声",
          bookURL: URL(string: "http://sourcelab.test/books/star-river/index.html")!,
          coverURL: URL(string: "http://sourcelab.test/covers/star-river.svg")!,
          tocURL: nil
        )
      ]
    )
    XCTAssertEqual(
      try runtime.search(
        html: fixture("search-empty.html"),
        responseURL: URL(string: "/search.html?q=不存在", relativeTo: origin)!.absoluteURL
      ),
      []
    )
  }

  func testBookInfoProjectionsMatchAndroidGoldenIncludingMissingFields() throws {
    let runtime = makeRuntime()
    let bookURL = URL(string: "http://sourcelab.test/books/star-river/index.html")!
    XCTAssertEqual(
      try runtime.bookInfo(html: fixture("book-detail.html"), bookURL: bookURL),
      SourceBook(
        name: "星河纪事",
        author: "林舟",
        intro: "一段包含 & 与 <转义> 的简介。",
        kind: "科幻,冒险",
        lastChapter: "第二章 回声",
        bookURL: bookURL,
        coverURL: URL(string: "http://sourcelab.test/covers/star-river.svg")!,
        tocURL: URL(string: "http://sourcelab.test/books/star-river/toc.html")!
      )
    )

    let noCoverURL = URL(string: "http://sourcelab.test/books/no-cover/index.html")!
    XCTAssertEqual(
      try runtime.bookInfo(
        html: fixture("book-detail-missing-cover.html"),
        bookURL: noCoverURL
      ),
      SourceBook(
        name: "无封面书籍",
        author: "匿名",
        intro: nil,
        kind: nil,
        lastChapter: nil,
        bookURL: noCoverURL,
        coverURL: nil,
        tocURL: URL(string: "http://sourcelab.test/books/no-cover/toc.html")!
      )
    )
  }

  func testChapterProjectionMatchesAndroidGoldenAndEmptyTOCIsTypedIssue() throws {
    let runtime = makeRuntime()
    let tocURL = URL(string: "http://sourcelab.test/books/star-river/toc.html")!
    XCTAssertEqual(
      try runtime.chapters(html: fixture("toc.html"), tocURL: tocURL),
      [
        SourceChapter(
          index: 0,
          title: "第一章 起点",
          url: URL(string: "http://sourcelab.test/books/star-river/chapter-1.html")!,
          isPay: false,
          isVIP: false,
          isVolume: false
        ),
        SourceChapter(
          index: 1,
          title: "第二章 回声",
          url: URL(string: "http://sourcelab.test/books/star-river/chapter-2.html")!,
          isPay: false,
          isVIP: false,
          isVolume: false
        ),
      ]
    )

    XCTAssertThrowsError(
      try runtime.chapters(
        html: fixture("toc-empty.html"),
        tocURL: URL(string: "http://sourcelab.test/books/no-cover/toc.html")!
      )
    ) { error in
      XCTAssertEqual(
        error as? SourceRuntimeIssue,
        SourceRuntimeIssue(stage: .fieldEvaluation, code: .ruleFailed)
      )
    }
  }

  func testContentProjectionMatchesBothAndroidGoldenCases() throws {
    let runtime = makeRuntime()
    let firstURL = URL(string: "http://sourcelab.test/books/star-river/chapter-1.html")!
    let secondURL = URL(string: "http://sourcelab.test/books/star-river/chapter-2.html")!

    XCTAssertEqual(
      try runtime.content(html: fixture("chapter-1.html"), chapterURL: firstURL),
      SourceContent(
        chapterURL: firstURL,
        content:
          "　　这是第一段正文。\n"
          + "　　这是第二段正文，包含 强调 与相对图片。\n"
          + "　　<img src=\"http://sourcelab.test/covers/star-river.svg\">"
      )
    )
    XCTAssertEqual(
      try runtime.content(html: fixture("chapter-2.html"), chapterURL: secondURL),
      SourceContent(
        chapterURL: secondURL,
        content: "　　第二章用于验证多章节目录和稳定排序。"
      )
    )
  }

  func testMalformedHTMLIsTypedParsingIssue() throws {
    XCTAssertThrowsError(
      try makeRuntime().search(
        html: "<html><article class=\"book-item\">",
        responseURL: origin
      )
    ) { error in
      XCTAssertEqual(
        error as? SourceRuntimeIssue,
        SourceRuntimeIssue(stage: .parsing, code: .malformedHTML)
      )
    }
  }

  func testProjectionIsDeterministicAndDoesNotHardcodeFixtureValues() throws {
    let runtime = makeRuntime()
    let html = """
      <html><body><article class="book-item">
      <a class="book-link" href="/novels/other.html"><img class="book-cover" src="/other.png"/>
      <h2 class="book-name">另一部作品</h2></a>
      <span class="book-author">新作者</span><p class="book-intro">新简介</p>
      <span class="book-kind">历史</span><span class="book-last-chapter">终章</span>
      </article></body></html>
      """
    let first = try runtime.search(html: html, responseURL: origin)
    let second = try runtime.search(html: html, responseURL: origin)

    XCTAssertEqual(first, second)
    XCTAssertEqual(first.first?.name, "另一部作品")
    XCTAssertEqual(first.first?.author, "新作者")
    XCTAssertEqual(first.first?.bookURL.absoluteString, "http://sourcelab.test/novels/other.html")
  }

  private func makeRuntime() -> HTMLCSSSourceRuntime {
    HTMLCSSSourceRuntime(
      definition: HTMLCSSSourceDefinition(
        searchURLTemplate: "http://sourcelab.test/search.html?q={{key}}",
        search: SearchRules(
          list: ".book-item",
          name: HTMLCSSRule(".book-name"),
          author: HTMLCSSRule(".book-author"),
          intro: HTMLCSSRule(".book-intro"),
          kind: HTMLCSSRule(".book-kind"),
          lastChapter: HTMLCSSRule(".book-last-chapter"),
          bookURL: HTMLCSSRule("a.book-link", value: .href),
          coverURL: HTMLCSSRule("img.book-cover", value: .src)
        ),
        bookInfo: BookInfoRules(
          name: HTMLCSSRule("h1.book-name"),
          author: HTMLCSSRule(".book-author"),
          intro: HTMLCSSRule(".book-intro"),
          kind: HTMLCSSRule(".book-kind"),
          lastChapter: HTMLCSSRule(".book-last-chapter"),
          coverURL: HTMLCSSRule("img.book-cover", value: .src),
          tocURL: HTMLCSSRule("a.toc-link", value: .href)
        ),
        toc: TOCRules(
          list: "#chapter-list > li.chapter",
          name: HTMLCSSRule("a"),
          url: HTMLCSSRule("a", value: .href)
        ),
        content: ContentRules(content: HTMLCSSRule("#chapter-content", value: .html))
      )
    )
  }

  private func fixture(_ name: String) -> String {
    let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    var repositoryRoot = testDirectory
    for _ in 0..<5 {
      repositoryRoot.deleteLastPathComponent()
    }
    let url =
      repositoryRoot
      .appendingPathComponent("ios/harness/fixtures/source-lab/sl-html-basic-001/responses")
      .appendingPathComponent(name)
    return try! String(contentsOf: url, encoding: .utf8)
  }
}
