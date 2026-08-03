public struct AndroidReaderConfigProjection: Equatable, Sendable {
  public let fontSize: Double?
  public let lineSpacing: Double?

  public init(fontSize: Double?, lineSpacing: Double?) {
    self.fontSize = fontSize
    self.lineSpacing = lineSpacing
  }

  public func applying(to current: ReaderPreferences) -> ReaderPreferences {
    var result = current
    if let fontSize { result.fontSize = fontSize }
    if let lineSpacing { result.lineSpacing = lineSpacing }
    result.normalize()
    return result
  }
}
