import Foundation

public enum SourceEndpointError: Error, Equatable, Sendable {
  case invalidURL
}

/// A source endpoint keeps the stable logical URL separate from the complete
/// Android-compatible request expression.
///
/// Legado appends `,{...}` request options to book, TOC and chapter URLs.
/// Only the URL prefix participates in relative URL resolution and identity;
/// the option suffix must survive unchanged until request-plan compilation.
public struct SourceEndpoint: Equatable, Sendable {
  public let logicalURL: URL
  public let requestExpression: String

  public static func plain(_ url: URL) -> SourceEndpoint {
    SourceEndpoint(
      logicalURL: url.absoluteURL,
      requestExpression: url.absoluteURL.absoluteString
    )
  }

  /// Android represents a volume without a chapter URL by its title and row
  /// index. It must remain distinct from a regular chapter that falls back to
  /// the TOC URL, while its public URL still resolves to that TOC page.
  static func syntheticVolume(
    title: String,
    index: Int,
    fallbackURL: URL
  ) -> SourceEndpoint {
    SourceEndpoint(
      logicalURL: fallbackURL.absoluteURL,
      requestExpression: title + String(index)
    )
  }

  public init(url: URL) throws {
    let absolute = url.absoluteURL.absoluteString
    guard
      !absolute.isEmpty,
      (try? HTTPURL(absolute)) != nil
    else {
      throw SourceEndpointError.invalidURL
    }
    self = .plain(url)
  }

  public init(
    resolving rawExpression: String,
    relativeTo baseURL: URL
  ) throws {
    let parts = SourceRequestCompiler.splitURLAndOption(
      rawExpression.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
    )
    let resolved = URL(
      string: parts.url,
      relativeTo: baseURL
    )?.absoluteURL
    let absolute = resolved?.absoluteString ?? ""
    guard
      !parts.url.isEmpty,
      resolved != nil,
      !absolute.isEmpty,
      (try? HTTPURL(absolute)) != nil,
      let logicalURL = URL(string: absolute)
    else {
      throw SourceEndpointError.invalidURL
    }
    self.logicalURL = logicalURL
    self.requestExpression = parts.option.map {
      absolute + "," + $0
    } ?? absolute
  }

  public func requestPlan() throws -> SourceRequestPlan {
    try SourceRequestCompiler.compileRendered(requestExpression)
  }

  public func requestPlan(
    resolver: SourceVariableResolver
  ) async throws -> SourceRequestPlan {
    let rendered = try await SourceVariableTemplateRenderer.render(
      requestExpression,
      resolver: resolver
    )
    return try SourceRequestCompiler.compileRendered(rendered)
  }

  private init(logicalURL: URL, requestExpression: String) {
    self.logicalURL = logicalURL
    self.requestExpression = requestExpression
  }
}
