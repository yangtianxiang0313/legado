import Foundation

/// URL state carried by Android's `AnalyzeRule` across consecutive rule
/// evaluations. Updating content does not clear either URL.
public struct SourceRuleURLContext: Sendable, Equatable {
  public private(set) var baseURL: String?
  public private(set) var redirectURL: URL?

  public init(baseURL: String? = nil, redirectURL: URL? = nil) {
    self.baseURL = baseURL
    self.redirectURL = redirectURL
  }

  /// Android retains the previous base URL when the new value is null.
  public mutating func setBaseURL(_ value: String?) {
    guard let value else { return }
    baseURL = value
  }

  /// Android retains the previous redirect URL when parsing the new value
  /// fails.
  public mutating func setRedirectURL(_ value: String?) {
    guard
      let value,
      let parsed = URL(string: value),
      let scheme = parsed.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      parsed.host != nil
    else { return }
    redirectURL = parsed
  }

  public func absoluteString(_ value: String) -> String {
    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return baseURL ?? ""
    }
    return resolve(value)
  }

  public func absoluteList(_ values: [String]) -> [String] {
    var result: [String] = []
    for value in values {
      let resolved = resolve(value)
      guard !resolved.isEmpty, !result.contains(resolved) else { continue }
      result.append(resolved)
    }
    return result
  }

  private func resolve(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let redirectURL else { return trimmed }
    let lowercased = trimmed.lowercased()
    if lowercased.hasPrefix("http://")
      || lowercased.hasPrefix("https://")
      || lowercased.hasPrefix("data:")
    {
      return trimmed
    }
    if lowercased.hasPrefix("javascript") {
      return ""
    }
    return URL(string: value, relativeTo: redirectURL)?
      .absoluteURL.absoluteString
      ?? trimmed
  }
}
