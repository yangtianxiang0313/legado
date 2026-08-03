import AppUseCases
import XCTest

final class LocalBookFormatsTests: XCTestCase {
  func testParsesEPUBMetadataNavigationAndChapterText() throws {
    let document = try EPUBBookParser.parse(
      members: [
        "META-INF/container.xml": data("""
          <?xml version="1.0"?>
          <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles>
          </container>
          """),
        "OEBPS/content.opf": data("""
          <package xmlns="http://www.idpf.org/2007/opf">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
              <dc:title>跨端论语</dc:title><dc:creator>孔门</dc:creator>
            </metadata>
            <manifest>
              <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
              <item id="c1" href="Text/chapter1.xhtml" media-type="application/xhtml+xml"/>
              <item id="c2" href="Text/chapter2.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
          </package>
          """),
        "OEBPS/nav.xhtml": data("""
          <html xmlns="http://www.w3.org/1999/xhtml"><body><nav>
            <ol><li><a href="Text/chapter1.xhtml">学而</a></li>
            <li><a href="Text/chapter2.xhtml">为政</a></li></ol>
          </nav></body></html>
          """),
        "OEBPS/Text/chapter1.xhtml": data("""
          <html xmlns="http://www.w3.org/1999/xhtml"><head><title>一</title></head>
          <body><h1>学而</h1><p>学而时习之，不亦说乎。</p><script>drop()</script></body></html>
          """),
        "OEBPS/Text/chapter2.xhtml": data("""
          <html xmlns="http://www.w3.org/1999/xhtml"><head><title>二</title></head>
          <body><p>为政以德，譬如北辰。</p></body></html>
          """),
      ],
      fallbackTitle: "fallback.epub"
    )

    XCTAssertEqual(document.title, "跨端论语")
    XCTAssertEqual(document.author, "孔门")
    XCTAssertEqual(document.chapters.map(\.title), ["学而", "为政"])
    XCTAssertTrue(document.chapters[0].content.contains("学而时习之"))
    XCTAssertFalse(document.chapters[0].content.contains("drop"))
  }

  func testFallsBackToSpineAndHTMLTitleWithoutNavigation() throws {
    let document = try EPUBBookParser.parse(
      members: [
        "META-INF/container.xml": data("""
          <container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>
          """),
        "book.opf": data("""
          <package><manifest>
            <item id="only" href="chapter.xhtml" media-type="application/xhtml+xml"/>
          </manifest><spine><itemref idref="only"/></spine></package>
          """),
        "chapter.xhtml": data("""
          <html><head><title>正文标题</title></head><body><p>可阅读正文</p></body></html>
          """),
      ],
      fallbackTitle: "无元数据.epub"
    )

    XCTAssertEqual(document.title, "无元数据")
    XCTAssertEqual(document.author, "")
    XCTAssertEqual(document.chapters.map(\.title), ["正文标题"])
    XCTAssertEqual(document.chapters[0].content, "可阅读正文")
  }

  func testRejectsMissingReferencedContent() throws {
    XCTAssertThrowsError(
      try EPUBBookParser.parse(
        members: [
          "META-INF/container.xml": data("""
            <container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>
            """),
          "book.opf": data("""
            <package><manifest><item id="lost" href="lost.xhtml"/></manifest>
            <spine><itemref idref="lost"/></spine></package>
            """),
        ],
        fallbackTitle: "broken.epub"
      )
    ) { error in
      XCTAssertEqual(error as? EPUBBookFailure, .missingContent("lost.xhtml"))
    }
  }

  private func data(_ value: String) -> Data {
    Data(value.utf8)
  }
}
