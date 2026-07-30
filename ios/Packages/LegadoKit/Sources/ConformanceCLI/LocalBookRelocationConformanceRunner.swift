import Foundation
import LegadoCore
import TestSupport

struct LocalBookRelocationConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum LocalBookRelocationConformanceRunner {
  static let fixtureID =
    LocalBookRelocationFixtureProjection.fixtureID

  static func run(
    fixtureDirectory: URL
  ) throws -> LocalBookRelocationConformanceRun {
    do {
      let run = try LocalBookRelocationFixtureProjection.run(
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
      return LocalBookRelocationConformanceRun(
        artifact: run.artifact,
        requestPlan: run.requestPlan
      )
    } catch {
      throw MinimalTaskConformanceError.invalidFixture
    }
  }
}
