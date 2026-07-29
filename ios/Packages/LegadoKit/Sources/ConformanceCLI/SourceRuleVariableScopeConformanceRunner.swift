import Foundation
import LegadoCore
import SourceRuntime

struct SourceRuleVariableScopeConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum SourceRuleVariableScopeConformanceRunner {
  static let fixtureID = "sl-source-session-rule-variable-scope-001"

  static func run(
    fixtureDirectory: URL
  ) async throws -> SourceRuleVariableScopeConformanceRun {
    let caseDocument = try json(
      at: fixtureDirectory.appendingPathComponent("case.json")
    )
    let inputDocument = try json(
      at: fixtureDirectory.appendingPathComponent("input.json")
    )
    guard
      case .object(let caseRoot) = caseDocument,
      caseRoot["id"] == .string(fixtureID),
      case .object(let determinism)? = caseRoot["determinism"],
      case .string(let origin)? = determinism["logical_origin"],
      case .object(let inputRoot) = inputDocument,
      case .array(let inputCases)? = inputRoot["cases"]
    else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }

    var plans: [JSONValue] = []
    var cases: [JSONValue] = []
    for value in inputCases {
      guard
        case .object(let inputCase) = value,
        case .string(let id)? = inputCase["id"],
        inputCase["operation"] == .string("rule_variable_scope"),
        case .object(let arguments)? = inputCase["arguments"],
        case .object(let request)? = inputCase["request"],
        request["method"] == .string("GET"),
        case .string(let target)? = request["target"],
        target.hasPrefix("/")
      else {
        throw SourcePipelineConformanceError.invalidSourceDefinition
      }
      plans.append(requestPlanValue(url: origin + target))
      cases.append(
        .object([
          "id": .string(id),
          "operation": .string("rule_variable_scope"),
          "result": try await projection(
            id: id,
            arguments: arguments,
            origin: origin
          ),
          "issue": .null,
        ])
      )
    }

