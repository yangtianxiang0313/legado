import AppNavigation
import AppUseCases
import ArchiveZIPFoundation
import BackupInteropUseCases
import Foundation
import IntegrationKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebDAVFoundation

private extension Color {
    init?(androidHex rawValue: String) {
        let value = rawValue.trimmingCharacters(
            in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines)
        )
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else {
            return nil
        }
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255,
            opacity: 1
        )
    }
}

private extension DefaultHomePage {
    var title: String {
        switch self {
        case .bookshelf: "书架"
        case .explore: "发现"
        case .rss: "RSS"
        case .settings: "我的"
        }
    }
}

private func synchronizeDefaultWebDAVServer(
    settings: WebDAVConnectionSettings,
    repository: any WebDAVServerProfileRepository
) async throws {
    guard
        let profile = WebDAVDefaultServerBridge.profile(settings: settings)
    else { return }
    try await repository.upsertWebDAVServerProfile(profile)
    if try await repository.selectedWebDAVServerProfileID() == nil {
        try await repository.selectWebDAVServerProfile(id: profile.id)
    }
}

private enum WebDAVBackupNotice: Identifiable {
    case offer(WebDAVBackupFile)
    case result(String)
    case failure(String)

    var id: String {
        switch self {
        case .offer(let file): "offer:\(file.name)"
        case .result(let message): "result:\(message)"
        case .failure(let message): "failure:\(message)"
        }
    }
}

private struct WebDAVBackupPasswordRequest: Identifiable {
    let file: WebDAVBackupFile
    var id: String { file.name }
}

