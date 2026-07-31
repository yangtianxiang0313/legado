import AppUseCases
import LibraryDomain
import XCTest

final class ReaderImageCacheTests: XCTestCase {
  func testSameBookAndURLReusesDecodedBytes() async {
    let cache = ReaderImageDataCache()
    let calls = ImageLoadCounter()
    let key = ReaderImageCacheKey(
      bookID: BookID(rawValue: "book-a"),
      sourceURL: "https://example.test/image.png"
    )

    let first = await cache.value(for: key) {
      await calls.load()
    }
    let second = await cache.value(for: key) {
      await calls.load()
    }

    XCTAssertEqual(first, [1, 2, 3])
    XCTAssertEqual(second, [1, 2, 3])
    let callCount = await calls.value()
    XCTAssertEqual(callCount, 1)
  }

  func testSameURLForDifferentBooksDoesNotShareCache() async {
    let cache = ReaderImageDataCache()
    let calls = ImageLoadCounter()
    let sourceURL = "https://example.test/image.png"

    _ = await cache.value(
      for: .init(bookID: BookID(rawValue: "book-a"), sourceURL: sourceURL)
    ) { await calls.load() }
    _ = await cache.value(
      for: .init(bookID: BookID(rawValue: "book-b"), sourceURL: sourceURL)
    ) { await calls.load() }

    let callCount = await calls.value()
    XCTAssertEqual(callCount, 2)
  }

  func testConcurrentRequestsForSameImageAreCoalesced() async {
    let cache = ReaderImageDataCache()
    let calls = ImageLoadCounter()
    let key = ReaderImageCacheKey(
      bookID: BookID(rawValue: "book-a"),
      sourceURL: "https://example.test/image.png"
    )

    async let first = cache.value(for: key) { await calls.slowLoad() }
    async let second = cache.value(for: key) { await calls.slowLoad() }

    let (firstValue, secondValue) = await (first, second)
    let callCount = await calls.value()
    XCTAssertEqual(firstValue, [1, 2, 3])
    XCTAssertEqual(secondValue, [1, 2, 3])
    XCTAssertEqual(callCount, 1)
  }
}

private actor ImageLoadCounter {
  private var count = 0

  func load() -> [UInt8] {
    count += 1
    return [1, 2, 3]
  }

  func slowLoad() async -> [UInt8] {
    count += 1
    try? await Task.sleep(for: .milliseconds(30))
    return [1, 2, 3]
  }

  func value() -> Int { count }
}
