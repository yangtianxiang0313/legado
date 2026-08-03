import Foundation

public struct HTTPTextToSpeechRuntimeDefinition: Sendable, Equatable {
  public let id: Int64
  public let urlTemplate: String
  public let contentTypePattern: String?
  public let headers: [SourceHeaderField]
  public let enabledCookieJar: Bool
  public let scriptLibrary: SourceScriptLibrary?

  public init(
    id: Int64,
    urlTemplate: String,
    contentTypePattern: String? = nil,
    headers: [SourceHeaderField] = [],
    enabledCookieJar: Bool = false,
    scriptLibrary: SourceScriptLibrary? = nil
  ) {
    self.id = id
    self.urlTemplate = urlTemplate
    self.contentTypePattern = contentTypePattern
    self.headers = headers
    self.enabledCookieJar = enabledCookieJar
    self.scriptLibrary = scriptLibrary
  }
}

public struct HTTPTextToSpeechAudio: Sendable, Equatable {
  public let data: Data
  public let contentType: String?
  public let request: HTTPRequest
  public let effectiveURL: HTTPURL
}

public enum HTTPTextToSpeechPipelineError: Error, Sendable, Equatable {
  case unsupportedTemplateExpression(String)
  case unsuccessfulStatus(Int)
  case jsonErrorResponse(String)
  case unexpectedContentType(expected: String, actual: String)
}

public struct HTTPTextToSpeechPipeline: Sendable {
  private let definition: HTTPTextToSpeechRuntimeDefinition
  private let transport: any HTTPTransport
  private let cookieStore: SourceCookieStore
  private let scriptRuntime: (any SourceScriptRuntime)?

  public init(
    definition: HTTPTextToSpeechRuntimeDefinition,
    transport: any HTTPTransport,
    cookieStore: SourceCookieStore = SourceCookieStore(),
    scriptRuntime: (any SourceScriptRuntime)? = nil
  ) {
    self.definition = definition
    self.transport = transport
    self.cookieStore = cookieStore
    self.scriptRuntime = scriptRuntime
  }

  public func load(text: String, speed: Int) async throws
    -> HTTPTextToSpeechAudio
  {
    let rendered = try await HTTPTextToSpeechTemplateRenderer(
      text: text,
      speed: speed,
      scriptRuntime: scriptRuntime,
      scriptLibrary: definition.scriptLibrary,
      sessionID: SourceScriptSessionID(rawValue: "httpTts:\(definition.id)")
    ).render(definition.urlTemplate)
    let compilation = try SourceURLTemplateCompiler.compile(
      SourceURLTemplateInput(template: rendered, baseURL: rendered)
    )
    let optionHeaders = try compilation.plan.optionHeaders.isEmpty
      ? compilation.plan.request.headers.fields.map {
        try SourceHeaderField(name: $0.name, value: $0.value)
      }
      : compilation.plan.optionHeaders
    let prepared = try SourceRequestPreparer.prepare(
      request: compilation.plan.request,
      inheritedHeaders: definition.headers,
      optionHeaders: optionHeaders,
      persistentCookie: "",
      enabledCookieJar: false,
      retry: compilation.plan.retry
    )
    let plan = SourceRequestPlan(
      request: prepared.constructedRequest,
      body: compilation.plan.body,
      formFields: compilation.plan.formFields,
      optionHeaders: optionHeaders,
      retry: compilation.plan.retry,
      useWebView: false,
      webJS: nil
    )
    let execution = try await SourceRequestSession(
      transport: transport,
      cookieStore: cookieStore
    ).execute(plan, enabledCookieJar: definition.enabledCookieJar)
    guard execution.isSuccessful else {
      throw HTTPTextToSpeechPipelineError.unsuccessfulStatus(
        execution.response.statusCode
      )
    }
    let contentType = execution.response.headers.values(for: "content-type").last
    if contentType == "application/json" {
      throw HTTPTextToSpeechPipelineError.jsonErrorResponse(
        String(decoding: execution.response.body.bytes, as: UTF8.self)
      )
    }
    if let pattern = definition.contentTypePattern,
       !pattern.isEmpty,
       let contentType,
       !Self.fullMatch(contentType, pattern: pattern) {
      throw HTTPTextToSpeechPipelineError.unexpectedContentType(
        expected: pattern,
        actual: contentType
      )
    }
    return HTTPTextToSpeechAudio(
      data: execution.response.body.bytes,
      contentType: contentType,
      request: plan.request,
      effectiveURL: execution.effectiveURL
    )
  }

