import AppNavigation
import AppUseCases
import LibraryDomain
import ReaderCore
import SwiftUI

struct ReaderContentView: View {
    let target: ReaderRoute
    @Bindable var library: ShelfLibrary
    let persistedSources: [BookSourceDraft]
    @Bindable var readAloud: ReadAloudSession
    @Bindable var readerPreferences: ReaderPreferencesStore
    let openTOC: () -> Void
    let openChapter: (ChapterID, Int) -> Void
    let openSourceEditor: (String?) -> Void
    private let contentLoader: any ReaderContentLoading

    @Environment(\.scenePhase) private var scenePhase
    @State private var session: ReaderContentSession
    @State private var pagination: ReaderPaginationSession
    @State private var menuPresented = false
    @State private var menuPath: [ReaderMenuLayer] = []
    @State private var chapters: [BookChapter] = []
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
        readerPreferences: ReaderPreferencesStore,
        openTOC: @escaping () -> Void,
        openChapter: @escaping (ChapterID, Int) -> Void,
        openSourceEditor: @escaping (String?) -> Void
    ) {
        self.target = target
        self.library = library
        self.persistedSources = persistedSources
        self.readAloud = readAloud
        self.readerPreferences = readerPreferences
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
        _pagination = State(
            initialValue: ReaderPaginationSession(
                paginator: NativeTextPaginator()
            )
        )
    }

    var body: some View {
        Group {
            if let document = session.document {
                pagedContent(document)
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
        .environment(
            \.colorScheme,
            readerPreferences.value.darkTheme ? .dark : .light
        )
        .brightness(readerPreferences.value.brightness - 1)
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

    private func pagedContent(_ document: ReaderDocument) -> some View {
        GeometryReader { proxy in
            let viewport = ReaderViewport(
                width: max(1, proxy.size.width - 48),
                height: max(1, proxy.size.height - 132)
            )
            VStack(alignment: .leading, spacing: 16) {
                Text(document.title)
                    .font(.title2.bold())
                    .accessibilityIdentifier("label.reader.chapterTitle")

                Group {
                    if pagination.state == .ready {
                        Text(pagination.currentPageText)
                            .font(
                                .system(
                                    size: readerPreferences.value.fontSize
                                )
                            )
                            .lineSpacing(
                                readerPreferences.value.lineSpacing
                            )
                            .textSelection(.enabled)
                            .contextMenu {
                                textSelectionMenu
                            }
                    } else {
                        ProgressView("正在分页…")
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                .accessibilityIdentifier("text.reader.content")

                HStack {
                    Button {
                        movePagedReader(by: -1)
                    } label: {
                        Label("上一页", systemImage: "chevron.left")
                    }
                    .disabled(
                        pagination.currentPageIndex == 0
                            && !canOpenPreviousChapter
                    )
                    .accessibilityIdentifier("action.reader.page.previous")

                    Spacer()

                    Text(
                        pagination.pageCount > 0
                            ? "\(pagination.currentPageIndex + 1)"
                                + "/\(pagination.pageCount)"
                            : "—"
                    )
                    .monospacedDigit()
                    .accessibilityIdentifier("label.reader.pageProgress")

                    Spacer()

                    Button {
                        movePagedReader(by: 1)
                    } label: {
                        Label("下一页", systemImage: "chevron.right")
                    }
                    .disabled(
                        pagination.pageCount > 0
                            && pagination.currentPageIndex
                                == pagination.pageCount - 1
                            && !canOpenNextChapter
                    )
                    .accessibilityIdentifier("action.reader.page.next")
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .task(
                id: ReaderPaginationRenderKey(
                    chapterID: document.position.chapterID.rawValue,
                    contentHash: document.content.hashValue,
                    width: Int(viewport.width.rounded()),
                    height: Int(viewport.height.rounded()),
                    fontSize: readerPreferences.value.fontSize,
                    lineSpacing: readerPreferences.value.lineSpacing
                )
            ) {
                pagination.layout(
                    document: document,
                    viewport: viewport,
                    typography: ReaderTypography(
                        fontSize: readerPreferences.value.fontSize,
                        lineSpacing: readerPreferences.value.lineSpacing
                    )
                )
                await savePaginationProgress()
                refreshBookmarkState()
            }
        }
    }

    private var currentReaderOffset: Int {
        pagination.state == .ready
            ? pagination.currentCharacterOffset
            : target.characterOffset
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
                            "characterOffset=\(currentReaderOffset)"
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
                    isOn: autoPageBinding
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
                Button {
                    readerPreferences.setDarkTheme(
                        !readerPreferences.value.darkTheme
                    )
                } label: {
                    HStack {
                        Label(
                            readerPreferences.value.darkTheme
                                ? "切换为浅色模式"
                                : "切换为深色模式",
                            systemImage: readerPreferences.value.darkTheme
                                ? "sun.max"
                                : "moon"
                        )
                        Spacer()
                        Text(
                            readerPreferences.value.darkTheme
                                ? "深色"
                                : "浅色"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier(
                    ReaderMenuAction.toggleTheme.accessibilityIdentifier
                )

                VStack(alignment: .leading) {
                    Text("亮度")
                    Slider(
                        value: brightnessBinding,
                        in: ReaderPreferences.brightnessRange
                    )
                        .accessibilityIdentifier(
                            ReaderMenuAction.updateBrightness
                                .accessibilityIdentifier
                        )
                }
            }

            Section("排版") {
                HStack {
                    Text(
                        "字号 \(Int(readerPreferences.value.fontSize))"
                    )
                    .accessibilityIdentifier(
                        "label.reader.fontSizeValue"
                    )
                    Spacer()
                    Button {
                        readerPreferences.setFontSize(
                            readerPreferences.value.fontSize - 1
                        )
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(
                        readerPreferences.value.fontSize
                            <= ReaderPreferences.fontSizeRange.lowerBound
                    )
                    .accessibilityIdentifier(
                        "action.reader.fontSize.decrement"
                    )
                    Button {
                        readerPreferences.setFontSize(
                            readerPreferences.value.fontSize + 1
                        )
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(
                        readerPreferences.value.fontSize
                            >= ReaderPreferences.fontSizeRange.upperBound
                    )
                    .accessibilityIdentifier(
                        "action.reader.fontSize.increment"
                    )
                }
                Stepper(
                    "行距 \(Int(readerPreferences.value.lineSpacing))",
                    value: lineSpacingBinding,
                    in: ReaderPreferences.lineSpacingRange
                )
                .accessibilityIdentifier("action.reader.updateLineSpacing")
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
            + " · 位置 \(currentReaderOffset)"
        )
    }

    private func openRelativeChapter(
        _ offset: Int,
        characterOffset: Int = 0
    ) {
        guard let currentChapterPosition else { return }
        let destination = currentChapterPosition + offset
        guard chapters.indices.contains(destination) else { return }
        let chapter = chapters[destination]
        menuPresented = false
        Task {
            await saveCurrentProgress()
            openChapter(chapter.id, characterOffset)
        }
    }

    private func movePagedReader(by delta: Int) {
        if pagination.movePage(by: delta) != nil {
            Task {
                await savePaginationProgress()
                refreshBookmarkState()
            }
            return
        }
        openRelativeChapter(
            delta,
            characterOffset: delta < 0 ? Int.max : 0
        )
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
                characterOffset: currentReaderOffset,
                content: document.content
            )
        }
    }

    private func refreshBookmarkState() {
        Task {
            bookmarked = await library.isBookmarked(
                bookID: target.bookID,
                chapterID: target.chapterID,
                characterOffset: currentReaderOffset
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
                ? currentReaderOffset
                : 0,
            chapterTitle: chapter.title
        )
    }

    private func savePaginationProgress() async {
        guard
            let chapter = chapters.first(where: {
                $0.id == target.chapterID
            })
        else { return }
        await saveProgress(chapter: chapter)
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

    private var brightnessBinding: Binding<Double> {
        Binding(
            get: { readerPreferences.value.brightness },
            set: { readerPreferences.setBrightness($0) }
        )
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { readerPreferences.value.fontSize },
            set: { readerPreferences.setFontSize($0) }
        )
    }

    private var lineSpacingBinding: Binding<Double> {
        Binding(
            get: { readerPreferences.value.lineSpacing },
            set: { readerPreferences.setLineSpacing($0) }
        )
    }

    private var autoPageBinding: Binding<Bool> {
        Binding(
            get: { readerPreferences.value.autoPageEnabled },
            set: { readerPreferences.setAutoPageEnabled($0) }
        )
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

private struct ReaderPaginationRenderKey: Hashable {
    let chapterID: String
    let contentHash: Int
    let width: Int
    let height: Int
    let fontSize: Double
    let lineSpacing: Double
}
