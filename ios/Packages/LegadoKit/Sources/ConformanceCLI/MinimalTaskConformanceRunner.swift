import Foundation
import LegadoCore
import SourceRuntime
import TestSupport

public struct MinimalTaskConformanceRun: Sendable {
  public let data: Data
  public let passed: Bool
}

public enum MinimalTaskConformanceError: String, Error, Sendable {
  case invalidTask = "invalid_task"
  case invalidFixture = "invalid_fixture"
  case invalidGolden = "invalid_golden"
  case pathEscapesRepository = "path_escapes_repository"
  case comparisonFailed = "comparison_failed"
}

public enum MinimalTaskConformanceRunner {
  public static func run(
    taskPath: String,
    repositoryRoot: URL = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true
    )
  ) async throws -> MinimalTaskConformanceRun {
    let root = repositoryRoot.standardizedFileURL.resolvingSymlinksInPath()
    let task = try json(
      at: resolve(taskPath, root: root),
      error: .invalidTask
    )
    guard
      case .object(let taskRoot) = task,
      taskRoot["schema_version"] == .number(JSONNumber(2)),
      case .string(let taskID)? = taskRoot["id"],
      case .object(let source)? = taskRoot["source"],
      case .string(let fixtureID)? = source["fixture_id"],
      case .string(let goldenPath)? = source["android_golden"]
    else {
      throw MinimalTaskConformanceError.invalidTask
    }
    let fixtureDirectory = try resolve(
      "ios/harness/fixtures/source-lab/\(fixtureID)",
      root: root
    )
    let loaded = try FixtureLoader.load(from: fixtureDirectory)
    guard loaded.definition.id == fixtureID else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    let input = try pipelineInput(
      at: fixtureDirectory.appendingPathComponent(loaded.definition.input)
    )
    let plans = try SourcePipelineConformanceRunner.compiledPlans(
      loaded,
      input: input
    )
    let actualArtifact = try JSONValueCodec.decode(
      await SourcePipelineConformanceRunner.run(
        loaded,
        input: input
      )
    )
    let golden = try json(
      at: resolve(goldenPath, root: root),
      error: .invalidGolden
    )
    guard
      case .object(let goldenRoot) = golden,
      goldenRoot["fixture_id"] == .string(fixtureID),
      case .object(let androidArtifact)? = goldenRoot["artifact"],
      androidArtifact["fixture_id"] == .string(fixtureID),
      case .object(let iosArtifact) = actualArtifact,
      iosArtifact["fixture_id"] == .string(fixtureID)
    else {
      throw MinimalTaskConformanceError.invalidGolden
    }
    let canonicalPlans = try requestPlanValue(
      loaded.requestCases,
      plans: plans
    )
    let androidExpected = try comparisonValue(
      artifact: androidArtifact,
      requestPlan: androidArtifact["request_plan"]
    )
    let iosActual = try comparisonValue(
      artifact: iosArtifact,
      requestPlan: canonicalPlans
    )
    let comparison = CanonicalJSONComparator.compare(
      expected: androidExpected,
      actual: iosActual
    )
    let passed: Bool
    let firstDivergence: JSONValue
    switch comparison {
    case .equal:
      passed = true
      firstDivergence = .null
    case .different(let difference):
      passed = false
      firstDivergence = .object([
        "kind": .string(difference.kind.rawValue),
        "json_pointer": .string(difference.jsonPointer),
      ])
    }
    let output = JSONValue.object([
      "schema_version": .number(JSONNumber(1)),
      "task_id": .string(taskID),
      "fixture_id": .string(fixtureID),
      "status": .string(passed ? "equal" : "different"),
      "android_expected": androidExpected,
      "ios_actual": iosActual,
      "canonical_request_plan": canonicalPlans,
      "first_divergence": firstDivergence,
    ])
    return MinimalTaskConformanceRun(
      data: try JSONValueCodec.encode(output),
      passed: passed
    )
  }

  private static func pipelineInput(at inputURL: URL) throws -> SourcePipelineInput {
    let value = try json(at: inputURL, error: .invalidFixture)
    guard
      case .object(let root) = value,
      case .array(let cases)? = root["cases"]
    else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    var result = SourcePipelineInput()
    var identifiers: Set<String> = []
    for value in cases {
      guard
        case .object(let inputCase) = value,
        case .string(let id)? = inputCase["id"],
        identifiers.insert(id).inserted,
        case .string(let operation)? = inputCase["operation"]
      else {
        throw MinimalTaskConformanceError.invalidFixture
      }
      let arguments: [String: JSONValue]
      if case .object(let value)? = inputCase["arguments"] {
        arguments = value
      } else {
        arguments = [:]
      }
      if operation == FixtureOperation.search.rawValue {
        guard
          case .string(let keyword)? = arguments["keyword"],
          result.searchKeywords.updateValue(keyword, forKey: id) == nil
        else {
          throw MinimalTaskConformanceError.invalidFixture
        }
      } else if operation == FixtureOperation.requestOptions.rawValue {
        guard
          case .string(let persistentCookie)? = arguments["persistent_cookie"],
          case .object(let option)? = arguments["option"],
          case .object(let rawHeaders)? = option["headers"]
        else {
          throw MinimalTaskConformanceError.invalidFixture
        }
        let headers = try rawHeaders.map { name, value -> SourceHeaderField in
          guard case .string(let stringValue) = value else {
            throw MinimalTaskConformanceError.invalidFixture
          }
          return try SourceHeaderField(name: name, value: stringValue)
        }
        let retry: Int
        if case .number(let number)? = option["retry"], let value = Int(number.rawToken) {
          retry = value
        } else if option["retry"] == nil {
          retry = 0
        } else {
          throw MinimalTaskConformanceError.invalidFixture
        }
        guard
          retry >= 0,
          result.requestOptions.updateValue(
            SourceRequestOptionInput(
              persistentCookie: persistentCookie,
              optionHeaders: headers,
              retry: retry
            ),
            forKey: id
          ) == nil
        else {
          throw MinimalTaskConformanceError.invalidFixture
        }
      } else if operation == FixtureOperation.fieldEncoding.rawValue {
        guard
          case .string(let methodText)? = arguments["method"],
          let method = HTTPMethod(rawValue: methodText),
          case .string(let fields)? = arguments["fields"]
        else {
          throw MinimalTaskConformanceError.invalidFixture
        }
        let charset: String?
        if case .string(let value)? = arguments["charset"] {
          charset = value
        } else if arguments["charset"] == nil {
          charset = nil
        } else {
          throw MinimalTaskConformanceError.invalidFixture
        }
        guard
          result.fieldEncodings.updateValue(
            SourceFieldEncodingInput(
              method: method,
              fields: fields,
              charset: charset
            ),
            forKey: id
          ) == nil
        else {
          throw MinimalTaskConformanceError.invalidFixture
        }
      }
    }
    return result
  }

  private static func requestPlanValue(
    _ requestCases: [FixtureRequestCase],
    plans: [String: SourceRequestPlan]
  ) throws -> JSONValue {
    .array(
      try requestCases.map { requestCase in
        guard let plan = plans[requestCase.id] else {
          throw MinimalTaskConformanceError.invalidFixture
        }
        let bodyData = plan.request.body?.bytes
        var value: [String: JSONValue] = [
          "method": .string(plan.request.method.rawValue),
          "url": .string(plan.request.url.absoluteString),
          "headers": .array(
            plan.request.headers.canonicalFields.map { header in
              .object([
                "name": .string(header.name),
                "value": .string(header.value),
              ])
            }
          ),
          "body": plan.body.map(JSONValue.string) ?? .null,
          "timeout_ms": plan.request.timeout.map {
            .number(JSONNumber(Int64($0.milliseconds)))
          } ?? .null,
        ]
        if requestCase.operation == .search {
          value["body_base64"] = bodyData.map {
            .string($0.base64EncodedString())
          } ?? .null
          value["form_fields"] = .array(
            plan.formFields.map { field in
              .object([
                "key": .string(field.key),
                "value": .string(field.value),
              ])
            }
          )
        }
        return .object(value)
      }
    )
  }

  private static func comparisonValue(
    artifact: [String: JSONValue],
    requestPlan: JSONValue?
  ) throws -> JSONValue {
    guard
      let requestPlan,
      case .object(let result)? = artifact["result"],
      result["type"] == .string("source_pipeline"),
      case .object(let value)? = result["value"],
      let projection = value["portable_known_projection"]
    else {
      throw MinimalTaskConformanceError.comparisonFailed
    }
    var comparison: [String: JSONValue] = [
      "request_plan": requestPlan,
      "portable_known_projection": projection,
    ]
    if let observation = value["source_lab_observation"] {
      comparison["source_lab_observation"] = observation
    } else if
      case .object(let characterization)? = value["android_characterization"],
      let observation = characterization["source_lab_observation"]
    {
      comparison["source_lab_observation"] = observation
    }
    return .object(comparison)
  }

  private static func json(
    at url: URL,
    error: MinimalTaskConformanceError
  ) throws -> JSONValue {
    do {
      return try JSONValueCodec.decode(
        Data(contentsOf: url, options: [.mappedIfSafe])
      )
    } catch {
      throw error
    }
  }

  private static func resolve(_ relative: String, root: URL) throws -> URL {
    let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
    guard
      !relative.isEmpty,
      !relative.hasPrefix("/"),
      !relative.contains("\\"),
      parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      throw MinimalTaskConformanceError.pathEscapesRepository
    }
    let candidate = root
      .appendingPathComponent(relative)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard candidate.path.hasPrefix(prefix) else {
      throw MinimalTaskConformanceError.pathEscapesRepository
    }
    return candidate
  }
}
