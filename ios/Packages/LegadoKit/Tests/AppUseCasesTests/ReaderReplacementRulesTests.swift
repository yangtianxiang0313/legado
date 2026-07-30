import LibraryDomain
@testable import AppUseCases
import ReaderCore
import XCTest

@MainActor
final class ReaderReplacementRulesTests: XCTestCase {
  func testNormalizingLoaderAppliesPersistedRulesToRawDocument() async throws {
    let repository = InMemoryReplacementRuleRepository(
      rules: [
        ReaderReplacementRule(
          id: "remove-ad",
          name: "去广告",
          pattern: "广告",
          replacement: "",
          isRegex: false,
          order: 0
        )
      ]
    )
    let book = makeBook()
    let chapter = makeChapter(bookID: book.id)
    let loader = ReplacementNormalizingReaderContentLoader(
      base: FixedReaderContentLoader(
        document: ReaderDocument(
          position: ReaderPosition(
            bookID: book.id,
            chapterID: chapter.id,
            chapterIndex: 0,
            characterOffset: 2
          ),
          title: "第一章",
          content: "第一章\n广告\n保留正文"
        )
      ),
      rules: repository
    )

    let document = try await loader.load(
      book: book,
      chapter: chapter,
      characterOffset: 2
    )

    XCTAssertEqual(document.title, "第一章")
    XCTAssertEqual(document.content, "　　保留正文")
    XCTAssertEqual(document.position.characterOffset, 2)
  }

  func testStoreRejectsInvalidRegexAndPersistsToggle() async {
    let repository = InMemoryReplacementRuleRepository()
    let store = ReaderReplacementRuleStore(repository: repository)
    let invalid = ReaderReplacementRule(
      id: "invalid",
      name: "错误规则",
      pattern: "[",
      replacement: "",
      isRegex: true
    )

    let invalidSaved = await store.save(invalid)
    XCTAssertFalse(invalidSaved)
    XCTAssertEqual(store.errorMessage, "正则表达式无效")

    let valid = ReaderReplacementRule(
      id: "valid",
      name: "文字规则",
      pattern: "旧",
      replacement: "新",
      isRegex: false
    )
    let validSaved = await store.save(valid)
    XCTAssertTrue(validSaved)
    XCTAssertEqual(store.rules, [valid])
    let toggled = await store.setEnabled(id: valid.id, enabled: false)
    XCTAssertTrue(toggled)
    XCTAssertFalse(store.rules[0].isEnabled)
  }

  private func makeBook() -> ShelfBookItem {
    ShelfBookItem(
      id: BookID(rawValue: "book"),
      candidate: ShelfBookCandidate(
        name: "测试书",
        author: "作者",
        kind: "",
        lastChapter: "第一章",
        intro: "",
        bookURL: "https://example.test/book",
        coverURL: nil,
        originName: "测试源",
        sourceID: "source://test"
      ),
      membership: .member(groupID: 0),
      order: 0,
      chapterCount: 1
    )
  }

  private func makeChapter(bookID: BookID) -> BookChapter {
    BookChapter(
      id: ChapterID(rawValue: "chapter"),
      bookID: bookID,
      sourceID: "source://test",
      index: 0,
      title: "第一章",
      url: "https://example.test/chapter"
    )
  }
}

private struct FixedReaderContentLoader: ReaderContentLoading {
  let document: ReaderDocument

  func load(
    book: ShelfBookItem,
    chapter: BookChapter,
    characterOffset: Int
  ) async throws -> ReaderDocument {
    document
  }
}

private actor InMemoryReplacementRuleRepository:
  ReaderReplacementRuleRepository
{
  private var values: [ReaderReplacementRule]

  init(rules: [ReaderReplacementRule] = []) {
    values = rules
  }

  func replacementRules() async throws -> [ReaderReplacementRule] {
    values.sorted { $0.order < $1.order }
  }

  func saveReplacementRule(_ rule: ReaderReplacementRule) async throws {
    if let index = values.firstIndex(where: { $0.id == rule.id }) {
      values[index] = rule
    } else {
      values.append(rule)
    }
  }

  func deleteReplacementRule(id: String) async throws {
    values.removeAll { $0.id == id }
  }

  func resetReplacementRules() async throws {
    values.removeAll()
  }
}
