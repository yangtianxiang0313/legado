import XCTest

@testable import SourceFormat

final class BookSourceSchemaTests: XCTestCase {
  func testKnownSchemaMatchesFrozenAndroidInventory() {
    XCTAssertEqual(
      BookSourceSchema.bookSourceFields,
      [
        field("bookSourceUrl", .string, false),
        field("bookSourceName", .string, false),
        field("bookSourceGroup", .string, true),
        field("bookSourceType", .int32, false),
        field("bookUrlPattern", .string, true),
        field("customOrder", .int32, false),
        field("enabled", .boolean, false),
        field("enabledExplore", .boolean, false),
        field("jsLib", .string, true),
        field("enabledCookieJar", .boolean, true),
        field("concurrentRate", .string, true),
        field("header", .string, true),
        field("loginUrl", .string, true),
        field("loginUi", .string, true),
        field("loginCheckJs", .string, true),
        field("coverDecodeJs", .string, true),
        field("bookSourceComment", .string, true),
        field("variableComment", .string, true),
        field("lastUpdateTime", .int64, false),
        field("respondTime", .int64, false),
        field("weight", .int32, false),
        field("exploreUrl", .string, true),
        field("exploreScreen", .string, true),
        field("ruleExplore", .object, true),
        field("searchUrl", .string, true),
        field("ruleSearch", .object, true),
        field("ruleBookInfo", .object, true),
        field("ruleToc", .object, true),
        field("ruleContent", .object, true),
        field("ruleReview", .object, true),
      ]
    )
    assertNullableStrings(
      BookSourceSchema.searchRuleFields,
      [
        "checkKeyWord", "bookList", "name", "author", "intro", "kind", "lastChapter",
        "updateTime", "bookUrl", "coverUrl", "wordCount",
      ]
    )
    assertNullableStrings(
      BookSourceSchema.exploreRuleFields,
      [
        "bookList", "name", "author", "intro", "kind", "lastChapter", "updateTime",
        "bookUrl", "coverUrl", "wordCount",
      ]
    )
    assertNullableStrings(
      BookSourceSchema.bookInfoRuleFields,
      [
        "init", "name", "author", "intro", "kind", "lastChapter", "updateTime", "coverUrl",
        "tocUrl", "wordCount", "canReName", "downloadUrls",
      ]
    )
    assertNullableStrings(
      BookSourceSchema.tocRuleFields,
      [
        "preUpdateJs", "chapterList", "chapterName", "chapterUrl", "formatJs", "isVolume",
        "isVip", "isPay", "updateTime", "nextTocUrl",
      ]
    )
    assertNullableStrings(
      BookSourceSchema.contentRuleFields,
      [
        "content", "title", "nextContentUrl", "webJs", "sourceRegex", "replaceRegex",
        "imageStyle", "imageDecode", "payAction",
      ]
    )
    assertNullableStrings(
      BookSourceSchema.reviewRuleFields,
      [
        "reviewUrl", "avatarRule", "contentRule", "postTimeRule", "reviewQuoteUrl",
        "voteUpUrl", "voteDownUrl", "postReviewUrl", "postQuoteUrl", "deleteUrl",
      ]
    )

    let total =
      BookSourceSchema.bookSourceFields.count
      + BookSourceSchema.searchRuleFields.count
      + BookSourceSchema.exploreRuleFields.count
      + BookSourceSchema.bookInfoRuleFields.count
      + BookSourceSchema.tocRuleFields.count
      + BookSourceSchema.contentRuleFields.count
      + BookSourceSchema.reviewRuleFields.count
    XCTAssertEqual(total, 92)
  }

  private func field(
    _ jsonName: String,
    _ kind: SourceFieldKind,
    _ nullable: Bool
  ) -> SourceFieldDefinition {
    SourceFieldDefinition(jsonName: jsonName, kind: kind, nullable: nullable)
  }

  private func assertNullableStrings(
    _ definitions: [SourceFieldDefinition],
    _ names: [String],
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(
      definitions,
      names.map { field($0, .string, true) },
      file: file,
      line: line
    )
  }
}
