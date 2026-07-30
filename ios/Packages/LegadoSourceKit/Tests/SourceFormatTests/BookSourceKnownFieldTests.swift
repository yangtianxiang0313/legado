import Foundation
import LegadoCore
import XCTest

@testable import SourceFormat

final class BookSourceKnownFieldTests: XCTestCase {
  func testEveryKnownFieldDecodesThroughTypedAccessors() throws {
    let canonical = try fullKnownFieldPayload()
    let source = try BookSourceCodec.decode(canonical)

    XCTAssertEqual(source.bookSourceUrl, .value("bookSourceUrl"))
    XCTAssertEqual(source.bookSourceName, .value("bookSourceName"))
    XCTAssertEqual(source.bookSourceGroup, .value("bookSourceGroup"))
    XCTAssertEqual(source.bookSourceType, .value(2))
    XCTAssertEqual(source.bookUrlPattern, .value("bookUrlPattern"))
    XCTAssertEqual(source.customOrder, .value(Int32.max))
    XCTAssertEqual(source.enabled, .value(true))
    XCTAssertEqual(source.enabledExplore, .value(true))
    XCTAssertEqual(source.jsLib, .value("jsLib"))
    XCTAssertEqual(source.enabledCookieJar, .value(true))
    XCTAssertEqual(source.concurrentRate, .value("concurrentRate"))
    XCTAssertEqual(source.header, .value("header"))
    XCTAssertEqual(source.loginUrl, .value("loginUrl"))
    XCTAssertEqual(source.loginUi, .value("loginUi"))
    XCTAssertEqual(source.loginCheckJs, .value("loginCheckJs"))
    XCTAssertEqual(source.coverDecodeJs, .value("coverDecodeJs"))
    XCTAssertEqual(source.bookSourceComment, .value("bookSourceComment"))
    XCTAssertEqual(source.variableComment, .value("variableComment"))
    XCTAssertEqual(source.lastUpdateTime, .value(Int64.max))
    XCTAssertEqual(source.respondTime, .value(Int64.min))
    XCTAssertEqual(source.weight, .value(Int32.min))
    XCTAssertEqual(source.exploreUrl, .value("exploreUrl"))
    XCTAssertEqual(source.exploreScreen, .value("exploreScreen"))
    XCTAssertEqual(source.searchUrl, .value("searchUrl"))

    let search = try value(source.ruleSearch)
    XCTAssertEqual(search.checkKeyWord, .value("checkKeyWord"))
    assertBookListFields(
      bookList: search.bookList,
      name: search.name,
      author: search.author,
      intro: search.intro,
      kind: search.kind,
      lastChapter: search.lastChapter,
      updateTime: search.updateTime,
      bookUrl: search.bookUrl,
      coverUrl: search.coverUrl,
      wordCount: search.wordCount
    )

    let explore = try value(source.ruleExplore)
    assertBookListFields(
      bookList: explore.bookList,
      name: explore.name,
      author: explore.author,
      intro: explore.intro,
      kind: explore.kind,
      lastChapter: explore.lastChapter,
      updateTime: explore.updateTime,
      bookUrl: explore.bookUrl,
      coverUrl: explore.coverUrl,
      wordCount: explore.wordCount
    )

    let bookInfo = try value(source.ruleBookInfo)
    XCTAssertEqual(bookInfo.initialization, .value("init"))
    XCTAssertEqual(bookInfo.name, .value("name"))
    XCTAssertEqual(bookInfo.author, .value("author"))
    XCTAssertEqual(bookInfo.intro, .value("intro"))
    XCTAssertEqual(bookInfo.kind, .value("kind"))
    XCTAssertEqual(bookInfo.lastChapter, .value("lastChapter"))
    XCTAssertEqual(bookInfo.updateTime, .value("updateTime"))
    XCTAssertEqual(bookInfo.coverUrl, .value("coverUrl"))
    XCTAssertEqual(bookInfo.tocUrl, .value("tocUrl"))
    XCTAssertEqual(bookInfo.wordCount, .value("wordCount"))
    XCTAssertEqual(bookInfo.canReName, .value("canReName"))
    XCTAssertEqual(bookInfo.downloadUrls, .value("downloadUrls"))

    let toc = try value(source.ruleToc)
    XCTAssertEqual(toc.preUpdateJs, .value("preUpdateJs"))
    XCTAssertEqual(toc.chapterList, .value("chapterList"))
    XCTAssertEqual(toc.chapterName, .value("chapterName"))
    XCTAssertEqual(toc.chapterUrl, .value("chapterUrl"))
    XCTAssertEqual(toc.formatJs, .value("formatJs"))
    XCTAssertEqual(toc.isVolume, .value("isVolume"))
    XCTAssertEqual(toc.isVip, .value("isVip"))
    XCTAssertEqual(toc.isPay, .value("isPay"))
    XCTAssertEqual(toc.updateTime, .value("updateTime"))
    XCTAssertEqual(toc.nextTocUrl, .value("nextTocUrl"))

    let content = try value(source.ruleContent)
    XCTAssertEqual(content.content, .value("content"))
    XCTAssertEqual(content.title, .value("title"))
    XCTAssertEqual(content.nextContentUrl, .value("nextContentUrl"))
    XCTAssertEqual(content.webJs, .value("webJs"))
    XCTAssertEqual(content.sourceRegex, .value("sourceRegex"))
    XCTAssertEqual(content.replaceRegex, .value("replaceRegex"))
    XCTAssertEqual(content.imageStyle, .value("imageStyle"))
    XCTAssertEqual(content.imageDecode, .value("imageDecode"))
    XCTAssertEqual(content.payAction, .value("payAction"))

    let review = try value(source.ruleReview)
    XCTAssertEqual(review.reviewUrl, .value("reviewUrl"))
    XCTAssertEqual(review.avatarRule, .value("avatarRule"))
    XCTAssertEqual(review.contentRule, .value("contentRule"))
    XCTAssertEqual(review.postTimeRule, .value("postTimeRule"))
    XCTAssertEqual(review.reviewQuoteUrl, .value("reviewQuoteUrl"))
    XCTAssertEqual(review.voteUpUrl, .value("voteUpUrl"))
    XCTAssertEqual(review.voteDownUrl, .value("voteDownUrl"))
    XCTAssertEqual(review.postReviewUrl, .value("postReviewUrl"))
    XCTAssertEqual(review.postQuoteUrl, .value("postQuoteUrl"))
    XCTAssertEqual(review.deleteUrl, .value("deleteUrl"))

    XCTAssertTrue(source.unknownFields.isEmpty)
    XCTAssertEqual(try BookSourceCodec.encode(source), canonical)
    requireSendable(source)
    requireSendable(search)
    requireSendable(explore)
    requireSendable(bookInfo)
    requireSendable(toc)
    requireSendable(content)
    requireSendable(review)
  }

