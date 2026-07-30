import Foundation

public enum SourceVariableStoragePolicy: Equatable, Sendable {
  case unbounded
  case androidRuleData(inlineLimit: Int)

  public static let androidRuleData = Self.androidRuleData(
    inlineLimit: 10_000
  )
}

public struct SourceVariableWriteResult: Equatable, Sendable {
  public let acceptedInline: Bool
  public let stored: Bool

  public init(acceptedInline: Bool, stored: Bool) {
    self.acceptedInline = acceptedInline
    self.stored = stored
  }
}

public actor SourceVariableStore {
  private let policy: SourceVariableStoragePolicy
  private var values: [String: String]

  public init(
    policy: SourceVariableStoragePolicy = .unbounded,
    values: [String: String] = [:]
  ) {
    self.policy = policy
    self.values = values
  }

  @discardableResult
  public func put(
    _ key: String,
    value: String?
  ) -> SourceVariableWriteResult {
    guard let value else {
      values.removeValue(forKey: key)
      return SourceVariableWriteResult(
        acceptedInline: true,
        stored: false
      )
    }
    values[key] = value
    let acceptedInline: Bool
    switch policy {
    case .unbounded:
      acceptedInline = true
    case .androidRuleData(let inlineLimit):
      acceptedInline = value.count < inlineLimit
    }
    return SourceVariableWriteResult(
      acceptedInline: acceptedInline,
      stored: true
    )
  }

  public func get(_ key: String) -> String {
    values[key] ?? ""
  }

  public func snapshot() -> [String: String] {
    values
  }

  public func androidSerializedVariables() throws -> String? {
    guard !values.isEmpty else {
      return nil
    }
    let fields = try values.keys.sorted().map { key in
      "  \(try Self.jsonString(key)): "
        + "\(try Self.jsonString(values[key] ?? ""))"
    }
    return "{\n" + fields.joined(separator: ",\n") + "\n}"
  }

  private static func jsonString(_ value: String) throws -> String {
    let data = try JSONSerialization.data(
      withJSONObject: value,
      options: [.fragmentsAllowed]
    )
    guard let encoded = String(data: data, encoding: .utf8) else {
      throw SourceVariableError.encodingFailed
    }
    return encoded
  }
}

public enum SourceVariableResolverRole: Equatable, Sendable {
  case rule
  case url
}

public struct SourceVariableScopes: Sendable {
  public let chapter: SourceVariableStore?
  public let book: SourceVariableStore?
  public let ruleData: SourceVariableStore?
  public let source: SourceVariableStore?
  public let bookName: String?
  public let chapterTitle: String?

  public init(
    chapter: SourceVariableStore? = nil,
    book: SourceVariableStore? = nil,
    ruleData: SourceVariableStore? = nil,
    source: SourceVariableStore? = nil,
    bookName: String? = nil,
    chapterTitle: String? = nil
  ) {
    self.chapter = chapter
    self.book = book
    self.ruleData = ruleData
    self.source = source
    self.bookName = bookName
    self.chapterTitle = chapterTitle
  }
}

public struct SourceVariableResolver: Sendable {
  public let role: SourceVariableResolverRole
  public let scopes: SourceVariableScopes

  public init(
    role: SourceVariableResolverRole,
    scopes: SourceVariableScopes
  ) {
    self.role = role
    self.scopes = scopes
  }

  public func get(_ key: String) async -> String {
    switch key {
    case "bookName":
      if let value = scopes.bookName {
        return value
      }
    case "title":
      if let value = scopes.chapterTitle {
        return value
      }
    default:
      break
    }
    for store in readOrder {
      let value = await store.get(key)
      if !value.isEmpty {
        return value
      }
    }
    return ""
  }

  @discardableResult
  public func put(_ key: String, value: String) async -> String {
    if let store = writeTarget {
      await store.put(key, value: value)
    }
    return value
  }

  public func snapshot() async -> [String: String] {
    var result: [String: String] = [:]
    for store in readOrder.reversed() {
      for (key, value) in await store.snapshot() where !value.isEmpty {
        result[key] = value
      }
    }
    if let bookName = scopes.bookName {
      result["bookName"] = bookName
    }
    if let chapterTitle = scopes.chapterTitle {
      result["title"] = chapterTitle
    }
    return result
  }

  private var readOrder: [SourceVariableStore] {
    switch role {
    case .rule:
      return unique([
        scopes.chapter,
        scopes.book,
        scopes.ruleData,
        scopes.source,
      ])
    case .url:
      return unique([
        scopes.chapter,
        scopes.ruleData,
      ])
    }
  }

  private var writeTarget: SourceVariableStore? {
    switch role {
    case .rule:
      return scopes.chapter
        ?? scopes.book
        ?? scopes.ruleData
        ?? scopes.source
    case .url:
      return scopes.chapter
        ?? scopes.ruleData
    }
  }

  private func unique(
    _ stores: [SourceVariableStore?]
  ) -> [SourceVariableStore] {
    var identities: Set<ObjectIdentifier> = []
    var result: [SourceVariableStore] = []
    for store in stores.compactMap({ $0 }) {
      let identity = ObjectIdentifier(store)
      if identities.insert(identity).inserted {
        result.append(store)
      }
    }
    return result
  }
}

public enum SourceVariableError: Error, Equatable, Sendable {
  case encodingFailed
}
