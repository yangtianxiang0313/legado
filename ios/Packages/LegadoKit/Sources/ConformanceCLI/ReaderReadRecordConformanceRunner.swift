import Foundation
import LegadoCore
import TestSupport

struct ReaderReadRecordConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum ReaderReadRecordConformanceRunner {
  static let fixtureID =
    ReaderReadRecordFixtureProjection.fixtureID

  static func run(
    fixtureDirectory: URL
  ) throws -> ReaderReadRecordConformanceRun {
    do {
      let run = try ReaderReadRecordFixtureProjection.run(
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
      return ReaderReadRecordConformanceRun(
        artifact: run.artifact,
        requestPlan: run.requestPlan
      )
    } catch {
      throw MinimalTaskConformanceError.invalidFixture
    }
  }
}
