import AppNavigation
import AppUseCases
import SwiftUI

struct RootShellView: View {
    @Bindable var router: AppRouter
    @Bindable var library: ShelfLibrary
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
            await library.reload()
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
                openSearch: {
                    router.push(.searchBooks, on: .shelf)
                },
                openBook: { item in
                    router.push(
                        .bookDetail(SearchBookRoute(item: item)),
                        on: .shelf
                    )
                },
                books: {
                    library.books
                }
            )
            .navigationDestination(for: AppRoute.self) { route in
                destination(for: route)
            }
        }
    }

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .searchBooks:
            SearchBooksView { result in
                router.push(
                    .bookDetail(
                        SearchBookRoute(
                            name: result.name,
                            author: result.author,
                            kind: result.kind,
                            lastChapter: result.lastChapter,
                            intro: result.intro,
                            bookURL: result.bookURL,
                            coverURL: result.coverURL,
                            originName: result.originName
                        )
                    ),
                    on: .shelf
                )
            }
        case .bookDetail(let book):
            BookDetailView(
                candidate: ShelfBookCandidate(route: book),
                library: library
            )
        }
    }

    private func pathBinding(for root: RootRoute) -> Binding<[AppRoute]> {
        Binding(
            get: { router.path(for: root) },
            set: { router.setPath($0, for: root) }
        )
    }
}

private struct RootContentView: View {
    let root: RootRoute
    let openSearch: () -> Void
    let openBook: (ShelfBookItem) -> Void
    let books: () -> [ShelfBookItem]

    var body: some View {
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

            if root == .shelf {
                if books().isEmpty {
                    Text("书架还是空的")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("state.shelf.empty")
                } else {
                    List(books()) { book in
                        Button {
                            openBook(book)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(book.candidate.name)
                                    .font(.headline)
                                Text("作者：\(book.candidate.author)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier(
                            "action.shelf.openBook"
                        )
                    }
                    .accessibilityIdentifier("list.shelf.books")
                    .frame(maxHeight: 320)
                }

                Button(action: openSearch) {
                    Label("搜索书籍", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("action.shelf.openSearch")
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
            coverURL: candidate.coverURL,
            originName: candidate.originName
        )
    }
}

private struct SearchBooksView: View {
    let openBookDetail: (SearchResult) -> Void
    @State private var session: SearchSession

    init(openBookDetail: @escaping (SearchResult) -> Void) {
        self.openBookDetail = openBookDetail
        _session = State(
            initialValue: SearchEnvironment.makeSession()
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
            RootShellView(router: router, library: library)
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
