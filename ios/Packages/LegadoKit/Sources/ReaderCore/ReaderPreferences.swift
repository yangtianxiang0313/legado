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

  public init(
    darkTheme: Bool = false,
    brightness: Double = 1,
    fontSize: Double = 20,
    lineSpacing: Double = 12,
    autoPageEnabled: Bool = false,
    preDownloadCount: Int = 10
  ) {
    self.darkTheme = darkTheme
    self.brightness = brightness
    self.fontSize = fontSize
    self.lineSpacing = lineSpacing
    self.autoPageEnabled = autoPageEnabled
    self.preDownloadCount = preDownloadCount
    normalize()
  }

  private enum CodingKeys: String, CodingKey {
    case darkTheme
    case brightness
    case fontSize
    case lineSpacing
    case autoPageEnabled
    case preDownloadCount
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
      ) ?? 10
    )
  }

  public mutating func normalize() {
    brightness = Self.brightnessRange.clamp(brightness)
    fontSize = Self.fontSizeRange.clamp(fontSize)
    lineSpacing = Self.lineSpacingRange.clamp(lineSpacing)
    preDownloadCount = Self.preDownloadCountRange.clamp(preDownloadCount)
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
