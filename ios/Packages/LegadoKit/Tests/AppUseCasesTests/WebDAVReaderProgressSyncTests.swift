import AppUseCases
import IntegrationKit
import LibraryDomain
import XCTest

final class WebDAVReaderProgressSyncTests: XCTestCase {
  func testCloudAheadIsReadyToApply() async throws {
    let outcome = await useCase(chapter: 2, position: 15).resolve(
      configuration: try configuration(),
      book: book(chapter: 1, position: 40)
    )

    guard case .applied(let progress) = outcome else {
      return XCTFail("expected automatic apply, got \(outcome)")
    }
    XCTAssertEqual(2, progress.position.chapterIndex)
    XCTAssertEqual(15, progress.position.characterOffset)
    XCTAssertEqual("第三章", progress.chapterTitle)
    XCTAssertEqual(200, progress.updatedAtMilliseconds)
  }

  func testCloudBehindRequiresConfirmation() async throws {
    let outcome = await useCase(chapter: 1, position: 30).resolve(
      configuration: try configuration(),
      book: book(chapter: 1, position: 90)
    )

    guard case .confirmationRequired(let progress) = outcome else {
      return XCTFail("expected confirmation, got \(outcome)")
    }
    XCTAssertEqual(1, progress.position.chapterIndex)
    XCTAssertEqual(30, progress.position.characterOffset)
  }

  func testRemoteFailureStaysStructured() async throws {
    let useCase = WebDAVReaderProgressSyncUseCase(
      loader: FixedProgressLoader(result: .failed(.notFound))
    )
    let outcome = await useCase.resolve(
      configuration: try configuration(),
      book: book(chapter: 1, position: 90)
    )
    XCTAssertEqual(.failed(.remote(.notFound)), outcome)
  }

  private func useCase(
    chapter: Int,
    position: Int
  ) -> WebDAVReaderProgressSyncUseCase {
    WebDAVReaderProgressSyncUseCase(
      loader: FixedProgressLoader(
        result: .loaded(
          WebDAVBookProgressDocument(
            name: "SyncBook",
            author: "SyncAuthor",
            durChapterIndex: chapter,
            durChapterPos: position,
            durChapterTime: 200,
            durChapterTitle: chapter == 2 ? "第三章" : "第二章"
          )
        )
      )
    )
  }

  private func configuration() throws -> WebDAVConnectionConfiguration {
    WebDAVConnectionConfiguration(
      serverURL: try XCTUnwrap(
        WebDAVServerURL(rawValue: "https://dav.example.test/dav")
      ),
      directoryName: "legado",
      credentialReference: WebDAVCredentialReference("credential")
    )
  }

  private func book(chapter: Int, position: Int) -> ShelfBookItem {
    ShelfBookItem(
      id: BookID(rawValue: "book"),
      candidate: ShelfBookCandidate(
        name: "SyncBook",
        author: "SyncAuthor",
        kind: "web",
        lastChapter: "第三章",
        intro: "",
        bookURL: "book://sync",
        coverURL: nil,
        originName: "source"
      ),
      membership: .member(groupID: 0),
      order: 0,
      chapterCount: 3,
      progress: ReadingProgress(
        position: ReadingPosition(
          chapterIndex: chapter,
          characterOffset: position
        ),
        chapterTitle: "第二章",
        updatedAtMilliseconds: 100
      )
    )
  }
}

private struct FixedProgressLoader: WebDAVBookProgressLoading {
  let result: WebDAVBookProgressLoadResult

  func load(
    configuration: WebDAVConnectionConfiguration,
    identity: WebDAVBookIdentity
  ) async -> WebDAVBookProgressLoadResult {
    result
  }
}
