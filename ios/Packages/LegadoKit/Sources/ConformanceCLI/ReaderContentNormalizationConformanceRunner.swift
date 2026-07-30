import Foundation
import LegadoCore
import ReaderCore

struct ReaderContentNormalizationConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum ReaderContentNormalizationConformanceRunner {
  static let fixtureID =
    "rl-reader-content-display-normalization-001"

  static func run(
    fixtureDirectory: URL
  ) throws -> ReaderContentNormalizationConformanceRun {
    let caseDocument = try json(
      at: fixtureDirectory.appendingPathComponent("case.json")
    )
    let inputDocument = try json(
      at: fixtureDirectory.appendingPathComponent("input.json")
    )
    guard
      case .object(let caseRoot) = caseDocument,
      caseRoot["id"] == .string(fixtureID),
      caseRoot["kind"] == .string("android_runtime_scenario"),
      caseRoot["operation"] == .string("android_runtime"),
      case .object(let inputRoot) = inputDocument,
      case .array(let inputCases)? = inputRoot["cases"]
    else {
      throw MinimalTaskConformanceError.invalidFixture
    }

    var identifiers: Set<String> = []
    var plans: [JSONValue] = []
    var cases: [JSONValue] = []
    for value in inputCases {
      guard
        case .object(let inputCase) = value,
        case .string(let id)? = inputCase["id"],
        identifiers.insert(id).inserted,
        inputCase["operation"]
          == .string("reader_content_normalization"),
        case .object(let arguments)? = inputCase["arguments"]
      else {
        throw MinimalTaskConformanceError.invalidFixture
      }
      plans.append(
        .object([
          "operation": .string("reader_content_normalization"),
          "arguments": .object(arguments),
        ])
      )
      cases.append(
        .object([
          "id": .string(id),
          "operation": .string("reader_content_normalization"),
          "result": try projection(arguments),
          "issue": .null,
        ])
      )
    }

    let requestPlan = JSONValue.array(plans)
    return ReaderContentNormalizationConformanceRun(
      artifact: .object([
        "schema_version": number(1),
        "fixture_id": .string(fixtureID),
        "engine": .object([
          "platform": .string("ios"),
          "revision": .string("reader-content-normalization-v1"),
          "compatibility_profile": .string("android-legado-v1"),
        ]),
        "request_plan": requestPlan,
        "decode": .null,
        "stages": .array([]),
        "result": .object([
          "type": .string("reader_runtime"),
          "value": .object([
            "portable_known_projection": .object([
              "cases": .array(cases)
            ])
          ]),
        ]),
        "issues": .array([]),
      ]),
      requestPlan: requestPlan
    )
  }

  private static func projection(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let title = try string("title", arguments)
    let content = try string("content", arguments)
    let includeTitle = try boolean("include_title", arguments)
    let useReplacement = try boolean("use_replace", arguments)
    let paragraphIndent = try string("paragraph_indent", arguments)
    let bookName = try optionalString("book_name", arguments)
      ?? "归一化测试书"
    let bookOrigin = try optionalString("book_origin", arguments)
      ?? "android-runtime://normalization"
    guard case .array(let ruleValues)? = arguments["rules"] else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    let rules = try ruleValues.enumerated().map { index, value in
      guard case .object(let rule) = value else {
        throw MinimalTaskConformanceError.invalidFixture
      }
      return ReaderContentReplacementRule(
        name: try string("name", rule),
        pattern: try string("pattern", rule),
        replacement: try string("replacement", rule),
        scope: try optionalString("scope", rule),
        excludeScope: try optionalString("exclude_scope", rule),
        appliesToTitle: try optionalBoolean("scope_title", rule) ?? false,
        appliesToContent:
          try optionalBoolean("scope_content", rule) ?? true,
        isEnabled: try optionalBoolean("enabled", rule) ?? true,
        isRegex: try optionalBoolean("is_regex", rule) ?? false,
        order: try optionalInteger("order", rule) ?? index
      )
    }
    let result = AndroidReaderContentNormalizationPolicy.normalize(
      ReaderContentNormalizationInput(
        bookName: bookName,
        bookOrigin: bookOrigin,
        chapterTitle: title,
        content: content,
        includeTitle: includeTitle,
        useReplacementRules: useReplacement,
        paragraphIndent: paragraphIndent,
        rules: rules
      )
    )
    return .object([
      "display_title": .string(result.displayTitle),
      "same_title_removed": .bool(result.sameTitleRemoved),
      "paragraphs": .array(result.paragraphs.map(JSONValue.string)),
      "rendered_text": .string(result.renderedText),
      "effective_rules":
        .array(result.effectiveRuleNames.map(JSONValue.string)),
    ])
  }

  private static func string(
    _ key: String,
    _ object: [String: JSONValue]
  ) throws -> String {
    guard case .string(let value)? = object[key] else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    return value
  }

  private static func boolean(
    _ key: String,
    _ object: [String: JSONValue]
  ) throws -> Bool {
    guard case .bool(let value)? = object[key] else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    return value
  }

  private static func optionalString(
    _ key: String,
    _ object: [String: JSONValue]
  ) throws -> String? {
    switch object[key] {
    case .string(let value):
      return value
    case .null, nil:
      return nil
    default:
      throw MinimalTaskConformanceError.invalidFixture
    }
  }

  private static func optionalBoolean(
    _ key: String,
    _ object: [String: JSONValue]
  ) throws -> Bool? {
    switch object[key] {
    case .bool(let value):
      return value
    case nil:
      return nil
    default:
      throw MinimalTaskConformanceError.invalidFixture
    }
  }

  private static func optionalInteger(
    _ key: String,
    _ object: [String: JSONValue]
  ) throws -> Int? {
    switch object[key] {
    case .number(let value):
      guard let integer = Int(value.rawToken) else {
        throw MinimalTaskConformanceError.invalidFixture
      }
      return integer
    case nil:
      return nil
    default:
      throw MinimalTaskConformanceError.invalidFixture
    }
  }

  private static func number(_ value: Int) -> JSONValue {
    .number(JSONNumber(Int64(value)))
  }

  private static func json(at url: URL) throws -> JSONValue {
    do {
      return try JSONValueCodec.decode(
        Data(contentsOf: url, options: [.mappedIfSafe])
      )
    } catch {
      throw MinimalTaskConformanceError.invalidFixture
    }
  }
}
