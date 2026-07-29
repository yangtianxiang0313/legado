import XCTest

@testable import SourceRuntime

final class SourceVariableScopeTests: XCTestCase {
  func testRuleDataStorageBoundaryMatchesAndroid() async throws {
    let store = SourceVariableStore(policy: .androidRuleData)

    let small = await store.put(
      "payload",
      value: String(repeating: "s", count: 9_999)
    )
    XCTAssertEqual(
      small,
      SourceVariableWriteResult(acceptedInline: true, stored: true)
    )
    let large = await store.put(
      "payload",
      value: String(repeating: "l", count: 10_000)
    )
    XCTAssertEqual(
      large,
      SourceVariableWriteResult(acceptedInline: false, stored: true)
    )
    let storedLarge = await store.get("payload")
    XCTAssertEqual(storedLarge.count, 10_000)

    let removed = await store.put("payload", value: nil)
    XCTAssertEqual(
      removed,
      SourceVariableWriteResult(acceptedInline: true, stored: false)
    )
    let valueAfterRemoval = await store.get("payload")
    XCTAssertEqual(valueAfterRemoval, "")
    let serialized = try await store.androidSerializedVariables()
    XCTAssertNil(serialized)
  }

  func testRuleResolverUsesRoleSpecificPriorityAndSpecialMappings()
    async
  {
    let chapter = SourceVariableStore(values: [
      "scope": "chapter",
      "empty-fallback": "",
      "title": "variable-title",
    ])
    let book = SourceVariableStore(values: [
      "scope": "book",
      "empty-fallback": "book-fallback",
      "bookName": "variable-book-name",
    ])
    let source = SourceVariableStore(values: [
      "scope": "source",
      "source-only": "source-only-value",
    ])
    let resolver = SourceVariableResolver(
      role: .rule,
      scopes: SourceVariableScopes(
        chapter: chapter,
        book: book,
        ruleData: book,
        source: source,
        bookName: "Mapped Book",
        chapterTitle: "Mapped Chapter"
      )
    )

    let priority = await resolver.get("scope")
    let fallback = await resolver.get("empty-fallback")
    let sourceValue = await resolver.get("source-only")
    let bookName = await resolver.get("bookName")
    let chapterTitle = await resolver.get("title")
    XCTAssertEqual(priority, "chapter")
    XCTAssertEqual(fallback, "book-fallback")
    XCTAssertEqual(sourceValue, "source-only-value")
    XCTAssertEqual(bookName, "Mapped Book")
    XCTAssertEqual(chapterTitle, "Mapped Chapter")

    let returned = await resolver.put("written", value: "rule")
    XCTAssertEqual(returned, "rule")
    let chapterWrite = await chapter.get("written")
    let bookWrite = await book.get("written")
    let sourceWrite = await source.get("written")
    XCTAssertEqual(chapterWrite, "rule")
    XCTAssertEqual(bookWrite, "")
    XCTAssertEqual(sourceWrite, "")
  }

  func testURLResolverNeverFallsBackToSource() async {
    let chapter = SourceVariableStore(values: [
      "scope": "chapter",
      "empty-fallback": "",
    ])
    let ruleData = SourceVariableStore(values: [
      "scope": "book",
      "empty-fallback": "book-fallback",
    ])
    let source = SourceVariableStore(values: [
      "source-only": "source-only-value"
    ])
    let resolver = SourceVariableResolver(
      role: .url,
      scopes: SourceVariableScopes(
        chapter: chapter,
        ruleData: ruleData,
        source: source,
        bookName: "Mapped Book",
        chapterTitle: "Mapped Chapter"
      )
    )

    let priority = await resolver.get("scope")
    let fallback = await resolver.get("empty-fallback")
    let sourceValue = await resolver.get("source-only")
    XCTAssertEqual(priority, "chapter")
    XCTAssertEqual(fallback, "book-fallback")
    XCTAssertEqual(sourceValue, "")
  }

  func testSharedContextPropagatesAndIndependentContextsAreIsolated()
    async throws
  {
    let shared = SourceVariableStore(policy: .androidRuleData)
    let first = SourceVariableResolver(
      role: .rule,
      scopes: SourceVariableScopes(ruleData: shared)
    )
    let later = SourceVariableResolver(
      role: .url,
      scopes: SourceVariableScopes(ruleData: shared)
    )
    let isolatedStore = SourceVariableStore(policy: .androidRuleData)
    let isolated = SourceVariableResolver(
      role: .rule,
      scopes: SourceVariableScopes(ruleData: isolatedStore)
    )

    _ = await first.put("token", value: "from-rule")
    let propagated = await later.get("token")
    let isolatedValue = await isolated.get("token")
    XCTAssertEqual(propagated, "from-rule")
    XCTAssertEqual(isolatedValue, "")
    let serialized = try await shared.androidSerializedVariables()
    XCTAssertEqual(serialized, "{\n  \"token\": \"from-rule\"\n}")
  }

  func testWritesAreImmediateAndNotRolledBackByLaterFailure() async {
    enum ProbeError: Error {
      case failed
    }
    let shared = SourceVariableStore(policy: .androidRuleData)
    let resolver = SourceVariableResolver(
      role: .rule,
      scopes: SourceVariableScopes(ruleData: shared)
    )

    do {
      _ = await resolver.put("token", value: "before-throw")
      throw ProbeError.failed
    } catch {
      XCTAssertTrue(error is ProbeError)
    }

    let value = await resolver.get("token")
    XCTAssertEqual(value, "before-throw")
  }
}
