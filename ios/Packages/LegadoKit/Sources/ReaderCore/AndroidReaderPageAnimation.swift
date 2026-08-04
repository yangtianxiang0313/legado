public enum AndroidReaderPageAnimation: Int, CaseIterable, Codable, Sendable {
  case cover = 0
  case slide = 1
  case simulation = 2
  case scroll = 3
  case none = 4

  public static func resolve(
    bookValue: Int?,
    globalValue: Int,
    isImageBook: Bool
  ) -> Self {
    let fallback = Self(rawValue: globalValue) ?? .cover
    guard let bookValue else {
      return isImageBook ? .scroll : fallback
    }
    guard bookValue >= 0 else { return fallback }
    return Self(rawValue: bookValue) ?? .none
  }

  public var usesContinuousScroll: Bool { self == .scroll }
}
