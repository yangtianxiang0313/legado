import Foundation
import LegadoCore
import Observation

public struct KeyboardAssist: Codable, Equatable, Identifiable, Sendable {
  public var id: String { "\(type):\(key)" }
  public var type: Int
  public var key: String
  public var value: String
  public var serialNumber: Int
  public var unknownFields: [String: JSONValue]

  public init(
    type: Int = 0,
    key: String,
    value: String,
    serialNumber: Int = 0,
    unknownFields: [String: JSONValue] = [:]
  ) {
    self.type = type
    self.key = key
    self.value = value
    self.serialNumber = serialNumber
    self.unknownFields = unknownFields
  }
}

public protocol KeyboardAssistRepository: Sendable {
  func keyboardAssists() async throws -> [KeyboardAssist]
  func restoreAndroidKeyboardAssists(_ values: [KeyboardAssist]) async throws
}

public extension KeyboardAssistRepository {
  func keyboardAssists() async throws -> [KeyboardAssist] { [] }
  func restoreAndroidKeyboardAssists(_ values: [KeyboardAssist]) async throws {}
}

@MainActor
@Observable
public final class KeyboardAssistStore {
  public private(set) var values: [KeyboardAssist] = []
  public private(set) var errorMessage: String?
  private let repository: any KeyboardAssistRepository

  public init(repository: any KeyboardAssistRepository) {
    self.repository = repository
  }

  public func reload(type: Int = 0) async {
    do {
      values = try await repository.keyboardAssists()
        .filter { $0.type == type }
        .sorted {
          if $0.serialNumber != $1.serialNumber {
            return $0.serialNumber < $1.serialNumber
          }
          return $0.key < $1.key
        }
      errorMessage = nil
    } catch {
      errorMessage = "无法读取辅助键"
    }
  }
}
