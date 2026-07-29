import Foundation
import LegadoCore
import TestSupport

struct ReaderProgressConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum ReaderProgressConformanceRunner {
  static let fixtureID =
    ReaderProgressFixtureProjection.fixtureID

  static func run(
    fixtureDirectory: URL
  ) throws -> ReaderProgressConformanceRun {
    do {
      let run = try ReaderProgressFixtureProjection.run(
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
      return ReaderProgressConformanceRun(
        artifact: run.artifact,
        requestPlan: run.requestPlan
      )
    } catch {
      throw MinimalTaskConformanceError.invalidFixture
    }
  }
}
