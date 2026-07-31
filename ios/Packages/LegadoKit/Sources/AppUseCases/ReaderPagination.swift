import Foundation
import LibraryDomain
import Observation
import ReaderCore

public struct ReaderViewport: Equatable, Hashable, Sendable {
  public let width: Double
  public let height: Double

  public init(width: Double, height: Double) {
    self.width = max(1, width)
    self.height = max(1, height)
  }
}

public struct ReaderTypography: Equatable, Hashable, Sendable {
  public let fontSize: Double
  public let lineSpacing: Double

  public init(fontSize: Double, lineSpacing: Double) {
    self.fontSize = fontSize
    self.lineSpacing = lineSpacing
  }
}

public struct ReaderImageAttachmentLayout: Equatable, Sendable {
  public let layoutCharacterOffset: Int
  public let size: ReaderImageLayoutSize

  public init(layoutCharacterOffset: Int, size: ReaderImageLayoutSize) {
    self.layoutCharacterOffset = max(0, layoutCharacterOffset)
    self.size = size
  }
}

@MainActor
public protocol ReaderPaginating: AnyObject {
  func pages(
    content: String,
    viewport: ReaderViewport,
    typography: ReaderTypography
  ) -> [ReaderLayoutPage]
}

@MainActor
public protocol ReaderImageAttachmentPaginating: ReaderPaginating {
  func pages(
    content: String,
    viewport: ReaderViewport,
    typography: ReaderTypography,
    imageAttachments: [ReaderImageAttachmentLayout]
  ) -> [ReaderLayoutPage]
}

public enum ReaderPaginationState: Equatable, Sendable {
  case idle
  case ready
  case empty
}

@MainActor
@Observable
public final class ReaderPaginationSession {
  public private(set) var state: ReaderPaginationState = .idle
  public private(set) var pages: [ReaderLayoutPage] = []
  public private(set) var currentPageIndex = 0
  public private(set) var currentCharacterOffset = 0

  private let paginator: any ReaderPaginating
  private var content = ""
  private var projection: ReaderContentImageProjection?
  private var currentLayoutCharacterOffset = 0
  private var chapterID: ChapterID?

  public init(paginator: any ReaderPaginating) {
    self.paginator = paginator
  }

  public var pageCount: Int {
    pages.count
  }

  public var currentPageText: String {
    guard pages.indices.contains(currentPageIndex) else { return "" }
    let source = content as NSString
    let start = pages[currentPageIndex].startCharacterOffset
    let end = currentPageIndex + 1 < pages.count
      ? pages[currentPageIndex + 1].startCharacterOffset
      : source.length
    guard start >= 0, end >= start, end <= source.length else {
      return ""
    }
    return source.substring(
      with: NSRange(location: start, length: end - start)
    )
  }

  public func layout(
    document: ReaderDocument,
    viewport: ReaderViewport,
    typography: ReaderTypography,
    imageAttachments: [ReaderImageAttachmentLayout] = []
  ) {
    let newProjection = ReaderContentImageProjection(
      sourceContent: document.content
    )
    let layoutContent = newProjection.layoutText
    let anchor = chapterID == document.position.chapterID
        && content == layoutContent
        && !pages.isEmpty
      ? currentLayoutCharacterOffset
      : newProjection.layoutOffset(
        forSourceOffset: max(0, document.position.characterOffset)
      )
    chapterID = document.position.chapterID
    projection = newProjection.imageAnchors.isEmpty ? nil : newProjection
    content = layoutContent
    currentLayoutCharacterOffset = min(
      anchor,
      (layoutContent as NSString).length
    )
    if let paginator = paginator as? any ReaderImageAttachmentPaginating {
      pages = paginator.pages(
        content: content,
        viewport: viewport,
        typography: typography,
        imageAttachments: imageAttachments
      )
    } else {
      pages = paginator.pages(
        content: content,
        viewport: viewport,
        typography: typography
      )
    }
    guard !pages.isEmpty else {
      currentPageIndex = 0
      state = .empty
      return
    }
    let map = try? ReaderLayoutMap(pages: pages, isComplete: true)
    currentPageIndex = map?.pageIndex(
      forCharacterOffset: currentLayoutCharacterOffset
    ) ?? pages.index(before: pages.endIndex)
    currentCharacterOffset = projection?.sourceOffset(
      forLayoutOffset: currentLayoutCharacterOffset
    ) ?? currentLayoutCharacterOffset
    state = .ready
  }

  @discardableResult
  public func movePage(by delta: Int) -> Int? {
    guard state == .ready else { return nil }
    let destination = currentPageIndex + delta
    guard pages.indices.contains(destination) else { return nil }
    currentPageIndex = destination
    currentLayoutCharacterOffset = pages[destination].startCharacterOffset
    currentCharacterOffset = projection?.sourceOffset(
      forLayoutOffset: currentLayoutCharacterOffset
    ) ?? currentLayoutCharacterOffset
    return currentCharacterOffset
  }
}
