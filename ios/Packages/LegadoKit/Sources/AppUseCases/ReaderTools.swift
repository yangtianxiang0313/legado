import Foundation
import LibraryDomain
import ReaderCore

@MainActor
public extension ShelfLibrary {
  func bookmarks(
    bookID: BookID
  ) async -> [ReadingBookmark] {
    (try? await repository.bookmarks(bookID: bookID)) ?? []
  }

  func isBookmarked(
    bookID: BookID,
    chapterID: ChapterID,
    characterOffset: Int
  ) async -> Bool {
    await bookmarks(bookID: bookID).contains {
      $0.chapterID == chapterID
        && $0.characterOffset == max(0, characterOffset)
    }
  }

  @discardableResult
  func toggleBookmark(
    bookID: BookID,
    chapter: BookChapter,
    characterOffset: Int,
    content: String
  ) async -> Bool {
    let offset = max(0, characterOffset)
    let id = ReadingBookmark.stableID(
      bookID: bookID,
      chapterID: chapter.id,
      characterOffset: offset
    )
    do {
      let existing = try await repository.bookmarks(bookID: bookID)
      if existing.contains(where: { $0.id == id }) {
        try await repository.deleteBookmark(id: id)
        errorMessage = nil
        return false
      }
      try await repository.saveBookmark(
        ReadingBookmark(
          id: id,
          bookID: bookID,
          chapterID: chapter.id,
          chapterIndex: chapter.index,
          characterOffset: offset,
          chapterTitle: chapter.title,
          excerpt: ReaderTextSearch.excerpt(
            content: content,
            characterOffset: offset
          ),
          createdAtMilliseconds: Int64(
            Date().timeIntervalSince1970 * 1_000
          )
        )
      )
      errorMessage = nil
      return true
    } catch {
      errorMessage = "无法保存书签"
      return await isBookmarked(
        bookID: bookID,
        chapterID: chapter.id,
        characterOffset: offset
      )
    }
  }

  func searchBookContent(
    bookID: BookID,
    query: String,
    loader: any ReaderContentLoading
  ) async -> [ReaderSearchResult] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }
    guard let book = try? await repository.book(id: bookID) else {
      return []
    }
    let chapters =
      ((try? await repository.chapters(bookID: bookID)) ?? [])
      .sorted { $0.index < $1.index }
    var values: [ReaderSearchResult] = []
    for chapter in chapters {
      guard !Task.isCancelled else { break }
      guard
        let document = try? await loader.load(
          book: book,
          chapter: chapter,
          characterOffset: 0
        )
      else {
        continue
      }
      values.append(
        contentsOf: ReaderTextSearch.results(
          content: document.content,
          query: query,
          bookID: bookID,
          chapterID: chapter.id,
          chapterIndex: chapter.index,
          chapterTitle: chapter.title
        )
      )
    }
    return values
  }
}
