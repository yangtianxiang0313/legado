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
      return SourceRequestPlan(
        request: HTTPRequest(
          method: .get,
          url: try validatedURL(url)
        ),
        body: nil,
        formFields: []
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
      return SourceRequestPlan(
        request: HTTPRequest(
          method: .get,
          url: try validatedURL(parts.url),
          headers: HTTPHeaders(headers)
        ),
        body: nil,
        formFields: [],
        retry: retry
      )
    }
    let body = option.body ?? ""
    let contentType = headers.first(where: { $0.name == "content-type" })?.value
    let formFields =
      contentType == nil && !looksLikeJSONOrXML(body)
      ? encodedFormFields(body)
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

  private static func encodedFormFields(_ body: String) -> [HTTPFormField] {
    var fields: [HTTPFormField] = []
    var positions: [String: Int] = [:]
    for raw in body.split(separator: "&", omittingEmptySubsequences: false) {
      let item = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !item.isEmpty else { continue }
      let pair = item.split(
        separator: "=",
        maxSplits: 1,
        omittingEmptySubsequences: false
      )
      let key = String(pair[0]).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !key.isEmpty else { continue }
      let rawValue =
        pair.count == 2
        ? String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        : ""
      let value = hasValidURLFormEncoding(rawValue)
        ? rawValue
        : javaFormEncode(rawValue)
      if let position = positions[key] {
        fields[position] = HTTPFormField(key: key, value: value)
      } else {
        positions[key] = fields.count
        fields.append(HTTPFormField(key: key, value: value))
      }
    }
    return fields
  }

  private static func hasValidURLFormEncoding(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    var index = 0
    while index < bytes.count {
      let byte = bytes[index]
      if isFormSafe(byte) || byte == 43 {
        index += 1
      } else if
        byte == 37,
        index + 2 < bytes.count,
        isHex(bytes[index + 1]),
        isHex(bytes[index + 2])
      {
        index += 3
      } else {
        return false
      }
    }
    return true
  }

  private static func javaFormEncode(_ value: String) -> String {
    let hexadecimal = Array("0123456789ABCDEF".utf8)
    var output: [UInt8] = []
    for byte in value.utf8 {
      if isFormSafe(byte) {
        output.append(byte)
      } else if byte == 32 {
        output.append(43)
      } else {
        output.append(37)
        output.append(hexadecimal[Int(byte >> 4)])
        output.append(hexadecimal[Int(byte & 15)])
      }
    }
    return String(decoding: output, as: UTF8.self)
  }

  private static func isFormSafe(_ byte: UInt8) -> Bool {
    (48...57).contains(byte)
      || (65...90).contains(byte)
      || (97...122).contains(byte)
      || [42, 45, 46, 95].contains(byte)
  }

  private static func isHex(_ byte: UInt8) -> Bool {
    (48...57).contains(byte)
      || (65...70).contains(byte)
      || (97...102).contains(byte)
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
