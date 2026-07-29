import LibraryDomain

public enum AndroidBookmarkCompatibility {
  public static func search(
    _ bookmarks: [Bookmark],
    bookName: String,
    bookAuthor: String,
    key: String
  ) -> [Bookmark] {
    ordered(
      bookmarks,
      where: { bookmark in
        (
          bookmark.bookName == bookName
            && bookmark.bookAuthor == bookAuthor
            && like(bookmark.chapterName, key: key)
        )
          || like(bookmark.content, key: key)
      }
    )
  }

  public static func insertingReplacingByTime(
    _ bookmarks: [Bookmark]
  ) -> [Bookmark] {
    var result: [Bookmark] = []
    var indexByTime: [Int64: Int] = [:]
    for bookmark in bookmarks {
      if let index = indexByTime[bookmark.time] {
        result[index] = bookmark
      } else {
        indexByTime[bookmark.time] = result.count
        result.append(bookmark)
      }
    }
    return result
  }

  static func like(_ value: String, key: String) -> Bool {
    let input = Array(value)
    let pattern = Array("%\(key)%")
    var inputIndex = 0
    var patternIndex = 0
    var wildcardIndex: Int?
    var wildcardInputIndex = 0

    while inputIndex < input.count {
      if
        patternIndex < pattern.count,
        pattern[patternIndex] == "%"
      {
        wildcardIndex = patternIndex
        wildcardInputIndex = inputIndex
        patternIndex += 1
      } else if
        patternIndex < pattern.count,
        pattern[patternIndex] == "_"
          || sqliteLiteralEqual(
            input[inputIndex],
            pattern[patternIndex]
          )
      {
        inputIndex += 1
        patternIndex += 1
      } else if let wildcardIndex {
        wildcardInputIndex += 1
        inputIndex = wildcardInputIndex
        patternIndex = wildcardIndex + 1
      } else {
        return false
      }
    }

    while
      patternIndex < pattern.count,
      pattern[patternIndex] == "%"
    {
      patternIndex += 1
    }
    return patternIndex == pattern.count
  }

  private static func ordered(
    _ bookmarks: [Bookmark],
    where predicate: (Bookmark) -> Bool
  ) -> [Bookmark] {
    bookmarks.enumerated()
      .filter { predicate($0.element) }
      .sorted { lhs, rhs in
        if lhs.element.chapterIndex != rhs.element.chapterIndex {
          return lhs.element.chapterIndex < rhs.element.chapterIndex
        }
        return lhs.offset < rhs.offset
      }
      .map(\.element)
  }

  private static func sqliteLiteralEqual(
    _ lhs: Character,
    _ rhs: Character
  ) -> Bool {
    if lhs == rhs {
      return true
    }
    guard
      lhs.isASCII,
      rhs.isASCII
    else {
      return false
    }
    return String(lhs).lowercased() == String(rhs).lowercased()
  }
}

public enum StrictBookmarkSearch {
  public static func search(
    _ bookmarks: [Bookmark],
    bookName: String,
    bookAuthor: String,
    key: String
  ) -> [Bookmark] {
    bookmarks.enumerated()
      .filter { _, bookmark in
        bookmark.bookName == bookName
          && bookmark.bookAuthor == bookAuthor
          && (
            AndroidBookmarkCompatibility.like(
              bookmark.chapterName,
              key: key
            )
              || AndroidBookmarkCompatibility.like(
                bookmark.content,
                key: key
              )
          )
      }
      .sorted { lhs, rhs in
        if lhs.element.chapterIndex != rhs.element.chapterIndex {
          return lhs.element.chapterIndex < rhs.element.chapterIndex
        }
        return lhs.offset < rhs.offset
      }
      .map(\.element)
  }
}
