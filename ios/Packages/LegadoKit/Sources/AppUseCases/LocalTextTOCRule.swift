import LibraryDomain
import Observation

public protocol LocalTextTOCRuleRepository: Sendable {
  func localTextTOCRules() async throws -> [LocalTextTOCRule]
  func restoreAndroidLocalTextTOCRules(
    _ values: [LocalTextTOCRule]
  ) async throws
}

public extension LocalTextTOCRuleRepository {
  func localTextTOCRules() async throws -> [LocalTextTOCRule] { [] }

  func restoreAndroidLocalTextTOCRules(
    _ values: [LocalTextTOCRule]
  ) async throws {}
}

@MainActor
@Observable
public final class LocalTextTOCRuleStore {
  public private(set) var rules: [LocalTextTOCRule] = []
  public private(set) var errorMessage: String?
  private let repository: any LocalTextTOCRuleRepository

  public init(repository: any LocalTextTOCRuleRepository) {
    self.repository = repository
  }

  public func reload() async {
    do {
      rules = try await repository.localTextTOCRules()
      errorMessage = nil
    } catch {
      errorMessage = "无法读取本地目录规则"
    }
  }

  @discardableResult
  public func importRules(_ values: [LocalTextTOCRule]) async -> Bool {
    do {
      try await repository.restoreAndroidLocalTextTOCRules(values)
      await reload()
      return true
    } catch {
      errorMessage = "无法导入本地目录规则"
      return false
    }
  }
}