  private static func fullMatch(_ value: String, pattern: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return false
    }
    let range = NSRange(value.startIndex..., in: value)
    guard let match = regex.firstMatch(in: value, range: range) else {
      return false
    }
    return match.range == range
  }
}

private struct HTTPTextToSpeechTemplateRenderer: Sendable {
  let text: String
  let speed: Int
  let scriptRuntime: (any SourceScriptRuntime)?
  let scriptLibrary: SourceScriptLibrary?
  let sessionID: SourceScriptSessionID

  func render(_ template: String) async throws -> String {
    var output = ""
    var cursor = template.startIndex
    while let start = template.range(of: "{{", range: cursor..<template.endIndex) {
      output += template[cursor..<start.lowerBound]
      guard let end = template.range(
        of: "}}",
        range: start.upperBound..<template.endIndex
      ) else {
        throw HTTPTextToSpeechPipelineError.unsupportedTemplateExpression(
          String(template[start.lowerBound...])
        )
      }
      let expression = String(template[start.upperBound..<end.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      output += try await evaluate(expression)
      cursor = end.upperBound
    }
    output += template[cursor...]
    return output
  }

  private func evaluate(_ expression: String) async throws -> String {
    if expression == "speakText" { return text }
    if expression == "speakSpeed" { return String(speed) }
    if let inner = functionArgument("java.encodeURI", in: expression) {
      return formEncode(try await evaluate(inner))
    }
    if let inner = functionArgument("String", in: expression) {
      return try await evaluate(inner)
    }
    var arithmetic = ArithmeticExpression(
      expression,
      variables: ["speakSpeed": Double(speed)]
    )
    if let value = try? arithmetic.evaluate() {
      return numberString(value)
    }
    guard let scriptRuntime else {
      throw HTTPTextToSpeechPipelineError.unsupportedTemplateExpression(expression)
    }
    let value = try await scriptRuntime.evaluate(
      SourceScriptRequest(
        sessionID: sessionID,
        library: scriptLibrary,
        script: expression,
        bindings: [
          "speakText": .string(text),
          "speakSpeed": .number(Double(speed)),
        ]
      ),
      host: nil
    )
    return scriptString(value)
  }

  private func functionArgument(_ name: String, in expression: String) -> String? {
    let prefix = name + "("
    guard expression.hasPrefix(prefix), expression.hasSuffix(")") else {
      return nil
    }
    return String(expression.dropFirst(prefix.count).dropLast())
  }

  private func formEncode(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._*")
    return value.addingPercentEncoding(withAllowedCharacters: allowed)?
      .replacingOccurrences(of: "%20", with: "+") ?? ""
  }

  private func numberString(_ value: Double) -> String {
    value.rounded() == value ? String(Int64(value)) : String(value)
  }

  private func scriptString(_ value: SourceScriptValue) -> String {
    switch value {
    case .undefined, .null: return ""
    case .bool(let value): return String(value)
    case .number(let value): return numberString(value)
    case .string(let value): return value
    case .array(let values): return values.map(scriptString).joined(separator: ",")
    case .object: return ""
    }
  }
}

private struct ArithmeticExpression {
  private let characters: [Character]
  private let variables: [String: Double]
  private var index = 0

  init(_ value: String, variables: [String: Double]) {
    characters = Array(value.filter { !$0.isWhitespace })
    self.variables = variables
  }

  mutating func evaluate() throws -> Double {
    let value = try sum()
    guard index == characters.count else { throw ParseError.invalid }
    return value
  }

  private mutating func sum() throws -> Double {
    var value = try product()
    while let operation = peek(), operation == "+" || operation == "-" {
      index += 1
      value = operation == "+" ? value + (try product()) : value - (try product())
    }
    return value
  }

  private mutating func product() throws -> Double {
    var value = try atom()
    while let operation = peek(), operation == "*" || operation == "/" {
      index += 1
      value = operation == "*" ? value * (try atom()) : value / (try atom())
    }
    return value
  }

  private mutating func atom() throws -> Double {
    if peek() == "(" {
      index += 1
      let value = try sum()
      guard peek() == ")" else { throw ParseError.invalid }
      index += 1
      return value
    }
    let start = index
    while let value = peek(), value.isNumber || value == "." { index += 1 }
    if start != index,
       let value = Double(String(characters[start..<index])) { return value }
    while let value = peek(), value.isLetter { index += 1 }
    let name = String(characters[start..<index])
    guard let value = variables[name] else { throw ParseError.invalid }
    return value
  }

  private func peek() -> Character? {
    index < characters.count ? characters[index] : nil
  }

  private enum ParseError: Error { case invalid }
}
