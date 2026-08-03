import LibraryDomain

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
