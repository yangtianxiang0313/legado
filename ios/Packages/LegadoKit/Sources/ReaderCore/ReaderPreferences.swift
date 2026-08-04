public struct ReaderLayoutPreferences:
  Codable, Equatable, Hashable, Sendable
{
  public var textWeight: Int
  public var letterSpacing: Double
  public var paragraphSpacing: Int
  public var paragraphIndent: String
  public var titleMode: Int
  public var paddingTop: Int
  public var paddingBottom: Int
  public var paddingLeft: Int
  public var paddingRight: Int

  public init(
    textWeight: Int = 0,
    letterSpacing: Double = 0.1,
    paragraphSpacing: Int = 2,
    paragraphIndent: String = "　　",
    titleMode: Int = 0,
    paddingTop: Int = 6,
    paddingBottom: Int = 6,
    paddingLeft: Int = 16,
    paddingRight: Int = 16
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
    normalize()
  }

  public mutating func normalize() {
    textWeight = min(max(textWeight, 0), 2)
    letterSpacing = min(max(letterSpacing, -0.5), 0.5)
    paragraphSpacing = min(max(paragraphSpacing, 0), 20)
    titleMode = min(max(titleMode, 0), 2)
    paddingTop = min(max(paddingTop, 0), 200)
    paddingBottom = min(max(paddingBottom, 0), 100)
    paddingLeft = min(max(paddingLeft, 0), 100)
    paddingRight = min(max(paddingRight, 0), 100)
  }
}

public struct ReaderPreferences:
  Codable, Equatable, Hashable, Sendable
{
  public static let fontSizeRange = 12.0...32.0
  public static let lineSpacingRange = 0.0...20.0
  public static let brightnessRange = 0.4...1.0
  public static let preDownloadCountRange = 0...9999

  public var darkTheme: Bool
  public var brightness: Double
  public var fontSize: Double
  public var lineSpacing: Double
  public var autoPageEnabled: Bool
  public var preDownloadCount: Int
  public var tocUsesReplacementRules: Bool
  public var pageAnimation: Int
  public var layout: ReaderLayoutPreferences

  public init(
    darkTheme: Bool = false,
    brightness: Double = 1,
    fontSize: Double = 20,
    lineSpacing: Double = 12,
    autoPageEnabled: Bool = false,
    preDownloadCount: Int = 10,
    tocUsesReplacementRules: Bool = false,
    pageAnimation: Int = AndroidReaderPageAnimation.cover.rawValue,
    layout: ReaderLayoutPreferences = ReaderLayoutPreferences()
  ) {
    self.darkTheme = darkTheme
    self.brightness = brightness
    self.fontSize = fontSize
    self.lineSpacing = lineSpacing
    self.autoPageEnabled = autoPageEnabled
    self.preDownloadCount = preDownloadCount
    self.tocUsesReplacementRules = tocUsesReplacementRules
    self.pageAnimation = pageAnimation
    self.layout = layout
    normalize()
  }

  private enum CodingKeys: String, CodingKey {
    case darkTheme
    case brightness
    case fontSize
    case lineSpacing
    case autoPageEnabled
    case preDownloadCount
    case tocUsesReplacementRules
    case pageAnimation
    case layout
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      darkTheme: try container.decodeIfPresent(Bool.self, forKey: .darkTheme)
        ?? false,
      brightness: try container.decodeIfPresent(Double.self, forKey: .brightness)
        ?? 1,
      fontSize: try container.decodeIfPresent(Double.self, forKey: .fontSize)
        ?? 20,
      lineSpacing: try container.decodeIfPresent(Double.self, forKey: .lineSpacing)
        ?? 12,
      autoPageEnabled: try container.decodeIfPresent(
        Bool.self,
        forKey: .autoPageEnabled
      ) ?? false,
      preDownloadCount: try container.decodeIfPresent(
        Int.self,
        forKey: .preDownloadCount
      ) ?? 10,
      tocUsesReplacementRules: try container.decodeIfPresent(
        Bool.self,
        forKey: .tocUsesReplacementRules
      ) ?? false,
      pageAnimation: try container.decodeIfPresent(
        Int.self,
        forKey: .pageAnimation
      ) ?? AndroidReaderPageAnimation.cover.rawValue,
      layout: try container.decodeIfPresent(
        ReaderLayoutPreferences.self,
        forKey: .layout
      ) ?? ReaderLayoutPreferences()
    )
  }

  public mutating func normalize() {
    brightness = Self.brightnessRange.clamp(brightness)
    fontSize = Self.fontSizeRange.clamp(fontSize)
    lineSpacing = Self.lineSpacingRange.clamp(lineSpacing)
    preDownloadCount = Self.preDownloadCountRange.clamp(preDownloadCount)
    if AndroidReaderPageAnimation(rawValue: pageAnimation) == nil {
      pageAnimation = AndroidReaderPageAnimation.cover.rawValue
    }
    layout.normalize()
  }

  public func normalized() -> Self {
    var value = self
    value.normalize()
    return value
  }
}

private extension ClosedRange where Bound == Int {
  func clamp(_ value: Int) -> Int {
    Swift.min(Swift.max(value, lowerBound), upperBound)
  }
}

private extension ClosedRange where Bound == Double {
  func clamp(_ value: Double) -> Double {
    Swift.min(Swift.max(value, lowerBound), upperBound)
  }
}
