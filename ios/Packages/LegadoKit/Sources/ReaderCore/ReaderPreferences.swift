public struct ReaderPreferences:
  Codable, Equatable, Hashable, Sendable
{
  public static let fontSizeRange = 12.0...32.0
  public static let lineSpacingRange = 0.0...20.0
  public static let brightnessRange = 0.4...1.0

  public var darkTheme: Bool
  public var brightness: Double
  public var fontSize: Double
  public var lineSpacing: Double
  public var autoPageEnabled: Bool

  public init(
    darkTheme: Bool = false,
    brightness: Double = 1,
    fontSize: Double = 20,
    lineSpacing: Double = 12,
    autoPageEnabled: Bool = false
  ) {
    self.darkTheme = darkTheme
    self.brightness = brightness
    self.fontSize = fontSize
    self.lineSpacing = lineSpacing
    self.autoPageEnabled = autoPageEnabled
    normalize()
  }

  public mutating func normalize() {
    brightness = Self.brightnessRange.clamp(brightness)
    fontSize = Self.fontSizeRange.clamp(fontSize)
    lineSpacing = Self.lineSpacingRange.clamp(lineSpacing)
  }

  public func normalized() -> Self {
    var value = self
    value.normalize()
    return value
  }
}

private extension ClosedRange where Bound == Double {
  func clamp(_ value: Double) -> Double {
    Swift.min(Swift.max(value, lowerBound), upperBound)
  }
}
