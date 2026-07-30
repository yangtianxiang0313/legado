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

  public static func parse(_ data: Data) throws -> LocalTextBookDocument {
    guard !data.isEmpty else {
      throw LocalTextBookFailure.emptyFile
    }
    guard let text = decode(data) else {
      throw LocalTextBookFailure.unsupportedEncoding
    }
    return LocalTextBookDocument(chapters: chapters(in: text))
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
}
