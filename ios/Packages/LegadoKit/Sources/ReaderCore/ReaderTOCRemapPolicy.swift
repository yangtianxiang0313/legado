import Foundation

public struct ReaderTOCRemapInput: Equatable, Sendable {
  public let oldChapterIndex: Int
  public let oldChapterTitle: String?
  public let oldChapterListSize: Int
  public let newChapterTitles: [String]

  public init(
    oldChapterIndex: Int,
    oldChapterTitle: String?,
    oldChapterListSize: Int,
    newChapterTitles: [String]
  ) {
    self.oldChapterIndex = oldChapterIndex
    self.oldChapterTitle = oldChapterTitle
    self.oldChapterListSize = oldChapterListSize
    self.newChapterTitles = newChapterTitles
  }
}

public enum ReaderTOCRemapResolution:
  String, Equatable, Hashable, Sendable
{
  case selected
  case preservedUnresolved = "preserved_unresolved"
}

public enum ReaderTOCRemapReason:
  String, Equatable, Hashable, Sendable
{
  case oldIndexZero = "old_index_zero"
  case emptyTableOfContents = "empty_table_of_contents"
  case titleSimilarity = "title_similarity"
  case exactChapterNumber = "exact_chapter_number"
  case boundedOldIndexFallback = "bounded_old_index_fallback"
}

public struct ReaderTOCRemapResult: Equatable, Sendable {
  public let selectedIndex: Int
  public let selectedTitle: String?
  public let newChapterCount: Int
  public let resolution: ReaderTOCRemapResolution
  public let reason: ReaderTOCRemapReason

  public init(
    selectedIndex: Int,
    selectedTitle: String?,
    newChapterCount: Int,
    resolution: ReaderTOCRemapResolution,
    reason: ReaderTOCRemapReason
  ) {
    self.selectedIndex = selectedIndex
    self.selectedTitle = selectedTitle
    self.newChapterCount = newChapterCount
    self.resolution = resolution
    self.reason = reason
  }

  public var selectedIndexInBounds: Bool {
    selectedIndex >= 0 && selectedIndex < newChapterCount
  }
}

public enum ReaderTOCRemapPolicyError:
  String, Error, Equatable, Sendable
{
  case negativeInput = "negative_input"
  case unsupportedAndroidIntegerRange =
    "unsupported_android_integer_range"
  case unverifiedAndroidOverflow = "unverified_android_overflow"
}

public enum AndroidReaderTOCRemapPolicy {
  private static let similarityThreshold = 0.96
  private static let androidIntegerMaximum = Int(Int32.max)

  private static let chapterNumberCharacters =
    #"[\d零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+"#

  public static func remap(
    _ input: ReaderTOCRemapInput
  ) throws -> ReaderTOCRemapResult {
    try validate(input)

    if input.oldChapterIndex == 0 {
      return result(
        index: 0,
        titles: input.newChapterTitles,
        reason: .oldIndexZero
      )
    }
    guard !input.newChapterTitles.isEmpty else {
      return result(
        index: input.oldChapterIndex,
        titles: input.newChapterTitles,
        reason: .emptyTableOfContents
      )
    }

    let oldChapterNumber = chapterNumber(
      from: input.oldChapterTitle
    )
    let oldPureTitle = pureChapterTitle(
      input.oldChapterTitle
    )
    let window = try searchWindow(for: input)
    var bestSimilarity = 0.0
    var newIndex = 0
    var newChapterNumber = 0

    if !oldPureTitle.isEmpty {
      for index in window {
        let newPureTitle = pureChapterTitle(
          input.newChapterTitles[index]
        )
        let similarity = jaccardSimilarity(
          oldPureTitle,
          newPureTitle
        )
        if similarity > bestSimilarity {
          bestSimilarity = similarity
          newIndex = index
        }
      }
    }

    if bestSimilarity < similarityThreshold,
      oldChapterNumber > 0
    {
      for index in window {
        let candidate = chapterNumber(
          from: input.newChapterTitles[index]
        )
        if candidate == oldChapterNumber {
          newChapterNumber = candidate
          newIndex = index
          break
        }
        if absoluteDifference(
          candidate,
          oldChapterNumber
        )
          < absoluteDifference(
            newChapterNumber,
            oldChapterNumber
          )
        {
          newChapterNumber = candidate
          newIndex = index
        }
      }
    }

    if bestSimilarity > similarityThreshold {
      return result(
        index: newIndex,
        titles: input.newChapterTitles,
        reason: .titleSimilarity
      )
    }
    if absoluteDifference(
      newChapterNumber,
      oldChapterNumber
    ) < 1 {
      return result(
        index: newIndex,
        titles: input.newChapterTitles,
        reason: .exactChapterNumber
      )
    }
    return result(
      index: min(
        max(0, input.newChapterTitles.count - 1),
        input.oldChapterIndex
      ),
      titles: input.newChapterTitles,
      reason: .boundedOldIndexFallback
    )
  }

