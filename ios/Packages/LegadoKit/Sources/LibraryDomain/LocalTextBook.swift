import Foundation

public struct LocalTextChapter: Equatable, Sendable {
  public let title: String
  public let content: String

  public init(title: String, content: String) {
    self.title = title
    self.content = content
  }
}

public struct LocalTextBookDocument: Equatable, Sendable {
  public let chapters: [LocalTextChapter]

  public init(chapters: [LocalTextChapter]) {
    self.chapters = chapters
  }
}

public enum LocalTextBookFailure: Error, Equatable, Sendable {
  case emptyFile
  case unsupportedEncoding
}

public enum LocalTextBookParser {
  public static let maximumBytesWithoutTOC = 10 * 1_024
  public static let maximumBytesWithTOC = 100 * 1_024

  private static let chapterPattern = try! NSRegularExpression(
    pattern: (
      #"^[ \t　]{0,4}(?:"# +
      #"序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|"# +
      #"第\s{0,4}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+"# +
      #"\s{0,4}(?:章|节(?!课)|卷|集(?![合和])|部(?![分赛游])|篇(?!张))|"# +
      #"(?:Chapter|Section|Part|Episode)\s{0,4}\d{1,4}"# +
      #").{0,30}$"#
    ),
    options: [.caseInsensitive]
  )

  public static func parse(
    _ data: Data,
    splitLongChapters: Bool = true
  ) throws -> LocalTextBookDocument {
    guard !data.isEmpty else {
      throw LocalTextBookFailure.emptyFile
    }
    guard let text = decode(data) else {
      throw LocalTextBookFailure.unsupportedEncoding
    }
    let hasTOC = containsChapterHeading(in: text)
    let parsed = chapters(in: text)
    let shouldSplit = !hasTOC || splitLongChapters
    guard shouldSplit else {
      return LocalTextBookDocument(chapters: parsed)
    }
    let maximumBytes =
      hasTOC ? maximumBytesWithTOC : maximumBytesWithoutTOC
    return LocalTextBookDocument(
      chapters: split(
        parsed,
        maximumBytes: maximumBytes,
        hasTOC: hasTOC
      )
    )
  }

  private static func decode(_ data: Data) -> String? {
    if
      data.starts(with: [0xFF, 0xFE]),
      let value = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
    {
      return value
    }
    if
      data.starts(with: [0xFE, 0xFF]),
      let value = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
    {
      return value
    }
    return String(data: data, encoding: .utf8)
      ?? String(data: data, encoding: .utf16)
  }

  private static func chapters(in text: String) -> [LocalTextChapter] {
    let lines = text.components(separatedBy: .newlines)
    var chapters: [LocalTextChapter] = []
    var title: String?
    var content: [String] = []

    func appendCurrent() {
      let body = content.joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard title != nil || !body.isEmpty else { return }
      chapters.append(
        LocalTextChapter(
          title: title ?? "前言",
          content: body
        )
      )
    }

    for line in lines {
      let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
      let range = NSRange(candidate.startIndex..., in: candidate)
      if
        !candidate.isEmpty,
        chapterPattern.firstMatch(
          in: candidate,
          range: range
        )?.range == range
      {
        appendCurrent()
        title = candidate
        content = []
      } else {
        content.append(line)
      }
    }
    appendCurrent()

    if chapters.isEmpty {
      return [
        LocalTextChapter(
          title: "第1章(1)",
          content: text.trimmingCharacters(
            in: .whitespacesAndNewlines
          )
        )
      ]
    }
    return chapters
  }

  private static func containsChapterHeading(in text: String) -> Bool {
    text.components(separatedBy: .newlines).contains { line in
      let candidate = line.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      guard !candidate.isEmpty else { return false }
      let range = NSRange(candidate.startIndex..., in: candidate)
      return chapterPattern.firstMatch(
        in: candidate,
        range: range
      )?.range == range
    }
  }

  private static func split(
    _ chapters: [LocalTextChapter],
    maximumBytes: Int,
    hasTOC: Bool
  ) -> [LocalTextChapter] {
    chapters.flatMap { chapter in
      let parts = splitContent(
        chapter.content,
        maximumBytes: maximumBytes
      )
      guard parts.count > 1 else {
        return [chapter]
      }
      let baseTitle = hasTOC ? chapter.title : "第1章"
      return parts.enumerated().map { index, content in
        LocalTextChapter(
          title: "\(baseTitle)(\(index + 1))",
          content: content
        )
      }
    }
  }

  private static func splitContent(
    _ content: String,
    maximumBytes: Int
  ) -> [String] {
    guard content.utf8.count > maximumBytes else {
      return [content]
    }
    var parts: [String] = []
    var current = ""
    var byteCount = 0
    for character in content {
      current.append(character)
      byteCount += String(character).utf8.count
      if
        byteCount >= maximumBytes,
        character.isNewline || byteCount >= maximumBytes * 2
      {
        let value = current.trimmingCharacters(
          in: .whitespacesAndNewlines
        )
        if !value.isEmpty {
          parts.append(value)
        }
        current = ""
        byteCount = 0
      }
    }
    let tail = current.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    if !tail.isEmpty {
      parts.append(tail)
    }
    return parts.isEmpty ? [content] : parts
  }
}
