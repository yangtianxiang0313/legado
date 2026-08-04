public struct AndroidReaderConfigProjection: Equatable, Sendable {
  public let fontSize: Double?
  public let lineSpacing: Double?
  public let pageAnimation: Int?

  public init(
    fontSize: Double?,
    lineSpacing: Double?,
    pageAnimation: Int? = nil
  ) {
    self.fontSize = fontSize
    self.lineSpacing = lineSpacing
    self.pageAnimation = pageAnimation
  }

  public func applying(to current: ReaderPreferences) -> ReaderPreferences {
    var result = current
    if let fontSize { result.fontSize = fontSize }
    if let lineSpacing { result.lineSpacing = lineSpacing }
    if let pageAnimation { result.pageAnimation = pageAnimation }
    result.normalize()
    return result
  }
}
