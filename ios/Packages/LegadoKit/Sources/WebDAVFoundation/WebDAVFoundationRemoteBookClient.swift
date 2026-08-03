import Foundation
import IntegrationKit

public struct WebDAVFoundationRemoteBookClient: WebDAVRemoteBookTransferring {
  private let credentials: any WebDAVCredentialResolving
  private let transport: any WebDAVHTTPDataTransport

  public init(
    credentials: any WebDAVCredentialResolving,
    transport: any WebDAVHTTPDataTransport = URLSessionWebDAVDataTransport()
  ) {
    self.credentials = credentials
    self.transport = transport
  }

  public func listRemoteBooks(
    configuration: WebDAVConnectionConfiguration,
    directoryURL: URL? = nil
  ) async -> WebDAVRemoteBookListResult {
    guard let rootURL = configuration.rootURL else {
      return .failed(.invalidConfiguration)
    }
    let targetURL = directoryURL ?? rootURL
    guard isSameServer(targetURL, as: rootURL) else {
      return .failed(.invalidResourceURL)
    }
    guard let resolved = await resolve(configuration) else {
      return .failed(.credentialUnavailable)
    }
    do {
      var request = authorizedRequest(
        url: targetURL,
        method: "PROPFIND",
        credentials: resolved
      )
      request.setValue("1", forHTTPHeaderField: "Depth")
      request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
      request.httpBody = Data(Self.propertyRequest.utf8)
      let response = try await transport.performData(request)
      if let failure = failure(statusCode: response.statusCode) {
        return .failed(failure)
      }
      guard
        let resources = WebDAVRemoteBookMultistatusParser.parse(
          response.body,
          relativeTo: targetURL
        )
      else {
        return .failed(.invalidResponse)
      }
      return .loaded(
        resources.filter {
          !sameResource($0.url, targetURL)
            && AndroidRemoteBookFilePolicy.includes(
              name: $0.name,
              isDirectory: $0.isDirectory
            )
        }
      )
    } catch {
      return .failed(.transportUnavailable)
    }
  }

  public func downloadRemoteBook(
    configuration: WebDAVConnectionConfiguration,
    resource: WebDAVRemoteBookResource
  ) async -> WebDAVRemoteBookDownloadResult {
    guard let rootURL = configuration.rootURL else {
      return .failed(.invalidConfiguration)
    }
    guard
      !resource.isDirectory,
      isSameServer(resource.url, as: rootURL)
    else {
      return .failed(.invalidResourceURL)
    }
    guard let resolved = await resolve(configuration) else {
      return .failed(.credentialUnavailable)
    }
    do {
      let response = try await transport.performData(
        authorizedRequest(
          url: resource.url,
          method: "GET",
          credentials: resolved
        )
      )
      if let failure = failure(statusCode: response.statusCode) {
        return .failed(failure)
      }
      return .downloaded(name: resource.name, data: response.body)
    } catch {
      return .failed(.transportUnavailable)
    }
  }

  public func inspectRemoteBook(
    configuration: WebDAVConnectionConfiguration,
    remoteURL: URL
  ) async -> WebDAVRemoteBookInspectionResult {
    guard let rootURL = configuration.rootURL else {
      return .failed(.invalidConfiguration)
    }
    guard isSameServer(remoteURL, as: rootURL) else {
      return .failed(.invalidResourceURL)
    }
    guard let resolved = await resolve(configuration) else {
      return .failed(.credentialUnavailable)
    }
    do {
      var request = authorizedRequest(
        url: remoteURL,
        method: "PROPFIND",
        credentials: resolved
      )
      request.setValue("0", forHTTPHeaderField: "Depth")
      request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
      request.httpBody = Data(Self.propertyRequest.utf8)
      let response = try await transport.performData(request)
      if response.statusCode == 404 { return .missing }
      if let failure = failure(statusCode: response.statusCode) {
        return .failed(failure)
      }
      guard
        let resources = WebDAVRemoteBookMultistatusParser.parse(
          response.body,
          relativeTo: remoteURL
        ),
        let resource = resources.first(where: {
          sameResource($0.url, remoteURL) && !$0.isDirectory
        })
      else {
        return .failed(.invalidResponse)
      }
      return .found(resource)
    } catch {
      return .failed(.transportUnavailable)
    }
  }

