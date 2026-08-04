import Foundation
import LibraryDomain

public struct SourceSwitchCandidateProbePlan: Equatable, Sendable {
  public let loadsBookInfo: Bool
  public let loadsTableOfContents: Bool
  public let loadsChapterWordCount: Bool

  public init(preferences: SourceSwitchPreferences) {
    loadsChapterWordCount = preferences.loadsChapterWordCount
    loadsTableOfContents = preferences.loadsTableOfContents
      || preferences.loadsChapterWordCount
    loadsBookInfo = preferences.loadsBookInfo
      || preferences.loadsTableOfContents
      || preferences.loadsChapterWordCount
  }
}

public struct SourceSwitchCandidatePreview:
  Equatable, Identifiable, Sendable
{
  public let source: BookSourceDraft
  public let candidate: ShelfBookCandidate
  public let chapters: [LibraryDomain.BookChapter]
  public let probedChapterNumber: Int?
  public let chapterWordCount: Int?
  public let chapterWordCountMessage: String?
  public let responseTimeMilliseconds: Int?
  public let bookScore: Int
  public let sourceScore: Int
  public let originOrder: Int

  public var id: String { candidate.bookURL }

  public init(
    source: BookSourceDraft,
    candidate: ShelfBookCandidate,
    chapters: [LibraryDomain.BookChapter] = [],
    probedChapterNumber: Int? = nil,
    chapterWordCount: Int? = nil,
    chapterWordCountMessage: String? = nil,
    responseTimeMilliseconds: Int? = nil,
    bookScore: Int = 0,
    sourceScore: Int = 0,
    originOrder: Int = 0
  ) {
    self.source = source
    self.candidate = candidate
    self.chapters = chapters
    self.probedChapterNumber = probedChapterNumber
    self.chapterWordCount = chapterWordCount
    self.chapterWordCountMessage = chapterWordCountMessage
    self.responseTimeMilliseconds = responseTimeMilliseconds
    self.bookScore = bookScore
    self.sourceScore = sourceScore
    self.originOrder = originOrder
  }
}

public enum AndroidSourceSwitchCandidatePolicy {
  public static func sorted(
    _ candidates: [SourceSwitchCandidatePreview],
    loadsChapterWordCount: Bool
  ) -> [SourceSwitchCandidatePreview] {
    candidates.enumerated().sorted { lhs, rhs in
      compare(
        lhs.element,
        rhs.element,
        lhsOffset: lhs.offset,
        rhsOffset: rhs.offset,
        loadsChapterWordCount: loadsChapterWordCount
      )
    }.map(\.element)
  }

  private static func compare(
    _ lhs: SourceSwitchCandidatePreview,
    _ rhs: SourceSwitchCandidatePreview,
    lhsOffset: Int,
    rhsOffset: Int,
    loadsChapterWordCount: Bool
  ) -> Bool {
    if lhs.bookScore != rhs.bookScore {
      return lhs.bookScore > rhs.bookScore
    }
    if lhs.sourceScore != rhs.sourceScore {
      return lhs.sourceScore > rhs.sourceScore
    }
    if loadsChapterWordCount {
      let lhsHasUsefulCount = (lhs.chapterWordCount ?? -1) > 1_000
      let rhsHasUsefulCount = (rhs.chapterWordCount ?? -1) > 1_000
      if lhsHasUsefulCount != rhsHasUsefulCount {
        return lhsHasUsefulCount && !rhsHasUsefulCount
      }
      let lhsChapter = lhs.probedChapterNumber ?? -1
      let rhsChapter = rhs.probedChapterNumber ?? -1
      if lhsChapter != rhsChapter {
        return lhsChapter > rhsChapter
      }
      let lhsCount = lhs.chapterWordCount ?? -1
      let rhsCount = rhs.chapterWordCount ?? -1
      if lhsCount != rhsCount {
        return lhsCount > rhsCount
      }
    }
    if lhs.originOrder != rhs.originOrder {
      return lhs.originOrder < rhs.originOrder
    }
    return lhsOffset < rhsOffset
  }
}
