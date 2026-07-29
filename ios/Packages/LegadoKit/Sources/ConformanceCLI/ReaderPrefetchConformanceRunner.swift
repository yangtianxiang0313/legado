import Foundation
import LegadoCore
import TestSupport

struct ReaderPrefetchConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum ReaderPrefetchConformanceRunner {
  static let fixtureID =
    ReaderPrefetchFixtureProjection.fixtureID

  static func run(
    fixtureDirectory: URL
  ) throws -> ReaderPrefetchConformanceRun {
    do {
      let run = try ReaderPrefetchFixtureProjection.run(
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
      return ReaderPrefetchConformanceRun(
        artifact: run.artifact,
        requestPlan: run.requestPlan
      )
    } catch {
      throw MinimalTaskConformanceError.invalidFixture
    }
  }
}
