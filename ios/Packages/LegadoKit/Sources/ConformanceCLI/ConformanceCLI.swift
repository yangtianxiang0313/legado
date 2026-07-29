import Foundation

@main
struct ConformanceCommand {
  static func main() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let output: Data
    if arguments.count == 1 {
      output = try await ConformanceRunner.run(
        fixtureDirectory: URL(fileURLWithPath: arguments[0], isDirectory: true)
      )
    } else if arguments.count == 2, arguments[0] == "run-work-item" {
      output = try await ConformanceWorkItemRunner.run(workItemID: arguments[1])
    } else if arguments.count == 2, arguments[0] == "run-task" {
      let run = try await MinimalTaskConformanceRunner.run(
        taskPath: arguments[1]
      )
      output = run.data
      FileHandle.standardOutput.write(output)
      FileHandle.standardOutput.write(Data([10]))
      if !run.passed {
        throw ConformanceCommandError.comparisonFailed
      }
      return
    } else {
      throw ConformanceCommandError.usage
    }
    FileHandle.standardOutput.write(output)
    FileHandle.standardOutput.write(Data([10]))
  }
}

enum ConformanceCommandError: String, Error {
  case usage =
    "usage: ConformanceCLI <fixture-directory> | run-work-item <work-item-id> | run-task <task-path>"
  case comparisonFailed = "structured comparison failed"
}