    let canonicalPlans = JSONValue.array(plans)
    let artifact = JSONValue.object([
      "schema_version": .number(JSONNumber(1)),
      "fixture_id": .string(fixtureID),
      "engine": .object([
        "platform": .string("ios"),
        "revision": .string("conformance-source-runtime-v2"),
        "compatibility_profile": .string("android-legado-v1"),
      ]),
      "request_plan": canonicalPlans,
      "decode": .null,
      "stages": .array([]),
      "result": .object([
        "type": .string("source_pipeline"),
        "value": .object([
          "portable_known_projection": .object([
            "cases": .array(cases)
          ])
        ]),
      ]),
      "issues": .array([]),
    ])
    return SourceRuleVariableScopeConformanceRun(
      artifact: artifact,
      requestPlan: canonicalPlans
    )
  }

  private static func projection(
    id: String,
    arguments: [String: JSONValue],
    origin: String
  ) async throws -> JSONValue {
    switch try string("mode", in: arguments) {
    case "storage_boundary":
      return try await storageBoundary(arguments)
    case "analyze_rule_priority":
      return try await priority(
        arguments,
        role: .rule,
        writeValue: "via-analyze-rule"
      )
    case "analyze_url_priority":
      return try await priority(
        arguments,
        role: .url,
        writeValue: "via-analyze-url"
      )
    case "rule_script_propagation":
      return try await ruleScriptPropagation(arguments)
    case "url_script_propagation":
      return try await urlScriptPropagation(
        arguments,
        origin: origin
      )
    case "failure_mutation":
      return try await failureMutation(arguments)
    case "independent_contexts":
      return try await independentContexts(arguments)
    default:
      _ = id
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
  }

  private static func storageBoundary(
    _ arguments: [String: JSONValue]
  ) async throws -> JSONValue {
    let store = SourceVariableStore(policy: .androidRuleData)
    let key = try string("key", in: arguments)
    let smallLength = try integer("small_length", in: arguments)
    let largeLength = try integer("large_length", in: arguments)
    let small = await store.put(
      key,
      value: String(repeating: "s", count: smallLength)
    )
    let observedSmallLength = await store.get(key).count
    let large = await store.put(
      key,
      value: String(repeating: "l", count: largeLength)
    )
    let observedLargeLength = await store.get(key).count
    let removed = await store.put(key, value: nil)
    let afterRemoval = await store.get(key)
    let serialized = try await store.androidSerializedVariables()
    return .object([
      "small_write_returned": .bool(small.acceptedInline),
      "small_value_length": number(observedSmallLength),
      "large_write_returned": .bool(large.acceptedInline),
      "large_value_length": number(observedLargeLength),
      "removal_returned": .bool(removed.acceptedInline),
      "value_after_removal": .string(afterRemoval),
      "serialized_after_removal":
        serialized.map(JSONValue.string) ?? .null,
    ])
  }

  private static func priority(
    _ arguments: [String: JSONValue],
    role: SourceVariableResolverRole,
    writeValue: String
  ) async throws -> JSONValue {
    let key = try string("key", in: arguments)
    let chapter = SourceVariableStore()
    let book = SourceVariableStore()
    let source = SourceVariableStore()
    await source.put(
      key,
      value: try string("source_value", in: arguments)
    )
    await source.put("source-only", value: "source-only-value")
    await book.put(
      key,
      value: try string("book_value", in: arguments)
    )
    await book.put("empty-fallback", value: "book-fallback")
    await book.put("bookName", value: "variable-book-name")
    await chapter.put(
      key,
      value: try string("chapter_value", in: arguments)
    )
    await chapter.put("empty-fallback", value: "")
    await chapter.put("title", value: "variable-chapter-title")
    let resolver = SourceVariableResolver(
      role: role,
      scopes: SourceVariableScopes(
        chapter: chapter,
        book: role == .rule ? book : nil,
        ruleData: book,
        source: source,
        bookName: try string("book_name", in: arguments),
        chapterTitle: try string("chapter_title", in: arguments)
      )
    )
    let priorityValue = await resolver.get(key)
    let emptyFallback = await resolver.get("empty-fallback")
    let sourceFallback = await resolver.get("source-only")
    let bookName = await resolver.get("bookName")
    let chapterTitle = await resolver.get("title")
    let returned = await resolver.put("written", value: writeValue)
    let chapterWrite = await chapter.get("written")
    let bookWrite = await book.get("written")
    let sourceWrite = await source.get("written")
    return .object([
      "priority_value": .string(priorityValue),
      "empty_chapter_falls_back": .string(emptyFallback),
      "source_fallback": .string(sourceFallback),
      "book_name": .string(bookName),
      "chapter_title": .string(chapterTitle),
      "write_return": .string(returned),
      "chapter_write": .string(chapterWrite),
      "book_write": .string(bookWrite),
      "source_write": .string(sourceWrite),
    ])
  }

  private static func ruleScriptPropagation(
    _ arguments: [String: JSONValue]
  ) async throws -> JSONValue {
    let key = try string("key", in: arguments)
    let value = try string("value", in: arguments)
    let shared = SourceVariableStore(policy: .androidRuleData)
    let script = SourceVariableResolver(
      role: .rule,
      scopes: SourceVariableScopes(ruleData: shared)
    )
    let later = SourceVariableResolver(
      role: .rule,
      scopes: SourceVariableScopes(ruleData: shared)
    )
    let isolated = SourceVariableResolver(
      role: .rule,
      scopes: SourceVariableScopes(
        ruleData: SourceVariableStore(policy: .androidRuleData)
      )
    )
    let scriptValue = await script.put(key, value: value)
    let laterValue = await later.get(key)
    let isolatedValue = await isolated.get(key)
    let serialized = try await shared.androidSerializedVariables()
    return .object([
      "script_value": .string(scriptValue),
      "later_field_value": .string(laterValue),
      "isolated_field_value": .string(isolatedValue),
      "serialized_variables":
        serialized.map(JSONValue.string) ?? .null,
    ])
  }

  private static func urlScriptPropagation(
    _ arguments: [String: JSONValue],
    origin: String
  ) async throws -> JSONValue {
    let key = try string("key", in: arguments)
    let value = try string("value", in: arguments)
    let shared = SourceVariableStore(policy: .androidRuleData)
    let first = SourceVariableResolver(
      role: .url,
      scopes: SourceVariableScopes(ruleData: shared)
    )
    let second = SourceVariableResolver(
      role: .url,
      scopes: SourceVariableScopes(ruleData: shared)
    )
    _ = await first.put(key, value: value)
    let stored = await shared.get(key)
    let propagated = await second.get(key)
    return .object([
      "first_url": .string(origin + "/variables/url-written"),
      "second_url":
        .string(origin + "/variables/url-read/" + propagated),
      "stored_value": .string(stored),
    ])
  }

  private static func failureMutation(
    _ arguments: [String: JSONValue]
  ) async throws -> JSONValue {
    enum ExpectedFailure: Error {
      case script
    }
    let shared = SourceVariableStore(policy: .androidRuleData)
    let resolver = SourceVariableResolver(
      role: .rule,
      scopes: SourceVariableScopes(ruleData: shared)
    )
    let ruleKey = try string("rule_key", in: arguments)
    let urlKey = try string("url_key", in: arguments)
    let value = try string("value", in: arguments)
    let ruleThrew = await writeThenFail(
      resolver: resolver,
      key: ruleKey,
      value: value,
      failure: ExpectedFailure.script
    )
    let urlThrew = await writeThenFail(
      resolver: resolver,
      key: urlKey,
      value: value,
      failure: ExpectedFailure.script
    )
    let ruleValue = await shared.get(ruleKey)
    let urlValue = await shared.get(urlKey)
    return .object([
      "rule_threw": .bool(ruleThrew),
      "rule_value_after_failure": .string(ruleValue),
      "url_threw": .bool(urlThrew),
      "url_value_after_failure": .string(urlValue),
    ])
  }

  private static func writeThenFail(
    resolver: SourceVariableResolver,
    key: String,
    value: String,
    failure: any Error
  ) async -> Bool {
    do {
      _ = await resolver.put(key, value: value)
      throw failure
    } catch {
      return true
    }
  }

  private static func independentContexts(
    _ arguments: [String: JSONValue]
  ) async throws -> JSONValue {
    let key = try string("key", in: arguments)
    let leftValue = try string("left_value", in: arguments)
    let rightValue = try string("right_value", in: arguments)
    let leftStore = SourceVariableStore(policy: .androidRuleData)
    let rightStore = SourceVariableStore(policy: .androidRuleData)
    let left = SourceVariableResolver(
      role: .rule,
      scopes: SourceVariableScopes(ruleData: leftStore)
    )
    let right = SourceVariableResolver(
      role: .rule,
      scopes: SourceVariableScopes(ruleData: rightStore)
    )
    async let leftWrite = left.put(key, value: leftValue)
    async let rightWrite = right.put(key, value: rightValue)
    let (observedLeft, observedRight) = await (leftWrite, rightWrite)
    let leftStorage = await leftStore.get(key)
    let rightStorage = await rightStore.get(key)
    return .object([
      "left_value": .string(observedLeft),
      "right_value": .string(observedRight),
      "left_storage": .string(leftStorage),
      "right_storage": .string(rightStorage),
      "storage_identity_distinct":
        .bool(ObjectIdentifier(leftStore) != ObjectIdentifier(rightStore)),
    ])
  }

  private static func requestPlanValue(url: String) -> JSONValue {
    .object([
      "method": .string("GET"),
      "url": .string(url),
      "headers": .array([]),
      "body": .null,
      "timeout_ms": .null,
    ])
  }

  private static func string(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> String {
    guard case .string(let value)? = object[key] else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    return value
  }

  private static func integer(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> Int {
    guard
      case .number(let value)? = object[key],
      let result = Int(value.rawToken),
      result >= 0
    else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    return result
  }

  private static func number(_ value: Int) -> JSONValue {
    .number(JSONNumber(Int64(value)))
  }

  private static func json(at url: URL) throws -> JSONValue {
    try JSONValueCodec.decode(
      Data(contentsOf: url, options: [.mappedIfSafe])
    )
  }
}
