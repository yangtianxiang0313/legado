import LegadoCore

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
