import AppUseCases
import LibraryDomain
import SwiftUI

struct ChapterTOCView: View {
    let bookID: LibraryDomain.BookID
    @Bindable var library: ShelfLibrary
    let persistedSources: [BookSourceDraft]
    let openReader: (LibraryDomain.BookChapter) -> Void

    @State private var book: ShelfBookItem?
    @State private var session: ChapterTOCSession?
    @State private var selectedChapterID: LibraryDomain.ChapterID?

    var body: some View {
        ZStack {
            Group {
                if let session {
                    content(session)
                } else {
                    ProgressView("正在准备目录…")
                }
            }
        }
        .navigationTitle(book?.candidate.name ?? "目录")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.chapterTOC")
        .task(id: bookID) {
            guard session == nil,
                  let item = await library.item(id: bookID)
            else { return }
            book = item
            let value = library.chapterSession(
                loader: SearchEnvironment.makeChapterLoader(
                    persistedSources: persistedSources
                )
            )
            session = value
            await value.load(book: item)
        }
    }

    @ViewBuilder
    private func content(_ session: ChapterTOCSession) -> some View {
        if session.state == .loading && session.chapters.isEmpty {
            ProgressView("正在加载目录…")
        } else if session.chapters.isEmpty {
            ContentUnavailableView(
                "暂无目录",
                systemImage: "list.bullet.rectangle",
                description: Text(session.errorMessage ?? "请稍后重试")
            )
        } else {
            List(session.chapters) { chapter in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(chapter.title)
                        Text("第 \(chapter.index + 1) 章")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selectedChapterID == chapter.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                            .accessibilityIdentifier(
                                "state.chapter.selected"
                            )
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedChapterID = chapter.id
                    openReader(chapter)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(
                    "action.chapter.select.\(chapter.index)"
                )
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(
                    selectedChapterID == chapter.id ? .isSelected : []
                )
            }
            .accessibilityIdentifier("list.chapterTOC")
            .refreshable {
                guard let book else { return }
                await session.load(book: book, force: true)
            }
            .safeAreaInset(edge: .bottom) {
                if let selected = session.chapters.first(
                    where: { $0.id == selectedChapterID }
                ) {
                    Text("已选择：\(selected.title)")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.bar)
                        .accessibilityIdentifier(
                            "label.chapter.selected"
                        )
                }
            }
        }
    }
}
