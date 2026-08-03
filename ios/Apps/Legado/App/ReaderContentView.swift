import AppNavigation
import AppUseCases
import IntegrationKit
import LibraryDomain
import ReaderCore
import SwiftUI
import UIKit

struct ReaderContentView: View {
    let target: ReaderRoute
    @Bindable var library: ShelfLibrary
    let persistedSources: [BookSourceDraft]
    @Bindable var readAloud: ReadAloudSession
    @Bindable var readAloudPreferences: ReadAloudPreferencesStore
    @Bindable var httpTextToSpeechEngines: HTTPTextToSpeechEngineStore
    @Bindable var dictionaryLookup: DictionaryLookupStore
    @Bindable var readerPreferences: ReaderPreferencesStore
    @Bindable var replacementRules: ReaderReplacementRuleStore
    @Bindable var webDAVSettings: WebDAVConnectionSettingsStore
    let webDAVProgressLoader: any WebDAVBookProgressLoading
    let webDAVProgressUploader: WebDAVReaderProgressUploadCoordinator
    let openTOC: () -> Void
    let openChapter: (ChapterID, Int) -> Void
    let openBookInfo: (ShelfBookItem) -> Void
    let openSourceEditor: (String?) -> Void
    private let contentLoader: any ReaderContentLoading

    @Environment(\.scenePhase) private var scenePhase
    @State private var session: ReaderContentSession
    @State private var pagination: ReaderPaginationSession
    @State private var menuPresented = false
    @State private var menuPath: [ReaderMenuLayer] = []
    @State private var showsReadAloudSettings = false
    @State private var showsDictionaryLookup = false
    @State private var chapters: [BookChapter] = []
    @State private var bookmarked = false
    @State private var searchQuery = ""
    @State private var searchResults: [ReaderSearchResult] = []
    @State private var isSearching = false
    @State private var sourceID: String?
    @State private var readerBook: ShelfBookItem?
    @State private var switchingBookSource = false
    @State private var bookSourceSwitchMessage: String?
    @State private var chapterSourceResolution:
        ChapterSourceResolution?
    @State private var loadingChapterSource = false
    @State private var chapterSourceMessage: String?
    @State private var offlineCacheStartChapter = 1
    @State private var offlineCacheEndChapter = 1
    @State private var cachingOffline = false
    @State private var offlineCacheReport: OfflineCacheReport?
    @State private var contentEditorDraft: ReaderContentEditorDraft?
    @State private var replacementDraft: ReaderReplacementRule?
    @State private var readerImages: [String: UIImage] = [:]
    @State private var pendingCloudProgress: ReadingProgress?
    @State private var webDAVProgressMessage: String?
    @State private var syncingWebDAVProgress = false