  private func fullKnownFieldPayload() throws -> Data {
    var root: [String: JSONValue] = [:]
    for definition in BookSourceSchema.bookSourceFields {
      switch definition.kind {
      case .string:
        root[definition.jsonName] = .string(definition.jsonName)
      case .boolean:
        root[definition.jsonName] = .bool(true)
      case .int32:
        let token: String
        switch definition.jsonName {
        case "bookSourceType": token = "2"
        case "customOrder": token = String(Int32.max)
        default: token = String(Int32.min)
        }
        root[definition.jsonName] = .number(try JSONNumber(validating: token))
      case .int64:
        let token = definition.jsonName == "lastUpdateTime" ? String(Int64.max) : String(Int64.min)
        root[definition.jsonName] = .number(try JSONNumber(validating: token))
      case .object:
        root[definition.jsonName] = .object(ruleFields(for: definition.jsonName))
      }
    }
    return try JSONValueCodec.encode(.object(root))
  }

  private func ruleFields(for jsonName: String) -> [String: JSONValue] {
    let definitions: [SourceFieldDefinition]
    switch jsonName {
    case "ruleExplore": definitions = BookSourceSchema.exploreRuleFields
    case "ruleSearch": definitions = BookSourceSchema.searchRuleFields
    case "ruleBookInfo": definitions = BookSourceSchema.bookInfoRuleFields
    case "ruleToc": definitions = BookSourceSchema.tocRuleFields
    case "ruleContent": definitions = BookSourceSchema.contentRuleFields
    case "ruleReview": definitions = BookSourceSchema.reviewRuleFields
    default: return [:]
    }
    return Dictionary(uniqueKeysWithValues: definitions.map { ($0.jsonName, .string($0.jsonName)) })
  }

  private func assertBookListFields(
    bookList: SourceField<String>,
    name: SourceField<String>,
    author: SourceField<String>,
    intro: SourceField<String>,
    kind: SourceField<String>,
    lastChapter: SourceField<String>,
    updateTime: SourceField<String>,
    bookUrl: SourceField<String>,
    coverUrl: SourceField<String>,
    wordCount: SourceField<String>
  ) {
    XCTAssertEqual(bookList, .value("bookList"))
    XCTAssertEqual(name, .value("name"))
    XCTAssertEqual(author, .value("author"))
    XCTAssertEqual(intro, .value("intro"))
    XCTAssertEqual(kind, .value("kind"))
    XCTAssertEqual(lastChapter, .value("lastChapter"))
    XCTAssertEqual(updateTime, .value("updateTime"))
    XCTAssertEqual(bookUrl, .value("bookUrl"))
    XCTAssertEqual(coverUrl, .value("coverUrl"))
    XCTAssertEqual(wordCount, .value("wordCount"))
  }

  private func value<Value: Equatable & Sendable>(_ field: SourceField<Value>) throws -> Value {
    guard case .value(let value) = field else {
      throw KnownFieldTestError.expectedValue
    }
    return value
  }

  private func requireSendable<Value: Sendable>(_: Value) {}
}

private enum KnownFieldTestError: Error {
  case expectedValue
}
