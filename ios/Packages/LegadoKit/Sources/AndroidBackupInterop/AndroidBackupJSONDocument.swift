import Foundation
import LegadoCore
import SourceFormat

public protocol AndroidBackupJSONDocument: Equatable, Sendable {
  static var knownFieldNames: Set<String> { get }
  var rawFields: [String: JSONValue] { get }
  init(jsonValue: JSONValue) throws
}

public extension AndroidBackupJSONDocument {
  var jsonValue: JSONValue { .object(rawFields) }

  var unknownFields: [String: JSONValue] {
    rawFields.filter { !Self.knownFieldNames.contains($0.key) }
  }

  func rawValue(for name: String) -> JSONValue? { rawFields[name] }

  func backupString(_ name: String) -> SourceField<String> {
    backupProject(name) { value in
      guard case .string(let string) = value else { return nil }
      return string
    }
  }

  func backupBoolean(_ name: String) -> SourceField<Bool> {
    backupProject(name) { value in
      guard case .bool(let boolean) = value else { return nil }
      return boolean
    }
  }

  func backupInteger(_ name: String) -> SourceField<Int64> {
    backupProject(name) { value in
      guard case .number(let number) = value else { return nil }
      return Int64(number.rawToken)
    }
  }

  func backupObject(_ name: String) -> SourceField<[String: JSONValue]> {
    backupProject(name) { value in
      guard case .object(let object) = value else { return nil }
      return object
    }
  }

  private func backupProject<Value: Equatable & Sendable>(
    _ name: String,
    transform: (JSONValue) -> Value?
  ) -> SourceField<Value> {
    guard let raw = rawFields[name] else { return .missing }
    if case .null = raw { return .null }
    guard let value = transform(raw) else { return .typeMismatch(raw) }
    return .value(value)
  }
}

enum AndroidBackupDocumentCodec {
  static func decodeMany<Document: AndroidBackupJSONDocument>(
    _ type: Document.Type,
    from data: Data,
    maximumDepth: Int
  ) throws -> [Document] {
    let value = try JSONValueCodec.decode(data, maximumDepth: maximumDepth)
    guard case .array(let values) = value else {
      throw AndroidReplaceRuleFormatError.expectedArray
    }
    return try values.map(Document.init(jsonValue:))
  }

  static func encodeMany<Document: AndroidBackupJSONDocument>(
    _ documents: [Document]
  ) throws -> Data {
    try JSONValueCodec.encode(.array(documents.map(\.jsonValue)))
  }
}

func androidBackupFields(
  knownFieldNames: Set<String>,
  unknownFields: [String: JSONValue],
  values: [String: JSONValue?]
) -> [String: JSONValue] {
  var fields = unknownFields.filter { !knownFieldNames.contains($0.key) }
  for (name, value) in values {
    if let value { fields[name] = value }
  }
  return fields
}
