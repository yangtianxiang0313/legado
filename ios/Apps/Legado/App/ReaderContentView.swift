import AppNavigation
import AppUseCases
import LibraryDomain
import SwiftUI

struct ReaderContentView: View {
    let target: ReaderRoute
    @Bindable var library: ShelfLibrary
    let persistedSources: [BookSourceDraft]
    @Bindable var readAloud: ReadAloudSession
    let openTOC: () -> Void
    let openChapter: (ChapterID, Int) -> Void
    let openSourceEditor: (String?) -> Void
    private let contentLoader: any ReaderContentLoading

    @Environment(\.scenePhase) private var scenePhase
    @State private var session: ReaderContentSession
    @State private var menuPresented = false
    @State private var menuPath: [ReaderMenuLayer] = []
    @State private var chapters: [BookChapter] = []
    @State private var isDarkTheme = false
    @State private var brightness = 1.0
    @State private var fontSize = 17.0
    @State private var lineSpacing = 8.0
    @State private var autoPageEnabled = false
    @State private var bookmarked = false
    @State private var searchQuery = ""
    @State private var searchResults: [ReaderSearchResult] = []
    @State private var isSearching = false
    @State private var sourceID: String?

    init(
        target: ReaderRoute,
        library: ShelfLibrary,
        persistedSources: [BookSourceDraft],
        readAloud: ReadAloudSession,
        openTOC: @escaping () -> Void,
        openChapter: @escaping (ChapterID, Int) -> Void,
        openSourceEditor: @escaping (String?) -> Void
    ) {
        self.target = target
        self.library = library
        self.persistedSources = persistedSources
        self.readAloud = readAloud
        self.openTOC = openTOC
        self.openChapter = openChapter
        self.openSourceEditor = openSourceEditor
        let loader = library.readerContentLoader(
            fallback: SearchEnvironment.makeReaderContentLoader(
                persistedSources: persistedSources
            )
        )
        contentLoader = loader
        _session = State(
            initialValue: ReaderContentSession(
                loader: loader
            )
        )
    }

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
                    refreshBookmarkState()
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
            sourceID = book.candidate.sourceID.isEmpty
                ? nil
                : book.candidate.sourceID
            bookmarked = await library.isBookmarked(
                bookID: target.bookID,
                chapterID: chapter.id,
                characterOffset: target.characterOffset
            )
            await session.load(
                book: book,
                chapter: chapter,
                characterOffset: target.characterOffset
            )
            if
                readAloud.state == .awaitingNextChapter,
                readAloud.bookID == target.bookID,
                let document = session.document
            {
                readAloud.continueWithNextChapter(
                    document: document,
                    requestNextChapter: requestNextReadAloudChapter
                )
            }
            await saveProgress(chapter: chapter)
        }
        .onChange(of: readAloud.characterOffset) { _, offset in
            guard
                readAloud.bookID == target.bookID,
                readAloud.chapterID == target.chapterID,
                let chapter = chapters.first(where: {
                    $0.id == target.chapterID
                })
            else { return }
            Task {
                await library.saveReadingProgress(
                    bookID: target.bookID,
                    chapterIndex: chapter.index,
                    characterOffset: offset,
                    chapterTitle: chapter.title
                )
            }
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
                        case .search:
                            searchMenu
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
                Button {
                    menuPresented = false
                    openSourceEditor(sourceID)
                } label: {
                    Label("编辑书源", systemImage: "pencil")
                }
                .accessibilityIdentifier("action.reader.editSource")

                NavigationLink(value: ReaderMenuLayer.search) {
                    Label("全文搜索", systemImage: "magnifyingglass")
                }
                .accessibilityIdentifier(
                    ReaderMenuAction.openSearch.accessibilityIdentifier
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
                Button {
                    toggleCurrentBookmark()
                } label: {
                    Label(
                        bookmarked ? "移除书签" : "添加书签",
                        systemImage: bookmarked
                            ? "bookmark.fill"
                            : "bookmark"
                    )
                }
                .accessibilityIdentifier(
                    ReaderMenuAction.addBookmark.accessibilityIdentifier
                )
                readAloudControls
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

    private var searchMenu: some View {
        List {
            Section {
                TextField("搜索全书正文", text: $searchQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("input.reader.search.query")
                Button {
                    runFullTextSearch()
                } label: {
                    Label("搜索", systemImage: "magnifyingglass")
                }
                .disabled(
                    searchQuery.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty || isSearching
                )
                .accessibilityIdentifier("action.reader.search.submit")
            }

            if isSearching {
                ProgressView("正在搜索全部章节…")
                    .accessibilityIdentifier("state.reader.search.loading")
            } else {
                Section("结果 \(searchResults.count)") {
                    if searchResults.isEmpty {
                        Text(searchQuery.isEmpty ? "输入关键词开始搜索" : "没有结果")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(
                                "state.reader.search.empty"
                            )
                    }
                    ForEach(searchResults) { result in
                        Button {
                            menuPresented = false
                            openChapter(
                                result.chapterID,
                                result.characterOffset
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.chapterTitle)
                                    .font(.headline)
                                Text(result.excerpt)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        .accessibilityIdentifier(
                            "action.reader.search.result."
                                + "\(result.chapterIndex)."
                                + "\(result.characterOffset)"
                        )
                    }
                }
            }
        }
        .navigationTitle("全文搜索")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("overlay.reader.search")
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
            toggleCurrentBookmark()
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
            openChapter(chapter.id, 0)
        }
    }

    private func toggleCurrentBookmark() {
        guard
            let chapter = chapters.first(where: {
                $0.id == target.chapterID
            }),
            let document = session.document
        else { return }
        Task {
            bookmarked = await library.toggleBookmark(
                bookID: target.bookID,
                chapter: chapter,
                characterOffset: target.characterOffset,
                content: document.content
            )
        }
    }

    private func refreshBookmarkState() {
        Task {
            bookmarked = await library.isBookmarked(
                bookID: target.bookID,
                chapterID: target.chapterID,
                characterOffset: target.characterOffset
            )
        }
    }

    private func runFullTextSearch() {
        isSearching = true
        searchResults = []
        Task {
            searchResults = await library.searchBookContent(
                bookID: target.bookID,
                query: searchQuery,
                loader: contentLoader
            )
            isSearching = false
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

    @ViewBuilder
    private var readAloudControls: some View {
        let ownsSession = readAloud.bookID == target.bookID
        if ownsSession, readAloud.state == .speaking {
            Button {
                readAloud.pause()
            } label: {
                Label("暂停朗读", systemImage: "pause.circle")
            }
            .accessibilityIdentifier(
                ReaderMenuAction.pauseReadAloud.accessibilityIdentifier
            )
        } else if ownsSession, readAloud.state == .paused {
            Button {
                readAloud.resume()
            } label: {
                Label("继续朗读", systemImage: "play.circle")
            }
            .accessibilityIdentifier(
                ReaderMenuAction.resumeReadAloud.accessibilityIdentifier
            )
        } else {
            Button {
                guard let document = session.document else { return }
                readAloud.start(
                    document: document,
                    requestNextChapter: requestNextReadAloudChapter
                )
            } label: {
                Label("朗读", systemImage: "speaker.wave.2")
            }
            .disabled(session.document == nil)
            .accessibilityIdentifier(
                ReaderMenuAction.startReadAloud.accessibilityIdentifier
            )
        }

        if ownsSession, readAloud.state != .idle {
            Button(role: .destructive) {
                readAloud.stop()
            } label: {
                Label("停止朗读", systemImage: "stop.circle")
            }
            .accessibilityIdentifier(
                ReaderMenuAction.stopReadAloud.accessibilityIdentifier
            )
            Text(readAloudStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("state.reader.readAloud")
        }
    }

    private var readAloudStatus: String {
        switch readAloud.state {
        case .idle:
            return "未朗读"
        case .speaking:
            return "正在朗读"
        case .paused:
            return "已暂停"
        case .awaitingNextChapter:
            return "正在进入下一章"
        case .finished:
            return "已读完"
        case .failed:
            return readAloud.errorMessage ?? "朗读失败"
        }
    }

    private func requestNextReadAloudChapter() {
        guard
            let currentChapterPosition,
            chapters.indices.contains(currentChapterPosition + 1)
        else {
            readAloud.finishAtEndOfBook()
            return
        }
        let next = chapters[currentChapterPosition + 1]
        menuPresented = false
        openChapter(next.id, 0)
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
