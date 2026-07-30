import Foundation
import LegadoCore
import TestSupport

struct BookDetailActionConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum BookDetailActionConformanceRunner {
  static let fixtureID = BookDetailActionFixtureProjection.fixtureID

  static func run(
    fixtureDirectory: URL
  ) throws -> BookDetailActionConformanceRun {
    do {
      let run = try BookDetailActionFixtureProjection.run(
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
      return BookDetailActionConformanceRun(
        artifact: run.artifact,
        requestPlan: run.requestPlan
      )
    } catch {
      throw MinimalTaskConformanceError.invalidFixture
    }
  }
}
