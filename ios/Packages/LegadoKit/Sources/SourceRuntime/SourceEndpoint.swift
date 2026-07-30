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

  public init(url: URL) throws {
    let absolute = url.absoluteURL.absoluteString
    guard
      !absolute.isEmpty,
      (try? HTTPURL(absolute)) != nil
    else {
      throw SourceEndpointError.invalidURL
    }
    self.logicalURL = URL(string: absolute)!
    self.requestExpression = absolute
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
}
