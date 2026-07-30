import Foundation
import LibraryDomain

public enum ReaderTextSearch {
  public static func results(
    content: String,
    query: String,
    bookID: BookID,
    chapterID: ChapterID,
    chapterIndex: Int,
    chapterTitle: String,
    contextLength: Int = 20
  ) -> [ReaderSearchResult] {
    guard !query.isEmpty else { return [] }
    let text = content as NSString
    let needleLength = (query as NSString).length
    guard needleLength > 0 else { return [] }
    let contextLength = max(0, contextLength)
    var searchRange = NSRange(location: 0, length: text.length)
    var values: [ReaderSearchResult] = []

    while searchRange.length > 0 {
      let match = text.range(
        of: query,
        options: [],
        range: searchRange
      )
      guard match.location != NSNotFound else { break }
      let excerptStart = max(0, match.location - contextLength)
      let excerptEnd = min(
        text.length,
        match.location + match.length + contextLength
      )
      let excerptRange = NSRange(
        location: excerptStart,
        length: excerptEnd - excerptStart
      )
      values.append(
        ReaderSearchResult(
          bookID: bookID,
          chapterID: chapterID,
          chapterIndex: chapterIndex,
          chapterTitle: chapterTitle,
          characterOffset: match.location,
          queryOffsetInExcerpt: match.location - excerptStart,
          excerpt: text.substring(with: excerptRange)
        )
      )
      let next = match.location + match.length
      guard next <= text.length else { break }
      searchRange = NSRange(
        location: next,
        length: text.length - next
      )
    }
    return values
  }

  public static func excerpt(
    content: String,
    characterOffset: Int,
    contextLength: Int = 40
  ) -> String {
    let text = content as NSString
    guard text.length > 0 else { return "" }
    let offset = min(max(0, characterOffset), text.length)
    let start = max(0, offset - max(0, contextLength))
    let end = min(text.length, offset + max(0, contextLength))
    return text.substring(
      with: NSRange(location: start, length: end - start)
    )
  }
}
