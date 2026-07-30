import XCTest

@testable import TestSupport

final class LibraryDomainTests: XCTestCase {
  func testReadableOriginalPreservesStableIdentityLocationAndChapters() {
    let result = LocalBookRelocationDomainProbe.readableOriginal()

    XCTAssertTrue(result.identityPreserved)
    XCTAssertEqual(result.location, "original")
    XCTAssertEqual(result.chapterCount, 1)
    XCTAssertTrue(result.returnedLocationIsReadable)
    XCTAssertFalse(result.retiredOriginal)
  }

  func testDefaultDirectoryRelocationKeepsBookIDAndClearsOldTOC() {
    let result = LocalBookRelocationDomainProbe.defaultRelocation()

    XCTAssertTrue(result.identityPreserved)
    XCTAssertEqual(result.location, "default")
    XCTAssertEqual(result.chapterCount, 0)
    XCTAssertTrue(result.retiredOriginal)
    XCTAssertTrue(result.returnedLocationIsReadable)
  }

  func testImportDirectoryIsUsedOnlyAfterDefaultMisses() {
    let result = LocalBookRelocationDomainProbe.importFallback()

    XCTAssertTrue(result.identityPreserved)
    XCTAssertEqual(result.location, "import")
    XCTAssertTrue(result.retiredOriginal)
  }

  func testMissPreservesBookAndRecordsExplicitFailureCache() {
    let result = LocalBookRelocationDomainProbe.missingFile()

    XCTAssertTrue(result.identityPreserved)
    XCTAssertEqual(result.location, "original")
    XCTAssertEqual(result.chapterCount, 1)
    XCTAssertFalse(result.returnedLocationIsReadable)
    XCTAssertTrue(result.failureCached)
  }

  func testCompatibilityFailureCacheIsStickyUntilExplicitlyReplaced() {
    let result = LocalBookRelocationDomainProbe.stickyFailure()

    XCTAssertTrue(result.identityPreserved)
    XCTAssertEqual(result.location, "original")
    XCTAssertEqual(result.chapterCount, 1)
    XCTAssertFalse(result.returnedLocationIsReadable)
    XCTAssertTrue(result.failureCached)
  }

  func testChapterReloadKeepsStableIdentityAtRelocatedLocation() {
    let result = LocalBookRelocationDomainProbe.reloadedDefault()

    XCTAssertTrue(result.identityPreserved)
    XCTAssertEqual(result.location, "default")
    XCTAssertEqual(result.chapterCount, 2)
  }
}
