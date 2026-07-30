import Foundation

public enum SourceWebLoginSessionError: Error, Equatable, Sendable {
  case invalidSourceURL
  case invalidLoginURL
  case scriptLoginUnsupported
}

public struct SourceWebLoginPreparation: Equatable, Sendable {
  public let storageURL: HTTPURL
  public let loginURL: HTTPURL
  public let headers: HTTPHeaders
  public let cookie: String

  public init(
    storageURL: HTTPURL,
    loginURL: HTTPURL,
    headers: HTTPHeaders,
    cookie: String
  ) {
    self.storageURL = storageURL
    self.loginURL = loginURL
    self.headers = headers
    self.cookie = cookie
  }
}

public struct SourceWebLoginSession: Sendable {
  private let sourceURL: String
  private let loginURL: String
  private let headers: HTTPHeaders
  private let cookieStore: SourceCookieStore

  public init(
    sourceURL: String,
    loginURL: String,
    headers: HTTPHeaders = HTTPHeaders(),
    cookieStore: SourceCookieStore
  ) {
    self.sourceURL = sourceURL
    self.loginURL = loginURL
    self.headers = headers
    self.cookieStore = cookieStore
  }

  public func prepare() async throws -> SourceWebLoginPreparation {
    let storageURL = try validatedSourceURL()
    let resolvedLoginURL = try resolveLoginURL(relativeTo: storageURL)
    let snapshot = try await cookieStore.snapshot(for: storageURL)
    return SourceWebLoginPreparation(
      storageURL: storageURL,
      loginURL: resolvedLoginURL,
      headers: headers,
      cookie: snapshot.combinedCookie
    )
  }

  public func synchronize(browserCookie: String) async throws {
    try await cookieStore.replacePersistentCookie(
      browserCookie,
      for: validatedSourceURL()
    )
  }

  public func clear() async throws {
    try await cookieStore.removeCookies(for: validatedSourceURL())
  }

  private func validatedSourceURL() throws -> HTTPURL {
    do {
      return try HTTPURL(
        sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    } catch {
      throw SourceWebLoginSessionError.invalidSourceURL
    }
  }

  private func resolveLoginURL(
    relativeTo storageURL: HTTPURL
  ) throws -> HTTPURL {
    let value = loginURL.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !value.isEmpty else {
      throw SourceWebLoginSessionError.invalidLoginURL
    }
    let lowercased = value.lowercased()
    guard
      !lowercased.hasPrefix("@js:"),
      !lowercased.hasPrefix("<js>")
    else {
      throw SourceWebLoginSessionError.scriptLoginUnsupported
    }
    guard
      let baseURL = URL(string: storageURL.absoluteString),
      let resolved = URL(string: value, relativeTo: baseURL)?.absoluteURL
    else {
      throw SourceWebLoginSessionError.invalidLoginURL
    }
    do {
      return try HTTPURL(resolved.absoluteString)
    } catch {
      throw SourceWebLoginSessionError.invalidLoginURL
    }
  }
}
