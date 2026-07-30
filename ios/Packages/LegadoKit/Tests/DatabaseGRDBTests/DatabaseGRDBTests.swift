import DatabaseGRDB
import XCTest

final class DatabaseGRDBTests: XCTestCase {
  func testExactDependencyCanOpenAndUseSQLite() throws {
    XCTAssertTrue(
      try DatabaseGRDBRuntime.verifyInMemoryDatabase()
    )
  }

  func testStagedBookIsNotShelfMembershipAndAddSurvivesReopen() async throws {
    let verified = try await DatabaseGRDBRuntime
      .verifyShelfPersistenceAcrossReopen()
    XCTAssertTrue(verified)
  }

  func testTOCReplacementPersistsAndFailurePreservesOldSnapshot() async throws {
    let verified =
      try await DatabaseGRDBRuntime.verifyTOCPersistenceAcrossReopen()
    XCTAssertTrue(verified)
  }
}