    init(
        target: ReaderRoute,
        library: ShelfLibrary,
        persistedSources: [BookSourceDraft],
        readAloud: ReadAloudSession,
        readAloudPreferences: ReadAloudPreferencesStore,
        httpTextToSpeechEngines: HTTPTextToSpeechEngineStore,
        dictionaryLookup: DictionaryLookupStore,
        readerPreferences: ReaderPreferencesStore,
        replacementRules: ReaderReplacementRuleStore,
        webDAVSettings: WebDAVConnectionSettingsStore,
        webDAVProgressLoader: any WebDAVBookProgressLoading,
        webDAVProgressUploader: WebDAVReaderProgressUploadCoordinator,
        openTOC: @escaping () -> Void,
        openChapter: @escaping (ChapterID, Int) -> Void,
        openBookInfo: @escaping (ShelfBookItem) -> Void,
        openSourceEditor: @escaping (String?) -> Void
    ) {
        self.target = target
        self.library = library
        self.persistedSources = persistedSources
        self.readAloud = readAloud
        self.readAloudPreferences = readAloudPreferences
        self.httpTextToSpeechEngines = httpTextToSpeechEngines
        self.dictionaryLookup = dictionaryLookup
        self.readerPreferences = readerPreferences
        self.replacementRules = replacementRules
        self.webDAVSettings = webDAVSettings
        self.webDAVProgressLoader = webDAVProgressLoader
        self.webDAVProgressUploader = webDAVProgressUploader
        self.openTOC = openTOC
        self.openChapter = openChapter
        self.openBookInfo = openBookInfo
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
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "正文加载失败",
                        systemImage: "exclamationmark.triangle",
                        description: Text(
                            session.errorMessage ?? "请稍后重试"
                        )
                    )
                    Button {
                        refreshReaderContent(.current)
                    } label: {
                        Label("重新加载", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("action.reader.retryContent")
                }
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
        .overlay(alignment: .top) {
            if let webDAVProgressMessage {
                Text(webDAVProgressMessage)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: .capsule)
                    .padding(.top, 8)
                    .accessibilityIdentifier(
                        "state.reader.webdavProgress"
                    )
            }
        }
        .alert(
            "当前进度超过云端",
            isPresented: Binding(
                get: { pendingCloudProgress != nil },
                set: { if !$0 { pendingCloudProgress = nil } }
            ),
            presenting: pendingCloudProgress
        ) { progress in
            Button("保留本地", role: .cancel) {
                pendingCloudProgress = nil
                webDAVProgressMessage = "已保留本地进度"
            }
            Button("使用云端", role: .destructive) {
                pendingCloudProgress = nil
                applyConfirmedCloudProgress(progress)
            }
        } message: { progress in
            Text(
                "云端位于第 \(progress.position.chapterIndex + 1) 章"
                    + " · 位置 \(progress.position.characterOffset)，"
                    + "是否回退？"
            )
        }
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
            let currentPosition = chapters.firstIndex {
                $0.id == target.chapterID
            } ?? chapters.startIndex
            offlineCacheStartChapter = min(
                max(1, currentPosition + 1),
                max(1, chapters.count)
            )
            offlineCacheEndChapter = max(1, chapters.count)
            sourceID = book.candidate.sourceID.isEmpty
                ? nil
                : book.candidate.sourceID
            readerBook = book
            await library.beginReadingRecord(bookName: book.candidate.name)
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
            await synchronizeWebDAVProgress()
            if
                readAloud.state == .awaitingNextChapter,
                readAloud.bookID == target.bookID,
                let document = session.document
            {
                readAloud.continueWithNextChapter(
                    document: document,
                    relativeRate: readAloudPreferences.value.relativeRate,
                    requestNextChapter: requestNextReadAloudChapter
                )
            }
        }
        .task(id: session.document?.content) {
            guard let document = session.document else {
                readerImages = [:]
                return
            }
            readerImages = await loadReaderImages(
                ReaderContentImageProjection(sourceContent: document.content),
                bookID: document.position.bookID,
                imageDecode: document.imageDecode
            )
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
                    chapterTitle: chapter.title,
                    webDAVConfiguration:
                        webDAVSettings.value.connectionConfiguration,
                    webDAVUploader: webDAVProgressUploader
                )
            }
        }
        .onChange(of: scenePhase) { _, phase in
            Task {
                if phase == .active {
                    if let bookName = readerBook?.candidate.name {
                        await library.beginReadingRecord(bookName: bookName)
                    }
                } else {
                    await saveCurrentProgress()
                    await webDAVProgressUploader.flush()
                    await library.settleReadingRecord()
                }
            }
        }
        .onDisappear {
            Task {
                await saveCurrentProgress()
                await webDAVProgressUploader.flush()
                await library.settleReadingRecord()
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
                        case .replacementRules:
                            replacementRulesMenu
                        case .bookSource:
                            bookSourceMenu
                        case .chapterSource:
                            chapterSourceMenu
                        case .offlineCache:
                            offlineCacheMenu
                        case .primary, .textSelection:
                            EmptyView()
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $contentEditorDraft) { draft in
            ReaderContentEditor(
                draft: draft,
                save: { content in
                    saveEditedContent(content)
                },
                reset: {
                    resetEditedContent()
                },
                cancel: {
                    contentEditorDraft = nil
                }
            )
        }
        .sheet(isPresented: $showsReadAloudSettings) {
            NavigationStack {
                ReadAloudEngineSettingsView(
                    store: httpTextToSpeechEngines,
                    preferences: readAloudPreferences,
                    select: { id in
                        readAloud.stop()
                        httpTextToSpeechEngines.select(id)
                    }
                )
            }
        }
        .sheet(isPresented: $showsDictionaryLookup) {
            DictionaryLookupView(store: dictionaryLookup)
        }
    }

    private func pagedContent(_ document: ReaderDocument) -> some View {
        GeometryReader { proxy in
            let projection = ReaderContentImageProjection(
                sourceContent: document.content
            )
            let viewport = ReaderViewport(
                width: max(1, proxy.size.width - 48),
                height: max(1, proxy.size.height - 132)
            )
            let imageLayouts = readerImageLayouts(
                projection: projection,
                viewport: viewport,
                imageStyle: document.imageStyle
            )
            let currentPageStart = pagination.pages.indices.contains(
                pagination.currentPageIndex
            ) ? pagination.pages[pagination.currentPageIndex]
                .startCharacterOffset : 0
            let currentPageEnd = pagination.currentPageIndex + 1 < pagination.pages.count
                ? pagination.pages[pagination.currentPageIndex + 1]
                    .startCharacterOffset
                : (projection.layoutText as NSString).length
            let pageAttachments = imageLayouts.compactMap { attachment -> ReaderImageAttachmentLayout? in
                guard attachment.layoutCharacterOffset >= currentPageStart,
                    attachment.layoutCharacterOffset < currentPageEnd
                else { return nil }
                return ReaderImageAttachmentLayout(
                    layoutCharacterOffset:
                        attachment.layoutCharacterOffset - currentPageStart,
                    size: attachment.size
                )
            }
            let pageImageSources: [Int: String] = projection.imageAnchors.reduce(
                into: [:]
            ) { result, anchor in
                guard anchor.layoutCharacterOffset >= currentPageStart,
                    anchor.layoutCharacterOffset < currentPageEnd
                else { return }
                result[anchor.layoutCharacterOffset - currentPageStart] =
                    anchor.sourceURL
            }
            VStack(alignment: .leading, spacing: 16) {
                Text(document.title)
                    .font(.title2.bold())
                    .accessibilityIdentifier("label.reader.chapterTitle")

                Group {
                    if pagination.state == .ready {
                        ReaderPageTextView(
                            text: pagination.currentPageText,
                            attachments: pageAttachments,
                            images: readerImages,
                            imageSources: pageImageSources,
                            fontSize: readerPreferences.value.fontSize,
                            lineSpacing: readerPreferences.value.lineSpacing
                        )
                        if !pageAttachments.isEmpty {
                            Text("本页含 \(pageAttachments.count) 张插图")
                                .font(.caption)
                                .accessibilityIdentifier("label.reader.inlineImage")
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

                if !projection.imageAnchors.isEmpty {
                    Text(
                        "正文含 \(projection.imageAnchors.count) 张插图，"
                            + "已加载 \(imageLayouts.count) 张"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("state.reader.inlineImage")
                }

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
                    lineSpacing: readerPreferences.value.lineSpacing,
                    imageCount: readerImages.count
                )
            ) {
                pagination.layout(
                    document: document,
                    viewport: viewport,
                    typography: ReaderTypography(
                        fontSize: readerPreferences.value.fontSize,
                        lineSpacing: readerPreferences.value.lineSpacing
                    ),
                    imageAttachments: imageLayouts
                )
                await savePaginationProgress()
                refreshBookmarkState()
            }
        }
    }

    private func readerImageLayouts(
        projection: ReaderContentImageProjection,
        viewport: ReaderViewport,
        imageStyle: String?
    ) -> [ReaderImageAttachmentLayout] {
        projection.imageAnchors.compactMap { anchor in
            guard let image = readerImages[anchor.sourceURL],
                let size = ReaderImageLayoutPolicy.size(
                    naturalWidth: image.size.width,
                    naturalHeight: image.size.height,
                    visibleWidth: viewport.width,
                    visibleHeight: viewport.height,
                    imageStyle: imageStyle
                )
            else { return nil }
            return ReaderImageAttachmentLayout(
                layoutCharacterOffset: anchor.layoutCharacterOffset,
                size: size
            )
        }
    }

    @MainActor
    private func loadReaderImages(
        _ projection: ReaderContentImageProjection,
        bookID: BookID,
        imageDecode: String?
    ) async -> [String: UIImage] {
        let sources = Set(projection.imageAnchors.map(\.sourceURL))
        let tasks = sources.map { source in
            Task { @MainActor in
                let image = await SearchEnvironment.loadReaderImage(
                    source,
                    bookID: bookID,
                    imageDecode: imageDecode
                )
                return (source, image)
            }
        }
        var images: [String: UIImage] = [:]
        for task in tasks {
            let (source, image) = await task.value
            if let image {
                images[source] = image
            }
        }
        return images
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
                    guard let readerBook else { return }
                    menuPresented = false
                    openBookInfo(readerBook)
                } label: {
                    Label(
                        session.document?.title ?? "书籍信息",
                        systemImage: "book.closed"
                    )
                }
                .accessibilityIdentifier(
                    ReaderMenuAction.openBookInfo.accessibilityIdentifier
                )
                .disabled(readerBook == nil)
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
                NavigationLink(value: ReaderMenuLayer.bookSource) {
                    Label("书籍换源", systemImage: "books.vertical")
                }
                .disabled(
                    readerBook == nil || switchableBookSources.isEmpty
                )
                .accessibilityIdentifier(
                    ReaderMenuAction.openBookSource
                        .accessibilityIdentifier
                )
                NavigationLink(value: ReaderMenuLayer.chapterSource) {
                    Label(
                        "章节换源",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(
                    readerBook == nil || switchableBookSources.isEmpty
                )
                .accessibilityIdentifier(
                    ReaderMenuAction.openChapterSource
                        .accessibilityIdentifier
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
            Section("跨端同步") {
                Button {
                    menuPresented = false
                    Task { await synchronizeWebDAVProgress() }
                } label: {
                    Label(
                        syncingWebDAVProgress ? "正在同步进度…" : "同步云端进度",
                        systemImage: "arrow.triangle.2.circlepath.icloud"
                    )
                }
                .disabled(
                    syncingWebDAVProgress
                        || webDAVSettings.value.connectionConfiguration == nil
                )
                .accessibilityIdentifier(
                    ReaderMenuAction.syncProgress.accessibilityIdentifier
                )
            }
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
                NavigationLink(value: ReaderMenuLayer.replacementRules) {
                    Label(
                        "替换规则",
                        systemImage: "arrow.left.arrow.right"
                    )
                }
                .accessibilityIdentifier(
                    ReaderMenuAction.openReplaceRules
                        .accessibilityIdentifier
                )
            }
            Section("章节") {
                Button {
                    refreshReaderContent(.current)
                } label: {
                    Label("刷新当前章", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier(
                    ReaderMenuAction.refreshCurrent
                        .accessibilityIdentifier
                )
                Button {
                    refreshReaderContent(.currentAndAfter)
                } label: {
                    Label(
                        "刷新后续章节",
                        systemImage: "arrow.clockwise.circle"
                    )
                }
                .accessibilityIdentifier(
                    ReaderMenuAction.refreshAfter
                        .accessibilityIdentifier
                )
                Button {
                    refreshReaderContent(.all)
                } label: {
                    Label(
                        "刷新全部章节",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .accessibilityIdentifier(
                    ReaderMenuAction.refreshAll
                        .accessibilityIdentifier
                )
                NavigationLink(value: ReaderMenuLayer.offlineCache) {
                    Label(
                        "离线缓存",
                        systemImage: "arrow.down.circle"
                    )
                }
                .disabled(chapters.isEmpty)
                .accessibilityIdentifier(
                    ReaderMenuAction.cacheOffline.accessibilityIdentifier
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
                Button {
                    menuPresented = false
                    Task {
                        await Task.yield()
                        showsReadAloudSettings = true
                    }
                } label: {
                    Label("朗读设置", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier(
                    ReaderMenuAction.openReadAloudSettings
                        .accessibilityIdentifier
                )
                Button {
                    menuPresented = false
                    Task {
                        await Task.yield()
                        showsDictionaryLookup = true
                    }
                } label: {
                    Label("词典", systemImage: "character.book.closed")
                }
                .accessibilityIdentifier(
                    ReaderMenuAction.selectionLookupDictionary
                        .accessibilityIdentifier
                )
                Button {
                    guard let document = session.document else {
                        return
                    }
                    let draft = ReaderContentEditorDraft(
                        chapterID: target.chapterID,
                        title: document.title,
                        content: document.content,
                        canReset: !AndroidWebDAVBookOrigin.isLocalSource(
                            readerBook?.candidate.sourceID ?? ""
                        )
                    )
                    menuPresented = false
                    Task {
                        await Task.yield()
                        contentEditorDraft = draft
                    }
                } label: {
                    Label("编辑正文", systemImage: "pencil")
                }
                .disabled(session.document == nil)
                .accessibilityIdentifier(
                    ReaderMenuAction.editContent.accessibilityIdentifier
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

    private var bookSourceMenu: some View {
        List {
            if let bookSourceSwitchMessage {
                Section {
                    Text(bookSourceSwitchMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier(
                            "state.reader.bookSource.error"
                        )
                }
            }
            Section("可用书源") {
                if switchableBookSources.isEmpty {
                    Text("没有其他已启用书源")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(
                            "state.reader.bookSource.empty"
                        )
                }
                ForEach(switchableBookSources) { source in
                    Button {
                        switchReaderBookSource(to: source)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.name)
                            Text(source.sourceURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(switchingBookSource)
                    .accessibilityIdentifier(
                        "action.reader.bookSource."
                            + source.sourceURL
                    )
                }
            }
        }
        .overlay {
            if switchingBookSource {
                ProgressView("正在搜索并迁移目录…")
                    .padding()
                    .background(
                        .regularMaterial,
                        in: .rect(cornerRadius: 12)
                    )
            }
        }
        .navigationTitle("书籍换源")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("overlay.reader.bookSource")
    }

    private var switchableBookSources: [BookSourceDraft] {
        persistedSources.filter {
            $0.sourceURL != sourceID
                && ($0.importMetadata?.enabled ?? true)
        }
    }

    private var chapterSourceMenu: some View {
        List {
            if let chapterSourceMessage {
                Section {
                    Text(chapterSourceMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier(
                            "state.reader.chapterSource.error"
                        )
                }
            }
            if let resolution = chapterSourceResolution {
                Section {
                    Button {
                        chapterSourceResolution = nil
                        chapterSourceMessage = nil
                    } label: {
                        Label(
                            "重新选择书源",
                            systemImage: "chevron.backward"
                        )
                    }
                    Text("目标书源：\(resolution.source.name)")
                        .foregroundStyle(.secondary)
                }
                Section("选择目标章节") {
                    ForEach(resolution.chapters) { chapter in
                        Button {
                            replaceCurrentChapterContent(
                                with: chapter,
                                resolution: resolution
                            )
                        } label: {
                            HStack {
                                VStack(
                                    alignment: .leading,
                                    spacing: 3
                                ) {
                                    Text(chapter.title)
                                    Text("第 \(chapter.index + 1) 章")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if
                                    chapter.id
                                        == resolution.suggestedChapterID
                                {
                                    Image(systemName: "checkmark.circle")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .disabled(loadingChapterSource)
                        .accessibilityIdentifier(
                            "action.reader.chapterSource.chapter."
                                + chapter.id.rawValue
                        )
                    }
                }
            } else {
                Section("选择书源") {
                    ForEach(switchableBookSources) { source in
                        Button {
                            loadChapterSource(from: source)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name)
                                Text(source.sourceURL)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(loadingChapterSource)
                        .accessibilityIdentifier(
                            "action.reader.chapterSource.source."
                                + source.sourceURL
                        )
                    }
                }
            }
        }
        .overlay {
            if loadingChapterSource {
                ProgressView(
                    chapterSourceResolution == nil
                        ? "正在搜索并加载目录…"
                        : "正在抓取目标章节…"
                )
                .padding()
                .background(
                    .regularMaterial,
                    in: .rect(cornerRadius: 12)
                )
            }
        }
        .navigationTitle("章节换源")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("overlay.reader.chapterSource")
    }

    private var offlineCacheMenu: some View {
        Form {
            Section("章节范围") {
                Stepper(
                    "起始：第 \(offlineCacheStartChapter) 章",
                    value: $offlineCacheStartChapter,
                    in: 1...max(1, offlineCacheEndChapter)
                )
                .disabled(cachingOffline)
                .accessibilityIdentifier(
                    "input.reader.offlineCache.start"
                )

                Stepper(
                    "结束：第 \(offlineCacheEndChapter) 章",
                    value: $offlineCacheEndChapter,
                    in: min(
                        offlineCacheStartChapter,
                        max(1, chapters.count)
                    )...max(1, chapters.count)
                )
                .disabled(cachingOffline)
                .accessibilityIdentifier(
                    "input.reader.offlineCache.end"
                )

                Text(
                    "默认从当前章节缓存到末章，共 "
                        + "\(offlineCacheSelectedCount) 章"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    startOfflineCache()
                } label: {
                    Label(
                        cachingOffline ? "正在缓存…" : "开始缓存",
                        systemImage: "arrow.down.circle"
                    )
                }
                .disabled(cachingOffline || chapters.isEmpty)
                .accessibilityIdentifier(
                    "action.reader.offlineCache.start"
                )

                if cachingOffline {
                    ProgressView(
                        value: Double(library.offlineCacheProgress),
                        total: Double(max(1, offlineCacheSelectedCount))
                    )
                    .accessibilityIdentifier(
                        "state.reader.offlineCache.progress"
                    )
                }
            }

            if let offlineCacheReport {
                Section("缓存结果") {
                    LabeledContent(
                        "成功",
                        value: "\(offlineCacheReport.cachedCount)"
                    )
                    LabeledContent(
                        "已存在",
                        value: "\(offlineCacheReport.skippedCount)"
                    )
                    LabeledContent(
                        "失败",
                        value: "\(offlineCacheReport.failedCount)"
                    )
                    if offlineCacheReport.cancelledCount > 0 {
                        LabeledContent(
                            "取消",
                            value: "\(offlineCacheReport.cancelledCount)"
                        )
                    }
                }
                .accessibilityIdentifier(
                    "state.reader.offlineCache.result"
                )
            }
        }
        .navigationTitle("离线缓存")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("overlay.reader.offlineCache")
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

    private var replacementRulesMenu: some View {
        List {
            Section {
                Button {
                    replacementDraft = ReaderReplacementRule(
                        name: "",
                        pattern: "",
                        replacement: "",
                        isRegex: false,
                        order: replacementRules.nextOrder
                    )
                } label: {
                    Label("新增规则", systemImage: "plus")
                }
                .accessibilityIdentifier(
                    "action.reader.replacement.add"
                )
            }

            if let errorMessage = replacementRules.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier(
                            "state.reader.replacement.error"
                        )
                }
            }

            Section("规则 \(replacementRules.rules.count)") {
                if replacementRules.rules.isEmpty {
                    Text("暂无替换规则")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(
                            "state.reader.replacement.empty"
                        )
                }
                ForEach(replacementRules.rules) { rule in
                    HStack {
                        Button {
                            replacementDraft = rule
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(rule.name)
                                    .font(.headline)
                                Text("\(rule.pattern) → \(rule.replacement)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(
                            "action.reader.replacement.edit.\(rule.id)"
                        )

                        Toggle(
                            "启用",
                            isOn: Binding(
                                get: { rule.isEnabled },
                                set: { enabled in
                                    Task {
                                        if await replacementRules.setEnabled(
                                            id: rule.id,
                                            enabled: enabled
                                        ) {
                                            await reloadCurrentContent()
                                        }
                                    }
                                }
                            )
                        )
                        .labelsHidden()
                        .accessibilityIdentifier(
                            "action.reader.replacement.toggle.\(rule.id)"
                        )
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task {
                                if await replacementRules.delete(id: rule.id) {
                                    await reloadCurrentContent()
                                }
                            }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        .accessibilityIdentifier(
                            "action.reader.replacement.delete.\(rule.id)"
                        )
                    }
                }
            }
        }
        .task {
            await replacementRules.reload()
        }
        .navigationTitle("替换规则")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("overlay.reader.replacementRules")
        .sheet(item: $replacementDraft) { rule in
            ReaderReplacementRuleEditor(
                rule: rule,
                save: { updated in
                    Task {
                        guard await replacementRules.save(updated) else {
                            return
                        }
                        replacementDraft = nil
                        menuPresented = false
                        await reloadCurrentContent()
                    }
                },
                cancel: {
                    replacementDraft = nil
                }
            )
        }
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

    private var offlineCacheSelectedCount: Int {
        max(
            0,
            offlineCacheEndChapter - offlineCacheStartChapter + 1
        )
    }

    private func startOfflineCache() {
        guard
            !cachingOffline,
            !chapters.isEmpty,
            offlineCacheStartChapter <= offlineCacheEndChapter
        else { return }
        let chapterIndexes: ClosedRange<Int> =
            (offlineCacheStartChapter - 1)...(offlineCacheEndChapter - 1)
        cachingOffline = true
        offlineCacheReport = nil
        Task {
            offlineCacheReport = await library.cacheOffline(
                bookID: target.bookID,
                chapterIndexes: chapterIndexes,
                loader: contentLoader
            )
            cachingOffline = false
        }
    }

    private func saveEditedContent(_ content: String) {
        contentEditorDraft = nil
        Task {
            await library.cacheChapterContent(
                content,
                bookID: target.bookID,
                chapterID: target.chapterID
            )
            await reloadCurrentContent()
        }
    }

    private func resetEditedContent() {
        contentEditorDraft = nil
        Task {
            guard await library.invalidateReaderContent(
                bookID: target.bookID,
                currentChapterID: target.chapterID,
                scope: .current
            ) else { return }
            await reloadCurrentContent()
        }
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

    private func reloadCurrentContent() async {
        guard
            let book = await library.item(id: target.bookID),
            let chapter = chapters.first(where: {
                $0.id == target.chapterID
            })
        else { return }
        let anchor = currentReaderOffset
        await session.load(
            book: book,
            chapter: chapter,
            characterOffset: anchor
        )
        refreshBookmarkState()
    }

    private func refreshReaderContent(
        _ scope: ReaderContentRefreshScope
    ) {
        menuPresented = false
        Task {
            guard await library.invalidateReaderContent(
                bookID: target.bookID,
                currentChapterID: target.chapterID,
                scope: scope
            ) else { return }
            await reloadCurrentContent()
        }
    }

    private func switchReaderBookSource(to source: BookSourceDraft) {
        guard let readerBook else { return }
        switchingBookSource = true
        bookSourceSwitchMessage = nil
        Task {
            do {
                let resolved = try await SearchEnvironment
                    .resolveSourceSwitch(
                        current: readerBook,
                        target: source,
                        persistedSources: persistedSources
                    )
                guard
                    let switched = await library.switchSource(
                        current: readerBook,
                        candidate: resolved.candidate,
                        chapters: resolved.chapters
                    )
                else {
                    bookSourceSwitchMessage =
                        library.errorMessage ?? "目标书源无法迁移"
                    switchingBookSource = false
                    return
                }
                let migratedChapters = await library.chapters(
                    bookID: switched.id
                ).sorted { $0.index < $1.index }
                guard
                    let progress = switched.progress,
                    let chapter = migratedChapters.first(where: {
                        $0.index == progress.position.chapterIndex
                    })
                else {
                    bookSourceSwitchMessage = "换源后无法定位映射章节"
                    switchingBookSource = false
                    return
                }
                self.readerBook = switched
                sourceID = switched.candidate.sourceID
                chapters = migratedChapters
                switchingBookSource = false
                menuPresented = false
                openChapter(
                    chapter.id,
                    progress.position.characterOffset
                )
            } catch {
                bookSourceSwitchMessage =
                    "目标书源解析失败：\(String(reflecting: error))"
                switchingBookSource = false
            }
        }
    }

    private func loadChapterSource(from source: BookSourceDraft) {
        guard
            let readerBook,
            let currentChapter = chapters.first(where: {
                $0.id == target.chapterID
            })
        else { return }
        loadingChapterSource = true
        chapterSourceMessage = nil
        Task {
            do {
                chapterSourceResolution =
                    try await SearchEnvironment.resolveChapterSource(
                        current: readerBook,
                        currentChapter: currentChapter,
                        target: source,
                        persistedSources: persistedSources
                    )
            } catch {
                chapterSourceMessage =
                    "目标书源目录加载失败："
                    + String(reflecting: error)
            }
            loadingChapterSource = false
        }
    }

    private func replaceCurrentChapterContent(
        with chapter: BookChapter,
        resolution: ChapterSourceResolution
    ) {
        loadingChapterSource = true
        chapterSourceMessage = nil
        Task {
            do {
                let index = resolution.chapters.firstIndex {
                    $0.id == chapter.id
                }
                let nextChapter = index.flatMap {
                    resolution.chapters.indices.contains($0 + 1)
                        ? resolution.chapters[$0 + 1]
                        : nil
                }
                let content = try await SearchEnvironment
                    .loadChapterSourceContent(
                        book: resolution.book,
                        chapter: chapter,
                        nextChapter: nextChapter,
                        persistedSources: persistedSources
                    )
                await library.cacheChapterContent(
                    content,
                    bookID: target.bookID,
                    chapterID: target.chapterID
                )
                guard library.errorMessage == nil else {
                    chapterSourceMessage =
                        library.errorMessage ?? "无法保存目标正文"
                    loadingChapterSource = false
                    return
                }
                loadingChapterSource = false
                menuPresented = false
                await reloadCurrentContent()
            } catch {
                chapterSourceMessage =
                    "目标章节正文加载失败："
                    + String(reflecting: error)
                loadingChapterSource = false
            }
        }
    }

    private func saveProgress(chapter: BookChapter) async {
        await library.saveReadingProgress(
            bookID: target.bookID,
            chapterIndex: chapter.index,
            characterOffset: chapter.id == target.chapterID
                ? currentReaderOffset
                : 0,
            chapterTitle: chapter.title,
            webDAVConfiguration:
                webDAVSettings.value.connectionConfiguration,
            webDAVUploader: webDAVProgressUploader
        )
    }

    @MainActor
    private func synchronizeWebDAVProgress() async {
        guard
            !syncingWebDAVProgress,
            webDAVSettings.value.connectionConfiguration != nil
        else { return }
        syncingWebDAVProgress = true
        let outcome = await library.synchronizeWebDAVReaderProgress(
            bookID: target.bookID,
            configuration: webDAVSettings.value.connectionConfiguration,
            loader: webDAVProgressLoader
        )
        syncingWebDAVProgress = false
        switch outcome {
        case .applied(let progress):
            webDAVProgressMessage = "已同步云端进度"
            navigateToCloudProgress(progress)
        case .confirmationRequired(let progress):
            pendingCloudProgress = progress
        case .failed(let failure):
            webDAVProgressMessage = webDAVProgressFailureMessage(failure)
        }
    }

    private func applyConfirmedCloudProgress(_ progress: ReadingProgress) {
        Task { @MainActor in
            let outcome = await library.confirmWebDAVReaderProgress(
                progress,
                bookID: target.bookID
            )
            switch outcome {
            case .applied(let applied):
                webDAVProgressMessage = "已回退到云端进度"
                navigateToCloudProgress(applied)
            case .confirmationRequired:
                webDAVProgressMessage = "云端进度仍需确认"
            case .failed(let failure):
                webDAVProgressMessage = webDAVProgressFailureMessage(failure)
            }
        }
    }

    private func navigateToCloudProgress(_ progress: ReadingProgress) {
        guard
            let chapter = chapters.first(where: {
                $0.index == progress.position.chapterIndex
            }),
            chapter.id != target.chapterID
                || progress.position.characterOffset != currentReaderOffset
        else { return }
        openChapter(chapter.id, progress.position.characterOffset)
    }

    private func webDAVProgressFailureMessage(
        _ failure: WebDAVReaderProgressSyncFailure
    ) -> String {
        switch failure {
        case .invalidConfiguration:
            return "请先配置 WebDAV"
        case .missingBook:
            return "当前书籍不存在"
        case .persistenceUnavailable:
            return "云端进度保存失败"
        case .remote(.notFound):
            return "云端没有该书进度"
        case .remote(.authenticationRejected):
            return "WebDAV 认证失败"
        case .remote(.identityMismatch):
            return "云端进度不属于当前书籍"
        case .remote:
            return "云端进度读取失败"
        }
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
                    relativeRate: readAloudPreferences.value.relativeRate,
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

private struct DictionaryLookupView: View {
    @Bindable var store: DictionaryLookupStore
    @Environment(\.dismiss) private var dismiss
    @State private var word = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("查询") {
                    TextField("输入词语", text: $word)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("input.reader.dictionary.word")
                    Picker(
                        "词典规则",
                        selection: Binding(
                            get: { store.selectedRuleName ?? "" },
                            set: { name in
                                guard !name.isEmpty else { return }
                                Task { await store.lookup(word, ruleName: name) }
                            }
                        )
                    ) {
                        ForEach(store.rules) { rule in
                            Text(rule.name).tag(rule.name)
                        }
                    }
                    Button("查询") {
                        Task { await store.lookup(word) }
                    }
                    .disabled(store.isLoading)
                    .accessibilityIdentifier("action.reader.dictionary.lookup")
                }
                if let result = store.result {
                    Section(store.selectedRuleName ?? "查询结果") {
                        Text(result)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("result.reader.dictionary")
                    }
                }
                if let errorMessage = store.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("state.reader.dictionary.error")
                    }
                }
            }
            .overlay { if store.isLoading { ProgressView() } }
            .navigationTitle("词典")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await store.reload() }
        }
    }
}

private struct ReaderPaginationRenderKey: Hashable {
    let chapterID: String
    let contentHash: Int
    let width: Int
    let height: Int
    let fontSize: Double
    let lineSpacing: Double
    let imageCount: Int
}

private struct ReaderContentEditorDraft: Identifiable {
    let chapterID: ChapterID
    let title: String
    let content: String
    let canReset: Bool

    var id: String {
        chapterID.rawValue
    }
}

private struct ReaderContentEditor: View {
    @State private var content: String
    let draft: ReaderContentEditorDraft
    let save: (String) -> Void
    let reset: () -> Void
    let cancel: () -> Void

    init(
        draft: ReaderContentEditorDraft,
        save: @escaping (String) -> Void,
        reset: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) {
        self.draft = draft
        _content = State(initialValue: draft.content)
        self.save = save
        self.reset = reset
        self.cancel = cancel
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $content)
                .font(.body)
                .padding(.horizontal)
                .accessibilityIdentifier(
                    "input.reader.contentEditor.body"
                )
                .navigationTitle(draft.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消", action: cancel)
                            .accessibilityIdentifier(
                                "action.reader.contentEditor.cancel"
                            )
                    }
                    ToolbarItemGroup(placement: .confirmationAction) {
                        Button("重置", action: reset)
                            .disabled(!draft.canReset)
                            .accessibilityIdentifier(
                                "action.reader.contentEditor.reset"
                            )
                        Button("保存") {
                            save(content)
                        }
                        .accessibilityIdentifier(
                            "action.reader.contentEditor.save"
                        )
                    }
                }
        }
        .accessibilityIdentifier("overlay.reader.contentEditor")
    }
}

private struct ReadAloudEngineSettingsView: View {
    @Bindable var store: HTTPTextToSpeechEngineStore
    @Bindable var preferences: ReadAloudPreferencesStore
    let select: (Int64?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("语速") {
                Toggle(
                    "跟随系统语速",
                    isOn: Binding(
                        get: {
                            preferences.value.followsSystemRate
                        },
                        set: {
                            preferences.setFollowsSystemRate($0)
                        }
                    )
                )
                .accessibilityIdentifier(
                    "toggle.reader.readAloud.followSystemRate"
                )
                VStack(alignment: .leading) {
                    Text(
                        String(
                            format: "自定义语速 %.1fx",
                            ReadAloudPlan.speechRate(
                                preference: preferences.value
                                    .speechRatePreference
                            )
                        )
                    )
                    .accessibilityIdentifier(
                        "state.reader.readAloud.customRate"
                    )
                    Slider(
                        value: Binding(
                            get: {
                                Double(
                                    preferences.value.speechRatePreference
                                )
                            },
                            set: {
                                preferences.setSpeechRatePreference(
                                    Int($0.rounded())
                                )
                            }
                        ),
                        in: Double(
                            ReadAloudPreferences.speechRateRange.lowerBound
                        )...Double(
                            ReadAloudPreferences.speechRateRange.upperBound
                        ),
                        step: 1
                    )
                    .disabled(preferences.value.followsSystemRate)
                    .accessibilityIdentifier(
                        "slider.reader.readAloud.speechRate"
                    )
                }
                Text(
                    String(
                        format: "当前生效 %.1fx",
                        preferences.value.relativeRate
                    )
                )
                .accessibilityIdentifier(
                    "state.reader.readAloud.effectiveRate"
                )
            }
            Section("朗读引擎") {
                engineRow(id: nil, name: "iOS 系统朗读")
                ForEach(store.engines) { engine in
                    engineRow(id: engine.id, name: engine.name)
                }
            }
            if let error = store.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("朗读设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        .task { await store.reload() }
        .accessibilityIdentifier("screen.reader.readAloudSettings")
    }

    private func engineRow(id: Int64?, name: String) -> some View {
        Button {
            select(id)
        } label: {
            HStack {
                Text(name)
                Spacer()
                if store.selectedEngineID == id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(
            id.map { "action.reader.readAloudEngine.\($0)" }
                ?? "action.reader.readAloudEngine.system"
        )
    }
}

private struct ReaderReplacementRuleEditor: View {
    @State private var rule: ReaderReplacementRule
    let save: (ReaderReplacementRule) -> Void
    let cancel: () -> Void

    init(
        rule: ReaderReplacementRule,
        save: @escaping (ReaderReplacementRule) -> Void,
        cancel: @escaping () -> Void
    ) {
        _rule = State(initialValue: rule)
        self.save = save
        self.cancel = cancel
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("规则") {
                    TextField("名称", text: $rule.name)
                        .accessibilityIdentifier(
                            "input.reader.replacement.name"
                        )
                    TextField("匹配内容", text: $rule.pattern)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier(
                            "input.reader.replacement.pattern"
                        )
                    TextField("替换为", text: $rule.replacement)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier(
                            "input.reader.replacement.replacement"
                        )
                }
                Section("应用") {
                    Toggle("使用正则表达式", isOn: $rule.isRegex)
                        .accessibilityIdentifier(
                            "action.reader.replacement.regex"
                        )
                    Toggle("作用于正文", isOn: $rule.appliesToContent)
                    Toggle("作用于标题", isOn: $rule.appliesToTitle)
                    Toggle("启用", isOn: $rule.isEnabled)
                }
                Section("作用域（可选）") {
                    TextField(
                        "包含书名或书源",
                        text: optionalBinding(\.scope)
                    )
                    TextField(
                        "排除书名或书源",
                        text: optionalBinding(\.excludeScope)
                    )
                }
                if let message = rule.validationMessage {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier(
                                "state.reader.replacement.validation"
                            )
                    }
                }
            }
            .navigationTitle(rule.name.isEmpty ? "新增规则" : "编辑规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var updated = rule
                        if updated.name.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty {
                            updated.name = "未命名规则"
                        }
                        save(updated)
                    }
                    .disabled(rule.validationMessage != nil)
                    .accessibilityIdentifier(
                        "action.reader.replacement.save"
                    )
                }
            }
            .accessibilityIdentifier("sheet.reader.replacementEditor")
        }
    }

    private func optionalBinding(
        _ keyPath: WritableKeyPath<ReaderReplacementRule, String?>
    ) -> Binding<String> {
        Binding(
            get: { rule[keyPath: keyPath] ?? "" },
            set: { value in
                rule[keyPath: keyPath] = value.isEmpty ? nil : value
            }
        )
    }
}
