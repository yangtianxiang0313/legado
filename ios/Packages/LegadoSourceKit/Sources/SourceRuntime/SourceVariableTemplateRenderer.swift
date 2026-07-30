import Foundation

enum SourceVariableTemplateRenderer {
  static func render(
    _ template: String,
    resolver: SourceVariableResolver
  ) async throws -> String {
    var value = try await renderDelimited(
      template,
      open: "{{",
      close: "}}",
      retainsUnsupported: true,
      resolver: resolver
    )
    value = try await renderDelimited(
      value,
      open: "<js>",
      close: "</js>",
      retainsUnsupported: true,
      resolver: resolver
    )
    return value
  }

  private static func renderDelimited(
    _ input: String,
    open: String,
    close: String,
    retainsUnsupported: Bool,
    resolver: SourceVariableResolver
  ) async throws -> String {
    var output = ""
    var cursor = input.startIndex
    while
      let start = input.range(
        of: open,
        options: [.caseInsensitive],
        range: cursor..<input.endIndex
      ),
      let end = input.range(
        of: close,
        options: [.caseInsensitive],
        range: start.upperBound..<input.endIndex
      )
    {
      output += input[cursor..<start.lowerBound]
      let expression = String(
        input[start.upperBound..<end.lowerBound]
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      if isVariableScript(expression) {
        output += try await SourceVariableRuleEvaluator(
          content: "",
          resolver: resolver
        ).getString("@js:" + expression)
      } else if retainsUnsupported {
        output += input[start.lowerBound..<end.upperBound]
      }
      cursor = end.upperBound
    }
    output += input[cursor...]
    return output
  }

  private static func isVariableScript(_ value: String) -> Bool {
    let normalized = value.lowercased()
    return normalized.hasPrefix("java.get(")
      || normalized.hasPrefix("java.put(")
  }
}
