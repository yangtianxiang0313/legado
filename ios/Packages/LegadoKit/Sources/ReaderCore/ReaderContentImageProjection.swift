import Foundation

public enum ReaderContentBlock: Equatable, Sendable {
  case text(String)
  case image(sourceURL: String)
}

public struct ReaderContentImageAnchor: Equatable, Sendable {
  public let layoutCharacterOffset: Int
  public let sourceURL: String

  public init(layoutCharacterOffset: Int, sourceURL: String) {
    self.layoutCharacterOffset = layoutCharacterOffset
    self.sourceURL = sourceURL
  }
}

/// Keeps the cached source text authoritative while providing a layout-safe
/// representation for a future native image attachment renderer. Image tags
/// become one object-replacement character in layout text; offset conversion
/// maps that character back to the beginning of its original source tag.
public struct ReaderContentImageProjection: Equatable, Sendable {
  private struct Segment: Equatable, Sendable {
    let source: NSRange
    let layout: NSRange
  }

  public let sourceContent: String
  public let blocks: [ReaderContentBlock]
  public let layoutText: String
  public let imageAnchors: [ReaderContentImageAnchor]
  private let segments: [Segment]

  public init(sourceContent: String) {
    self.sourceContent = sourceContent
    let expression = Self.imageExpression
    let fullRange = NSRange(sourceContent.startIndex..., in: sourceContent)
    let matches = expression.matches(in: sourceContent, range: fullRange)
    var blocks: [ReaderContentBlock] = []
    var imageAnchors: [ReaderContentImageAnchor] = []
    var layoutText = ""
    var segments: [Segment] = []
    var sourceCursor = 0

    func appendText(_ range: NSRange) {
      guard range.length > 0,
        let swiftRange = Range(range, in: sourceContent)
      else { return }
      let value = String(sourceContent[swiftRange])
      let layoutRange = NSRange(location: (layoutText as NSString).length, length: range.length)
      blocks.append(.text(value))
      layoutText.append(value)
      segments.append(Segment(source: range, layout: layoutRange))
    }

    for match in matches {
      appendText(NSRange(location: sourceCursor, length: match.range.location - sourceCursor))
      let sourceURL = Self.imageSource(in: sourceContent, match: match) ?? ""
      let layoutRange = NSRange(location: (layoutText as NSString).length, length: 1)
      blocks.append(.image(sourceURL: sourceURL))
      imageAnchors.append(
        ReaderContentImageAnchor(
          layoutCharacterOffset: layoutRange.location,
          sourceURL: sourceURL
        )
      )
      layoutText.append("\u{FFFC}")
      segments.append(Segment(source: match.range, layout: layoutRange))
      sourceCursor = NSMaxRange(match.range)
    }
    appendText(NSRange(location: sourceCursor, length: fullRange.length - sourceCursor))
    self.blocks = blocks
    self.imageAnchors = imageAnchors
    self.layoutText = layoutText
    self.segments = segments
  }

  public func layoutOffset(forSourceOffset offset: Int) -> Int {
    let clamped = max(0, min(offset, (sourceContent as NSString).length))
    for segment in segments {
      if clamped < NSMaxRange(segment.source) {
        if segment.layout.length == 1, segment.source.length != 1 {
          return segment.layout.location
        }
        return segment.layout.location + max(0, clamped - segment.source.location)
      }
    }
    return (layoutText as NSString).length
  }

  public func sourceOffset(forLayoutOffset offset: Int) -> Int {
    let clamped = max(0, min(offset, (layoutText as NSString).length))
    for segment in segments {
      if clamped < NSMaxRange(segment.layout) {
        if segment.layout.length == 1, segment.source.length != 1 {
          return segment.source.location
        }
        return segment.source.location + max(0, clamped - segment.layout.location)
      }
    }
    return (sourceContent as NSString).length
  }

  private static let imageExpression = try! NSRegularExpression(
    pattern: #"<img\b[^>]*\bsrc\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))[^>]*>"#,
    options: [.caseInsensitive]
  )

  private static func imageSource(
    in content: String,
    match: NSTextCheckingResult
  ) -> String? {
    for index in 1...3 {
      let range = match.range(at: index)
      if range.location != NSNotFound,
        let swiftRange = Range(range, in: content)
      {
        return String(content[swiftRange])
      }
    }
    return nil
  }
}
