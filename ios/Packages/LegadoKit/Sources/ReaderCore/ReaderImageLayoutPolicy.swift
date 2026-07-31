import Foundation

public struct ReaderImageLayoutSize: Equatable, Sendable {
  public let width: Double
  public let height: Double
  public let horizontalInset: Double

  public init(width: Double, height: Double, horizontalInset: Double) {
    self.width = width
    self.height = height
    self.horizontalInset = horizontalInset
  }
}

/// Android-compatible image bounds used by the reader's future attachment
/// renderer. `FULL` deliberately only constrains width; the default style
/// contains images within both visible dimensions.
public enum ReaderImageLayoutPolicy {
  public static func size(
    naturalWidth: Double,
    naturalHeight: Double,
    visibleWidth: Double,
    visibleHeight: Double,
    imageStyle: String?
  ) -> ReaderImageLayoutSize? {
    guard naturalWidth > 0, naturalHeight > 0,
      visibleWidth > 0, visibleHeight > 0
    else { return nil }
    var width = naturalWidth
    var height = naturalHeight
    if imageStyle?.trimmingCharacters(in: .whitespacesAndNewlines)
      .uppercased() == "FULL"
    {
      width = visibleWidth
      height = naturalHeight * visibleWidth / naturalWidth
    } else {
      if width > visibleWidth {
        height = naturalHeight * visibleWidth / naturalWidth
        width = visibleWidth
      }
      if height > visibleHeight {
        width = width * visibleHeight / height
        height = visibleHeight
      }
    }
    return ReaderImageLayoutSize(
      width: width,
      height: height,
      horizontalInset: max(0, (visibleWidth - width) / 2)
    )
  }
}
