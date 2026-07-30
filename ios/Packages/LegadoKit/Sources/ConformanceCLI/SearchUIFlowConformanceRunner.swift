import Foundation
import LegadoCore
import TestSupport

struct SearchUIFlowConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum SearchUIFlowConformanceRunner {
  static let fixtureID = SearchUIFlowFixtureProjection.fixtureID

  static func run(
    fixtureDirectory: URL
  ) throws -> SearchUIFlowConformanceRun {
    do {
      let run = try SearchUIFlowFixtureProjection.run(
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
      return SearchUIFlowConformanceRun(
        artifact: run.artifact,
        requestPlan: run.requestPlan
      )
    } catch {
      throw MinimalTaskConformanceError.invalidFixture
    }
  }
}
