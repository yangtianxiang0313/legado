import AppNavigation
import AppUseCases
import LibraryDomain
import SwiftUI

struct ReaderContentView: View {
    let target: ReaderRoute
    @Bindable var library: ShelfLibrary

    @State private var session = ReaderContentSession(
        loader: SearchEnvironment.makeReaderContentLoader()
    )

    var body: some View {
        Group {
            if let document = session.document {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(document.title)
                            .font(.title2.bold())
                            .accessibilityIdentifier("label.reader.chapterTitle")
                        Text(document.content)
                            .font(.body)
                            .lineSpacing(8)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("text.reader.content")
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 28)
                }
                .accessibilityIdentifier("scroll.reader.content")
            } else if session.state == .failed {
                ContentUnavailableView(
                    "正文加载失败",
                    systemImage: "exclamationmark.triangle",
                    description: Text(session.errorMessage ?? "请稍后重试")
                )
            } else {
                ProgressView("正在加载正文…")
                    .accessibilityIdentifier("state.reader.loading")
            }
        }
        .navigationTitle("阅读")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.reader")
        .task(id: target) {
            guard
                session.state == .idle,
                let book = await library.item(id: target.bookID),
                let chapter = await library.chapter(
                    bookID: target.bookID,
                    chapterID: target.chapterID
                )
            else { return }
            await session.load(
                book: book,
                chapter: chapter,
                characterOffset: target.characterOffset
            )
        }
    }
}