  public func uploadRemoteBook(
    configuration: WebDAVConnectionConfiguration,
    fileName: String,
    data: Data
  ) async -> WebDAVRemoteBookUploadResult {
    guard let rootURL = configuration.rootURL else {
      return .failed(.invalidConfiguration)
    }
    let normalizedName = fileName.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard
      !normalizedName.isEmpty,
      normalizedName != ".",
      normalizedName != "..",
      !normalizedName.contains("/"),
      !normalizedName.contains("\\")
    else {
      return .failed(.invalidFileName)
    }
    guard let resolved = await resolve(configuration) else {
      return .failed(.credentialUnavailable)
    }
    let remoteURL = rootURL.appendingPathComponent(normalizedName)
    do {
      var request = authorizedRequest(
        url: remoteURL,
        method: "PUT",
        credentials: resolved
      )
      request.setValue(
        "application/octet-stream",
        forHTTPHeaderField: "Content-Type"
      )
      request.httpBody = data
      let response = try await transport.performData(request)
      if let failure = failure(statusCode: response.statusCode) {
        return .failed(failure)
      }
      return .uploaded(name: normalizedName, remoteURL: remoteURL)
    } catch {
      return .failed(.transportUnavailable)
    }
  }

  private func resolve(
    _ configuration: WebDAVConnectionConfiguration
  ) async -> WebDAVBasicCredentials? {
    try? await credentials.credentials(for: configuration.credentialReference)
  }

  private func authorizedRequest(
    url: URL,
    method: String,
    credentials: WebDAVBasicCredentials
  ) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = method
    let raw = "\(credentials.username):\(credentials.password)"
    request.setValue(
      "Basic \(Data(raw.utf8).base64EncodedString())",
      forHTTPHeaderField: "Authorization"
    )
    return request
  }

  private func isSameServer(_ candidate: URL, as root: URL) -> Bool {
    candidate.scheme?.lowercased() == root.scheme?.lowercased()
      && candidate.host?.lowercased() == root.host?.lowercased()
      && candidate.port == root.port
  }

  private func sameResource(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      == rhs.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  private func failure(statusCode: Int) -> WebDAVRemoteBookFailure? {
    switch statusCode {
    case 200 ... 299: nil
    case 401: .authenticationRejected
    case 404: .notFound
    default: .remoteRejected(statusCode: statusCode)
    }
  }

  private static let propertyRequest = """
    <?xml version="1.0"?>
    <a:propfind xmlns:a="DAV:">
      <a:prop>
        <a:displayname/>
        <a:resourcetype/>
        <a:getcontentlength/>
        <a:creationdate/>
        <a:getlastmodified/>
      </a:prop>
    </a:propfind>
    """
}

private final class WebDAVRemoteBookMultistatusParser: NSObject,
  XMLParserDelegate
{
  private struct Response {
    var href = ""
    var size: Int64 = 0
    var modified: Int64 = 0
    var isCollection = false
  }

  private let baseURL: URL
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

  private init(baseURL: URL) {
    self.baseURL = baseURL
  }

  static func parse(
    _ data: Data,
    relativeTo baseURL: URL
  ) -> [WebDAVRemoteBookResource]? {
    let delegate = WebDAVRemoteBookMultistatusParser(baseURL: baseURL)
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse() else { return nil }
    return delegate.responses.compactMap { response in
      let decodedHref = response.href.removingPercentEncoding ?? response.href
      let trimmed = decodedHref.hasSuffix("/")
        ? String(decodedHref.dropLast())
        : decodedHref
      guard
        let name = trimmed.split(separator: "/").last.map(String.init),
        let url = URL(string: response.href, relativeTo: baseURL)?.absoluteURL
      else { return nil }
      return WebDAVRemoteBookResource(
        name: name,
        url: url,
        size: response.size,
        lastModifiedMilliseconds: response.modified,
        isDirectory: response.isCollection
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
    case "href": current?.href = value
    case "getcontentlength": current?.size = Int64(value) ?? 0
    case "getlastmodified":
      if let date = dateFormatter.date(from: value) {
        current?.modified = Int64(date.timeIntervalSince1970 * 1_000)
      }
    case "response":
      if let current { responses.append(current) }
      current = nil
    default: break
    }
    text = ""
  }

  private func localName(_ name: String) -> String {
    name.split(separator: ":").last.map(String.init) ?? name
  }
}