struct RootShellView: View {
    @Bindable var router: AppRouter
    @Bindable var library: ShelfLibrary
    @Bindable var sourceCatalog: SourceCatalog
    @Bindable var readAloud: ReadAloudSession
    @Bindable var readAloudPreferences: ReadAloudPreferencesStore
    @Bindable var readingHistoryPreferences: ReadingHistoryPreferencesStore
    @Bindable var searchScopePreferences: SearchScopePreferencesStore
    @Bindable var sourceSwitchPreferences: SourceSwitchPreferencesStore
    @Bindable var httpTextToSpeechEngines: HTTPTextToSpeechEngineStore
    @Bindable var dictionaryLookup: DictionaryLookupStore
    @Bindable var keyboardAssists: KeyboardAssistStore
    @Bindable var appThemeProfiles: AppThemeProfileStore
    @Bindable var readerPreferences: ReaderPreferencesStore
    @Bindable var bookDetailPreferences: BookDetailPreferencesStore
    @Bindable var rootVisibility: RootVisibilityPreferencesStore
    @Bindable var replacementRules: ReaderReplacementRuleStore
    @Bindable var ruleSubscriptions: RuleSubscriptionStore
    @Bindable var rssStore: RSSStore
    @Bindable var webDAVSettings: WebDAVConnectionSettingsStore
    @Bindable var webDAVBackupCheckpoint: WebDAVBackupCheckpointStore
    let webDAVCredentials: KeychainWebDAVCredentialStore
    let androidBackupPasswordStore: any AndroidBackupPasswordStoring
    let webDAVClient: any WebDAVConnectionInitializing
    let webDAVProgressLoader: any WebDAVBookProgressLoading
    let webDAVProgressUploader: WebDAVReaderProgressUploadCoordinator
    let backupRestore: AndroidCoreBackupRestoreUseCase
    let libraryBackup: AndroidLibraryBackupUseCase
    let webDAVBackupSync: WebDAVBackupSyncUseCase
    let webDAVServerProfiles: any WebDAVServerProfileRepository
    let webDAVRemoteBooks: any WebDAVRemoteBookTransferring
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var didLoadLibrary = false
    @State private var webDAVBackupNotice: WebDAVBackupNotice?
    @State private var webDAVBackupPasswordRequest:
        WebDAVBackupPasswordRequest?
    @State private var webDAVRestorePassword = ""
    @State private var webDAVRestorePasswordError: String?
    @State private var isAutomaticBackupRunning = false

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
        .onAppear {
            router.reconcileVisibleRoots(visibleRoots)
        }
        .tint(activeThemeTint)
        .preferredColorScheme(activeThemeColorScheme)
        .background(activeThemeBackground.ignoresSafeArea())
        .toolbarBackground(activeThemePrimary, for: .navigationBar)
        .toolbarBackground(activeThemeBottomBackground, for: .tabBar)
        .alert(item: $webDAVBackupNotice) { notice in
            switch notice {
            case .offer(let file):
                Alert(
                    title: Text("发现新的云端备份"),
                    message: Text("是否恢复 \(file.name)？"),
                    primaryButton: .default(Text("恢复")) {
                        restoreWebDAVBackup(file)
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            case .result(let message):
                Alert(
                    title: Text("云端备份恢复完成"),
                    message: Text(message),
                    dismissButton: .default(Text("好"))
                )
            case .failure(let message):
                Alert(
                    title: Text("云端备份恢复失败"),
                    message: Text(message),
                    dismissButton: .default(Text("好"))
                )
            }
        }
        .sheet(item: $webDAVBackupPasswordRequest) { request in
            NavigationStack {
                Form {
                    Section {
                        SecureField(
                            "Android 备份口令",
                            text: $webDAVRestorePassword
                        )
                        .textContentType(.password)
                        .accessibilityIdentifier(
                            "field.webdav.restore.password"
                        )
                    } footer: {
                        Text("口令仅用于本次解密，不会保存。")
                    }
                    if let webDAVRestorePasswordError {
                        Text(webDAVRestorePasswordError)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier(
                                "status.webdav.restore.password"
                            )
                    }
                }
                .navigationTitle("输入备份口令")
                .accessibilityIdentifier(
                    "sheet.webdav.restore.password"
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") {
                            webDAVBackupPasswordRequest = nil
                            webDAVRestorePassword = ""
                            webDAVRestorePasswordError = nil
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("恢复") {
                            restoreWebDAVBackup(
                                request.file,
                                backupPassword: webDAVRestorePassword
                            )
                        }
                        .disabled(webDAVRestorePassword.isEmpty)
                        .accessibilityIdentifier(
                            "action.webdav.restore.password"
                        )
                    }
                }
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
                "--seed-webdav-remote-book"
            ) {
                let reference = WebDAVCredentialReference(
                    "webdav.server.7001"
                )
                try? await webDAVServerProfiles.replaceWebDAVServerProfiles(
                    [
                        WebDAVServerProfile(
                            id: 7001,
                            name: "测试书库",
                            serverAddress: "https://dav.example.test/books",
                            sortNumber: 0,
                            credentialReference: reference
                        )
                    ],
                    selectedID: 7001
                )
                try? await webDAVCredentials.save(
                    WebDAVBasicCredentials(
                        username: "reader",
                        password: "secret"
                    ),
                    for: reference
                )
            } else {
                try? await synchronizeDefaultWebDAVServer(
                    settings: webDAVSettings.value,
                    repository: webDAVServerProfiles
                )
            }
            if ProcessInfo.processInfo.arguments.contains(
                "--reset-sources"
            ) {
                await sourceCatalog.reset()
            }
            if
                let rawSource = ProcessInfo.processInfo.environment[
                    "LEGADO_SEED_SOURCE_JSON"
                ],
                let data = rawSource.data(using: .utf8),
                let sources = try? SourceDefinitionImport.decode(data)
            {
                _ = await sourceCatalog.importSources(sources)
            }
            if ProcessInfo.processInfo.arguments.contains(
                "--reset-replacement-rules"
            ) {
                await replacementRules.reset()
            }
            await library.reload()
            await sourceCatalog.reload()
            await replacementRules.reload()
            await ruleSubscriptions.reload()
            await rssStore.reload()
            await httpTextToSpeechEngines.reload()
            await dictionaryLookup.reload()
            await keyboardAssists.reload()
            await appThemeProfiles.reload()
            router.reconcileVisibleRoots(visibleRoots)
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
                "--seed-epub-import"
            ) {
                await seedEPUBImport()
            }
            if ProcessInfo.processInfo.arguments.contains(
                "--seed-zip-import"
            ) {
                await seedZIPImport()
            }
            if ProcessInfo.processInfo.arguments.contains(
                "--seed-offline-cache"
            ) {
                await seedOfflineCache()
            }
            if ProcessInfo.processInfo.arguments.contains(
                "--seed-missing-source-reader"
            ) {
                await seedMissingSourceReader()
            }
            if ProcessInfo.processInfo.arguments.contains(
                "--seed-pagination-cache"
            ) {
                await seedPaginationCache()
            }
            if ProcessInfo.processInfo.arguments.contains(
                "--seed-webdav-progress"
            ) {
                await seedWebDAVProgress()
            }
            if webDAVSettings.value.syncBookProgress,
               !ProcessInfo.processInfo.arguments.contains(
                   "--seed-webdav-progress"
               ) {
                _ = await library.synchronizeWebDAVShelfProgress(
                    configuration: webDAVSettings.value.connectionConfiguration,
                    loader: webDAVProgressLoader
                )
            }
            if !ProcessInfo.processInfo.arguments.contains(
                "--skip-webdav-latest-backup-discovery"
            ) {
                await discoverLatestWebDAVBackup()
            }
        }
        .onChange(of: rootVisibility.value) { _, _ in
            router.reconcileVisibleRoots(visibleRoots)
        }
        .onChange(of: scenePhase) { _, phase in
            // Android invokes autoBack from Activity.onPause/onDestroy. The
            // inactive transition is the closest iOS lifecycle boundary that
            // still gives the asynchronous upload time to finish.
            if phase == .inactive {
                performAutomaticWebDAVBackupIfNeeded()
            }
        }
    }

    private func discoverLatestWebDAVBackup() async {
        guard
            let configuration = webDAVSettings.value.connectionConfiguration
        else { return }
        guard case .loaded(let files) = await webDAVBackupSync.listBackups(
            configuration: configuration
        ) else { return }
        guard case .offer(let file, let checkpoint) =
            WebDAVLatestBackupDiscovery.decide(
                files: files,
                lastHandledMilliseconds:
                    webDAVBackupCheckpoint.lastBackupMilliseconds
            )
        else { return }

        // Android advances LocalConfig.lastBackup before showing the dialog,
        // so cancelling does not repeatedly prompt for the same remote file.
        webDAVBackupCheckpoint.markBackup(checkpoint)
        webDAVBackupNotice = .offer(file)
    }

    private func restoreWebDAVBackup(
        _ file: WebDAVBackupFile,
        backupPassword: String? = nil
    ) {
        guard
            let configuration = webDAVSettings.value.connectionConfiguration
        else {
            webDAVBackupNotice = .failure("请先配置 WebDAV")
            return
        }
        Task {
            switch await webDAVBackupSync.restore(
                configuration: configuration,
                fileName: file.name,
                backupPassword: backupPassword
            ) {
            case .restored(let summary):
                webDAVBackupPasswordRequest = nil
                webDAVRestorePassword = ""
                webDAVRestorePasswordError = nil
                webDAVBackupCheckpoint.markBackup(
                    Int64(Date().timeIntervalSince1970 * 1_000)
                )
                if let projection = summary.readerConfigProjection {
                    readerPreferences.apply(projection)
                }
                await library.reload()
                await sourceCatalog.reload()
                await replacementRules.reload()
                await ruleSubscriptions.reload()
                await rssStore.reload()
                await httpTextToSpeechEngines.reload()
                await dictionaryLookup.reload()
                await keyboardAssists.reload()
                await appThemeProfiles.reload()
                webDAVBackupNotice = .result(
                    "已恢复 \(summary.bookCount) 本书、"
                    + "\(summary.groupCount) 个分组、"
                    + "\(summary.bookmarkCount) 条书签"
                )
            case .failed(.backupPasswordRequired):
                webDAVRestorePassword = ""
                webDAVRestorePasswordError = nil
                webDAVBackupPasswordRequest = WebDAVBackupPasswordRequest(
                    file: file
                )
            case .failed(.invalidBackupPassword):
                webDAVRestorePassword = ""
                webDAVRestorePasswordError = "备份口令错误，请重试"
            case .failed:
                webDAVBackupPasswordRequest = nil
                webDAVRestorePassword = ""
                webDAVRestorePasswordError = nil
                webDAVBackupNotice = .failure("无法恢复 \(file.name)")
            }
        }
    }

    private func performAutomaticWebDAVBackupIfNeeded() {
        guard !isAutomaticBackupRunning else { return }
        guard
            let configuration = webDAVSettings.value.connectionConfiguration
        else { return }
        isAutomaticBackupRunning = true
        Task {
            defer { isAutomaticBackupRunning = false }
            let exportContext: AndroidBackupExportContext
            do {
                exportContext = try await automaticBackupExportContext()
            } catch {
                return
            }
            let result = await webDAVBackupSync.automaticBackup(
                configuration: configuration,
                now: Date(),
                lastBackupMilliseconds:
                    webDAVBackupCheckpoint.lastBackupMilliseconds,
                deviceName: webDAVSettings.value.webDAVDeviceName,
                bookSources: sourceCatalog.sources,
                replacementRules: replacementRules.rules,
                readerPreferences: readerPreferences.value,
                exportContext: exportContext
            )
            switch result {
            case .remoteAlreadyExists(_, let checkpoint),
                 .uploaded(_, let checkpoint, _):
                webDAVBackupCheckpoint.markBackup(checkpoint)
            case .notDue, .failed:
                break
            }
        }
    }

    private func automaticBackupExportContext() async throws
        -> AndroidBackupExportContext
    {
        guard
            let backupPassword = try await androidBackupPasswordStore.password()
        else { throw AndroidLibraryBackupError.backupPasswordRequired }

        let storedProfiles = WebDAVDefaultServerBridge.androidExportProfiles(
            try await webDAVServerProfiles.webDAVServerProfiles()
        )
        var profileExports: [AndroidWebDAVServerProfileExportInput] = []
        for profile in storedProfiles {
            let credential = try await webDAVCredentials.credentials(
                for: profile.credentialReference
            )
            profileExports.append(
                AndroidWebDAVServerProfileExportInput(
                    id: profile.id,
                    name: profile.name,
                    serverAddress: profile.serverAddress,
                    username: credential.username,
                    password: credential.password,
                    sortNumber: profile.sortNumber
                )
            )
        }

        let settings = webDAVSettings.value
        let primaryConfiguration: AndroidWebDAVBackupExportInput?
        if settings.serverAddress.isEmpty {
            primaryConfiguration = nil
        } else {
            let credential = try await webDAVCredentials.credentials(
                for: settings.credentialReference
            )
            primaryConfiguration = AndroidWebDAVBackupExportInput(
                serverAddress: settings.serverAddress,
                username: credential.username,
                password: credential.password,
                directoryName: settings.directoryName,
                backupPassword: backupPassword,
                syncBookProgress: settings.syncBookProgress,
                webDAVDeviceName: settings.webDAVDeviceName,
                onlyLatestBackup: settings.onlyLatestBackup
            )
        }
        let selectedID = WebDAVDefaultServerBridge.androidExportSelectedID(
            try await webDAVServerProfiles.selectedWebDAVServerProfileID()
        )
        return AndroidBackupExportContext(
            applicationPreferences: AndroidApplicationBackupExportInput(
                showsDiscovery: rootVisibility.value.showsExplore,
                showsRSS: rootVisibility.value.showsRSS,
                bookshelfSort: await library.globalShelfSortMode(),
                defaultHomePage: rootVisibility.value.defaultHomePage,
                readingHistoryPreferences: readingHistoryPreferences.value,
                searchScopePreferences: searchScopePreferences.value,
                sourceSwitchPreferences: sourceSwitchPreferences.value,
                readAloudPreferences: readAloudPreferences.value,
                readerPreferences: readerPreferences.value
            ),
            webDAVConfiguration: primaryConfiguration,
            webDAVServerProfiles: profileExports,
            selectedWebDAVServerID: selectedID,
            backupPassword: backupPassword
        )
    }

    private var visibleRoots: [RootRoute] {
        var roots: [RootRoute] = [.shelf]
        if rootVisibility.value.showsExplore { roots.append(.explore) }
        if rootVisibility.value.showsRSS { roots.append(.rss) }
        roots.append(.settings)
        return roots
    }

    private var activeThemeTint: Color {
        guard let value = appThemeProfiles.selectedProfile?.accentColor,
              let color = Color(androidHex: value)
        else { return .accentColor }
        return color
    }

    private var activeThemePrimary: Color {
        guard let value = appThemeProfiles.selectedProfile?.primaryColor,
              let color = Color(androidHex: value)
        else { return Color(uiColor: .systemBackground) }
        return color
    }

    private var activeThemeBackground: Color {
        guard let value = appThemeProfiles.selectedProfile?.backgroundColor,
              let color = Color(androidHex: value)
        else { return Color(uiColor: .systemBackground) }
        return color
    }

    private var activeThemeBottomBackground: Color {
        guard let value = appThemeProfiles.selectedProfile?.bottomBackgroundColor,
              let color = Color(androidHex: value)
        else { return Color(uiColor: .systemBackground) }
        return color
    }

    private var activeThemeColorScheme: ColorScheme? {
        guard let profile = appThemeProfiles.selectedProfile else { return nil }
        return profile.isNightTheme ? .dark : .light
    }

    private var compactShell: some View {
        TabView(selection: $router.selectedRoot) {
            ForEach(visibleRoots) { root in
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
                ForEach(visibleRoots) { root in
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
                backupSources: sourceCatalog.sources,
                backupReplacementRules: replacementRules.rules,
                webDAVBackupCheckpoint: webDAVBackupCheckpoint,
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
                },
                rssStore: rssStore,
                readerPreferences: readerPreferences,
                readAloudPreferences: readAloudPreferences,
                readingHistoryPreferences: readingHistoryPreferences,
                searchScopePreferences: searchScopePreferences,
                sourceSwitchPreferences: sourceSwitchPreferences,
                appThemeProfiles: appThemeProfiles,
                rootVisibility: rootVisibility,
                webDAVSettings: webDAVSettings,
                webDAVCredentials: webDAVCredentials,
                androidBackupPasswordStore: androidBackupPasswordStore,
                webDAVClient: webDAVClient,
                backupRestore: backupRestore,
                reloadBackupDomains: {
                    await sourceCatalog.reload()
                    await replacementRules.reload()
                    await ruleSubscriptions.reload()
                    await rssStore.reload()
                    await httpTextToSpeechEngines.reload()
                    await dictionaryLookup.reload()
                    await keyboardAssists.reload()
                    await appThemeProfiles.reload()
                },
                libraryBackup: libraryBackup,
                webDAVBackupSync: webDAVBackupSync,
                webDAVServerProfiles: webDAVServerProfiles,
                webDAVRemoteBooks: webDAVRemoteBooks,
                restoreWebDAVBackup: { file in
                    restoreWebDAVBackup(file)
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
                persistedSources: sourceCatalog.sources,
                library: library,
                scopePreferences: searchScopePreferences
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
                preferences: bookDetailPreferences,
                copyToClipboard: { value in
                    UIPasteboard.general.string = value
                },
                refreshBookInfo: { item in
                    if AndroidWebDAVBookOrigin.isLocalSource(
                        item.candidate.sourceID
                    ) {
                        return await refreshLocalBook(item)
                    }
                    return await library.refreshBookInfo(
                        item,
                        infoLoader:
                            SearchEnvironment.makeBookInfoLoader(
                                persistedSources: sourceCatalog.sources
                            ),
                        chapterLoader:
                            SearchEnvironment.makeChapterLoader(
                                persistedSources: sourceCatalog.sources
                            )
                    )
                },
                updateMetadata: { bookID, update in
                    await library.updateBookMetadata(
                        bookID: bookID,
                        update: update
                    )
                },
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
                loginSource: { sourceID in
                    guard
                        let source = sourceCatalog.source(id: sourceID),
                        !source.loginURL.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                    else {
                        return
                    }
                    router.push(
                        .sourceLogin(sourceID),
                        on: root
                    )
                },
                setSourceVariable: { sourceID, variable in
                    await sourceCatalog.saveUserVariable(
                        variable,
                        sourceID: sourceID
                    )
                },
                setSplitLongChapters: { item, enabled in
                    guard let file = await localBookFile(for: item) else {
                        return nil
                    }
                    if file.reference != item.candidate.bookURL {
                        return await library.restoreWebDAVLocalText(
                            bookID: item.id,
                            managedReference: file.reference,
                            data: file.data,
                            splitsLongChapters: enabled
                        )
                    }
                    return await library
                        .setLocalTextLongChapterSplitting(
                            enabled,
                            bookID: item.id,
                            data: file.data
                        )
                },
                availableSources: sourceCatalog.sources,
                sourceSwitchPreferences: sourceSwitchPreferences,
                loadSourceSwitchCandidates: { current, sources, preferences in
                    await SearchEnvironment.loadSourceSwitchCandidates(
                        current: current,
                        currentChapter: nil,
                        targets: sources,
                        persistedSources: sourceCatalog.sources,
                        preferences: preferences,
                        sourceConcurrency: searchScopePreferences.value
                            .effectiveSourceConcurrency,
                        replacementRules: replacementRules.rules
                    )
                },
                switchSource: { current, source in
                    do {
                        let resolved = try await SearchEnvironment
                            .resolveSourceSwitch(
                                current: current,
                                target: source,
                                persistedSources: sourceCatalog.sources,
                                requiresAuthorMatch:
                                    sourceSwitchPreferences.value
                                    .requiresAuthorMatch
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
                },
                uploadLocalBook: { item in
                    guard
                        AndroidWebDAVBookOrigin.isLocalSource(
                            item.candidate.sourceID
                        ),
                        let fileURL = URL(
                            string: item.candidate.bookURL
                        ),
                        fileURL.isFileURL,
                        let data = try? Data(contentsOf: fileURL)
                    else {
                        return .localFileUnavailable
                    }
                    let outcome = await WebDAVLocalBookUploadUseCase(
                        repository: webDAVServerProfiles,
                        transfer: webDAVRemoteBooks
                    ).upload(
                        fileName: item.candidate.originName,
                        data: data
                    )
                    if case .uploaded(
                        let profileID,
                        _,
                        _,
                        let remoteURL
                    ) = outcome {
                        _ = await library.markWebDAVOrigin(
                            for: item,
                            remoteURL: remoteURL,
                            serverID: profileID
                        )
                    }
                    return outcome
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
                readAloudPreferences: readAloudPreferences,
                readingHistoryPreferences: readingHistoryPreferences,
                searchScopePreferences: searchScopePreferences,
                sourceSwitchPreferences: sourceSwitchPreferences,
                httpTextToSpeechEngines: httpTextToSpeechEngines,
                dictionaryLookup: dictionaryLookup,
                readerPreferences: readerPreferences,
                replacementRules: replacementRules,
                webDAVSettings: webDAVSettings,
                webDAVProgressLoader: webDAVProgressLoader,
                webDAVProgressUploader: webDAVProgressUploader,
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
                openBookInfo: { item in
                    router.push(
                        .bookDetail(SearchBookRoute(item: item)),
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
            SourceManagementView(
                catalog: sourceCatalog,
                ruleSubscriptions: ruleSubscriptions
            ) { sourceID in
                router.push(.sourceEditor(sourceID), on: root)
            }
        case .sourceEditor(let sourceID):
            SourceEditorView(
                source: sourceCatalog.source(id: sourceID),
                catalog: sourceCatalog,
                keyboardAssists: keyboardAssists,
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
            SourceSingleSearchView(
                source: sourceDraft(id: sourceID),
                persistedSources: sourceCatalog.sources
            ) { result in
                router.push(
                    .bookDetail(SearchBookRoute(result: result)),
                    on: root
                )
            }
        }
    }

    private func sourceDraft(id: String) -> BookSourceDraft {
        sourceCatalog.source(id: id)
            ?? BookSourceDraft(sourceURL: id, name: id)
    }

    private func localBookFile(
        for item: ShelfBookItem
    ) async -> ManagedBookFile? {
        if
            let url = URL(string: item.candidate.bookURL),
            url.isFileURL,
            let data = try? Data(contentsOf: url)
        {
            return ManagedBookFile(
                reference: item.candidate.bookURL,
                fileName: item.candidate.originName,
                data: data
            )
        }
        let outcome = await WebDAVLocalBookRecoveryUseCase(
            repository: webDAVServerProfiles,
            transfer: webDAVRemoteBooks
        ).recover(
            sourceID: item.candidate.sourceID,
            fallbackFileName: item.candidate.originName
        )
        guard case .recovered(_, let fileName, _, let data) = outcome else {
            return nil
        }
        return try? ManagedBookFileStore.persist(
            data: data,
            fileName: fileName
        )
    }

    private func refreshLocalBook(
        _ item: ShelfBookItem
    ) async -> ShelfBookItem? {
        let existingFile: ManagedBookFile? = {
            guard
                let url = URL(string: item.candidate.bookURL),
                url.isFileURL,
                let data = try? Data(contentsOf: url)
            else { return nil }
            return ManagedBookFile(
                reference: item.candidate.bookURL,
                fileName: item.candidate.originName,
                data: data
            )
        }()
        guard item.candidate.sourceID != "local-file" else {
            guard let existingFile else { return nil }
            return await library.refreshLocalText(
                bookID: item.id,
                data: existingFile.data
            )
        }
        let decision = await WebDAVRemoteBookRefreshUseCase(
            repository: webDAVServerProfiles,
            transfer: webDAVRemoteBooks
        ).check(
            sourceID: item.candidate.sourceID,
            lastCheckTime: item.lastCheckTime,
            localFileAvailable: existingFile != nil
        )
        switch decision {
        case .current(let remoteModifiedMilliseconds):
            guard let existingFile else { return nil }
            guard
                let refreshed = await library.refreshLocalText(
                    bookID: item.id,
                    data: existingFile.data
                )
            else { return nil }
            return await library.updateWebDAVBookState(
                bookID: refreshed.id,
                sourceID: refreshed.candidate.sourceID,
                lastCheckTime: remoteModifiedMilliseconds
            )
        case .downloadRequired(let target):
            guard case .downloaded(let name, let data) =
                await webDAVRemoteBooks.downloadRemoteBook(
                    configuration: target.configuration,
                    resource: target.resource
                ),
                let file = try? ManagedBookFileStore.persist(
                    data: data,
                    fileName: name
                ),
                let restored = await library.restoreWebDAVLocalText(
                    bookID: item.id,
                    managedReference: file.reference,
                    data: file.data
                )
            else { return nil }
            return await library.updateWebDAVBookState(
                bookID: restored.id,
                sourceID: restored.candidate.sourceID,
                lastCheckTime: target.resource.lastModifiedMilliseconds
            )
        case .remoteMissing:
            guard let existingFile else { return nil }
            guard
                let downgraded = await library.updateWebDAVBookState(
                    bookID: item.id,
                    sourceID: "local-file",
                    lastCheckTime: 0
                )
            else { return nil }
            return await library.refreshLocalText(
                bookID: downgraded.id,
                data: existingFile.data
            )
        case .notWebDAVBook, .invalidOrigin, .serverProfileUnavailable,
            .invalidServerProfile, .repositoryUnavailable, .failed:
            return nil
        }
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

    private func seedEPUBImport() async {
        guard library.books.isEmpty else { return }
        guard
            let data = makeEPUBFixtureData(),
            let file = try? ManagedBookFileStore.persist(
                data: data,
                fileName: "跨端论语.epub"
            ),
            let unpacked = try? ManagedBookFileStore.epubMembers(from: file)
        else { return }
        _ = await library.importLocalBook(
            fileName: file.fileName,
            managedReference: file.reference,
            payload: .epub(unpacked)
        )
    }

    private func seedZIPImport() async {
        guard library.books.isEmpty, let epub = makeEPUBFixtureData() else {
            return
        }
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("legado-ui-multibook.zip")
        let text = """
        归档前言
        第一章 出发
        ZIP 中的文本书已经可以阅读。
        第二章 抵达
        两本书共享同一导入主链。
        """
        let members = [
            ArchiveZIPFoundation.Member(
                path: "文本/《归档旅程》作者：林舟.txt",
                data: Data(text.utf8)
            ),
            ArchiveZIPFoundation.Member(
                path: "电子书/跨端论语.epub",
                data: epub
            ),
            ArchiveZIPFoundation.Member(
                path: "说明/readme.md",
                data: Data("不应导入".utf8)
            ),
        ]
        guard
            (try? ArchiveZIPFoundation.create(members: members, at: archiveURL)) != nil,
            let data = try? Data(contentsOf: archiveURL),
            let file = try? ManagedBookFileStore.persist(
                data: data,
                fileName: "双端书库.zip"
            ),
            let prepared = try? ManagedBookFileStore.localArchiveItems(
                from: file
            )
        else { return }
        _ = await library.importLocalArchive(
            archiveName: file.fileName,
            items: prepared.items,
            skipped: prepared.skipped
        )
    }

    private func makeEPUBFixtureData() -> Data? {
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("legado-ui-minimal.epub")
        let members = [
            ArchiveZIPFoundation.Member(
                path: "mimetype",
                data: Data("application/epub+zip".utf8)
            ),
            ArchiveZIPFoundation.Member(
                path: "META-INF/container.xml",
                data: Data("""
                <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                  <rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles>
                </container>
                """.utf8)
            ),
            ArchiveZIPFoundation.Member(
                path: "OEBPS/content.opf",
                data: Data("""
                <package xmlns="http://www.idpf.org/2007/opf">
                  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                    <dc:title>跨端论语</dc:title><dc:creator>孔门</dc:creator>
                  </metadata>
                  <manifest>
                    <item id="nav" href="nav.xhtml" properties="nav"/>
                    <item id="one" href="Text/one.xhtml"/>
                    <item id="two" href="Text/two.xhtml"/>
                  </manifest>
                  <spine><itemref idref="one"/><itemref idref="two"/></spine>
                </package>
                """.utf8)
            ),
            ArchiveZIPFoundation.Member(
                path: "OEBPS/nav.xhtml",
                data: Data("""
                <html xmlns="http://www.w3.org/1999/xhtml"><body><nav><ol>
                  <li><a href="Text/one.xhtml">学而</a></li>
                  <li><a href="Text/two.xhtml">为政</a></li>
                </ol></nav></body></html>
                """.utf8)
            ),
            ArchiveZIPFoundation.Member(
                path: "OEBPS/Text/one.xhtml",
                data: Data("""
                <html xmlns="http://www.w3.org/1999/xhtml"><head><title>学而</title></head>
                <body><p>学而时习之，不亦说乎。</p></body></html>
                """.utf8)
            ),
            ArchiveZIPFoundation.Member(
                path: "OEBPS/Text/two.xhtml",
                data: Data("""
                <html xmlns="http://www.w3.org/1999/xhtml"><head><title>为政</title></head>
                <body><p>为政以德，譬如北辰。</p></body></html>
                """.utf8)
            ),
        ]
        guard
            (try? ArchiveZIPFoundation.create(members: members, at: archiveURL)) != nil
        else { return nil }
        return try? Data(contentsOf: archiveURL)
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

    private func seedMissingSourceReader() async {
        await seedOfflineCache()
        guard let book = library.books.first else { return }
        let chapters = await library.chapters(bookID: book.id)
            .sorted { $0.index < $1.index }
        guard let chapter = chapters.first else { return }
        _ = await library.saveReadingProgress(
            bookID: book.id,
            chapterIndex: chapter.index,
            characterOffset: 0,
            chapterTitle: chapter.title
        )
        let missingCandidate = ShelfBookCandidate(
            name: book.candidate.name,
            author: book.candidate.author,
            kind: book.candidate.kind,
            lastChapter: book.candidate.lastChapter,
            intro: book.candidate.intro,
            bookURL: book.candidate.bookURL,
            tocURL: book.candidate.tocURL,
            bookRequestExpression: book.candidate.bookRequestExpression,
            coverURL: book.candidate.coverURL,
            customCoverURL: book.candidate.customCoverURL,
            customIntro: book.candidate.customIntro,
            originName: "已失效书源",
            sourceID: "https://missing.invalid/source",
            variables: book.candidate.variables
        )
        _ = await library.switchSource(
            current: book,
            candidate: missingCandidate,
            chapters: chapters
        )
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

    private func seedWebDAVProgress() async {
        await seedOfflineCache()
        guard let book = library.books.first else { return }
        let chapters = await library.chapters(bookID: book.id)
            .sorted { $0.index < $1.index }
        guard chapters.indices.contains(1) else { return }
        let chapter = chapters[1]
        await library.saveReadingProgress(
            bookID: book.id,
            chapterIndex: chapter.index,
            characterOffset: 90,
            chapterTitle: chapter.title
        )
    }
}

private struct RootContentView: View {
    let root: RootRoute
    @Bindable var library: ShelfLibrary
    let persistedSources: [BookSourceDraft]
    let backupSources: [BookSourceDraft]
    let backupReplacementRules: [ReaderReplacementRule]
    @Bindable var webDAVBackupCheckpoint: WebDAVBackupCheckpointStore
    let openSearch: () -> Void
    let openSources: () -> Void
    let openExploreSource: (ExploreSourceSummary) -> Void
    let openBook: (ShelfBookItem) -> Void
    let books: () -> [ShelfBookItem]
    let exploreSources: () -> [ExploreSourceSummary]
    @Bindable var rssStore: RSSStore
    @Bindable var readerPreferences: ReaderPreferencesStore
    @Bindable var readAloudPreferences: ReadAloudPreferencesStore
    @Bindable var readingHistoryPreferences: ReadingHistoryPreferencesStore
    @Bindable var searchScopePreferences: SearchScopePreferencesStore
    @Bindable var sourceSwitchPreferences: SourceSwitchPreferencesStore
    @Bindable var appThemeProfiles: AppThemeProfileStore
    @Bindable var rootVisibility: RootVisibilityPreferencesStore
    @Bindable var webDAVSettings: WebDAVConnectionSettingsStore
    let webDAVCredentials: KeychainWebDAVCredentialStore
    let androidBackupPasswordStore: any AndroidBackupPasswordStoring
    let webDAVClient: any WebDAVConnectionInitializing
    let backupRestore: AndroidCoreBackupRestoreUseCase
    let reloadBackupDomains: () async -> Void
    let libraryBackup: AndroidLibraryBackupUseCase
    let webDAVBackupSync: WebDAVBackupSyncUseCase
    let webDAVServerProfiles: any WebDAVServerProfileRepository
    let webDAVRemoteBooks: any WebDAVRemoteBookTransferring
    let restoreWebDAVBackup: (WebDAVBackupFile) -> Void
    @State private var webDAVAccount = ProcessInfo.processInfo.arguments.contains(
        "--webdav-test-double"
    ) ? "reader" : ""
    @State private var webDAVPassword = ProcessInfo.processInfo.arguments.contains(
        "--webdav-test-double"
    ) ? "p@ssword" : ""
    @State private var webDAVStatus = ""
    @State private var showsAndroidBackupImporter = false
    @State private var androidBackupImportStatus = ""
    @State private var androidBackupPassword = ""
    @State private var showsAndroidBackupExporter = false
    @State private var androidBackupExportDocument = AndroidBackupZipDocument()
    @State private var androidBackupExportStatus = ""
    @State private var webDAVBackupFiles: [WebDAVBackupFile] = []
    @State private var webDAVBackupStatus = ""

    var body: some View {
        if root == .shelf {
            ShelfManagementView(
                library: library,
                persistedSources: persistedSources,
                sourceSwitchPreferences: sourceSwitchPreferences,
                webDAVServerProfiles: webDAVServerProfiles,
                webDAVServerCredentials: KeychainWebDAVServerCredentialVault(
                    store: webDAVCredentials
                ),
                webDAVRemoteBooks: webDAVRemoteBooks,
                openSearch: openSearch,
                openBook: openBook
            )
        } else if root == .rss {
            RSSRootView(store: rssStore)
        } else {
            genericRoot
        }
    }

    private var genericRoot: some View {
        ScrollView {
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

                VStack(alignment: .leading, spacing: 10) {
                    Text("Android 数据互通")
                        .font(.headline)
                    Button {
                        beginAndroidBackupImport()
                    } label: {
                        Label("导入 Android backup.zip", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("action.settings.androidBackup.import")
                    SecureField(
                        "Android 备份口令（可留空）",
                        text: $androidBackupPassword
                    )
                    .accessibilityIdentifier(
                        "field.settings.androidBackup.password"
                    )
                    Button("保存为自动备份口令（空值兼容 Android 默认）") {
                        saveAutomaticBackupPassword()
                    }
                    .accessibilityIdentifier(
                        "action.settings.androidBackup.savePassword"
                    )
                    if !androidBackupImportStatus.isEmpty {
                        Text(androidBackupImportStatus)
                            .accessibilityIdentifier("state.settings.androidBackup.import")
                    }
                    Button {
                        prepareAndroidBackupExport()
                    } label: {
                        Label("导出 Android backup.zip", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("action.settings.androidBackup.export")
                    if !androidBackupExportStatus.isEmpty {
                        Text(androidBackupExportStatus)
                            .accessibilityIdentifier("state.settings.androidBackup.export")
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("根入口")
                        .font(.headline)
                    Toggle(
                        "显示发现",
                        isOn: Binding(
                            get: { rootVisibility.value.showsExplore },
                            set: { rootVisibility.setShowsExplore($0) }
                        )
                    )
                    .accessibilityIdentifier("toggle.settings.root.explore")
                    Toggle(
                        "显示 RSS",
                        isOn: Binding(
                            get: { rootVisibility.value.showsRSS },
                            set: { rootVisibility.setShowsRSS($0) }
                        )
                    )
                    .accessibilityIdentifier("toggle.settings.root.rss")
                    Picker(
                        "默认首页",
                        selection: Binding(
                            get: {
                                rootVisibility.value.defaultHomePage
                            },
                            set: {
                                rootVisibility.setDefaultHomePage($0)
                            }
                        )
                    ) {
                        ForEach(DefaultHomePage.allCases, id: \.rawValue) {
                            page in
                            Text(page.title).tag(page)
                        }
                    }
                    .accessibilityIdentifier(
                        "picker.settings.root.defaultHomePage"
                    )
                }
                .accessibilityIdentifier("section.settings.rootVisibility")

                VStack(alignment: .leading, spacing: 10) {
                    Text("阅读记录")
                        .font(.headline)
                    Toggle(
                        "记录阅读时长",
                        isOn: Binding(
                            get: {
                                readingHistoryPreferences.value
                                    .recordsReadingTime
                            },
                            set: {
                                readingHistoryPreferences
                                    .setRecordsReadingTime($0)
                            }
                        )
                    )
                    .accessibilityIdentifier(
                        "toggle.settings.readingHistory.enabled"
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("换源")
                        .font(.headline)
                    Toggle(
                        "原书源失效时自动换源",
                        isOn: Binding(
                            get: {
                                sourceSwitchPreferences.value
                                    .automaticallyRecoversMissingSource
                            },
                            set: {
                                sourceSwitchPreferences
                                    .setAutomaticallyRecoversMissingSource($0)
                            }
                        )
                    )
                    .accessibilityIdentifier(
                        "toggle.settings.sourceSwitch.automaticRecovery"
                    )
                    Toggle(
                        "换源时校验作者",
                        isOn: Binding(
                            get: {
                                sourceSwitchPreferences.value
                                    .requiresAuthorMatch
                            },
                            set: {
                                sourceSwitchPreferences
                                    .setRequiresAuthorMatch($0)
                            }
                        )
                    )
                    .accessibilityIdentifier(
                        "toggle.settings.sourceSwitch.authorMatch"
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("应用主题")
                        .font(.headline)
                    Picker(
                        "主题模板",
                        selection: Binding(
                            get: { appThemeProfiles.selectedName },
                            set: { appThemeProfiles.select($0) }
                        )
                    ) {
                        Text("跟随系统").tag(String?.none)
                        ForEach(appThemeProfiles.profiles) { profile in
                            Text(profile.name).tag(Optional(profile.name))
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("picker.settings.appTheme")
                    if let profile = appThemeProfiles.selectedProfile {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color(androidHex: profile.primaryColor) ?? .primary)
                            Circle()
                                .fill(Color(androidHex: profile.accentColor) ?? .accentColor)
                            Text(profile.isNightTheme ? "深色" : "浅色")
                                .foregroundStyle(.secondary)
                        }
                        .frame(height: 24)
                        .accessibilityIdentifier("state.settings.appTheme.selected")
                    } else if appThemeProfiles.profiles.isEmpty {
                        Text("导入 Android backup.zip 后可选择主题模板")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("section.settings.appTheme")

                VStack(alignment: .leading, spacing: 10) {
                    Text("WebDAV")
                        .font(.headline)
                    TextField("服务器地址", text: Binding(
                        get: { webDAVSettings.value.serverAddress },
                        set: { webDAVSettings.update(serverAddress: $0, directoryName: webDAVSettings.value.directoryName) }
                    ))
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("field.settings.webdav.server")
                    TextField("账号", text: $webDAVAccount)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("field.settings.webdav.account")
                    SecureField("密码", text: $webDAVPassword)
                        .accessibilityIdentifier("field.settings.webdav.password")
                    TextField("目录", text: Binding(
                        get: { webDAVSettings.value.directoryName },
                        set: { webDAVSettings.update(serverAddress: webDAVSettings.value.serverAddress, directoryName: $0) }
                    ))
                    .accessibilityIdentifier("field.settings.webdav.directory")
                    Toggle(
                        "同步阅读进度",
                        isOn: Binding(
                            get: { webDAVSettings.value.syncBookProgress },
                            set: { webDAVSettings.updateSyncBookProgress($0) }
                        )
                    )
                    .accessibilityIdentifier(
                        "toggle.settings.webdav.syncBookProgress"
                    )
                    TextField("备份设备名称", text: Binding(
                        get: { webDAVSettings.value.webDAVDeviceName },
                        set: {
                            webDAVSettings.updateBackupPreferences(
                                deviceName: $0,
                                onlyLatestBackup:
                                    webDAVSettings.value.onlyLatestBackup
                            )
                        }
                    ))
                    .accessibilityIdentifier(
                        "field.settings.webdav.deviceName"
                    )
                    Toggle(
                        "Android 本地仅保留最新备份",
                        isOn: Binding(
                            get: { webDAVSettings.value.onlyLatestBackup },
                            set: {
                                webDAVSettings.updateBackupPreferences(
                                    deviceName:
                                        webDAVSettings.value.webDAVDeviceName,
                                    onlyLatestBackup: $0
                                )
                            }
                        )
                    )
                    .accessibilityIdentifier(
                        "toggle.settings.webdav.onlyLatestBackup"
                    )
                    Button("测试连接") { testWebDAVConnection() }
                        .accessibilityIdentifier("action.settings.webdav.test")
                    if !webDAVStatus.isEmpty {
                        Text(webDAVStatus)
                            .accessibilityIdentifier("state.settings.webdav.connection")
                    }
                    Divider()
                    Button {
                        uploadWebDAVBackup()
                    } label: {
                        Label("上传全量备份", systemImage: "icloud.and.arrow.up")
                    }
                    .accessibilityIdentifier(
                        "action.settings.webdav.backup.upload"
                    )
                    Button {
                        loadWebDAVBackups()
                    } label: {
                        Label("刷新云端备份", systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier(
                        "action.settings.webdav.backup.refresh"
                    )
                    ForEach(webDAVBackupFiles, id: \.name) { file in
                        Button {
                            restoreWebDAVBackup(file)
                        } label: {
                            Label(
                                "恢复 \(file.name)",
                                systemImage: "icloud.and.arrow.down"
                            )
                        }
                        .accessibilityIdentifier(
                            "action.settings.webdav.backup.restore.\(file.name)"
                        )
                    }
                    if !webDAVBackupStatus.isEmpty {
                        Text(webDAVBackupStatus)
                            .accessibilityIdentifier(
                                "state.settings.webdav.backup"
                            )
                    }
                }
            }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(root.title)
        .accessibilityIdentifier("scroll.\(root.rawValue)")
        .fileImporter(
            isPresented: $showsAndroidBackupImporter,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else {
                    androidBackupImportStatus = "未选择备份文件"
                    return
                }
                restoreAndroidLibrary(from: url, removeAfterRestore: false)
            case .failure:
                androidBackupImportStatus = "备份文件选择失败"
            }
        }
        .fileExporter(
            isPresented: $showsAndroidBackupExporter,
            document: androidBackupExportDocument,
            contentType: .zip,
            defaultFilename: "backup"
        ) { result in
            switch result {
            case .success:
                androidBackupExportStatus = androidBackupExportStatus
                    .replacingOccurrences(of: "已准备", with: "已导出")
            case .failure:
                androidBackupExportStatus = "Android 备份保存失败"
            }
        }
    }

    private func beginAndroidBackupImport() {
        guard
            let encoded = ProcessInfo.processInfo.environment[
                "LEGADO_ANDROID_BACKUP_FIXTURE_BASE64"
            ],
            let data = Data(base64Encoded: encoded)
        else {
            showsAndroidBackupImporter = true
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-library-import-ui-test.zip")
        do {
            try data.write(to: url, options: .atomic)
            restoreAndroidLibrary(from: url, removeAfterRestore: true)
        } catch {
            androidBackupImportStatus = "备份测试文件准备失败"
        }
    }

    private func restoreAndroidLibrary(
        from url: URL,
        removeAfterRestore: Bool
    ) {
        androidBackupImportStatus = "正在导入…"
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        Task {
            defer {
                if hasSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
                if removeAfterRestore {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            do {
                let summary = try await backupRestore.restore(
                    from: url,
                    backupPassword: androidBackupPassword.isEmpty
                        ? nil
                        : androidBackupPassword
                )
                androidBackupPassword = ""
                if let projection = summary.readerConfigProjection {
                    readerPreferences.apply(projection)
                }
                await library.reload()
                await reloadBackupDomains()
                androidBackupImportStatus =
                    "已导入 \(summary.bookCount) 本书、"
                    + "\(summary.groupCount) 个分组、"
                    + "\(summary.bookmarkCount) 条书签"
                if summary.bookSourceCount > 0
                    || summary.replacementRuleCount > 0
                {
                    androidBackupImportStatus +=
                        "、\(summary.bookSourceCount) 个书源、"
                        + "\(summary.replacementRuleCount) 条替换规则"
                }
                if summary.readRecordCount > 0 {
                    androidBackupImportStatus +=
                        "、\(summary.readRecordCount) 条阅读记录"
                }
                if summary.searchHistoryCount > 0 {
                    androidBackupImportStatus +=
                        "、\(summary.searchHistoryCount) 条搜索历史"
                }
                if summary.ruleSubscriptionCount > 0 {
                    androidBackupImportStatus +=
                        "、\(summary.ruleSubscriptionCount) 条规则订阅"
                }
                if summary.keyboardAssistCount > 0 {
                    androidBackupImportStatus +=
                        "、\(summary.keyboardAssistCount) 个编辑辅助键"
                }
                if summary.themeConfigCount > 0 {
                    androidBackupImportStatus +=
                        "、\(summary.themeConfigCount) 个主题模板"
                }
                if summary.rssSourceCount > 0 || summary.rssStarCount > 0 {
                    androidBackupImportStatus +=
                        "、\(summary.rssSourceCount) 个 RSS 源、"
                        + "\(summary.rssStarCount) 条 RSS 收藏"
                }
                if summary.httpTextToSpeechEngineCount > 0 {
                    androidBackupImportStatus +=
                        "、\(summary.httpTextToSpeechEngineCount) 个在线朗读引擎"
                }
                if summary.readerConfigCount > 0 {
                    androidBackupImportStatus +=
                        "、\(summary.readerConfigCount) 份阅读配置"
                }
                if summary.dictionaryRuleCount > 0 {
                    androidBackupImportStatus +=
                        "、\(summary.dictionaryRuleCount) 条词典规则"
                }
                if summary.webDAVConfigurationCount > 0 {
                    androidBackupImportStatus += "、1 份 WebDAV 配置"
                }
                if summary.webDAVServerProfileCount > 0 {
                    androidBackupImportStatus +=
                        "、\(summary.webDAVServerProfileCount) 个 WebDAV 服务器"
                }
            } catch AndroidCoreBackupRestoreError.backupPasswordRequired {
                androidBackupImportStatus = "请输入 Android 备份口令后重试"
            } catch AndroidCoreBackupRestoreError.invalidBackupPassword {
                androidBackupImportStatus = "Android 备份口令错误"
            } catch {
                androidBackupImportStatus = "Android 备份导入失败"
            }
        }
    }

    private func prepareAndroidBackupExport() {
        androidBackupExportStatus = "正在准备…"
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("backup.zip")
        Task {
            do {
                try FileManager.default.createDirectory(
                    at: archiveURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                defer {
                    try? FileManager.default.removeItem(
                        at: archiveURL.deletingLastPathComponent()
                    )
                }
                let storedServerProfiles = WebDAVDefaultServerBridge
                    .androidExportProfiles(
                        try await webDAVServerProfiles
                            .webDAVServerProfiles()
                    )
                let selectedServerID = WebDAVDefaultServerBridge
                    .androidExportSelectedID(
                        try await webDAVServerProfiles
                            .selectedWebDAVServerProfileID()
                    )
                var serverProfileExports: [
                    AndroidWebDAVServerProfileExportInput
                ] = []
                for profile in storedServerProfiles {
                    let credential = try await webDAVCredentials.credentials(
                        for: profile.credentialReference
                    )
                    serverProfileExports.append(
                        AndroidWebDAVServerProfileExportInput(
                            id: profile.id,
                            name: profile.name,
                            serverAddress: profile.serverAddress,
                            username: credential.username,
                            password: credential.password,
                            sortNumber: profile.sortNumber
                        )
                    )
                }
                let webDAVConfiguration: AndroidWebDAVBackupExportInput?
                if webDAVSettings.value.serverAddress.isEmpty {
                    webDAVConfiguration = nil
                } else {
                    let credentials = try await webDAVCredentials.credentials(
                        for: webDAVSettings.value.credentialReference
                    )
                    webDAVConfiguration = AndroidWebDAVBackupExportInput(
                        serverAddress: webDAVSettings.value.serverAddress,
                        username: credentials.username,
                        password: credentials.password,
                        directoryName: webDAVSettings.value.directoryName,
                        backupPassword: androidBackupPassword,
                        syncBookProgress: webDAVSettings.value.syncBookProgress,
                        webDAVDeviceName:
                            webDAVSettings.value.webDAVDeviceName,
                        onlyLatestBackup:
                            webDAVSettings.value.onlyLatestBackup
                    )
                }
                let summary = try await libraryBackup.export(
                    to: archiveURL,
                    bookSources: backupSources,
                    replacementRules: backupReplacementRules,
                    readerPreferences: readerPreferences.value,
                    applicationPreferences:
                        AndroidApplicationBackupExportInput(
                            showsDiscovery:
                                rootVisibility.value.showsExplore,
                            showsRSS: rootVisibility.value.showsRSS,
                            bookshelfSort:
                                await library.globalShelfSortMode(),
                            defaultHomePage:
                                rootVisibility.value.defaultHomePage,
                            readingHistoryPreferences:
                                readingHistoryPreferences.value,
                            searchScopePreferences:
                                searchScopePreferences.value,
                            sourceSwitchPreferences:
                                sourceSwitchPreferences.value,
                            readAloudPreferences:
                                readAloudPreferences.value,
                            readerPreferences: readerPreferences.value
                        ),
                    webDAVConfiguration: webDAVConfiguration,
                    webDAVServerProfiles: serverProfileExports,
                    selectedWebDAVServerID: selectedServerID,
                    backupPassword: androidBackupPassword
                )
                androidBackupPassword = ""
                androidBackupExportDocument = AndroidBackupZipDocument(
                    data: try Data(contentsOf: archiveURL)
                )
                androidBackupExportStatus =
                    "已准备 \(summary.bookCount) 本书、"
                    + "\(summary.groupCount) 个分组、"
                    + "\(summary.bookmarkCount) 条书签、"
                    + "\(summary.bookSourceCount) 个书源、"
                    + "\(summary.replacementRuleCount) 条替换规则、"
                    + "\(summary.readRecordCount) 条阅读记录、"
                    + "\(summary.searchHistoryCount) 条搜索历史、"
                    + "\(summary.ruleSubscriptionCount) 条规则订阅、"
                    + "\(summary.rssSourceCount) 个 RSS 源、"
                    + "\(summary.rssStarCount) 条 RSS 收藏、"
                    + "\(summary.httpTextToSpeechEngineCount) 个在线朗读引擎"
                if summary.webDAVConfigurationCount > 0 {
                    androidBackupExportStatus += "、1 份 WebDAV 配置"
                }
                if summary.webDAVServerProfileCount > 0 {
                    androidBackupExportStatus +=
                        "、\(summary.webDAVServerProfileCount) 个 WebDAV 服务器"
                }
                showsAndroidBackupExporter = true
            } catch {
                androidBackupExportStatus = "Android 备份生成失败"
            }
        }
    }

    private func saveAutomaticBackupPassword() {
        let password = androidBackupPassword
        Task {
            do {
                try await androidBackupPasswordStore.save(password)
                androidBackupExportStatus = "自动备份口令已安全保存"
                androidBackupPassword = ""
            } catch {
                androidBackupExportStatus = "自动备份口令保存失败"
            }
        }
    }

    private func testWebDAVConnection() {
        guard
            let serverURL = WebDAVServerURL(
                rawValue: webDAVSettings.value.serverAddress
            ),
            !webDAVAccount.isEmpty,
            !webDAVPassword.isEmpty
        else {
            webDAVStatus = "请填写完整 WebDAV 配置"
            return
        }
        let settings = WebDAVConnectionConfiguration(
            serverURL: serverURL,
            directoryName: webDAVSettings.value.directoryName,
            credentialReference: webDAVSettings.value.credentialReference
        )
        Task {
            do {
                try await webDAVCredentials.save(
                    WebDAVBasicCredentials(
                        username: webDAVAccount,
                        password: webDAVPassword
                    ),
                    for: settings.credentialReference
                )
                webDAVSettings.update(
                    serverAddress: serverURL.rawValue,
                    directoryName: webDAVSettings.value.directoryName
                )
                switch await webDAVClient.initialize(settings) {
                case .ready:
                    try await synchronizeDefaultWebDAVServer(
                        settings: webDAVSettings.value,
                        repository: webDAVServerProfiles
                    )
                    webDAVStatus = "WebDAV 连接成功"
                case .failed:
                    webDAVStatus = "WebDAV 连接失败"
                }
            } catch {
                webDAVStatus = "WebDAV 凭据保存失败"
            }
        }
    }

    private func uploadWebDAVBackup() {
        guard let configuration = webDAVSettings.value.connectionConfiguration else {
            webDAVBackupStatus = "请先配置 WebDAV"
            return
        }
        webDAVBackupStatus = "正在上传备份…"
        Task {
            let fileName = WebDAVBackupSyncUseCase.androidFileName(
                date: Date(),
                deviceName: webDAVSettings.value.webDAVDeviceName
            )
            let result = await webDAVBackupSync.upload(
                configuration: configuration,
                fileName: fileName,
                bookSources: backupSources,
                replacementRules: backupReplacementRules,
                readerPreferences: readerPreferences.value
            )
            switch result {
            case .uploaded(_, let summary):
                webDAVBackupCheckpoint.markBackup(
                    Int64(Date().timeIntervalSince1970 * 1_000)
                )
                webDAVBackupStatus =
                    "已上传 \(summary.bookCount) 本书、"
                    + "\(summary.bookSourceCount) 个书源"
                await refreshWebDAVBackups(configuration: configuration)
            case .failed:
                webDAVBackupStatus = "WebDAV 备份上传失败"
            }
        }
    }

    private func loadWebDAVBackups() {
        guard let configuration = webDAVSettings.value.connectionConfiguration else {
            webDAVBackupStatus = "请先配置 WebDAV"
            return
        }
        webDAVBackupStatus = "正在读取云端备份…"
        Task { await refreshWebDAVBackups(configuration: configuration) }
    }

    private func refreshWebDAVBackups(
        configuration: WebDAVConnectionConfiguration
    ) async {
        switch await webDAVBackupSync.listBackups(configuration: configuration) {
        case .loaded(let files):
            webDAVBackupFiles = files
            webDAVBackupStatus = files.isEmpty
                ? "云端没有备份"
                : "找到 \(files.count) 个云端备份"
        case .failed:
            webDAVBackupStatus = "云端备份读取失败"
        }
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
            tocURL: candidate.tocURL,
            bookRequestExpression:
                candidate.bookRequestExpression,
            coverURL: candidate.coverURL,
            customCoverURL: candidate.customCoverURL,
            customIntro: candidate.customIntro,
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
            tocURL: nil,
            bookRequestExpression: result.bookRequestExpression,
            coverURL: result.coverURL,
            customCoverURL: nil,
            customIntro: nil,
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
    @Bindable var library: ShelfLibrary
    @State private var session: SearchSession

    init(
        persistedSources: [BookSourceDraft],
        library: ShelfLibrary,
        scopePreferences: SearchScopePreferencesStore,
        openBookDetail: @escaping (SearchResult) -> Void
    ) {
        self.openBookDetail = openBookDetail
        self.library = library
        _session = State(
            initialValue: SearchEnvironment.makeSession(
                persistedSources: persistedSources,
                scopePreferences: scopePreferences
            )
        )
    }

    var body: some View {
        List {
            if session.query.isEmpty, !library.searchHistory.isEmpty {
                Section("搜索历史") {
                    ForEach(library.searchHistory, id: \.word) { entry in
                        Button(entry.word) {
                            session.query = entry.word
                            submitSearch()
                        }
                    }
                }
            }
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
            submitSearch()
        }
        .task {
            await library.reloadSearchHistory()
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
                    submitSearch()
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

    private func submitSearch() {
        let keyword = session.query
        Task {
            await library.recordSearchKeyword(keyword)
            session.search()
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
            Toggle(
                "精准搜索",
                isOn: Binding(
                    get: { session.usesPrecisionSearch },
                    set: { session.setUsesPrecisionSearch($0) }
                )
            )
            .accessibilityIdentifier("toggle.search.precision")

            Stepper(
                "并发书源数 \(session.sourceConcurrency)",
                value: Binding(
                    get: { session.sourceConcurrency },
                    set: { session.setSourceConcurrency($0) }
                ),
                in: SearchScopePreferences.sourceConcurrencyRange
            )
            .accessibilityIdentifier("action.search.sourceConcurrency")

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

private struct RSSRootView: View {
    @Bindable var store: RSSStore
    @State private var articles = SearchEnvironment.makeRSSArticleSession()
    @State private var selectedSourceID: String?
    @State private var selectedArticle: RSSArticleItem?

    var body: some View {
        List {
            Section("RSS 源（\(store.sources.count)）") {
                if store.sources.isEmpty {
                    ContentUnavailableView(
                        "还没有 RSS 源",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text("可从 Android backup.zip 导入 RSS 源。")
                    )
                } else {
                    ForEach(store.sources) { source in
                        Button {
                            selectedSourceID = source.id
                            Task { await articles.load(source: source) }
                        } label: {
                            HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.sourceName.isEmpty
                                    ? source.sourceURL
                                    : source.sourceName)
                                    .font(.headline)
                                Text(source.sourceURL)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if let group = source.sourceGroup, !group.isEmpty {
                                    Text(group)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Image(systemName: source.enabled
                                ? "checkmark.circle.fill"
                                : "pause.circle")
                                .foregroundStyle(source.enabled ? .green : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let selectedSourceID,
               let source = store.sources.first(where: { $0.id == selectedSourceID }) {
                Section(source.sourceName.isEmpty ? "文章" : source.sourceName) {
                    if articles.articles.isEmpty && !articles.isLoading {
                        if let error = articles.errorMessage {
                            Text(error).foregroundStyle(.red)
                        } else {
                            Text("暂无文章").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(articles.articles) { article in
                        Button {
                            selectedArticle = article
                        } label: {
                            articleRow(article)
                        }
                        .buttonStyle(.plain)
                    }
                    if articles.isLoading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if articles.hasMore {
                        Button("加载更多") {
                            Task { await articles.loadMore() }
                        }
                    }
                }
            }

            Section("收藏（\(store.stars.count)）") {
                if store.stars.isEmpty {
                    Text("暂无 RSS 收藏").foregroundStyle(.secondary)
                } else {
                    ForEach(store.stars) { star in
                        if let url = URL(string: star.link) {
                            Link(destination: url) { starRow(star) }
                        } else {
                            starRow(star)
                        }
                    }
                }
            }

            if let error = store.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("RSS")
        .task { await store.reload() }
        .sheet(item: $selectedArticle) { article in
            if let source = store.sources.first(where: {
                $0.sourceURL == article.origin
            }) {
                NavigationStack {
                    RSSReadView(
                        source: source,
                        article: article,
                        store: store
                    )
                }
            }
        }
        .accessibilityIdentifier("screen.rss")
    }

    private func starRow(_ star: RSSStar) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(star.title.isEmpty ? star.link : star.title)
                .font(.headline)
            if let description = star.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func articleRow(_ article: RSSArticleItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(article.title).font(.headline)
            if let pubDate = article.pubDate, !pubDate.isEmpty {
                Text(pubDate).font(.caption2).foregroundStyle(.tertiary)
            }
            if let description = article.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }
}

private struct RSSReadView: View {
    let source: RSSSource
    let article: RSSArticleItem
    @Bindable var store: RSSStore
    @State private var session = SearchEnvironment.makeRSSReadSession()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(article.title).font(.title2.bold())
                if session.isLoading {
                    ProgressView()
                } else if let content = session.content, !content.isEmpty {
                    Text(content)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } else if let error = session.errorMessage {
                    Text(error).foregroundStyle(.red)
                } else if let url = URL(string: article.link) {
                    Link("在网页中打开", destination: url)
                }
            }
            .padding()
        }
        .navigationTitle(source.sourceName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await store.toggleStar(article) }
                } label: {
                    Image(systemName: store.isStarred(article) ? "star.fill" : "star")
                }
                .accessibilityLabel(store.isStarred(article) ? "取消收藏" : "收藏")
            }
        }
        .task(id: article.id) {
            await session.load(source: source, article: article)
        }
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
    @Bindable var readAloudPreferences: ReadAloudPreferencesStore
    @Bindable var readingHistoryPreferences: ReadingHistoryPreferencesStore
    @Bindable var searchScopePreferences: SearchScopePreferencesStore
    @Bindable var sourceSwitchPreferences: SourceSwitchPreferencesStore
    @Bindable var httpTextToSpeechEngines: HTTPTextToSpeechEngineStore
    @Bindable var dictionaryLookup: DictionaryLookupStore
    @Bindable var keyboardAssists: KeyboardAssistStore
    @Bindable var appThemeProfiles: AppThemeProfileStore
    @Bindable var readerPreferences: ReaderPreferencesStore
    @Bindable var bookDetailPreferences: BookDetailPreferencesStore
    @Bindable var rootVisibility: RootVisibilityPreferencesStore
    @Bindable var replacementRules: ReaderReplacementRuleStore
    @Bindable var ruleSubscriptions: RuleSubscriptionStore
    @Bindable var rssStore: RSSStore
    @Bindable var webDAVSettings: WebDAVConnectionSettingsStore
    @Bindable var webDAVBackupCheckpoint: WebDAVBackupCheckpointStore
    let webDAVCredentials: KeychainWebDAVCredentialStore
    let androidBackupPasswordStore: any AndroidBackupPasswordStoring
    let webDAVClient: any WebDAVConnectionInitializing
    let webDAVProgressLoader: any WebDAVBookProgressLoading
    let webDAVProgressUploader: WebDAVReaderProgressUploadCoordinator
    let backupRestore: AndroidCoreBackupRestoreUseCase
    let libraryBackup: AndroidLibraryBackupUseCase
    let webDAVBackupSync: WebDAVBackupSyncUseCase
    let webDAVServerProfiles: any WebDAVServerProfileRepository
    let webDAVRemoteBooks: any WebDAVRemoteBookTransferring
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
                readAloudPreferences: readAloudPreferences,
                readingHistoryPreferences: readingHistoryPreferences,
                searchScopePreferences: searchScopePreferences,
                sourceSwitchPreferences: sourceSwitchPreferences,
                httpTextToSpeechEngines: httpTextToSpeechEngines,
                dictionaryLookup: dictionaryLookup,
                keyboardAssists: keyboardAssists,
                appThemeProfiles: appThemeProfiles,
                readerPreferences: readerPreferences,
                bookDetailPreferences: bookDetailPreferences,
                rootVisibility: rootVisibility,
                replacementRules: replacementRules,
                ruleSubscriptions: ruleSubscriptions,
                rssStore: rssStore,
                webDAVSettings: webDAVSettings,
                webDAVBackupCheckpoint: webDAVBackupCheckpoint,
                webDAVCredentials: webDAVCredentials,
                androidBackupPasswordStore: androidBackupPasswordStore,
                webDAVClient: webDAVClient,
                webDAVProgressLoader: webDAVProgressLoader,
                webDAVProgressUploader: webDAVProgressUploader,
                backupRestore: backupRestore,
                libraryBackup: libraryBackup,
                webDAVBackupSync: webDAVBackupSync,
                webDAVServerProfiles: webDAVServerProfiles,
                webDAVRemoteBooks: webDAVRemoteBooks
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

private struct AndroidBackupZipDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
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
