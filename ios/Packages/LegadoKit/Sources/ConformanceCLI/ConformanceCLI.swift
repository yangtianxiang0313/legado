import Foundation

@main
struct ConformanceCommand {
  static func main() async throws {
    guard CommandLine.arguments.count == 2 else {
      throw ConformanceCommandError.usage
    }
    let output = try await ConformanceRunner.run(
      fixtureDirectory: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    )
    FileHandle.standardOutput.write(output)
    FileHandle.standardOutput.write(Data([10]))
  }
}

enum ConformanceCommandError: String, Error {
  case usage = "usage: ConformanceCLI <fixture-directory>"
}
