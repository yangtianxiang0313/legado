import Foundation

public struct ReadAloudSegment: Equatable, Hashable, Sendable {
  public let id: String
  public let text: String
  public let startOffset: Int
  public let endOffset: Int

  public init(
    id: String,
    text: String,
    startOffset: Int,
    endOffset: Int
  ) {
    self.id = id
    self.text = text
    self.startOffset = startOffset
    self.endOffset = endOffset
  }
}

public enum ReadAloudPlan {
  public static func segments(
    content: String,
    startingAt requestedOffset: Int = 0
  ) -> [ReadAloudSegment] {
    let source = content as NSString
    let sourceLength = source.length
    let requestedOffset = min(max(0, requestedOffset), sourceLength)
    var cursor = 0
    var values: [ReadAloudSegment] = []

    while cursor <= sourceLength {
      let remaining = NSRange(
        location: cursor,
        length: sourceLength - cursor
      )
      let newline = source.range(of: "\n", options: [], range: remaining)
      let rawEnd = newline.location == NSNotFound
        ? sourceLength
        : newline.location
      let rawRange = NSRange(
        location: cursor,
        length: rawEnd - cursor
      )
      let rawText = source.substring(with: rawRange)
      let trimmed = rawText.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      let prefixLength = (rawText as NSString).range(of: trimmed).location
      let segmentStart = trimmed.isEmpty
        ? cursor
        : cursor + max(0, prefixLength)
      let segmentEnd = newline.location == NSNotFound
        ? rawEnd
        : rawEnd + newline.length

      if
        !trimmed.isEmpty,
        containsReadableCharacter(trimmed),
        segmentEnd > requestedOffset
      {
        let spokenStart = max(segmentStart, requestedOffset)
        let spokenLength = max(0, rawEnd - spokenStart)
        if spokenLength > 0 {
          let spokenText = source.substring(
            with: NSRange(
              location: spokenStart,
              length: spokenLength
            )
          ).trimmingCharacters(in: .whitespacesAndNewlines)
          if !spokenText.isEmpty, containsReadableCharacter(spokenText) {
            values.append(
              ReadAloudSegment(
                id: "read-aloud-\(spokenStart)",
                text: spokenText,
                startOffset: spokenStart,
                endOffset: segmentEnd
              )
            )
          }
        }
      }

      guard newline.location != NSNotFound else { break }
      cursor = newline.location + newline.length
    }
    return values
  }

  public static func speechRate(preference: Int) -> Float {
    Float(preference + 5) / 10
  }

  private static func containsReadableCharacter(_ text: String) -> Bool {
    text.unicodeScalars.contains {
      CharacterSet.alphanumerics.contains($0)
    }
  }
}
