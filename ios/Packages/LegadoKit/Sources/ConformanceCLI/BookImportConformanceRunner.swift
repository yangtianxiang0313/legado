import Foundation
import LegadoCore
import TestSupport

struct BookImportConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum BookImportConformanceRunner {
  static let fixtureID = BookImportFixtureProjection.fixtureID

  static func run(
    fixtureDirectory: URL
  ) throws -> BookImportConformanceRun {
    do {
      let run = try BookImportFixtureProjection.run(
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
      return BookImportConformanceRun(
        artifact: run.artifact,
        requestPlan: run.requestPlan
      )
    } catch {
      throw MinimalTaskConformanceError.invalidFixture
    }
  }
}
