import Foundation
import LegadoCore
import Observation

public struct DirectLinkUploadRule: Codable, Equatable, Sendable {
  public var uploadURL: String
  public var downloadURLRule: String
  public var summary: String
  public var compress: Bool
  public var unknownFields: [String: JSONValue]

  public init(
    uploadURL: String,
    downloadURLRule: String,
    summary: String,
    compress: Bool = false,
    unknownFields: [String: JSONValue] = [:]
  ) {
    self.uploadURL = uploadURL
    self.downloadURLRule = downloadURLRule
    self.summary = summary
    self.compress = compress
    self.unknownFields = unknownFields
  }
}

public protocol DirectLinkUploadRuleRepository: Sendable {
  func directLinkUploadRule() async throws -> DirectLinkUploadRule?
  func restoreAndroidDirectLinkUploadRule(
    _ value: DirectLinkUploadRule
  ) async throws
}

public extension DirectLinkUploadRuleRepository {
  func directLinkUploadRule() async throws -> DirectLinkUploadRule? { nil }
  func restoreAndroidDirectLinkUploadRule(
    _ value: DirectLinkUploadRule
  ) async throws {}
}

@MainActor
@Observable
public final class DirectLinkUploadRuleStore {
  public private(set) var rule: DirectLinkUploadRule?
  public private(set) var errorMessage: String?
  private let repository: any DirectLinkUploadRuleRepository

  public init(repository: any DirectLinkUploadRuleRepository) {
    self.repository = repository
  }

  public func reload() async {
    do {
      rule = try await repository.directLinkUploadRule()
      errorMessage = nil
    } catch {
      errorMessage = "无法读取直链上传规则"
    }
  }

  @discardableResult
  public func save(_ value: DirectLinkUploadRule) async -> Bool {
    guard !value.uploadURL.trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty else {
      errorMessage = "上传 URL 不能为空"
      return false
    }
    guard !value.downloadURLRule
      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      errorMessage = "下载地址规则不能为空"
      return false
    }
    guard !value.summary.trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty else {
      errorMessage = "注释不能为空"
      return false
    }
    do {
      try await repository.restoreAndroidDirectLinkUploadRule(value)
      await reload()
      return true
    } catch {
      errorMessage = "无法保存直链上传规则"
      return false
    }
  }
}
