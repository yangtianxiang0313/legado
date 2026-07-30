import Foundation

struct SourceVariableHTMLRuleEvaluator {
  let document: HTMLDocument
  let node: HTMLNode
  let resolver: SourceVariableResolver
  let scriptRuntime: (any SourceScriptRuntime)?
  let scriptSessionID: SourceScriptSessionID?
  let scriptLibrary: SourceScriptLibrary?
  let baseURL: String?

  init(
    document: HTMLDocument,
    node: HTMLNode,
    resolver: SourceVariableResolver,
    scriptRuntime: (any SourceScriptRuntime)? = nil,
    scriptSessionID: SourceScriptSessionID? = nil,
    scriptLibrary: SourceScriptLibrary? = nil,
    baseURL: String? = nil
  ) {
    self.document = document
    self.node = node
    self.resolver = resolver
    self.scriptRuntime = scriptRuntime
    self.scriptSessionID = scriptSessionID
    self.scriptLibrary = scriptLibrary
    self.baseURL = baseURL
  }

  func string(_ rule: HTMLCSSRule) async throws -> String? {
    (try await strings(rule)).first
  }

  func strings(_ rule: HTMLCSSRule) async throws -> [String] {
    let executionRule = try await prepare(rule)
    guard !executionRule.isEmpty else { return [] }
    if
      executionRule.lowercased().hasPrefix("@js:")
        || executionRule.lowercased().hasPrefix("<js>")
    {
      let value = try await SourceVariableRuleEvaluator(
        content: node.normalizedText,
        resolver: resolver,
        scriptRuntime: scriptRuntime,
        scriptSessionID: scriptSessionID,
        scriptLibrary: scriptLibrary,
        baseURL: baseURL
      ).getString(executionRule)
      return value.isEmpty ? [] : [value]
    }
    let matches = try document.select(
        HTMLCSSRule(executionRule).cssSelector,
        within: node
      )
    return matches.compactMap { match in
      let raw: String?
      switch rule.value {
      case .text, .html:
        raw = match.normalizedText
      case .href:
        raw = match.attributes["href"]
      case .src:
        raw = match.attributes["src"]
      }
      let value = raw?.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      return value?.isEmpty == false ? value : nil
    }
  }

  func prepare(_ rule: HTMLCSSRule) async throws -> String {
    let plan = SourceVariableRulePlan.parse(rule.selector)
    for key in plan.writes.keys.sorted() {
      let value =
        try await string(
          HTMLCSSRule(plan.writes[key] ?? "")
        ) ?? ""
      _ = await resolver.put(key, value: value)
    }
    return plan.executionRule
  }

  func elements(_ rule: String) async throws -> [HTMLNode] {
    let plan = SourceVariableRulePlan.parse(rule)
    for key in plan.writes.keys.sorted() {
      let value =
        try await string(
          HTMLCSSRule(plan.writes[key] ?? "")
        ) ?? ""
      _ = await resolver.put(key, value: value)
    }
    guard !plan.executionRule.isEmpty else { return [] }
    return try document.select(
      HTMLCSSRule(plan.executionRule).cssSelector,
      within: node
    )
  }
}
