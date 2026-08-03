public struct ReadAloudPreferences:
  Codable, Equatable, Hashable, Sendable
{
  public static let androidDefaultSpeechRate = 5
  public static let speechRateRange = 0...45

  public var followsSystemRate: Bool
  public var speechRatePreference: Int

  public init(
    followsSystemRate: Bool = true,
    speechRatePreference: Int = Self.androidDefaultSpeechRate
  ) {
    self.followsSystemRate = followsSystemRate
    self.speechRatePreference = speechRatePreference
    normalize()
  }

  public var effectiveSpeechRatePreference: Int {
    followsSystemRate
      ? Self.androidDefaultSpeechRate
      : speechRatePreference
  }

  public var relativeRate: Float {
    ReadAloudPlan.speechRate(preference: effectiveSpeechRatePreference)
  }

  public mutating func normalize() {
    speechRatePreference = min(
      Self.speechRateRange.upperBound,
      max(Self.speechRateRange.lowerBound, speechRatePreference)
    )
  }

  public func normalized() -> Self {
    var value = self
    value.normalize()
    return value
  }
}
