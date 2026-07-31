import Foundation

/// SourceRuntime-side projection of Android `ImageUtils.decode` for book
/// content images. The caller owns image fetching and platform decoding; this
/// type only makes the source-script byte transformation deterministic.
public struct SourceImageDecodeContext: Equatable, Sendable {
  public let sourceURL: String
  public let bindings: [String: SourceScriptValue]

  public init(
    sourceURL: String,
    bindings: [String: SourceScriptValue] = [:]
  ) {
    self.sourceURL = sourceURL
    self.bindings = bindings
  }
}

public enum SourceImageDecodeResult: Equatable, Sendable {
  case passthrough([UInt8])
  case decoded([UInt8])
  case failed(SourceScriptIssueCode)
}

public struct SourceImageDecoder: Sendable {
  private let runtime: any SourceScriptRuntime
  private let sessionID: SourceScriptSessionID
  private let library: SourceScriptLibrary?

  public init(
    runtime: any SourceScriptRuntime,
    sessionID: SourceScriptSessionID,
    library: SourceScriptLibrary? = nil
  ) {
    self.runtime = runtime
    self.sessionID = sessionID
    self.library = library
  }

  public func decode(
    bytes: [UInt8],
    rule: String?,
    context: SourceImageDecodeContext
  ) async -> SourceImageDecodeResult {
    guard let script = nonBlank(rule) else {
      return .passthrough(bytes)
    }
    var bindings = context.bindings
    bindings["src"] = .string(context.sourceURL)
    do {
      let output = try await runtime.evaluate(
        SourceScriptRequest(
          sessionID: sessionID,
          purpose: .imageDecode,
          library: library,
          script: script,
          result: .array(bytes.map { .number(Double($0)) }),
          baseURL: context.sourceURL,
          bindings: bindings
        ),
        host: nil
      )
      guard let decoded = Self.bytes(from: output) else {
        return .failed(.invalidResult)
      }
      return .decoded(decoded)
    } catch let issue as SourceScriptIssue {
      return .failed(issue.code)
    } catch {
      return .failed(.executionFailed)
    }
  }

  private static func bytes(from value: SourceScriptValue) -> [UInt8]? {
    guard case .array(let values) = value else { return nil }
    return values.reduce(into: [UInt8]()) { result, value in
      guard case .number(let number) = value,
        number.isFinite,
        number.rounded() == number,
        number >= 0,
        number <= 255
      else {
        result.removeAll(keepingCapacity: false)
        return
      }
      result.append(UInt8(number))
    }.count == values.count ? values.compactMap { value in
      guard case .number(let number) = value else { return nil }
      return UInt8(number)
    } : nil
  }

  private func nonBlank(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : value
  }
}
