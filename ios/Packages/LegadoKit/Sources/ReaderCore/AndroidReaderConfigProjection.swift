public struct AndroidReaderConfigProjection: Equatable, Sendable {
  public let fontSize: Double?
  public let lineSpacing: Double?
  public let pageAnimation: Int?
  public let layout: AndroidReaderLayoutProjection

  public init(
    fontSize: Double?,
    lineSpacing: Double?,
    pageAnimation: Int? = nil,
    layout: AndroidReaderLayoutProjection = AndroidReaderLayoutProjection()
  ) {
    self.fontSize = fontSize
    self.lineSpacing = lineSpacing
    self.pageAnimation = pageAnimation
    self.layout = layout
  }

  public func applying(to current: ReaderPreferences) -> ReaderPreferences {
    var result = current
    if let fontSize { result.fontSize = fontSize }
    if let lineSpacing { result.lineSpacing = lineSpacing }
    if let pageAnimation { result.pageAnimation = pageAnimation }
    result.layout = layout.applying(to: result.layout)
    result.normalize()
    return result
  }
}

public struct AndroidReaderLayoutProjection: Equatable, Sendable {
  public let textWeight: Int?
  public let letterSpacing: Double?
  public let paragraphSpacing: Int?
  public let paragraphIndent: String?
  public let titleMode: Int?
  public let paddingTop: Int?
  public let paddingBottom: Int?
  public let paddingLeft: Int?
  public let paddingRight: Int?

  public init(
    textWeight: Int? = nil,
    letterSpacing: Double? = nil,
    paragraphSpacing: Int? = nil,
    paragraphIndent: String? = nil,
    titleMode: Int? = nil,
    paddingTop: Int? = nil,
    paddingBottom: Int? = nil,
    paddingLeft: Int? = nil,
    paddingRight: Int? = nil
  ) {
    self.textWeight = textWeight
    self.letterSpacing = letterSpacing
    self.paragraphSpacing = paragraphSpacing
    self.paragraphIndent = paragraphIndent
    self.titleMode = titleMode
    self.paddingTop = paddingTop
    self.paddingBottom = paddingBottom
    self.paddingLeft = paddingLeft
    self.paddingRight = paddingRight
  }

  public func applying(
    to current: ReaderLayoutPreferences
  ) -> ReaderLayoutPreferences {
    var result = current
    if let textWeight { result.textWeight = textWeight }
    if let letterSpacing { result.letterSpacing = letterSpacing }
    if let paragraphSpacing { result.paragraphSpacing = paragraphSpacing }
    if let paragraphIndent { result.paragraphIndent = paragraphIndent }
    if let titleMode { result.titleMode = titleMode }
    if let paddingTop { result.paddingTop = paddingTop }
    if let paddingBottom { result.paddingBottom = paddingBottom }
    if let paddingLeft { result.paddingLeft = paddingLeft }
    if let paddingRight { result.paddingRight = paddingRight }
    result.normalize()
    return result
  }
}
