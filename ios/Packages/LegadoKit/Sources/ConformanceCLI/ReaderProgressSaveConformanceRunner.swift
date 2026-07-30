import Foundation
import LegadoCore
import TestSupport

struct ReaderProgressSaveConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum ReaderProgressSaveConformanceRunner {
  static let fixtureID =
    ReaderProgressSaveFixtureProjection.fixtureID

  static func run(
    fixtureDirectory: URL
  ) throws -> ReaderProgressSaveConformanceRun {
    do {
      let run = try ReaderProgressSaveFixtureProjection.run(
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
      return ReaderProgressSaveConformanceRun(
        artifact: run.artifact,
        requestPlan: run.requestPlan
      )
    } catch {
      throw MinimalTaskConformanceError.invalidFixture
    }
  }
}
