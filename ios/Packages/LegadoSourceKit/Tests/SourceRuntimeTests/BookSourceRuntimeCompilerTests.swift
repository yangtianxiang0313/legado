import Foundation
import XCTest

@testable import SourceRuntime

final class BookSourceRuntimeCompilerTests: XCTestCase {
  func testCompilesImportedDTOAndAppliesOnlyMetadataOverrides()
    throws
  {
    let compiled = try BookSourceRuntimeCompiler.compile(
      Data(
        #"""
        {
          "bookSourceUrl": "https://stored.example",
          "bookSourceName": "Stored",
          "bookSourceGroup": "Stored Group",
          "customOrder": 3,
          "enabled": false,
          "enabledExplore": false,
          "enabledCookieJar": false,
          "bookUrlPattern": "^https://stored.example/book/",
          "header": {
            "User-Agent": "Source UA",
            "X-Source": "runtime-compiler"
          },
          "loginCheckJs": "result == 'login'",
          "jsLib": "function helper() { return 1; }",
          "searchUrl": "https://stored.example/search?q={{key}}",
          "exploreUrl": "全部::https://stored.example/all?page={{page}}",
          "ruleSearch": {
            "bookList": ".book",
            "name": ".name",
            "author": ".author",
            "bookUrl": "a@href"
          },
          "ruleExplore": {
            "bookList": ".explore-book",
            "name": ".explore-name",
            "bookUrl": "a@href"
          },
          "ruleBookInfo": {
            "name": "h1",
            "author": ".author",
            "tocUrl": ".toc@href",
            "canReName": "1"
          },
          "ruleToc": {
            "chapterList": ".chapter",
            "chapterName": "a@text",
            "chapterUrl": "a@href",
            "nextTocUrl": ".next@href"
          },
          "ruleContent": {
            "content": "#content@html",
            "nextContentUrl": ".next@href",
            "webJs": "document.body.innerHTML",
            "sourceRegex": "media=(.+)"
          }
        }
        """#.utf8
      ),
      overrides: BookSourceRuntimeOverrides(
        sourceURL: "https://edited.example",
        sourceName: "Edited",
        group: "Edited Group",
        originOrder: 42,
        enabled: true,
        enabledExplore: true,
        exploreURL:
          "精选::https://edited.example/explore?page={{page}}",
        sourceUserVariable: #"{"token":"one"}"#
      )
    )

    XCTAssertEqual(compiled.id, "https://edited.example")
    XCTAssertEqual(compiled.name, "Edited")
    XCTAssertEqual(compiled.group, "Edited Group")
    XCTAssertTrue(compiled.enabled)
    XCTAssertEqual(compiled.definition.originOrder, 42)
    XCTAssertEqual(
      compiled.definition.runtime.searchURLTemplate,
      "https://stored.example/search?q={{key}}"
    )
    XCTAssertEqual(
      compiled.definition.runtime.search.list,
      ".book"
    )
    XCTAssertEqual(
      compiled.definition.runtime.explore?.list,
      ".explore-book"
    )
    XCTAssertEqual(
      compiled.definition.runtime.toc.nextTocURL?.selector,
      ".next@href"
    )
    XCTAssertEqual(
      compiled.definition.runtime.content.webJS,
      "document.body.innerHTML"
    )
    XCTAssertTrue(
      compiled.definition.runtime.bookInfo.allowsRename
    )
    XCTAssertEqual(
      compiled.definition.sourceHeaders.map(\.name),
      ["User-Agent", "X-Source"]
    )
    XCTAssertFalse(compiled.definition.enabledCookieJar)
    XCTAssertNotNil(compiled.definition.scriptLibrary)
    XCTAssertEqual(
      compiled.definition.sourceUserVariable,
      #"{"token":"one"}"#
    )
    XCTAssertEqual(
      compiled.exploreDefinition?.catalog,
      "精选::https://edited.example/explore?page={{page}}"
    )
    XCTAssertTrue(
      compiled.exploreDefinition?.enabled == true
    )
  }

  func testSparseAndroidSourceGetsDefaultRuleObjectsInsteadOfDropping()
    throws
  {
    let compiled = try BookSourceRuntimeCompiler.compile(
      Data(
        #"""
        {
          "bookSourceUrl": "https://sparse.example",
          "bookSourceName": "Sparse"
        }
        """#.utf8
      )
    )

    XCTAssertTrue(compiled.enabled)
    XCTAssertTrue(compiled.definition.enabledCookieJar)
    XCTAssertEqual(compiled.definition.runtime.search.list, "")
    XCTAssertEqual(
      compiled.definition.runtime.search.name.selector,
      "__legado_missing__"
    )
    XCTAssertEqual(
      compiled.definition.runtime.bookInfo.tocURL.selector,
      "__legado_missing__"
    )
    XCTAssertEqual(
      compiled.definition.runtime.toc.url.selector,
      "__legado_missing__"
    )
    XCTAssertEqual(
      compiled.definition.runtime.content.content.selector,
      "__legado_missing__"
    )
    XCTAssertNotNil(compiled.definition.runtime.explore)
    XCTAssertNil(compiled.exploreDefinition)
  }

  func testMissingSourceURLFailsClosed() {
    XCTAssertThrowsError(
      try BookSourceRuntimeCompiler.compile(
        Data(#"{"bookSourceName":"Missing URL"}"#.utf8)
      )
    ) { error in
      XCTAssertEqual(
        error as? BookSourceRuntimeCompilerError,
        .missingSourceURL
      )
    }
  }
}
