import Foundation
import LegadoCore
import TestSupport

struct ReaderBookmarkConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum ReaderBookmarkConformanceRunner {
  static let fixtureID =
    ReaderBookmarkFixtureProjection.fixtureID

  static func run(
    fixtureDirectory: URL
  ) throws -> ReaderBookmarkConformanceRun {
    do {
      let run = try ReaderBookmarkFixtureProjection.run(
        caseData: Data(
          contentsOf:
            fixtureDirectory.appendingPathComponent("case.json"),
          options: [.mappedIfSafe]
        ),
        inputData: Data(
          contentsOf:
            fixtureDirectory.appendingPathComponent("input.json"),
          options: [.mappedIfSafe]
        )
      )
      return ReaderBookmarkConformanceRun(
        artifact: run.artifact,
        requestPlan: run.requestPlan
      )
    } catch {
      throw MinimalTaskConformanceError.invalidFixture
    }
  }
}
