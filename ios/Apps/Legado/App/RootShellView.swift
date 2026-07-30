import AppNavigation
import AppUseCases
import SwiftUI

struct RootShellView: View {
    @Bindable var router: AppRouter
    @Bindable var library: ShelfLibrary
    @Bindable var sourceCatalog: SourceCatalog
    @Bindable var readAloud: ReadAloudSession
    @Bindable var readerPreferences: ReaderPreferencesStore
    @Bindable var replacementRules: ReaderReplacementRuleStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var didLoadLibrary = false

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularShell
                    .accessibilityIdentifier("projection.regularSplit")
            } else {
                compactShell
                    .accessibilityIdentifier("projection.compactStack")
            }
        }
        .task {
            guard !didLoadLibrary else { return }
            didLoadLibrary = true
            if ProcessInfo.processInfo.arguments.contains(
                "--reset-library"
            ) {
                await library.reset()
            }
            if ProcessInfo.processInfo.arguments.contains(
                "--reset-sources"
            ) {
                await sourceCatalog.reset()
            }
            if ProcessInfo.processInfo.arguments.contains(
                "--reset-replacement-rules"
            ) {
                await replacementRules.reset()
            }
            await library.reload()
            await sourceCatalog.reload()
            await replacementRules.reload()
            if ProcessInfo.processInfo.arguments.contains(
                "--seed-shelf-management"
            ) {
                await seedShelfManagement()
            }
            if ProcessInfo.processInfo.arguments.contains(
                "--seed-book-import"
            ) {
                await seedBookImport()
            }
            if ProcessInfo.processInfo.arguments.contains(
                "--seed-offline-cache"
            ) {
                await seedOfflineCache()
            }
            if ProcessInfo.processInfo.arguments.contains(
                "--seed-pagination-cache"
            ) {
                await seedPaginationCache()
            }
        }
    }

    private var compactShell: some View {
        TabView(selection: $router.selectedRoot) {
            ForEach(RootRoute.allCases) { root in
                navigationStack(for: root)
                    .tabItem {
                        Label(root.title, systemImage: root.systemImage)
                            .accessibilityIdentifier(root.selectionIdentifier)
                    }
                    .tag(root)
            }
        }
    }

    private var regularShell: some View {
        NavigationSplitView {
            List {
                ForEach(RootRoute.allCases) { root in
                    Button {
                        router.selectRoot(root)
                    } label: {
                        Label(root.title, systemImage: root.systemImage)
                    }
                    .accessibilityIdentifier(root.selectionIdentifier)
                    .listRowBackground(
                        router.selectedRoot == root
                            ? Color.accentColor.opacity(0.14)
                            : Color.clear
                    )
                }
            }
            .navigationTitle("Legado")
        } detail: {
            navigationStack(for: router.selectedRoot)
        }
    }

    private func navigationStack(for root: RootRoute) -> some View {
        NavigationStack(path: pathBinding(for: root)) {
            RootContentView(
                root: root,
                library: library,
                persistedSources: SearchEnvironment.sourceSwitchTargets(
                    persistedSources: sourceCatalog.sources
                ),
                openSearch: {
                    router.push(.searchBooks, on: .shelf)
                },
                openSources: {
                    router.push(.sourceManagement, on: .settings)
                },
                openExploreSource: { source in
                    router.push(
                        .exploreSource(
                            ExploreSourceRoute(
                                sourceID: source.id,
                                title: source.name
                            )
                        ),
                        on: .explore
                    )
                },
                openBook: { item in
                    router.push(
                        .bookDetail(SearchBookRoute(item: item)),
                        on: .shelf
                    )
                },
                books: {
                    library.books
                },
                exploreSources: {
                    SearchEnvironment.exploreSources(
                        persistedSources: sourceCatalog.sources
                    )
                }
            )
            .navigationDestination(for: AppRoute.self) { route in
                destination(for: route, on: root)
            }
        }
    }

    @ViewBuilder
    private func destination(
        for route: AppRoute,
        on root: RootRoute
    ) -> some View {
        switch route {
        case .searchBooks:
            SearchBooksView(
                persistedSources: sourceCatalog.sources
            ) { result in
                router.push(
                    .bookDetail(SearchBookRoute(result: result)),
                    on: .shelf
                )
            }
        case .exploreSource(let source):
            ExploreSourceView(
                source: source,
                persistedSources: sourceCatalog.sources
            ) { result in
                router.push(
                    .bookDetail(SearchBookRoute(result: result)),
                    on: .explore
                )
            }
        case .bookDetail(let book):
            BookDetailView(
                candidate: ShelfBookCandidate(route: book),
                library: library,
                openReading: { item in
                    let chapters = await library.chapters(
                        bookID: item.id
                    )
                    if
                        let progress = item.progress,
                        let chapter = chapters.first(where: {
                            $0.index == progress.position.chapterIndex
                        })
                    {
                        router.push(
                            .reader(
                                ReaderRoute(
                                    bookID: item.id,
                                    chapterID: chapter.id,
                                    characterOffset:
                                        progress.position.characterOffset
                                )
                            ),
                            on: root
                        )
                    } else {
                        router.push(.chapterTOC(item.id), on: root)
                    }
                },
                editSource: { sourceID in
                    Task {
                        let normalizedID = sourceID.isEmpty
                            ? book.sourceID
                            : sourceID
                        if
                            !normalizedID.isEmpty,
                            sourceCatalog.source(id: normalizedID) == nil
                        {
                            _ = await sourceCatalog.save(
                                BookSourceDraft(
                                    sourceURL: normalizedID,
                                    name: book.originName
                                )
                            )
                        }
                        router.push(
                            .sourceEditor(
                                normalizedID.isEmpty ? nil : normalizedID
                            ),
                            on: root
                        )
                    }
                },
                availableSources: sourceCatalog.sources,
                switchSource: { current, source in
                    do {
                        let resolved = try await SearchEnvironment
                            .resolveSourceSwitch(
                                current: current,
                                target: source,
                                persistedSources: sourceCatalog.sources
                            )
                        let switched = await library.switchSource(
                            current: current,
                            candidate: resolved.candidate,
                            chapters: resolved.chapters
                        )
                        guard let switched else {
                            return .failure(
                                library.errorMessage
                                    ?? "目标书源目录无法迁移"
                            )
                        }
                        return .success(switched)
                    } catch {
                        return .failure(
                            "目标书源解析失败："
                                + String(reflecting: error)
                        )
                    }
                }
            )
        case .chapterTOC(let bookID):
            ChapterTOCView(
                bookID: bookID,
                library: library,
                persistedSources: sourceCatalog.sources,
                openReader: { chapter in
                    router.push(
                        .reader(
                            ReaderRoute(
                                bookID: bookID,
                                chapterID: chapter.id
                            )
                        ),
                        on: root
                    )
                }
            )
        case .reader(let target):
            ReaderContentView(
                target: target,
                library: library,
                persistedSources: sourceCatalog.sources,
                readAloud: readAloud,
                readerPreferences: readerPreferences,
                replacementRules: replacementRules,
                openTOC: {
                    router.push(.chapterTOC(target.bookID), on: root)
                },
                openChapter: { chapterID, characterOffset in
                    router.replaceTop(
                        with: .reader(
                            ReaderRoute(
                                bookID: target.bookID,
                                chapterID: chapterID,
                                characterOffset: characterOffset
                            )
                        ),
                        on: root
                    )
                },
                openSourceEditor: { sourceID in
                    router.push(
                        .sourceEditor(sourceID),
                        on: root
                    )
                }
            )
        case .sourceManagement:
            SourceManagementView(catalog: sourceCatalog) { sourceID in
                router.push(.sourceEditor(sourceID), on: root)
            }
        case .sourceEditor(let sourceID):
            SourceEditorView(
                source: sourceCatalog.source(id: sourceID),
                catalog: sourceCatalog,
                navigate: { destination, savedSourceID in
                    let route: AppRoute
                    switch destination {
                    case .sourceDebug:
                        route = .sourceDebug(savedSourceID)
                    case .sourceLogin:
                        route = .sourceLogin(savedSourceID)
                    case .singleSourceSearch:
                        route = .sourceSearch(savedSourceID)
                    case .dismiss, .discardConfirmation:
                        return
                    }
                    router.push(route, on: root)
                },
                dismiss: {
                    _ = router.pop(on: root)
                }
            )
        case .sourceDebug(let sourceID):
            SourceDebugView(source: sourceDraft(id: sourceID))
        case .sourceLogin(let sourceID):
            SourceLoginView(source: sourceDraft(id: sourceID))
        case .sourceSearch(let sourceID):
            SourceSingleSearchView(source: sourceDraft(id: sourceID))
        }
    }

    private func sourceDraft(id: String) -> BookSourceDraft {
        sourceCatalog.source(id: id)
            ?? BookSourceDraft(sourceURL: id, name: id)
    }

    private func pathBinding(for root: RootRoute) -> Binding<[AppRoute]> {
        Binding(
            get: { router.path(for: root) },
            set: { router.setPath($0, for: root) }
        )
    }

    private func seedShelfManagement() async {
        guard library.books.isEmpty else { return }
        let session = SearchEnvironment.makeSession(
            persistedSources: sourceCatalog.sources
        )
        session.query = "星河"
        session.selectGroup("科幻")
        session.search()
        while session.loadingState == .loading {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let candidates = session.results.prefix(2).map {
            ShelfBookCandidate(
                name: $0.name,
                author: $0.author,
                kind: $0.kind,
                lastChapter: $0.lastChapter,
                intro: $0.intro,
                bookURL: $0.bookURL,
                bookRequestExpression: $0.bookRequestExpression,
                coverURL: $0.coverURL,
                originName: $0.originName,
                sourceID: $0.origin,
                variables: $0.variables
            )
        }
        for (index, candidate) in candidates.enumerated() {
            await library.add(candidate, groupID: index)
            guard let item = await library.item(forURL: candidate.bookURL)
            else { continue }
            let toc = library.chapterSession(
                loader: SearchEnvironment.makeChapterLoader(
                    persistedSources: sourceCatalog.sources
                )
            )
            await toc.load(book: item, force: true)
        }
        if
            let first = candidates.first,
            let item = await library.item(forURL: first.bookURL)
        {
            await library.saveReadingProgress(
                bookID: item.id,
                chapterIndex: 1,
                characterOffset: 0,
                chapterTitle: "第二章 回声"
            )
        }
        await library.reload()
    }

    private func seedBookImport() async {
        guard library.books.isEmpty else { return }
        let text = """
        这是一段导入后的前言。
        第一章 启程
        海风越过窗沿，旅人翻开了第一封信。
        第二章 回声
        山谷把遥远的回答送回灯塔。
        """
        guard
            let file = try? ManagedBookFileStore.persist(
                data: Data(text.utf8),
                fileName: "《本地旅程》作者：林舟.txt"
            )
        else { return }
        _ = await library.importLocalText(
            fileName: file.fileName,
            managedReference: file.reference,
            data: file.data
        )
    }

    private func seedOfflineCache() async {
        guard library.books.isEmpty else { return }
        let session = SearchEnvironment.makeSession(
            persistedSources: sourceCatalog.sources
        )
        session.query = "星河纪事"
        session.selectGroup("科幻")
        session.search()
        while session.loadingState == .loading {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let result = session.results.first else { return }
        let candidate = ShelfBookCandidate(
            name: result.name,
            author: result.author,
            kind: result.kind,
            lastChapter: result.lastChapter,
            intro: result.intro,
            bookURL: result.bookURL,
            bookRequestExpression: result.bookRequestExpression,
            coverURL: result.coverURL,
            originName: result.originName,
            sourceID: result.origin,
            variables: result.variables
        )
        await library.add(candidate)
        guard let item = await library.item(forURL: candidate.bookURL)
        else { return }
        let toc = library.chapterSession(
            loader: SearchEnvironment.makeChapterLoader(
                persistedSources: sourceCatalog.sources
            )
        )
        await toc.load(book: item, force: true)
        await library.reload()
    }

    private func seedPaginationCache() async {
        guard let book = library.books.first else { return }
        let chapters = await library.chapters(bookID: book.id)
            .sorted { $0.index < $1.index }
        guard let chapter = chapters.first else { return }
        let paragraph = """
        星港的晨光沿着舷窗缓缓移动，远处的航标逐个熄灭。\
        林舟重新核对航线，把尚未寄出的信放回口袋。
        """
        let content = Array(repeating: paragraph, count: 5)
            .joined(separator: "\n\n")
        await library.cacheChapterContent(
            content,
            bookID: book.id,
            chapterID: chapter.id
        )
        await library.saveReadingProgress(
            bookID: book.id,
            chapterIndex: chapter.index,
            characterOffset: 0,
            chapterTitle: chapter.title
        )
    }
}

private struct RootContentView: View {
    let root: RootRoute
    @Bindable var library: ShelfLibrary
    let persistedSources: [BookSourceDraft]
    let openSearch: () -> Void
    let openSources: () -> Void
    let openExploreSource: (ExploreSourceSummary) -> Void
    let openBook: (ShelfBookItem) -> Void
    let books: () -> [ShelfBookItem]
    let exploreSources: () -> [ExploreSourceSummary]

    var body: some View {
        if root == .shelf {
            ShelfManagementView(
                library: library,
                persistedSources: persistedSources,
                openSearch: openSearch,
                openBook: openBook
            )
        } else {
            genericRoot
        }
    }

    private var genericRoot: some View {
        VStack(spacing: 20) {
            Image(systemName: root.systemImage)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.tint)

            Text(root.title)
                .font(.largeTitle.bold())
                .accessibilityIdentifier(root.screenIdentifier)

            Text(root.subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if root == .explore {
                if exploreSources().isEmpty {
                    ContentUnavailableView {
                        Label("没有发现书源", systemImage: "safari")
                    } description: {
                        Text("请在书源管理中导入并启用发现。")
                    }
                    .accessibilityIdentifier("state.explore.empty")
                } else {
                    List(exploreSources()) { source in
                        Button {
                            openExploreSource(source)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(source.name)
                                        .font(.headline)
                                    if !source.group.isEmpty {
                                        Text(source.group)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .accessibilityIdentifier(
                            "action.explore.openSource.\(source.id)"
                        )
                    }
                    .accessibilityIdentifier("list.explore.sources")
                    .frame(maxHeight: 360)
                }
            } else if root == .settings {
                Button(action: openSources) {
                    Label("书源管理", systemImage: "network")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("action.settings.openSources")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(root.title)
    }
}

private extension SearchBookRoute {
    init(item: ShelfBookItem) {
        let candidate = item.candidate
        self.init(
            name: candidate.name,
            author: candidate.author,
            kind: candidate.kind,
            lastChapter: candidate.lastChapter,
            intro: candidate.intro,
            bookURL: candidate.bookURL,
            bookRequestExpression:
                candidate.bookRequestExpression,
            coverURL: candidate.coverURL,
            originName: candidate.originName,
            sourceID: candidate.sourceID,
            variables: candidate.variables
        )
    }

    init(result: SearchResult) {
        self.init(
            name: result.name,
            author: result.author,
            kind: result.kind,
            lastChapter: result.lastChapter,
            intro: result.intro,
            bookURL: result.bookURL,
            bookRequestExpression: result.bookRequestExpression,
            coverURL: result.coverURL,
            originName: result.originName,
            sourceID: result.origin,
            variables: result.variables
        )
    }
}

private struct ExploreSourceView: View {
    let openBookDetail: (SearchResult) -> Void
    @State private var session: ExploreSession

    init(
        source: ExploreSourceRoute,
        persistedSources: [BookSourceDraft],
        openBookDetail: @escaping (SearchResult) -> Void
    ) {
        self.openBookDetail = openBookDetail
        _session = State(
            initialValue: SearchEnvironment.makeExploreSession(
                sourceID: source.sourceID,
                persistedSources: persistedSources
            )
        )
    }

    var body: some View {
        List {
            if !session.categories.isEmpty {
                Section("分类") {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(session.categories) { category in
                                Button(category.title) {
                                    session.selectCategory(category)
                                }
                                .buttonStyle(.bordered)
                                .tint(
                                    session.selectedCategory == category
                                        ? .accentColor
                                        : .secondary
                                )
                                .accessibilityIdentifier(
                                    "action.explore.category.\(category.id)"
                                )
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .accessibilityIdentifier("list.explore.categories")
                }
            }

            if session.results.isEmpty,
                session.loadingState == .idle
            {
                ContentUnavailableView {
                    Label(
                        session.errorMessage == nil
                            ? "暂无书籍"
                            : "加载失败",
                        systemImage: "books.vertical"
                    )
                } description: {
                    Text(
                        session.errorMessage
                            ?? "这个分类暂时没有返回书籍。"
                    )
                } actions: {
                    if session.errorMessage != nil {
                        Button("重试", action: session.retry)
                            .accessibilityIdentifier(
                                "action.explore.retry"
                            )
                    }
                }
                .accessibilityIdentifier("state.explore.results.empty")
            } else {
                Section("书单") {
                    ForEach(session.results) { result in
                        Button {
                            openBookDetail(result)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(result.name)
                                    .font(.headline)
                                Text(
                                    [result.author, result.kind]
                                        .filter { !$0.isEmpty }
                                        .joined(separator: " · ")
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                if !result.lastChapter.isEmpty {
                                    Text(result.lastChapter)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(
                            "action.explore.openBook.\(result.id)"
                        )
                    }

                    if session.canLoadMore, !session.results.isEmpty {
                        Button("加载下一页", action: session.loadNextPage)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier(
                                "action.explore.loadNextPage"
                            )
                    }
                }
            }
        }
        .navigationTitle(session.source.name)
        .accessibilityIdentifier("screen.explore.source")
        .overlay {
            if session.loadingState.showsProgress {
                ProgressView("正在加载书单…")
                    .padding()
                    .background(
                        .regularMaterial,
                        in: .rect(cornerRadius: 12)
                    )
                    .accessibilityIdentifier("state.explore.loading")
            }
        }
        .task {
            session.start()
        }
        .onDisappear {
            session.stop()
        }
    }
}

private struct SearchBooksView: View {
    let openBookDetail: (SearchResult) -> Void
    @State private var session: SearchSession

    init(
        persistedSources: [BookSourceDraft],
        openBookDetail: @escaping (SearchResult) -> Void
    ) {
        self.openBookDetail = openBookDetail
        _session = State(
            initialValue: SearchEnvironment.makeSession(
                persistedSources: persistedSources
            )
        )
    }

    var body: some View {
        List {
            if session.results.isEmpty {
                ContentUnavailableView {
                    Label(
                        session.query.isEmpty
                            ? "搜索书籍"
                            : "没有找到结果",
                        systemImage: "books.vertical"
                    )
                } description: {
                    Text(
                        session.query.isEmpty
                            ? "输入书名或作者，从已选择的书源中搜索。"
                            : "可以更换搜索范围或关键词后重试。"
                    )
                }
                .accessibilityIdentifier("state.search.empty")
            } else {
                Section {
                    ForEach(session.results) { result in
                        Button {
                            openBookDetail(result)
                        } label: {
                            searchResultRow(result)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(
                            "action.search.openBookDetail.\(result.id)"
                        )
                    }
                } header: {
                    Text(
                        "搜索结果 · \(session.results.count)"
                    )
                } footer: {
                    Text(scopeSummary)
                }
            }

            if let error = session.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("state.search.error")
                }
            }
        }
        .accessibilityIdentifier("screen.search.books")
        .navigationTitle("搜索")
        .searchable(
            text: $session.query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "书名或作者"
        )
        .onSubmit(of: .search) {
            session.search()
        }
        .overlay {
            if session.loadingState.showsProgress {
                ProgressView("正在搜索…")
                    .padding()
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
                    .accessibilityIdentifier("state.search.loading")
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    session.search()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .disabled(
                    session.query.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                )
                .accessibilityLabel("搜索")
                .accessibilityIdentifier("action.search.submit")
                if session.loadingState.showsStop {
                    Button("停止", action: session.stop)
                        .accessibilityIdentifier("action.search.stop")
                }
                scopeMenu
            }
        }
    }

    private var scopeSummary: String {
        let names = session.scope.displayNames
        return names.isEmpty
            ? "范围：全部书源"
            : "范围：\(names.joined(separator: "、"))"
    }

    private var scopeMenu: some View {
        Menu {
            Button {
                session.selectAllSources()
            } label: {
                Label(
                    "全部书源",
                    systemImage: session.scopeMenu.allChecked
                        ? "checkmark"
                        : "circle"
                )
            }

            if !session.scopeMenu.selected.isEmpty {
                Section("当前范围") {
                    ForEach(
                        session.scopeMenu.selected,
                        id: \.self
                    ) { name in
                        Button {
                            session.removeScope(name)
                        } label: {
                            Label(
                                name,
                                systemImage: "checkmark"
                            )
                                }
                            }
                        }
                        .accessibilityIdentifier("action.shelf.openBook")
                    }

            if !session.scopeMenu.available.isEmpty {
                Section("分组") {
                    ForEach(
                        session.scopeMenu.available,
                        id: \.self
                    ) { group in
                        Button(group) {
                            session.selectGroup(group)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("搜索范围")
        .accessibilityIdentifier("action.search.scope")
    }

    private func searchResultRow(
        _ result: SearchResult
    ) -> some View {
        HStack(spacing: 14) {
            AsyncImage(url: result.coverURL.flatMap(URL.init(string:))) {
                image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "book.closed.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            .frame(width: 42, height: 54)
            .background(
                Color.accentColor.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 5) {
                Text(result.name)
                    .font(.headline)
                Text(
                    [result.author, result.kind]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · ")
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if !result.lastChapter.isEmpty {
                    Text(result.lastChapter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(
                    result.originCount > 1
                        ? "\(result.originCount) 个书源"
                        : result.originName
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private extension RootRoute {
    var title: String {
        switch self {
        case .shelf:
            "书架"
        case .explore:
            "发现"
        case .rss:
            "RSS"
        case .settings:
            "我的"
        }
    }

    var subtitle: String {
        switch self {
        case .shelf:
            "管理与阅读已收藏的书籍"
        case .explore:
            "发现书源与新的阅读内容"
        case .rss:
            "查看订阅内容"
        case .settings:
            "管理书源、备份与应用设置"
        }
    }

    var systemImage: String {
        switch self {
        case .shelf:
            "books.vertical"
        case .explore:
            "safari"
        case .rss:
            "dot.radiowaves.left.and.right"
        case .settings:
            "person.crop.circle"
        }
    }

    var screenIdentifier: String {
        "screen.\(rawValue)"
    }

    var selectionIdentifier: String {
        "action.\(rawValue).select"
    }
}

enum StartupAcceptanceCase: String {
    case welcomeMainOnly = "welcome-default-opens-main-only"
    case welcomeReader = "welcome-default-to-read-opens-reader-after-main"
    case privacyRefusal = "privacy-refusal-stops-main-pipeline"
    case firstAgreement = "first-open-agreement-runs-help-then-password"
    case returningCurrent = "returning-current-version-skips-onboarding"
    case returningVersionChange =
        "returning-version-change-debug-skips-update-log"

    init?(processArguments: [String]) {
        guard
            let marker = processArguments.firstIndex(of: "--startup-case"),
            processArguments.indices.contains(marker + 1)
        else {
            return nil
        }
        self.init(rawValue: processArguments[marker + 1])
    }

    var effects: [StartupEffect] {
        switch self {
        case .welcomeMainOnly:
            AppStartupCoordinator.welcome(
                defaultToRead: false
            ).effects
        case .welcomeReader:
            AppStartupCoordinator.welcome(
                defaultToRead: true
            ).effects
        case .privacyRefusal:
            AppStartupCoordinator.main(
                StartupMainSnapshot(
                    privacyState: .pending,
                    privacyAction: .refuse,
                    storedVersion: .zero,
                    firstOpen: true,
                    passwordState: .unset,
                    appCrash: true
                )
            ).effects
        case .firstAgreement:
            AppStartupCoordinator.main(
                StartupMainSnapshot(
                    privacyState: .pending,
                    privacyAction: .agree,
                    storedVersion: .zero,
                    firstOpen: true,
                    passwordState: .unset,
                    passwordAction: .cancel,
                    appCrash: true
                )
            ).effects
        case .returningCurrent:
            AppStartupCoordinator.main(
                StartupMainSnapshot(
                    privacyState: .accepted,
                    storedVersion: .current,
                    firstOpen: false,
                    passwordState: .nonempty,
                    appCrash: true
                )
            ).effects
        case .returningVersionChange:
            AppStartupCoordinator.main(
                StartupMainSnapshot(
                    privacyState: .accepted,
                    storedVersion: .previous,
                    firstOpen: false,
                    passwordState: .empty,
                    appCrash: false
                )
            ).effects
        }
    }
}

struct StartupAcceptanceView: View {
    @Bindable var router: AppRouter
    @Bindable var library: ShelfLibrary
    @Bindable var sourceCatalog: SourceCatalog
    @Bindable var readAloud: ReadAloudSession
    @Bindable var readerPreferences: ReaderPreferencesStore
    @Bindable var replacementRules: ReaderReplacementRuleStore
    let startupCase: StartupAcceptanceCase

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var promptIndex = 0

    var body: some View {
        ZStack {
            destination
            if let prompt = currentPrompt {
                Color.black.opacity(0.24)
                    .ignoresSafeArea()
                promptCard(prompt)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projection.\(projection)")
    }

    @ViewBuilder
    private var destination: some View {
        if promptsAreComplete && effects.contains(.finishMain) {
            StartupStatusView(
                symbol: "hand.raised.fill",
                title: "已停止启动",
                subtitle: "隐私政策未同意，后续启动步骤不会执行。",
                identifier: "screen.startup.finished"
            )
        } else if promptsAreComplete && destinations.last == .reader {
            StartupStatusView(
                symbol: "book.pages.fill",
                title: "阅读",
                subtitle: "主壳已建立，随后进入阅读目的地。",
                identifier: "screen.reader.startup"
            )
        } else {
            RootShellView(
                router: router,
                library: library,
                sourceCatalog: sourceCatalog,
                readAloud: readAloud,
                readerPreferences: readerPreferences,
                replacementRules: replacementRules
            )
        }
    }

    private var effects: [StartupEffect] {
        startupCase.effects
    }

    private var prompts: [StartupPrompt] {
        effects.compactMap { effect in
            guard case .present(let prompt) = effect else {
                return nil
            }
            return prompt
        }
    }

    private var destinations: [StartupDestination] {
        effects.compactMap { effect in
            guard case .navigate(let destination) = effect else {
                return nil
            }
            return destination
        }
    }

    private var promptsAreComplete: Bool {
        promptIndex >= prompts.count
    }

    private var currentPrompt: StartupPrompt? {
        prompts.indices.contains(promptIndex) ? prompts[promptIndex] : nil
    }

    private var projection: String {
        horizontalSizeClass == .regular
            ? "regularSplit"
            : "compactStack"
    }

    @ViewBuilder
    private func promptCard(_ prompt: StartupPrompt) -> some View {
        VStack(spacing: 18) {
            Image(systemName: prompt.symbol)
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.tint)

            Text(prompt.title)
                .font(.title2.bold())

            Text(prompt.message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            switch prompt {
            case .privacy:
                HStack {
                    Button("拒绝") {
                        advancePrompt()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(
                        "startup.action.privacy.refuse"
                    )

                    Button("同意") {
                        advancePrompt()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(
                        "startup.action.privacy.agree"
                    )
                }
            case .help:
                Button("开始使用") {
                    advancePrompt()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("startup.action.help.close")
            case .localPassword:
                Button("暂不设置") {
                    advancePrompt()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(
                    "startup.action.local_password.cancel"
                )
            }
        }
        .padding(28)
        .frame(maxWidth: 420)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 24)
        )
        .shadow(radius: 24)
        .padding()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("startup.prompt.\(prompt.rawValue)")
    }

    private func advancePrompt() {
        promptIndex += 1
    }
}

private struct StartupStatusView: View {
    let symbol: String
    let title: String
    let subtitle: String
    let identifier: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.tint)
            Text(title)
                .font(.largeTitle.bold())
                .accessibilityIdentifier(identifier)
            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

private extension StartupPrompt {
    var title: String {
        switch self {
        case .privacy:
            "隐私政策"
        case .help:
            "欢迎使用 Legado"
        case .localPassword:
            "本地密码"
        }
    }

    var message: String {
        switch self {
        case .privacy:
            "请阅读并选择是否同意隐私政策。"
        case .help:
            "完成首次使用说明后，再检查本地密码。"
        case .localPassword:
            "可以设置本地密码，也可以暂时跳过。"
        }
    }

    var symbol: String {
        switch self {
        case .privacy:
            "hand.raised.fill"
        case .help:
            "sparkles"
        case .localPassword:
            "lock.fill"
        }
    }
}
