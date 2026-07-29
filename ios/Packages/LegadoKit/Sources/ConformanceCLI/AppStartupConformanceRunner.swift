import Foundation
import LegadoCore
import TestSupport

struct AppStartupConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum AppStartupConformanceRunner {
  static let fixtureID =
    AppStartupFixtureProjection.fixtureID

  static func run(
    fixtureDirectory: URL
  ) throws -> AppStartupConformanceRun {
    do {
      let run = try AppStartupFixtureProjection.run(
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
      return AppStartupConformanceRun(
        artifact: run.artifact,
        requestPlan: run.requestPlan
      )
    } catch {
      throw MinimalTaskConformanceError.invalidFixture
    }
  }
}
