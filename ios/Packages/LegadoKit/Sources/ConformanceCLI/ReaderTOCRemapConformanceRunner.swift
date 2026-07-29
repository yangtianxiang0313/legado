import Foundation
import LegadoCore
import TestSupport

struct ReaderTOCRemapConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum ReaderTOCRemapConformanceRunner {
  static let fixtureID =
    ReaderTOCRemapFixtureProjection.fixtureID

  static func run(
    fixtureDirectory: URL
  ) throws -> ReaderTOCRemapConformanceRun {
    do {
      let run = try ReaderTOCRemapFixtureProjection.run(
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
      return ReaderTOCRemapConformanceRun(
        artifact: run.artifact,
        requestPlan: run.requestPlan
      )
    } catch {
      throw MinimalTaskConformanceError.invalidFixture
    }
  }
}