  private static func validate(
    _ input: ReaderTOCRemapInput
  ) throws {
    guard
      input.oldChapterIndex >= 0,
      input.oldChapterListSize >= 0
    else {
      throw ReaderTOCRemapPolicyError.negativeInput
    }
    guard
      input.oldChapterIndex <= androidIntegerMaximum,
      input.oldChapterListSize <= androidIntegerMaximum,
      input.newChapterTitles.count <= androidIntegerMaximum
    else {
      throw ReaderTOCRemapPolicyError
        .unsupportedAndroidIntegerRange
    }
  }

  private static func searchWindow(
    for input: ReaderTOCRemapInput
  ) throws -> [Int] {
    let newChapterCount = input.newChapterTitles.count
    let derivedIndex: Int
    if input.oldChapterListSize == 0 {
      derivedIndex = input.oldChapterIndex
    } else {
      let product =
        Int64(input.oldChapterIndex)
        * Int64(input.oldChapterListSize)
      guard product <= Int64(Int32.max) else {
        throw ReaderTOCRemapPolicyError
          .unverifiedAndroidOverflow
      }
      derivedIndex = Int(product) / newChapterCount
    }
    let lowerBound = max(
      0,
      min(input.oldChapterIndex, derivedIndex) - 10
    )
    let upperBound = min(
      newChapterCount - 1,
      max(input.oldChapterIndex, derivedIndex) + 10
    )
    guard lowerBound <= upperBound else { return [] }
    return Array(lowerBound...upperBound)
  }

  private static func result(
    index: Int,
    titles: [String],
    reason: ReaderTOCRemapReason
  ) -> ReaderTOCRemapResult {
    let inBounds = index >= 0 && index < titles.count
    return ReaderTOCRemapResult(
      selectedIndex: index,
      selectedTitle: inBounds ? titles[index] : nil,
      newChapterCount: titles.count,
      resolution: inBounds ? .selected : .preservedUnresolved,
      reason: reason
    )
  }

  private static func chapterNumber(
    from title: String?
  ) -> Int {
    guard let title else { return -1 }
    let normalized = replacingMatches(
      in: fullToHalf(title),
      pattern: #"\s"#
    )
    let firstPattern =
      #".*?第("# + chapterNumberCharacters
      + #")[章节篇回集话]"#
    let secondPattern =
      #"^(?:"# + chapterNumberCharacters
      + #"[,:、])*("# + chapterNumberCharacters
      + #")(?:[,:、]|\.[^\d])"#
    guard
      let token =
        firstCapture(in: normalized, pattern: firstPattern)
        ?? firstCapture(in: normalized, pattern: secondPattern)
    else {
      return -1
    }
    return stringToInteger(token)
  }

  private static func pureChapterTitle(
    _ title: String?
  ) -> String {
    guard let title else { return "" }
    let withoutWhitespace = replacingMatches(
      in: fullToHalf(title),
      pattern: #"\s"#
    )
    let prefixPattern =
      #"^.*?第(?:"# + chapterNumberCharacters
      + #")[章节篇回集话](?!$)|^(?:"# + chapterNumberCharacters
      + #"[,:、])*(?:"# + chapterNumberCharacters
      + #")(?:[,:、](?!$)|\.(?=[^\d]))"#
    let withoutPrefix = replacingMatches(
      in: withoutWhitespace,
      pattern: prefixPattern
    )
    let annotationPattern =
      #"(?!^)(?:[〖【《〔\[{(][^〖【《〔\[{()〕》】〗\]}]+)?[)〕》】〗\]}]$|^[〖【《〔\[{(](?:[^〖【《〔\[{()〕》】〗\]}]+[〕》】〗\]})])?(?!$)"#
    let withoutAnnotation = replacingMatches(
      in: withoutPrefix,
      pattern: annotationPattern
    )
    return String(
      withoutAnnotation.unicodeScalars.filter(
        isPureTitleScalar
      )
    )
  }

