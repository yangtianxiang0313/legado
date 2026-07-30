import AppNavigation
import AppUseCases
import LibraryDomain
import SwiftUI

struct ReaderContentView: View {
    let target: ReaderRoute
    @Bindable var library: ShelfLibrary
    let openTOC: () -> Void
    let openChapter: (ChapterID) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var session = ReaderContentSession(
        loader: SearchEnvironment.makeReaderContentLoader()
    )
    @State private var menuPresented = false
    @State private var menuPath: [ReaderMenuLayer] = []
    @State private var chapters: [BookChapter] = []
    @State private var isDarkTheme = false
    @State private var brightness = 1.0
    @State private var fontSize = 17.0
    @State private var lineSpacing = 8.0
    @State private var autoPageEnabled = false
    @State private var bookmarked = false

    var body: some View {
        Group {
            if let document = session.document {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(document.title)
                            .font(.title2.bold())
                            .accessibilityIdentifier("label.reader.chapterTitle")
                        Text(document.content)
                            .font(.system(size: fontSize))
                            .lineSpacing(lineSpacing)
                            .textSelection(.enabled)
                            .contextMenu {
                                textSelectionMenu
                            }
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
        .preferredColorScheme(isDarkTheme ? .dark : .light)
        .brightness(brightness - 1)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    menuPath = []
                    menuPresented = true
                } label: {
                    Label("阅读菜单", systemImage: "text.justify")
                }
                .accessibilityIdentifier("action.reader.openPrimaryMenu")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.reader")
        .task(id: target) {
            guard
                let book = await library.item(id: target.bookID),
                let chapter = await library.chapter(
                    bookID: target.bookID,
                    chapterID: target.chapterID
                )
            else { return }
            chapters = await library.chapters(bookID: target.bookID)
                .sorted { lhs, rhs in
                    if lhs.index == rhs.index {
                        return lhs.id.rawValue < rhs.id.rawValue
                    }
                    return lhs.index < rhs.index
                }
            await session.load(
                book: book,
                chapter: chapter,
                characterOffset: target.characterOffset
            )
            await saveProgress(chapter: chapter)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            Task {
                await saveCurrentProgress()
            }
        }
        .sheet(isPresented: $menuPresented) {
            NavigationStack(path: $menuPath) {
                primaryMenu
                    .navigationDestination(for: ReaderMenuLayer.self) {
                        layer in
                        switch layer {
                        case .appearance:
                            appearanceMenu
                        case .more:
                            moreMenu
                        case .primary, .textSelection:
                            EmptyView()
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var currentChapterPosition: Int? {
        chapters.firstIndex { $0.id == target.chapterID }
    }

    private var canOpenPreviousChapter: Bool {
        guard let currentChapterPosition else { return false }
        return currentChapterPosition > chapters.startIndex
    }

    private var canOpenNextChapter: Bool {
        guard let currentChapterPosition else { return false }
        return chapters.index(after: currentChapterPosition) < chapters.endIndex
    }

    private var primaryMenu: some View {
        List {
            Section {
                Button {
                    menuPresented = false
                } label: {
                    Label(
                        session.document?.title ?? "书籍信息",
                        systemImage: "book.closed"
                    )
                }
                .accessibilityIdentifier(
                    ReaderMenuAction.openBookInfo.accessibilityIdentifier
                )
            }

            Section("章节") {
                HStack {
                    Button {
                        openRelativeChapter(-1)
                    } label: {
                        Label("上一章", systemImage: "chevron.left")
                    }
                    .disabled(!canOpenPreviousChapter)
                    .accessibilityIdentifier(
                        ReaderMenuAction.previousChapter
                            .accessibilityIdentifier
                    )

                    Spacer()

                    Text(chapterProgressLabel)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(chapterProgressLabel)
                        .accessibilityIdentifier(
                            ReaderMenuAction.seekProgress
                                .accessibilityIdentifier
                        )
                        .accessibilityValue(
                            "characterOffset=\(target.characterOffset)"
                        )

                    Spacer()

                    Button {
                        openRelativeChapter(1)
                    } label: {
                        Label("下一章", systemImage: "chevron.right")
                    }
                    .disabled(!canOpenNextChapter)
                    .accessibilityIdentifier(
                        ReaderMenuAction.nextChapter
                            .accessibilityIdentifier
                    )
                }

                Button {
                    menuPresented = false
                    openTOC()
                } label: {
                    Label("目录", systemImage: "list.bullet")
                }
                .accessibilityIdentifier(
                    ReaderMenuAction.openTOC.accessibilityIdentifier
                )
            }

            Section("阅读") {
                menuPlaceholder(
                    .openBookSource,
                    title: "书籍换源",
                    systemImage: "books.vertical"
                )
                menuPlaceholder(
                    .openChapterSource,
                    title: "章节换源",
                    systemImage: "arrow.triangle.2.circlepath"
                )

                NavigationLink(value: ReaderMenuLayer.appearance) {
                    Label("外观", systemImage: "textformat.size")
                }
                .accessibilityIdentifier(
                    ReaderMenuAction.openAppearance.accessibilityIdentifier
                )

                NavigationLink(value: ReaderMenuLayer.more) {
                    Label("更多设置", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier(
                    ReaderMenuAction.openMore.accessibilityIdentifier
                )

                Toggle(
                    "自动翻页",
                    isOn: $autoPageEnabled
                )
                .accessibilityIdentifier(
                    ReaderMenuAction.toggleAutoPage.accessibilityIdentifier
                )
            }
        }
        .navigationTitle("阅读菜单")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("overlay.reader.primaryMenu")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    menuPresented = false
                }
                .accessibilityIdentifier("action.reader.closeMenu")
            }
        }
    }

    private var appearanceMenu: some View {
        Form {
            Section("主题") {
                Toggle("深色模式", isOn: $isDarkTheme)
                    .accessibilityIdentifier(
                        ReaderMenuAction.toggleTheme.accessibilityIdentifier
                    )

                VStack(alignment: .leading) {
                    Text("亮度")
                    Slider(value: $brightness, in: 0.4...1)
                        .accessibilityIdentifier(
                            ReaderMenuAction.updateBrightness
                                .accessibilityIdentifier
                        )
                }
            }

            Section("排版") {
                Stepper(
                    "字号 \(Int(fontSize))",
                    value: $fontSize,
                    in: 12...32
                )
                Stepper(
                    "行距 \(Int(lineSpacing))",
                    value: $lineSpacing,
                    in: 0...20
                )
                .accessibilityIdentifier(
                    ReaderMenuAction.updateAppearance.accessibilityIdentifier
                )
            }
        }
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("overlay.reader.appearance")
    }

    private var moreMenu: some View {
        List {
            Section("查找与替换") {
                menuPlaceholder(
                    .openSearch,
                    title: "全文搜索",
                    systemImage: "magnifyingglass"
                )
                menuPlaceholder(
                    .openReplaceRules,
                    title: "替换规则",
                    systemImage: "arrow.left.arrow.right"
                )
            }
            Section("章节") {
                menuPlaceholder(
                    .refreshCurrent,
                    title: "刷新当前章",
                    systemImage: "arrow.clockwise"
                )
                menuPlaceholder(
                    .refreshAfter,
                    title: "刷新后续章节",
                    systemImage: "arrow.clockwise.circle"
                )
                menuPlaceholder(
                    .refreshAll,
                    title: "刷新全部章节",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                menuPlaceholder(
                    .cacheOffline,
                    title: "离线缓存",
                    systemImage: "arrow.down.circle"
                )
            }
            Section("阅读工具") {
                Toggle(
                    "添加书签",
                    isOn: $bookmarked
                )
                .accessibilityIdentifier(
                    ReaderMenuAction.addBookmark.accessibilityIdentifier
                )
                menuPlaceholder(
                    .startReadAloud,
                    title: "朗读",
                    systemImage: "speaker.wave.2"
                )
                menuPlaceholder(
                    .openReadAloudSettings,
                    title: "朗读设置",
                    systemImage: "slider.horizontal.3"
                )
                menuPlaceholder(
                    .editContent,
                    title: "编辑正文",
                    systemImage: "pencil"
                )
                menuPlaceholder(
                    .configurePageAnimation,
                    title: "翻页动画",
                    systemImage: "rectangle.on.rectangle"
                )
                menuPlaceholder(
                    .updateReadingSettings,
                    title: "阅读设置",
                    systemImage: "gearshape"
                )
            }
        }
        .navigationTitle("更多设置")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("overlay.reader.more")
    }

    @ViewBuilder
    private var textSelectionMenu: some View {
        Button {
        } label: {
            Label("朗读选中内容", systemImage: "speaker.wave.2")
        }
        .accessibilityIdentifier(
            ReaderMenuAction.selectionReadAloud.accessibilityIdentifier
        )
        Button {
            bookmarked = true
        } label: {
            Label("添加书签", systemImage: "bookmark")
        }
        .accessibilityIdentifier(
            ReaderMenuAction.selectionAddBookmark.accessibilityIdentifier
        )
        Button {
        } label: {
            Label("替换", systemImage: "arrow.left.arrow.right")
        }
        .accessibilityIdentifier(
            ReaderMenuAction.selectionReplace.accessibilityIdentifier
        )
        Button {
        } label: {
            Label("全文搜索", systemImage: "magnifyingglass")
        }
        .accessibilityIdentifier(
            ReaderMenuAction.selectionSearchFullText
                .accessibilityIdentifier
        )
        Button {
        } label: {
            Label("词典", systemImage: "character.book.closed")
        }
        .accessibilityIdentifier(
            ReaderMenuAction.selectionLookupDictionary
                .accessibilityIdentifier
        )
    }

    private var chapterProgressLabel: String {
        guard let currentChapterPosition, !chapters.isEmpty else {
            return "—"
        }
        return (
            "\(currentChapterPosition + 1)/\(chapters.count)"
            + " · 位置 \(target.characterOffset)"
        )
    }

    private func openRelativeChapter(_ offset: Int) {
        guard let currentChapterPosition else { return }
        let destination = currentChapterPosition + offset
        guard chapters.indices.contains(destination) else { return }
        let chapter = chapters[destination]
        menuPresented = false
        Task {
            await saveProgress(chapter: chapter)
            openChapter(chapter.id)
        }
    }

    private func saveCurrentProgress() async {
        guard
            let chapter = chapters.first(where: {
                $0.id == target.chapterID
            })
        else { return }
        await saveProgress(chapter: chapter)
    }

    private func saveProgress(chapter: BookChapter) async {
        await library.saveReadingProgress(
            bookID: target.bookID,
            chapterIndex: chapter.index,
            characterOffset: chapter.id == target.chapterID
                ? target.characterOffset
                : 0,
            chapterTitle: chapter.title
        )
    }

    private func menuPlaceholder(
        _ action: ReaderMenuAction,
        title: String,
        systemImage: String
    ) -> some View {
        Button {
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text("待接入")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(true)
        .accessibilityIdentifier(action.accessibilityIdentifier)
    }
}
