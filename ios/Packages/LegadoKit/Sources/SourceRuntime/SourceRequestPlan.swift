import Foundation

public struct HTTPFormField: Codable, Equatable, Sendable {
  public let key: String
  public let value: String

  public init(key: String, value: String) {
    self.key = key
    self.value = value
  }
}

public struct SourceRequestPlan: Equatable, Sendable {
  public let request: HTTPRequest
  public let body: String?
  public let formFields: [HTTPFormField]
  public let retry: Int

  public init(
    request: HTTPRequest,
    body: String?,
    formFields: [HTTPFormField],
    retry: Int = 0
  ) {
    self.request = request
    self.body = body
    self.formFields = formFields
    self.retry = retry
  }
}

public enum SourceRequestCompiler {
  public static let androidDefaultUserAgent =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    + "AppleWebKit/537.36 (KHTML, like Gecko) "
    + "Chrome/123.0.0.0 Safari/537.36"

  public static func compile(
    template: String,
    keyword: String
  ) throws -> SourceRequestPlan {
    if splitURLAndOption(template).option == nil {
      guard template.contains("{{key}}") else {
        throw SourceRuntimeIssue(stage: .urlTemplate, code: .invalidURL)
      }
      let url = template.replacingOccurrences(
        of: "{{key}}",
        with: encodeURLComponent(keyword)
      )
      let compiled = try compiledGET(url, charset: nil)
      return SourceRequestPlan(
        request: HTTPRequest(
          method: .get,
          url: compiled.url
        ),
        body: nil,
        formFields: compiled.fields
      )
    }
    let rendered = try render(template: template, keyword: keyword)
    let parts = splitURLAndOption(rendered)
    guard !parts.url.isEmpty else {
      throw SourceRuntimeIssue(stage: .urlTemplate, code: .invalidURL)
    }
    guard let optionText = parts.option else {
      return SourceRequestPlan(
        request: HTTPRequest(
          method: .get,
          url: try validatedURL(parts.url)
        ),
        body: nil,
        formFields: []
      )
    }
    let option: URLOption
    do {
      option = try JSONDecoder().decode(
        URLOption.self,
        from: Data(optionText.utf8)
      )
    } catch {
      throw SourceRuntimeIssue(stage: .urlTemplate, code: .invalidURL)
    }
    let retry = option.retry ?? 0
    guard retry >= 0, retry < Int.max else {
      throw SourceRequestPreparationError.invalidRetry
    }
    let headers = try configuredHeaders(option.headers ?? option.header)
    guard option.method?.caseInsensitiveCompare("POST") == .orderedSame else {
      let compiled = try compiledGET(parts.url, charset: option.charset)
      return SourceRequestPlan(
        request: HTTPRequest(
          method: .get,
          url: compiled.url,
          headers: HTTPHeaders(headers)
        ),
        body: nil,
        formFields: compiled.fields,
        retry: retry
      )
    }
    let body = option.body ?? ""
    let contentType = headers.first(where: { $0.name == "content-type" })?.value
    let formFields =
      contentType == nil && !looksLikeJSONOrXML(body)
      ? try SourceFieldCompiler.compile(body, charset: option.charset)
      : []
    let canonicalBody =
      formFields.isEmpty && !body.isEmpty
      ? body
      : formFields.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    var requestHeaders = headers
    if !requestHeaders.contains(where: { $0.name == "user-agent" }) {
      requestHeaders.append(
        try HTTPHeader(name: "user-agent", value: androidDefaultUserAgent)
      )
    }
    return SourceRequestPlan(
      request: HTTPRequest(
        method: .post,
        url: try validatedURL(parts.url),
        headers: HTTPHeaders(requestHeaders),
        body: HTTPBody(Data(canonicalBody.utf8))
      ),
      body: canonicalBody,
      formFields: formFields,
      retry: retry
    )
  }

  private struct URLOption: Decodable {
    let method: String?
    let body: String?
    let header: [String: String]?
    let headers: [String: String]?
    let retry: Int?
    let charset: String?
  }

  private static func render(template: String, keyword: String) throws -> String {
    var output = ""
    var cursor = template.startIndex
    while let start = template.range(of: "{{", range: cursor..<template.endIndex) {
      output += template[cursor..<start.lowerBound]
      guard
        let end = template.range(
          of: "}}",
          range: start.upperBound..<template.endIndex
        )
      else {
        throw SourceRuntimeIssue(stage: .urlTemplate, code: .invalidURL)
      }
      let expression = String(template[start.upperBound..<end.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      output += try evaluate(expression: expression, keyword: keyword)
      cursor = end.upperBound
    }
    output += template[cursor...]
    return output
  }

  private static func evaluate(
    expression: String,
    keyword: String
  ) throws -> String {
    if expression == "key" {
      return keyword
    }
    let pattern =
      #"^key\s*==\s*'([^']*)'\s*\?\s*'([^']*)'\s*:\s*'([^']*)'$"#
    let regex = try NSRegularExpression(pattern: pattern)
    let range = NSRange(expression.startIndex..., in: expression)
    guard
      let match = regex.firstMatch(in: expression, range: range),
      match.range == range,
      let expectedRange = Range(match.range(at: 1), in: expression),
      let trueRange = Range(match.range(at: 2), in: expression),
      let falseRange = Range(match.range(at: 3), in: expression)
    else {
      throw SourceRuntimeIssue(stage: .urlTemplate, code: .invalidURL)
    }
    return keyword == expression[expectedRange]
      ? String(expression[trueRange])
      : String(expression[falseRange])
  }

  private static func splitURLAndOption(
    _ rendered: String
  ) -> (url: String, option: String?) {
    guard
      let range = rendered.range(
        of: #",\s*(?=\{)"#,
        options: .regularExpression
      )
    else {
      return (rendered.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }
    return (
      String(rendered[..<range.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines),
      String(rendered[range.upperBound...])
    )
  }

  private static func configuredHeaders(
    _ values: [String: String]?
  ) throws -> [HTTPHeader] {
    try (values ?? [:]).sorted { lhs, rhs in
      let left = lhs.key.lowercased()
      let right = rhs.key.lowercased()
      return left == right ? lhs.key < rhs.key : left < right
    }.map { try HTTPHeader(name: $0.key, value: $0.value) }
  }

  private static func compiledGET(
    _ value: String,
    charset: String?
  ) throws -> (url: HTTPURL, fields: [HTTPFormField]) {
    guard let queryStart = value.firstIndex(of: "?") else {
      return (try validatedURL(value), [])
    }
    let base = String(value[..<queryStart])
    let rawQuery = String(value[value.index(after: queryStart)...])
    let fields = try SourceFieldCompiler.compile(rawQuery, charset: charset)
    let query =
      fields
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: "&")
    return (
      try validatedURL(base + "?" + query),
      fields
    )
  }

  private static func looksLikeJSONOrXML(_ body: String) -> Bool {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    return
      (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
      || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
      || (trimmed.hasPrefix("<") && trimmed.hasSuffix(">"))
  }

  private static func encodeURLComponent(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: ":#[]@!$&'()*+,;=?/")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  private static func validatedURL(_ value: String) throws -> HTTPURL {
    do {
      return try HTTPURL(value)
    } catch {
      throw SourceRuntimeIssue(stage: .urlTemplate, code: .invalidURL)
    }
  }
}
