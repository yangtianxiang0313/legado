import Foundation

public struct SourceExploreCategory: Sendable, Equatable {
  public let title: String
  public let urlTemplate: String?

  public init(title: String, urlTemplate: String?) {
    self.title = title
    self.urlTemplate = urlTemplate
  }
}

public struct SourceExploreDefinition: Sendable, Equatable {
  public let source: SourceSearchDefinition
  public let enabled: Bool
  public let catalog: String

  public init(
    source: SourceSearchDefinition,
    enabled: Bool,
    catalog: String
  ) {
    self.source = source
    self.enabled = enabled
    self.catalog = catalog
  }
}

public struct SourceExploreInput: Sendable, Equatable {
  public let category: SourceExploreCategory
  public let page: Int

  public init(category: SourceExploreCategory, page: Int) {
    self.category = category
    self.page = page
  }
}

public protocol SourceExploreResponseChecking: Sendable {
  func check(
    _ response: SourceSearchResponse,
    source: SourceExploreDefinition,
    input: SourceExploreInput
  ) async throws -> SourceSearchResponse
}

public struct IdentitySourceExploreResponseChecker:
  SourceExploreResponseChecking
{
  public init() {}

  public func check(
    _ response: SourceSearchResponse,
    source: SourceExploreDefinition,
    input: SourceExploreInput
  ) async throws -> SourceSearchResponse {
    response
  }
}

public enum SourceExplorePipelineError: Error, Sendable, Equatable {
  case disabled
  case missingCategoryURL
  case invalidCatalog
}

public enum SourceExploreCatalog {
  public static func parse(_ value: String) throws
    -> [SourceExploreCategory]
  {
    let trimmed = value.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !trimmed.isEmpty else { return [] }
    if trimmed.first == "[" {
      guard
        let data = trimmed.data(using: .utf8),
        let values = try? JSONDecoder().decode(
          [JSONCategory].self,
          from: data
        )
      else {
        throw SourceExplorePipelineError.invalidCatalog
      }
      return values.compactMap { value in
        let title = value.title.trimmingCharacters(
          in: .whitespacesAndNewlines
        )
        guard !title.isEmpty else { return nil }
        return SourceExploreCategory(
          title: title,
          urlTemplate: normalizedURL(value.url)
        )
      }
    }

    return trimmed
      .components(
        separatedBy: try NSRegularExpression(
          pattern: #"(?:&&|\r?\n)+"#
        )
      )
      .compactMap { entry in
        let parts = entry.components(
          separatedBy: "::",
          maxSplits: 1
        )
        let title = parts[0].trimmingCharacters(
          in: .whitespacesAndNewlines
        )
        guard !title.isEmpty else { return nil }
        return SourceExploreCategory(
          title: title,
          urlTemplate: normalizedURL(parts.count > 1 ? parts[1] : nil)
        )
      }
  }

  private struct JSONCategory: Decodable {
    let title: String
    let url: String?
  }

  private static func normalizedURL(_ value: String?) -> String? {
    let result = value?.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    return result?.isEmpty == false ? result : nil
  }
}

public struct SourceExplorePipeline: Sendable {
  private let definition: SourceExploreDefinition
  private let transport: any HTTPTransport
  private let responseChecker: any SourceExploreResponseChecking

  public init(
    definition: SourceExploreDefinition,
    transport: any HTTPTransport,
    responseChecker: any SourceExploreResponseChecking =
      IdentitySourceExploreResponseChecker()
  ) {
    self.definition = definition
    self.transport = transport
    self.responseChecker = responseChecker
  }

  public func categories() throws -> [SourceExploreCategory] {
    guard definition.enabled else { return [] }
    return try SourceExploreCatalog.parse(definition.catalog)
  }

  public func explore(_ input: SourceExploreInput) async throws
    -> SourceSearchExecution
  {
    guard definition.enabled else {
      throw SourceExplorePipelineError.disabled
    }
    guard let template = input.category.urlTemplate else {
      throw SourceExplorePipelineError.missingCategoryURL
    }
    let compilation = try SourceURLTemplateCompiler.compile(
      SourceURLTemplateInput(
        template: template,
        page: input.page,
        baseURL: definition.source.sourceURL
      )
    )
    let networkResponse = try await transport.execute(
      compilation.plan.request
    )
    guard
      let body = String(
        data: networkResponse.body.bytes,
        encoding: .utf8
      )
    else {
      throw SourceSearchPipelineError.invalidResponseEncoding
    }
    let checked = try await responseChecker.check(
      SourceSearchResponse(
        url: networkResponse.effectiveURL.absoluteString,
        body: body
      ),
      source: definition,
      input: input
    )
    let rules =
      definition.source.runtime.explore
      ?? definition.source.runtime.search
    let books = try SourceBookListParser(
      definition: definition.source
    ).parse(
      response: checked,
      rules: rules,
      reverse: rules.list.hasPrefix("-"),
      allowsDetailPattern: false
    )
    return SourceSearchExecution(
      requestPlan: compilation.plan,
      response: checked,
      books: books
    )
  }
}

private extension String {
  func components(
    separatedBy expression: NSRegularExpression
  ) -> [String] {
    let range = NSRange(startIndex..., in: self)
    var result: [String] = []
    var cursor = startIndex
    for match in expression.matches(in: self, range: range) {
      guard let matchRange = Range(match.range, in: self) else {
        continue
      }
      result.append(String(self[cursor..<matchRange.lowerBound]))
      cursor = matchRange.upperBound
    }
    result.append(String(self[cursor...]))
    return result
  }

  func components(
    separatedBy separator: String,
    maxSplits: Int
  ) -> [String] {
    guard
      maxSplits > 0,
      let range = range(of: separator)
    else {
      return [self]
    }
    return [
      String(self[..<range.lowerBound]),
      String(self[range.upperBound...]),
    ]
  }
}