  private static func jaccardSimilarity(
    _ lhs: String,
    _ rhs: String
  ) -> Double {
    let left = Set(lhs.utf16)
    let right = Set(rhs.utf16)
    let union = left.union(right)
    guard !union.isEmpty else { return 1 }
    return Double(left.intersection(right).count)
      / Double(union.count)
  }

  private static func fullToHalf(_ input: String) -> String {
    var result = ""
    for scalar in input.unicodeScalars {
      let value = scalar.value
      if value == 12_288 {
        result.unicodeScalars.append(" ")
      } else if (65_281...65_374).contains(value),
        let converted = UnicodeScalar(value - 65_248)
      {
        result.unicodeScalars.append(converted)
      } else {
        result.unicodeScalars.append(scalar)
      }
    }
    return result
  }

  private static func replacingMatches(
    in input: String,
    pattern: String
  ) -> String {
    guard
      let expression = try? NSRegularExpression(
        pattern: pattern
      )
    else {
      return input
    }
    return expression.stringByReplacingMatches(
      in: input,
      range: NSRange(input.startIndex..<input.endIndex, in: input),
      withTemplate: ""
    )
  }

  private static func firstCapture(
    in input: String,
    pattern: String
  ) -> String? {
    guard
      let expression = try? NSRegularExpression(
        pattern: pattern
      ),
      let match = expression.firstMatch(
        in: input,
        range: NSRange(
          input.startIndex..<input.endIndex,
          in: input
        )
      ),
      match.numberOfRanges > 1,
      let range = Range(match.range(at: 1), in: input)
    else {
      return nil
    }
    return String(input[range])
  }

  private static func isPureTitleScalar(
    _ scalar: UnicodeScalar
  ) -> Bool {
    let value = scalar.value
    return (48...57).contains(value)
      || (65...90).contains(value)
      || value == 95
      || (97...122).contains(value)
      || value == 0x3007
      || (0x3400...0x4DBF).contains(value)
      || (0x4E00...0x9FEF).contains(value)
      || (0x20000...0x2A6DF).contains(value)
      || (0x2A700...0x2EBEF).contains(value)
  }

  private static func stringToInteger(
    _ input: String
  ) -> Int {
    let normalized = replacingMatches(
      in: fullToHalf(input),
      pattern: #"\s+"#
    )
    if let value = Int32(normalized) {
      return Int(value)
    }
    return chineseNumberToInteger(normalized)
  }

  private static func chineseNumberToInteger(
    _ input: String
  ) -> Int {
    let characters = Array(input)
    var result = 0
    var temporary = 0
    var billion = 0
    for (index, character) in characters.enumerated() {
      guard let number = chineseNumberValue(character) else {
        return -1
      }
      switch number {
      case 100_000_000:
        result += temporary
        result *= number
        billion = billion * 100_000_000 + result
        result = 0
        temporary = 0
      case 10_000:
        result += temporary
        result *= number
        temporary = 0
      case 10...:
        if temporary == 0 {
          temporary = 1
        }
        result += number * temporary
        temporary = 0
      default:
        if index >= 2,
          index == characters.count - 1,
          let previous = chineseNumberValue(
            characters[index - 1]
          ),
          previous > 10
        {
          temporary = number * previous / 10
        } else {
          temporary = temporary * 10 + number
        }
      }
    }
    return result + temporary + billion
  }

  private static func chineseNumberValue(
    _ character: Character
  ) -> Int? {
    switch character {
    case "零", "〇": 0
    case "一", "壹": 1
    case "二", "两", "贰": 2
    case "三", "叁": 3
    case "四", "肆": 4
    case "五", "伍": 5
    case "六", "陆": 6
    case "七", "柒": 7
    case "八", "捌": 8
    case "九", "玖": 9
    case "十", "拾": 10
    case "百", "佰": 100
    case "千", "仟": 1_000
    case "万": 10_000
    case "亿": 100_000_000
    default: nil
    }
  }

  private static func absoluteDifference(
    _ lhs: Int,
    _ rhs: Int
  ) -> Int {
    abs(lhs - rhs)
  }
}
