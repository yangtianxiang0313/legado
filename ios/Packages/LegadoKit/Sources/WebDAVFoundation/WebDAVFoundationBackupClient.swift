import Foundation
import IntegrationKit

public struct WebDAVFoundationBackupClient: WebDAVBackupTransferring {
  private let credentials: any WebDAVCredentialResolving
  private let transport: any WebDAVHTTPDataTransport

  public init(
    credentials: any WebDAVCredentialResolving,
    transport: any WebDAVHTTPDataTransport = URLSessionWebDAVDataTransport()
  ) {
    self.credentials = credentials
    self.transport = transport
  }

  public func listBackups(
    configuration: WebDAVConnectionConfiguration
  ) async -> WebDAVBackupListResult {
    guard let rootURL = configuration.rootURL else {
      return .failed(.invalidConfiguration)
    }
    guard let resolved = await resolve(configuration) else {
      return .failed(.credentialUnavailable)
    }
    do {
      let response = try await transport.performData(
        request(
          url: rootURL,
          method: "PROPFIND",
          credentials: resolved,
          depth: "1"
        )
      )
      if let failure = failure(statusCode: response.statusCode) {
        return .failed(failure)
      }
      guard let files = WebDAVBackupMultistatusParser.parse(response.body) else {
        return .failed(.invalidResponse)
      }
      return .loaded(
        files
          .filter { AndroidWebDAVBackupPath.isValidFileName($0.name) }
          .sorted {
            if $0.lastModifiedMilliseconds != $1.lastModifiedMilliseconds {
              return $0.lastModifiedMilliseconds > $1.lastModifiedMilliseconds
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedDescending
          }
      )
    } catch {
      return .failed(.transportUnavailable)
    }
  }

  public func uploadBackup(
    configuration: WebDAVConnectionConfiguration,
    fileName: String,
    data: Data
  ) async -> WebDAVBackupUploadResult {
    guard
      let url = AndroidWebDAVBackupPath.fileURL(
        configuration: configuration,
        fileName: fileName
      )
    else {
      return .failed(
        configuration.rootURL == nil ? .invalidConfiguration : .invalidFileName
      )
    }
    guard let resolved = await resolve(configuration) else {
      return .failed(.credentialUnavailable)
    }
    do {
      var upload = request(
        url: url,
        method: "PUT",
        credentials: resolved,
        depth: nil
      )
      upload.httpBody = data
      upload.setValue(
        "application/octet-stream",
        forHTTPHeaderField: "Content-Type"
      )
      let response = try await transport.performData(upload)
      if let failure = failure(statusCode: response.statusCode) {
        return .failed(failure)
      }
      return .uploaded
    } catch {
      return .failed(.transportUnavailable)
    }
  }

  public func downloadBackup(
    configuration: WebDAVConnectionConfiguration,
    fileName: String
  ) async -> WebDAVBackupDownloadResult {
    guard
      let url = AndroidWebDAVBackupPath.fileURL(
        configuration: configuration,
        fileName: fileName
      )
    else {
      return .failed(
        configuration.rootURL == nil ? .invalidConfiguration : .invalidFileName
      )
    }
    guard let resolved = await resolve(configuration) else {
      return .failed(.credentialUnavailable)
    }
    do {
      let response = try await transport.performData(
        request(
          url: url,
          method: "GET",
          credentials: resolved,
          depth: nil
        )
      )
      if let failure = failure(statusCode: response.statusCode) {
        return .failed(failure)
      }
      return .downloaded(response.body)
    } catch {
      return .failed(.transportUnavailable)
    }
  }

  private func resolve(
    _ configuration: WebDAVConnectionConfiguration
  ) async -> WebDAVBasicCredentials? {
    try? await credentials.credentials(for: configuration.credentialReference)
  }

  private func failure(statusCode: Int) -> WebDAVBackupTransferFailure? {
    switch statusCode {
    case 200 ... 299:
      nil
    case 401:
      .authenticationRejected
    case 404:
      .notFound
    default:
      .remoteRejected(statusCode: statusCode)
    }
  }

  private func request(
    url: URL,
    method: String,
    credentials: WebDAVBasicCredentials,
    depth: String?
  ) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = method
    if let depth {
      request.setValue(depth, forHTTPHeaderField: "Depth")
    }
    let raw = "\(credentials.username):\(credentials.password)"
    request.setValue(
      "Basic \(Data(raw.utf8).base64EncodedString())",
      forHTTPHeaderField: "Authorization"
    )
    return request
  }
}

private final class WebDAVBackupMultistatusParser: NSObject, XMLParserDelegate {
  private struct Response {
    var href = ""
    var size: Int64 = 0
    var modified: Int64 = 0
    var isCollection = false
  }

  private var current: Response?
  private var text = ""
  private var responses: [Response] = []
  private let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter
  }()

  static func parse(_ data: Data) -> [WebDAVBackupFile]? {
    let delegate = WebDAVBackupMultistatusParser()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse() else { return nil }
    return delegate.responses.compactMap { response in
      guard !response.isCollection else { return nil }
      let decoded = response.href.removingPercentEncoding ?? response.href
      guard let name = decoded.split(separator: "/").last.map(String.init) else {
        return nil
      }
      return WebDAVBackupFile(
        name: name,
        size: response.size,
        lastModifiedMilliseconds: response.modified
      )
    }
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    let name = localName(elementName)
    if name == "response" { current = Response() }
    if name == "collection" { current?.isCollection = true }
    text = ""
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    text += string
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let name = localName(elementName)
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    switch name {
    case "href":
      current?.href = value
    case "getcontentlength":
      current?.size = Int64(value) ?? 0
    case "getlastmodified":
      if let date = dateFormatter.date(from: value) {
        current?.modified = Int64(date.timeIntervalSince1970 * 1_000)
      }
    case "response":
      if let current { responses.append(current) }
      current = nil
    default:
      break
    }
    text = ""
  }

  private func localName(_ name: String) -> String {
    name.split(separator: ":").last.map(String.init) ?? name
  }
}
