import AVFoundation
import AndroidBackupInterop
import AppNavigation
import AppUseCases
import BackupInteropUseCases
import DatabaseGRDB
import Foundation
import IntegrationKit
import LibraryDomain
import ReaderCore
import SwiftUI
import UIKit
import WebDAVFoundation

private extension DefaultHomePage {
    var rootRoute: RootRoute {
        switch self {
        case .bookshelf: .shelf
        case .explore: .explore
        case .rss: .rss
        case .settings: .settings
        }
    }
}

@main
struct LegadoApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var router = AppRouter()
    @State private var library: ShelfLibrary
    @State private var sourceCatalog: SourceCatalog
    @State private var readAloud: ReadAloudSession
    @State private var readAloudPreferences: ReadAloudPreferencesStore
    @State private var readingHistoryPreferences:
        ReadingHistoryPreferencesStore
    @State private var searchScopePreferences: SearchScopePreferencesStore
    @State private var sourceSwitchPreferences: SourceSwitchPreferencesStore
    @State private var httpTextToSpeechEngines: HTTPTextToSpeechEngineStore
    @State private var dictionaryLookup: DictionaryLookupStore
    @State private var keyboardAssists: KeyboardAssistStore
    @State private var appThemeProfiles: AppThemeProfileStore
    @State private var readerPreferences: ReaderPreferencesStore
    @State private var bookDetailPreferences: BookDetailPreferencesStore
    @State private var rootVisibility: RootVisibilityPreferencesStore
    @State private var replacementRules: ReaderReplacementRuleStore
    @State private var ruleSubscriptions: RuleSubscriptionStore
    @State private var rssStore: RSSStore
    @State private var onlineImportRequest: AndroidOnlineImportRequest?
    @State private var onlineImportError: String?
    @State private var processedShareTokens: Set<String> = []
    @State private var localTextTOCRules: LocalTextTOCRuleStore
    @State private var readerConfigProfiles: AndroidReaderConfigProfileStore
    @State private var directLinkUploadRule: DirectLinkUploadRuleStore
    @State private var webDAVSettings: WebDAVConnectionSettingsStore
    @State private var webDAVBackupCheckpoint:
        WebDAVBackupCheckpointStore
    private let webDAVCredentials: KeychainWebDAVCredentialStore
    private let androidBackupPasswordStore: KeychainAndroidBackupPasswordStore
    private let webDAVClient: any WebDAVConnectionInitializing
    private let webDAVProgressLoader: any WebDAVBookProgressLoading
    private let webDAVProgressUploader: WebDAVReaderProgressUploadCoordinator
    private let backupRestore: AndroidCoreBackupRestoreUseCase
    private let libraryBackup: AndroidLibraryBackupUseCase
    private let webDAVBackupSync: WebDAVBackupSyncUseCase
    private let webDAVServerProfiles: any WebDAVServerProfileRepository
    private let webDAVRemoteBooks: any WebDAVRemoteBookTransferring

    init() {
        let processArguments = ProcessInfo.processInfo.arguments
        let rootVisibilityRepository =
            UserDefaultsRootVisibilityPreferencesRepository()
        let webDAVCredentials = KeychainWebDAVCredentialStore()
        self.webDAVCredentials = webDAVCredentials
        self.androidBackupPasswordStore = KeychainAndroidBackupPasswordStore()
        self.webDAVRemoteBooks = processArguments.contains(
            "--webdav-remote-book-test-double"
        )
            ? UITestWebDAVRemoteBookTransfer()
            : WebDAVFoundationRemoteBookClient(
                credentials: webDAVCredentials
            )
        self.webDAVClient = ProcessInfo.processInfo.arguments.contains(
            "--webdav-test-double"
        )
            ? WebDAVFoundationConnectionClient(
                credentials: webDAVCredentials,
                transport: UITestWebDAVTransport()
            )
            : WebDAVFoundationConnectionClient(credentials: webDAVCredentials)
        if processArguments.contains("--webdav-progress-cloud-ahead") {
            self.webDAVProgressLoader = UITestWebDAVProgressLoader(
                chapterIndex: 2,
                chapterPosition: 15,
                chapterTitle: "第三章 归途"
            )
        } else if processArguments.contains(
            "--webdav-progress-cloud-behind"
        ) {
            self.webDAVProgressLoader = UITestWebDAVProgressLoader(
                chapterIndex: 0,
                chapterPosition: 70,
                chapterTitle: "第一章 启航"
            )
        } else {
            self.webDAVProgressLoader = WebDAVFoundationProgressClient(
                credentials: webDAVCredentials
            )
        }
        self.webDAVProgressUploader = WebDAVReaderProgressUploadCoordinator(
            saver: processArguments.contains("--webdav-test-double")
                ? UITestWebDAVProgressSaver()
                : WebDAVFoundationProgressClient(
                    credentials: webDAVCredentials
                )
        )
        let webDAVSettingsRepository =
            UserDefaultsWebDAVConnectionSettingsRepository()
        if processArguments.contains("--reset-webdav-settings") {
            webDAVSettingsRepository.save(WebDAVConnectionSettings())
        }
        if processArguments.contains("--webdav-test-double") {
            webDAVSettingsRepository.save(
                WebDAVConnectionSettings(
                    serverAddress: "https://dav.example.test/dav",
                    directoryName: "legado"
                )
            )
        }
        let webDAVSettingsStore = WebDAVConnectionSettingsStore(
            repository: webDAVSettingsRepository
        )
        _webDAVSettings = State(initialValue: webDAVSettingsStore)
        let backupCheckpoint =
            WebDAVBackupCheckpointStore(
                repository:
                    UserDefaultsWebDAVBackupCheckpointRepository()
            )
        if processArguments.contains("--reset-webdav-backup-discovery")
            || processArguments.contains("--reset-webdav-backup-checkpoint")
        {
            backupCheckpoint.reset()
        }
        _webDAVBackupCheckpoint = State(
            initialValue: backupCheckpoint
        )
        if processArguments.contains("--reset-root-visibility") {
            rootVisibilityRepository.save(RootVisibilityPreferences())
        }
        if processArguments.contains("--hide-optional-roots") {
            rootVisibilityRepository.save(
                RootVisibilityPreferences(
                    showsExplore: false,
                    showsRSS: false
                )
            )
        }
        let rootVisibilityStore = RootVisibilityPreferencesStore(
            repository: rootVisibilityRepository
        )
        let readAloudPreferencesRepository =
            UserDefaultsReadAloudPreferencesRepository()
        if processArguments.contains("--reset-read-aloud-preferences") {
            readAloudPreferencesRepository.save(ReadAloudPreferences())
        }
        let readAloudPreferencesStore = ReadAloudPreferencesStore(
            repository: readAloudPreferencesRepository
        )
        let readingHistoryPreferencesRepository =
            UserDefaultsReadingHistoryPreferencesRepository()
        if processArguments.contains("--reset-reading-history-preferences") {
            readingHistoryPreferencesRepository.save(
                ReadingHistoryPreferences()
            )
        }
        let readingHistoryPreferencesStore =
            ReadingHistoryPreferencesStore(
                repository: readingHistoryPreferencesRepository
            )
        let searchScopePreferencesRepository =
            UserDefaultsSearchScopePreferencesRepository()
        if processArguments.contains("--reset-search-scope-preferences") {
            searchScopePreferencesRepository.save(SearchScopePreferences())
        }
        let searchScopePreferencesStore = SearchScopePreferencesStore(
            repository: searchScopePreferencesRepository
        )
        let sourceSwitchPreferencesRepository =
            UserDefaultsSourceSwitchPreferencesRepository()
        if processArguments.contains("--reset-source-switch-preferences") {
            sourceSwitchPreferencesRepository.save(SourceSwitchPreferences())
        }
        let sourceSwitchPreferencesStore = SourceSwitchPreferencesStore(
            repository: sourceSwitchPreferencesRepository
        )
        let readerPreferencesRepository =
            UserDefaultsReaderPreferencesRepository()
        if processArguments.contains("--reset-reader-preferences") {
            readerPreferencesRepository.save(ReaderPreferences())
        }
        let readerPreferencesStore = ReaderPreferencesStore(
            repository: readerPreferencesRepository
        )
        _rootVisibility = State(initialValue: rootVisibilityStore)
        _readAloudPreferences = State(
            initialValue: readAloudPreferencesStore
        )
        _readingHistoryPreferences = State(
            initialValue: readingHistoryPreferencesStore
        )
        _searchScopePreferences = State(
            initialValue: searchScopePreferencesStore
        )
        _sourceSwitchPreferences = State(
            initialValue: sourceSwitchPreferencesStore
        )
        _readerPreferences = State(
            initialValue: readerPreferencesStore
        )
        _router = State(
            initialValue: AppRouter(
                selectedRoot: processArguments.contains("--initial-root-explore")
                    && rootVisibilityStore.value.showsExplore
                    ? .explore
                    : rootVisibilityStore.value.effectiveDefaultHomePage
                        .rootRoute
            )
        )
        do {
            let libraryRepository = try GRDBBookShelfRepository
                .applicationSupport()
            let readRecordDeviceID = ReadRecordDeviceIdentity.current()
            self.webDAVServerProfiles = libraryRepository
            let sourceRepository = UserDefaultsSourceCatalogRepository()
            self.backupRestore = AndroidCoreBackupRestoreUseCase(
                repository: AppAndroidCoreBackupRestoreRepository(
                    repository: libraryRepository,
                    localReadRecordDeviceID: readRecordDeviceID,
                    sourceRepository: sourceRepository,
                    rootVisibility: rootVisibilityStore,
                    readAloudPreferences: readAloudPreferencesStore,
                    readingHistoryPreferences:
                        readingHistoryPreferencesStore,
                    searchScopePreferences: searchScopePreferencesStore,
                    sourceSwitchPreferences: sourceSwitchPreferencesStore,
                    readerPreferences: readerPreferencesStore,
                    webDAVSettings: webDAVSettingsStore,
                    webDAVCredentials: webDAVCredentials
                )
            )
            self.libraryBackup = AndroidLibraryBackupUseCase(
                repository: AppAndroidLibraryBackupRepository(
                    repository: libraryRepository
                )
            )
            self.webDAVBackupSync = WebDAVBackupSyncUseCase(
                transfer: processArguments.contains("--webdav-test-double")
                    ? UITestWebDAVBackupTransfer(
                        seededArchive: ProcessInfo.processInfo.environment[
                            "LEGADO_ANDROID_BACKUP_FIXTURE_BASE64"
                        ].flatMap { Data(base64Encoded: $0) },
                        seedsFallbackArchive: processArguments.contains(
                            "--webdav-latest-backup-test-double"
                        ),
                        seedsEncryptedFallbackArchive:
                            processArguments.contains(
                                "--webdav-encrypted-backup-test-double"
                            ),
                        seedsBookmarkFallbackArchive:
                            processArguments.contains(
                                "--webdav-bookmark-backup-test-double"
                            ),
                        seedsApplicationPreferencesFallbackArchive:
                            processArguments.contains(
                                "--webdav-app-preferences-backup-test-double"
                            )
                    )
                    : WebDAVFoundationBackupClient(
                        credentials: webDAVCredentials
                    ),
                exporter: libraryBackup,
                restorer: backupRestore
            )
            _library = State(
                initialValue: ShelfLibrary(
                    repository: libraryRepository,
                    readRecordDeviceID: readRecordDeviceID
                )
            )
            _replacementRules = State(
                initialValue: ReaderReplacementRuleStore(
                    repository: libraryRepository
                )
            )
            _ruleSubscriptions = State(
                initialValue: RuleSubscriptionStore(
                    repository: libraryRepository
                )
            )
            _rssStore = State(
                initialValue: RSSStore(repository: libraryRepository)
            )
            _localTextTOCRules = State(
                initialValue: LocalTextTOCRuleStore(
                    repository: libraryRepository
                )
            )
            _readerConfigProfiles = State(
                initialValue: AndroidReaderConfigProfileStore(
                    repository: libraryRepository
                )
            )
            _directLinkUploadRule = State(
                initialValue: DirectLinkUploadRuleStore(
                    repository: libraryRepository
                )
            )
            _sourceCatalog = State(
                initialValue: SourceCatalog(
                    repository: sourceRepository
                )
            )
            let engineStore = HTTPTextToSpeechEngineStore(
                repository: libraryRepository,
                persistence:
                    UserDefaultsHTTPTextToSpeechSelectionPersistence()
            )
            _httpTextToSpeechEngines = State(initialValue: engineStore)
            _dictionaryLookup = State(
                initialValue: DictionaryLookupStore(
                    repository: libraryRepository,
                    executor: SearchEnvironment.makeDictionaryLookupExecutor()
                )
            )
            _keyboardAssists = State(
                initialValue: KeyboardAssistStore(repository: libraryRepository)
            )
            _appThemeProfiles = State(
                initialValue: AppThemeProfileStore(
                    repository: libraryRepository,
                    selection: UserDefaultsAppThemeSelectionPersistence()
                )
            )
            let systemSynthesizer: any SystemSpeechSynthesizing =
                ProcessInfo.processInfo.arguments.contains(
                    "--system-read-aloud-test-double"
                )
                ? UITestSystemSpeechSynthesizer()
                : AVSystemSpeechSynthesizer()
            let synthesizer = SelectableSpeechSynthesizer(
                system: systemSynthesizer,
                engineStore: engineStore,
                audioLoader:
                    SearchEnvironment.makeHTTPTextToSpeechAudioLoader()
            )
            _readAloud = State(
                initialValue: ReadAloudSession(
                    synthesizer: synthesizer
                )
            )
            _bookDetailPreferences = State(
                initialValue: BookDetailPreferencesStore(
                    repository:
                        UserDefaultsBookDetailPreferencesRepository()
                )
            )
        } catch {
            fatalError("Unable to initialize library database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            if let bookDetailCase = BookDetailAcceptanceCase(
                processArguments: ProcessInfo.processInfo.arguments
            ) {
                BookDetailAcceptanceView(acceptanceCase: bookDetailCase)
            } else if let startupCase = StartupAcceptanceCase(
                processArguments: ProcessInfo.processInfo.arguments
            ) {
                StartupAcceptanceView(
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
                    localTextTOCRules: localTextTOCRules,
                    readerConfigProfiles: readerConfigProfiles,
                    directLinkUploadRule: directLinkUploadRule,
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
                    webDAVRemoteBooks: webDAVRemoteBooks,
                    startupCase: startupCase
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
                    localTextTOCRules: localTextTOCRules,
                    readerConfigProfiles: readerConfigProfiles,
                    directLinkUploadRule: directLinkUploadRule,
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
                .onOpenURL(perform: openOnlineImportLink)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        openPendingSharedPayload()
                    }
                }
                .sheet(item: $onlineImportRequest) { request in
                    AndroidOnlineImportView(
                        request: request,
                        library: library,
                        catalog: sourceCatalog,
                        rssStore: rssStore,
                        replacementRules: replacementRules,
                        httpTextToSpeechEngines: httpTextToSpeechEngines,
                        dictionaryLookup: dictionaryLookup,
                        localTextTOCRules: localTextTOCRules,
                        readerConfigProfiles: readerConfigProfiles,
                        directLinkUploadRule: directLinkUploadRule,
                        appThemeProfiles: appThemeProfiles,
                        dismiss: { onlineImportRequest = nil }
                    )
                }
                .alert(
                    "无法导入",
                    isPresented: Binding(
                        get: { onlineImportError != nil },
                        set: { if !$0 { onlineImportError = nil } }
                    )
                ) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(onlineImportError ?? "链接无效")
                }
            }
        }
    }

    private func openOnlineImportLink(_ url: URL) {
        if url.isFileURL {
            openAssociatedFile(url)
            return
        }
        if let token = AndroidShareInbox.token(from: url) {
            openSharedInbox(token: token)
            return
        }
        do {
            onlineImportRequest = try AndroidOnlineImportLinkParser.parse(url)
            onlineImportError = nil
        } catch AndroidOnlineImportLinkError.unsupportedTarget {
            onlineImportError = "此 Android 一键导入类型尚未支持"
        } catch AndroidOnlineImportLinkError.missingSourceURL {
            onlineImportError = "导入链接缺少 src 地址"
        } catch {
            onlineImportError = "不是有效的 Legado 一键导入链接"
        }
    }

    private func openAssociatedFile(_ url: URL) {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 32 * 1_024 * 1_024 else {
                onlineImportError = "导入文件超过 32 MB 限制"
                return
            }
            try openAssociatedData(
                Data(contentsOf: url, options: [.mappedIfSafe]),
                suggestedName: url.lastPathComponent,
                sourceURL: url.absoluteString
            )
        } catch AndroidAssociatedImportError.ambiguous {
            onlineImportError = "文件同时匹配多种 Android 数据类型"
        } catch {
            onlineImportError = "无法识别此 Android 导出文件"
        }
    }

    private func openSharedInbox(token: String) {
        guard !processedShareTokens.contains(token) else { return }
        do {
            let payload = try AndroidShareInbox.applicationGroup()
                .consume(token: token)
            processedShareTokens.insert(token)
            switch payload.kind {
            case .file:
                try openAssociatedData(
                    payload.data,
                    suggestedName: payload.suggestedName,
                    sourceURL: "shared://\(payload.suggestedName ?? "payload")"
                )
            case .text, .url:
                try openSharedText(payload.data)
            }
        } catch AndroidAssociatedImportError.ambiguous {
            onlineImportError = "分享内容同时匹配多种 Android 数据类型"
        } catch AndroidShareInboxError.missingPayload {
            onlineImportError = "分享内容已被处理或已经失效"
        } catch {
            onlineImportError = "无法识别此分享内容"
        }
    }

    private func openPendingSharedPayload() {
        guard onlineImportRequest == nil,
              let inbox = try? AndroidShareInbox.applicationGroup(),
              let token = try? inbox.pendingTokens().first
        else { return }
        openSharedInbox(token: token)
    }

    private func openSharedText(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { throw AndroidAssociatedImportError.unrecognized }
        if let url = URL(string: text),
           ["legado", "yuedu"].contains(url.scheme?.lowercased() ?? "") {
            onlineImportRequest = try AndroidOnlineImportLinkParser.parse(url)
            onlineImportError = nil
            return
        }
        try openAssociatedData(
            data,
            suggestedName: "shared.json",
            sourceURL: "shared://text"
        )
    }

    private func openAssociatedData(
        _ data: Data,
        suggestedName: String?,
        sourceURL: String
    ) throws {
        guard data.count <= AndroidShareInbox.maximumPayloadBytes else {
            throw AndroidShareInboxError.payloadTooLarge
        }
        let target: AndroidOnlineImportTarget
        if suggestedName?.lowercased().hasSuffix(".zip") == true {
            target = .readerConfig
        } else {
            target = try AndroidAssociatedImportClassifier.classifyJSON(data)
        }
        onlineImportRequest = AndroidOnlineImportRequest(
            target: target,
            sourceURL: sourceURL,
            inlineData: data
        )
        onlineImportError = nil
    }
}

private enum ReadRecordDeviceIdentity {
    private static let key = "reader.readRecord.deviceID"

    static func current(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let created = "ios-" + UUID().uuidString.lowercased()
        defaults.set(created, forKey: key)
        return created
    }
}

private struct AppAndroidCoreBackupRestoreRepository:
    AndroidCoreBackupRestoreRepository
{
    let repository: GRDBBookShelfRepository
    let localReadRecordDeviceID: String
    let sourceRepository: UserDefaultsSourceCatalogRepository
    let rootVisibility: RootVisibilityPreferencesStore
    let readAloudPreferences: ReadAloudPreferencesStore
    let readingHistoryPreferences: ReadingHistoryPreferencesStore
    let searchScopePreferences: SearchScopePreferencesStore
    let sourceSwitchPreferences: SourceSwitchPreferencesStore
    let readerPreferences: ReaderPreferencesStore
    let webDAVSettings: WebDAVConnectionSettingsStore
    let webDAVCredentials: KeychainWebDAVCredentialStore

    func restoreAndroidCoreBackup(
        _ payload: AndroidCoreBackupRestorePayload
    ) async throws -> AndroidLibraryRestoreSummary {
        try await AndroidCoreRestoreTransaction.execute(
            capture: {
                try await restoreCheckpoint()
            },
            applyExternal: {
                if !payload.webDAVServerProfiles.entries.isEmpty
                    || payload.webDAVServerProfiles.selectedID != nil
                {
                    try await restoreAndroidWebDAVServerProfiles(
                        payload.webDAVServerProfiles
                    )
                }
                if let configuration = payload.webDAVConfiguration {
                    try await restoreAndroidWebDAVConfiguration(configuration)
                }
                if let preferences = payload.navigationPreferences,
                   preferences.isPresent {
                    try await restoreAndroidNavigationPreferences(preferences)
                }
                if let preferences = payload.readAloudPreferences,
                   preferences.isPresent {
                    try await restoreAndroidReadAloudPreferences(preferences)
                }
                if let preferences = payload.readingHistoryPreferences {
                    try await restoreAndroidReadingHistoryPreferences(
                        preferences
                    )
                }
                if let preferences = payload.searchScopePreferences,
                   preferences.isPresent {
                    try await restoreAndroidSearchScopePreferences(preferences)
                }
                if let preferences = payload.sourceSwitchPreferences {
                    try await restoreAndroidSourceSwitchPreferences(preferences)
                }
                if let preferences = payload.readerPreferences,
                   preferences.isPresent {
                    try await restoreAndroidReaderPreferences(preferences)
                }
                if !payload.bookSources.isEmpty {
                    try await sourceRepository.saveSources(
                        payload.bookSources
                    )
                }
            },
            commitDatabase: {
                try await repository.restoreAndroidDatabaseDomains(
                    payload.database,
                    localReadRecordDeviceID: localReadRecordDeviceID
                )
            },
            rollbackExternal: { checkpoint in
                try await rollback(
                    checkpoint,
                    importedPayload: payload
                )
            }
        )
    }

    private func restoreCheckpoint() async throws
        -> AppAndroidCoreRestoreCheckpoint
    {
        let settings = await MainActor.run { webDAVSettings.value }
        let mainCredential = try? await webDAVCredentials.credentials(
            for: settings.credentialReference
        )
        let serverProfiles = try await repository.webDAVServerProfiles()
        let selectedServerID = try await repository
            .selectedWebDAVServerProfileID()
        var serverCredentials: [
            WebDAVCredentialReference: WebDAVBasicCredentials
        ] = [:]
        for profile in serverProfiles {
            if let credential = try? await webDAVCredentials.credentials(
                for: profile.credentialReference
            ) {
                serverCredentials[profile.credentialReference] = credential
            }
        }
        return AppAndroidCoreRestoreCheckpoint(
            sources: try await sourceRepository.loadSources(),
            rootVisibility: await MainActor.run {
                rootVisibility.value
            },
            readAloudPreferences: await MainActor.run {
                readAloudPreferences.value
            },
            readingHistoryPreferences: await MainActor.run {
                readingHistoryPreferences.value
            },
            searchScopePreferences: await MainActor.run {
                searchScopePreferences.value
            },
            sourceSwitchPreferences: await MainActor.run {
                sourceSwitchPreferences.value
            },
            readerPreferences: await MainActor.run {
                readerPreferences.value
            },
            webDAVSettings: settings,
            mainCredential: mainCredential,
            serverProfiles: serverProfiles,
            selectedServerID: selectedServerID,
            serverCredentials: serverCredentials
        )
    }

    private func rollback(
        _ checkpoint: AppAndroidCoreRestoreCheckpoint,
        importedPayload: AndroidCoreBackupRestorePayload
    ) async throws {
        var failed = false
        do {
            try await sourceRepository.replaceSources(checkpoint.sources)
        } catch {
            failed = true
        }
        await MainActor.run {
            rootVisibility.replace(checkpoint.rootVisibility)
            readAloudPreferences.replace(checkpoint.readAloudPreferences)
            readingHistoryPreferences.replace(
                checkpoint.readingHistoryPreferences
            )
            searchScopePreferences.replace(
                checkpoint.searchScopePreferences
            )
            sourceSwitchPreferences.replace(
                checkpoint.sourceSwitchPreferences
            )
            readerPreferences.replace(checkpoint.readerPreferences)
        }

        let importedServerReferences = Set(
            importedPayload.webDAVServerProfiles.webDAVProfiles.map {
                AndroidWebDAVServerProfileRestoreUseCase
                    .credentialReference(id: $0.id)
            }
        )
        for reference in importedServerReferences
        where checkpoint.serverCredentials[reference] == nil {
            await webDAVCredentials.remove(reference: reference)
        }
        for (reference, credential) in checkpoint.serverCredentials {
            do {
                try await webDAVCredentials.save(
                    credential,
                    for: reference
                )
            } catch {
                failed = true
            }
        }
        do {
            try await repository.replaceWebDAVServerProfiles(
                checkpoint.serverProfiles,
                selectedID: checkpoint.selectedServerID
            )
        } catch {
            failed = true
        }

        let oldMainReference = checkpoint.webDAVSettings.credentialReference
        if let newMainReference = importedPayload.webDAVConfiguration?
            .settings.credentialReference,
            newMainReference != oldMainReference
        {
            await webDAVCredentials.remove(reference: newMainReference)
        }
        if let credential = checkpoint.mainCredential {
            do {
                try await webDAVCredentials.save(
                    credential,
                    for: oldMainReference
                )
            } catch {
                failed = true
            }
        } else {
            await webDAVCredentials.remove(reference: oldMainReference)
        }
        await MainActor.run {
            webDAVSettings.replace(checkpoint.webDAVSettings)
        }
        if failed {
            throw AppAndroidCoreRestoreRollbackError.failed
        }
    }

    func restoreAndroidDatabaseDomains(
        _ payload: AndroidCoreDatabaseRestorePayload
    ) async throws -> AndroidLibraryRestoreSummary {
        try await repository.restoreAndroidDatabaseDomains(
            payload,
            localReadRecordDeviceID: localReadRecordDeviceID
        )
    }

    func restoreAndroidLibrary(
        _ plan: AndroidLibraryRestorePlan
    ) async throws -> AndroidLibraryRestoreSummary {
        try await repository.restoreAndroidLibrary(plan)
    }

    func restoreAndroidBookSources(
        _ sources: [BookSourceDraft]
    ) async throws {
        try await sourceRepository.saveSources(sources)
    }

    func restoreAndroidReplacementRules(
        _ rules: [ReaderReplacementRule]
    ) async throws {
        for rule in rules {
            try await repository.saveReplacementRule(rule)
        }
    }

    func restoreAndroidReadRecords(
        _ records: [LibraryDomain.ReadRecord]
    ) async throws {
        try await repository.restoreAndroidReadRecords(records)
    }

    func restoreAndroidSearchHistory(
        _ entries: [SearchHistoryEntry]
    ) async throws {
        try await repository.restoreAndroidSearchHistory(entries)
    }

    func restoreAndroidRuleSubscriptions(
        _ values: [RuleSubscription]
    ) async throws {
        try await repository.restoreAndroidRuleSubscriptions(values)
    }

    func restoreAndroidRSS(
        sources: [RSSSource],
        stars: [RSSStar]
    ) async throws {
        try await repository.restoreAndroidRSS(sources: sources, stars: stars)
    }

    func restoreAndroidHTTPTextToSpeechEngines(
        _ values: [HTTPTextToSpeechEngine]
    ) async throws {
        try await repository.restoreAndroidHTTPTextToSpeechEngines(values)
    }

    func restoreAndroidLocalTextTOCRules(
        _ values: [LocalTextTOCRule]
    ) async throws {
        try await repository.restoreAndroidLocalTextTOCRules(values)
    }

    func restoreAndroidReaderConfigBundle(
        _ bundle: AndroidReaderConfigBundle
    ) async throws {
        try await repository.restoreAndroidReaderConfigBundle(bundle)
    }

    func restoreAndroidDictionaryRules(
        _ values: [DictionaryRule]
    ) async throws {
        try await repository.restoreAndroidDictionaryRules(values)
    }

    func restoreAndroidKeyboardAssists(
        _ values: [KeyboardAssist]
    ) async throws {
        try await repository.restoreAndroidKeyboardAssists(values)
    }

    func restoreAndroidThemeProfiles(
        _ values: [AppThemeProfile]
    ) async throws {
        try await repository.restoreAndroidThemeProfiles(values)
    }

    func restoreAndroidDirectLinkUploadRule(
        _ value: DirectLinkUploadRule
    ) async throws {
        try await repository.restoreAndroidDirectLinkUploadRule(value)
    }

    func restoreAndroidWebDAVConfiguration(
        _ plan: AndroidWebDAVConfigurationImportPlan
    ) async throws {
        let reference = await MainActor.run {
            webDAVSettings.value.credentialReference
        }
        switch plan.credential {
        case .missing:
            break
        case .resolved(let username, let password):
            try await webDAVCredentials.save(
                WebDAVBasicCredentials(
                    username: username,
                    password: password
                ),
                for: reference
            )
        case .unresolvedAndroidBackupPayload:
            throw AndroidCoreBackupRestoreError.backupPasswordRequired
        }
        await MainActor.run {
            webDAVSettings.replace(plan.settings)
        }
    }

    func restoreAndroidNavigationPreferences(
        _ plan: AndroidNavigationPreferencesImportPlan
    ) async throws {
        await MainActor.run {
            var value = rootVisibility.value
            if let showsExplore = plan.showsExplore {
                value.showsExplore = showsExplore
            }
            if let showsRSS = plan.showsRSS {
                value.showsRSS = showsRSS
            }
            if let defaultHomePage = plan.defaultHomePage {
                value.defaultHomePage = defaultHomePage
            }
            rootVisibility.replace(value)
        }
    }

    func restoreAndroidReadAloudPreferences(
        _ plan: AndroidReadAloudPreferencesImportPlan
    ) async throws {
        await MainActor.run {
            var value = readAloudPreferences.value
            if let followsSystemRate = plan.followsSystemRate {
                value.followsSystemRate = followsSystemRate
            }
            if let speechRatePreference = plan.speechRatePreference {
                value.speechRatePreference = speechRatePreference
            }
            readAloudPreferences.replace(value)
        }
    }

    func restoreAndroidReadingHistoryPreferences(
        _ plan: AndroidReadingHistoryPreferencesImportPlan
    ) async throws {
        await MainActor.run {
            readingHistoryPreferences.setRecordsReadingTime(
                plan.recordsReadingTime
            )
        }
    }

    func restoreAndroidSearchScopePreferences(
        _ plan: AndroidSearchScopePreferencesImportPlan
    ) async throws {
        await MainActor.run {
            var value = searchScopePreferences.value
            if let serializedScope = plan.serializedScope {
                value.serializedScope = serializedScope
            }
            if let changeSourceGroup = plan.changeSourceGroup {
                value.changeSourceGroup = changeSourceGroup
            }
            if let enabled = plan.usesPrecisionSearch {
                value.usesPrecisionSearch = enabled
            }
            if let count = plan.sourceConcurrency {
                value.sourceConcurrency = count
            }
            searchScopePreferences.replace(value)
        }
    }

    func restoreAndroidSourceSwitchPreferences(
        _ plan: AndroidSourceSwitchPreferencesImportPlan
    ) async throws {
        await MainActor.run {
            var value = sourceSwitchPreferences.value
            if let enabled = plan.automaticallyRecoversMissingSource {
                value.automaticallyRecoversMissingSource = enabled
            }
            if let enabled = plan.requiresAuthorMatch {
                value.requiresAuthorMatch = enabled
            }
            if let enabled = plan.loadsBookInfo {
                value.loadsBookInfo = enabled
            }
            if let enabled = plan.loadsTableOfContents {
                value.loadsTableOfContents = enabled
            }
            if let enabled = plan.loadsChapterWordCount {
                value.loadsChapterWordCount = enabled
            }
            sourceSwitchPreferences.replace(value)
        }
    }

    func restoreAndroidReaderPreferences(
        _ plan: AndroidReaderPreferencesImportPlan
    ) async throws {
        await MainActor.run {
            if let count = plan.preDownloadCount {
                readerPreferences.setPreDownloadCount(count)
            }
            if let enabled = plan.tocUsesReplacementRules {
                readerPreferences.setTOCUsesReplacementRules(enabled)
            }
        }
    }

    func restoreAndroidWebDAVServerProfiles(
        _ plan: AndroidServerProfileImportPlan
    ) async throws {
        try await AndroidWebDAVServerProfileRestoreUseCase(
            repository: repository,
            vault: AppAndroidWebDAVServerCredentialVault(
                store: webDAVCredentials
            )
        ).restore(plan)
    }
}

private struct AppAndroidCoreRestoreCheckpoint: Sendable {
    let sources: [BookSourceDraft]
    let rootVisibility: RootVisibilityPreferences
    let readAloudPreferences: ReadAloudPreferences
    let readingHistoryPreferences: ReadingHistoryPreferences
    let searchScopePreferences: SearchScopePreferences
    let sourceSwitchPreferences: SourceSwitchPreferences
    let readerPreferences: ReaderPreferences
    let webDAVSettings: WebDAVConnectionSettings
    let mainCredential: WebDAVBasicCredentials?
    let serverProfiles: [WebDAVServerProfile]
    let selectedServerID: Int64?
    let serverCredentials: [
        WebDAVCredentialReference: WebDAVBasicCredentials
    ]
}

private enum AppAndroidCoreRestoreRollbackError: Error {
    case failed
}

private struct AppAndroidWebDAVServerCredentialVault:
    AndroidWebDAVServerCredentialVault
{
    let store: KeychainWebDAVCredentialStore

    func credential(
        for reference: WebDAVCredentialReference
    ) async -> AndroidWebDAVServerCredential? {
        guard let value = try? await store.credentials(for: reference) else {
            return nil
        }
        return AndroidWebDAVServerCredential(
            username: value.username,
            password: value.password
        )
    }

    func save(
        _ credential: AndroidWebDAVServerCredential,
        for reference: WebDAVCredentialReference
    ) async throws {
        try await store.save(
            WebDAVBasicCredentials(
                username: credential.username,
                password: credential.password
            ),
            for: reference
        )
    }

    func remove(reference: WebDAVCredentialReference) async {
        await store.remove(reference: reference)
    }
}

private struct AppAndroidLibraryBackupRepository:
    AndroidLibraryBackupRepository
{
    let repository: GRDBBookShelfRepository

    func androidLibraryBackupPlan() async throws
        -> AndroidLibraryRestorePlan
    {
        try await repository.androidLibraryBackupPlan()
    }

    func androidReadRecords() async throws -> [LibraryDomain.ReadRecord] {
        try await repository.androidReadRecords()
    }

    func androidSearchHistory() async throws -> [SearchHistoryEntry] {
        try await repository.androidSearchHistory()
    }

    func androidRuleSubscriptions() async throws -> [RuleSubscription] {
        try await repository.androidRuleSubscriptions()
    }

    func androidRSSSources() async throws -> [RSSSource] {
        try await repository.androidRSSSources()
    }

    func androidRSSStars() async throws -> [RSSStar] {
        try await repository.androidRSSStars()
    }

    func androidHTTPTextToSpeechEngines() async throws
        -> [HTTPTextToSpeechEngine]
    {
        try await repository.androidHTTPTextToSpeechEngines()
    }

    func localTextTOCRules() async throws -> [LocalTextTOCRule] {
        try await repository.localTextTOCRules()
    }

    func androidReaderConfigBundle() async throws
        -> AndroidReaderConfigBundle?
    {
        try await repository.androidReaderConfigBundle()
    }

    func dictionaryRules() async throws -> [DictionaryRule] {
        try await repository.dictionaryRules()
    }

    func keyboardAssists() async throws -> [KeyboardAssist] {
        try await repository.keyboardAssists()
    }

    func appThemeProfiles() async throws -> [AppThemeProfile] {
        try await repository.appThemeProfiles()
    }

    func directLinkUploadRule() async throws -> DirectLinkUploadRule? {
        try await repository.directLinkUploadRule()
    }
}

@MainActor
private final class UserDefaultsAppThemeSelectionPersistence:
    AppThemeSelectionPersistence
{
    private let defaults: UserDefaults
    private let key = "appearance.selectedAndroidThemeName.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func selectedThemeName() -> String? {
        defaults.string(forKey: key)
    }

    func saveSelectedThemeName(_ value: String?) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

@MainActor
private final class UserDefaultsWebDAVConnectionSettingsRepository:
    WebDAVConnectionSettingsRepository
{
    private let defaults: UserDefaults
    private let key = "webdav.connection.settings.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> WebDAVConnectionSettings {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(WebDAVConnectionSettings.self, from: data)
        else { return WebDAVConnectionSettings() }
        return value
    }

    func save(_ settings: WebDAVConnectionSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
private final class UserDefaultsWebDAVBackupCheckpointRepository:
    WebDAVBackupCheckpointRepository
{
    private let defaults: UserDefaults
    private let key = "webdav.backup.lastHandledMilliseconds.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func loadLastBackupMilliseconds() -> Int64 {
        (defaults.object(forKey: key) as? NSNumber)?.int64Value ?? 0
    }

    func saveLastBackupMilliseconds(_ value: Int64) {
        defaults.set(value, forKey: key)
    }
}

private struct UITestWebDAVTransport: WebDAVHTTPTransport {
    func perform(_ request: URLRequest) async throws -> WebDAVHTTPResponse {
        WebDAVHTTPResponse(statusCode: 207)
    }
}

private struct UITestWebDAVProgressLoader: WebDAVBookProgressLoading {
    let chapterIndex: Int
    let chapterPosition: Int
    let chapterTitle: String

    func load(
        configuration: WebDAVConnectionConfiguration,
        identity: WebDAVBookIdentity
    ) async -> WebDAVBookProgressLoadResult {
        .loaded(
            WebDAVBookProgressDocument(
                name: identity.name,
                author: identity.author,
                durChapterIndex: chapterIndex,
                durChapterPos: chapterPosition,
                durChapterTime: 200,
                durChapterTitle: chapterTitle
            )
        )
    }
}

private struct UITestWebDAVProgressSaver: WebDAVBookProgressSaving {
    func save(
        configuration: WebDAVConnectionConfiguration,
        document: WebDAVBookProgressDocument
    ) async -> WebDAVBookProgressSaveResult {
        .saved
    }
}

private struct UITestWebDAVRemoteBookTransfer:
    WebDAVRemoteBookTransferring
{
    func listRemoteBooks(
        configuration: WebDAVConnectionConfiguration,
        directoryURL: URL?
    ) async -> WebDAVRemoteBookListResult {
        guard let rootURL = configuration.rootURL else {
            return .failed(.invalidConfiguration)
        }
        if directoryURL == nil {
            return .loaded([
                WebDAVRemoteBookResource(
                    name: "古典",
                    url: rootURL.appendingPathComponent(
                        "古典",
                        isDirectory: true
                    ),
                    size: 0,
                    lastModifiedMilliseconds: 0,
                    isDirectory: true
                )
            ])
        }
        return .loaded([
            WebDAVRemoteBookResource(
                name: "远程论语.txt",
                url: directoryURL!.appendingPathComponent(
                    "远程论语.txt",
                    isDirectory: false
                ),
                size: 72,
                lastModifiedMilliseconds: 0,
                isDirectory: false
            )
        ])
    }

    func downloadRemoteBook(
        configuration: WebDAVConnectionConfiguration,
        resource: WebDAVRemoteBookResource
    ) async -> WebDAVRemoteBookDownloadResult {
        .downloaded(
            name: resource.name,
            data: Data(
                "第一章 学而\n学而时习之，不亦说乎。\n\n第二章 为政\n为政以德。"
                    .utf8
            )
        )
    }

    func uploadRemoteBook(
        configuration: WebDAVConnectionConfiguration,
        fileName: String,
        data: Data
    ) async -> WebDAVRemoteBookUploadResult {
        guard let rootURL = configuration.rootURL else {
            return .failed(.invalidConfiguration)
        }
        return .uploaded(
            name: fileName,
            remoteURL: rootURL.appendingPathComponent(fileName)
        )
    }
}

private actor UITestWebDAVBackupTransfer: WebDAVBackupTransferring {
    private var archives: [String: Data]

    init(
        seededArchive: Data?,
        seedsFallbackArchive: Bool = false,
        seedsEncryptedFallbackArchive: Bool = false,
        seedsBookmarkFallbackArchive: Bool = false,
        seedsApplicationPreferencesFallbackArchive: Bool = false
    ) {
        let archive = seededArchive ?? (
            seedsFallbackArchive || seedsEncryptedFallbackArchive
                || seedsBookmarkFallbackArchive
                || seedsApplicationPreferencesFallbackArchive
                ? Self.makeFallbackArchive(
                    encrypted: seedsEncryptedFallbackArchive,
                    includesBookmark: seedsBookmarkFallbackArchive,
                    includesApplicationPreferences:
                        seedsApplicationPreferencesFallbackArchive
                )
                : nil
        )
        archives = archive.map {
            ["backup-android-fixture.zip": $0]
        } ?? [:]
    }

    private static func makeFallbackArchive(
        encrypted: Bool,
        includesBookmark: Bool,
        includesApplicationPreferences: Bool
    ) -> Data? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archiveURL = directory.appendingPathComponent("backup.zip")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            let sharedPreferences: AndroidSharedPreferencesDocument
            if encrypted {
                sharedPreferences = AndroidSharedPreferencesDocument(
                    values: [
                        AndroidWebDAVBackupConfiguration.serverAddressKey:
                            .string("https://dav.encrypted.test/dav"),
                        AndroidWebDAVBackupConfiguration.usernameKey:
                            .string("android-user"),
                        AndroidWebDAVBackupConfiguration.passwordKey:
                            .string(
                                try AndroidBackupAES.encryptBase64(
                                    "android-secret",
                                    backupPassword: "android-pass"
                                )
                            ),
                        AndroidWebDAVBackupConfiguration.directoryNameKey:
                            .string("legado"),
                    ]
                )
            } else if includesApplicationPreferences {
                sharedPreferences = AndroidSharedPreferencesDocument(
                    values: [
                        AndroidApplicationBackupPreferences.showDiscoveryKey:
                            .boolean(false),
                        AndroidApplicationBackupPreferences.showRSSKey:
                            .boolean(false),
                        AndroidApplicationBackupPreferences.bookshelfSortKey:
                            .int(4),
                        AndroidApplicationBackupPreferences.defaultHomePageKey:
                            .string("my"),
                        AndroidApplicationBackupPreferences.enableReadRecordKey:
                            .boolean(false),
                        AndroidApplicationBackupPreferences.searchScopeKey:
                            .string("科幻"),
                        AndroidApplicationBackupPreferences.searchGroupKey:
                            .string("科幻"),
                        AndroidApplicationBackupPreferences.precisionSearchKey:
                            .boolean(true),
                        AndroidApplicationBackupPreferences.autoChangeSourceKey:
                            .boolean(true),
                        AndroidApplicationBackupPreferences
                            .changeSourceCheckAuthorKey:
                            .boolean(true),
                        AndroidApplicationBackupPreferences.ttsFollowSystemKey:
                            .boolean(false),
                        AndroidApplicationBackupPreferences.ttsSpeechRateKey:
                            .int(15),
                    ]
                )
            } else if includesBookmark {
                sharedPreferences = AndroidSharedPreferencesDocument(
                    values: [
                        AndroidWebDAVBackupConfiguration.syncBookProgressKey:
                            .boolean(false)
                    ]
                )
            } else {
                sharedPreferences = AndroidSharedPreferencesDocument()
            }
            try AndroidBackupArchive.write(
                AndroidBackupContents(
                    bookmarks: includesBookmark
                        ? [
                            AndroidBookmarkDTO(
                                time: 1_775_433_600_000,
                                bookName: "星河纪事",
                                bookAuthor: "林舟",
                                chapterIndex: 0,
                                chapterPosition: 0,
                                chapterName: "第一章 启航",
                                bookText: "星港的晨光",
                                content: "来自 Android 的书签"
                            )
                        ]
                        : [],
                    sharedPreferences: sharedPreferences
                ),
                to: archiveURL
            )
            return try Data(contentsOf: archiveURL)
        } catch {
            return nil
        }
    }

    func listBackups(
        configuration: WebDAVConnectionConfiguration
    ) async -> WebDAVBackupListResult {
        .loaded(
            archives.keys.sorted(by: >).map {
                WebDAVBackupFile(
                    name: $0,
                    size: Int64(archives[$0]?.count ?? 0),
                    lastModifiedMilliseconds: 1_775_433_600_000
                )
            }
        )
    }

    func uploadBackup(
        configuration: WebDAVConnectionConfiguration,
        fileName: String,
        data: Data
    ) async -> WebDAVBackupUploadResult {
        archives[fileName] = data
        return .uploaded
    }

    func downloadBackup(
        configuration: WebDAVConnectionConfiguration,
        fileName: String
    ) async -> WebDAVBackupDownloadResult {
        guard let data = archives[fileName] else {
            return .failed(.notFound)
        }
        return .downloaded(data)
    }
}

@MainActor
private final class UserDefaultsReaderPreferencesRepository:
    ReaderPreferencesRepository
{
    private let defaults: UserDefaults
    private let key = "reader.preferences.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ReaderPreferences {
        guard
            let data = defaults.data(forKey: key),
            let value = try? JSONDecoder().decode(
                ReaderPreferences.self,
                from: data
            )
        else {
            return ReaderPreferences()
        }
        return value
    }

    func save(_ preferences: ReaderPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}

@MainActor
private final class UserDefaultsReadAloudPreferencesRepository:
    ReadAloudPreferencesRepository
{
    private let defaults: UserDefaults
    private let key = "reader.readAloud.preferences.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ReadAloudPreferences {
        guard
            let data = defaults.data(forKey: key),
            let value = try? JSONDecoder().decode(
                ReadAloudPreferences.self,
                from: data
            )
        else {
            return ReadAloudPreferences()
        }
        return value
    }

    func save(_ preferences: ReadAloudPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}

@MainActor
private final class UserDefaultsReadingHistoryPreferencesRepository:
    ReadingHistoryPreferencesRepository
{
    private let defaults: UserDefaults
    private let key = "reader.history.preferences.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ReadingHistoryPreferences {
        guard
            let data = defaults.data(forKey: key),
            let value = try? JSONDecoder().decode(
                ReadingHistoryPreferences.self,
                from: data
            )
        else {
            return ReadingHistoryPreferences()
        }
        return value
    }

    func save(_ preferences: ReadingHistoryPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}

@MainActor
private final class UserDefaultsSearchScopePreferencesRepository:
    SearchScopePreferencesRepository
{
    private let defaults: UserDefaults
    private let key = "search.scope.preferences.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> SearchScopePreferences {
        guard
            let data = defaults.data(forKey: key),
            let value = try? JSONDecoder().decode(
                SearchScopePreferences.self,
                from: data
            )
        else {
            return SearchScopePreferences()
        }
        return value
    }

    func save(_ preferences: SearchScopePreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}

@MainActor
private final class UserDefaultsSourceSwitchPreferencesRepository:
    SourceSwitchPreferencesRepository
{
    private let defaults: UserDefaults
    private let key = "reader.sourceSwitch.preferences.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> SourceSwitchPreferences {
        guard
            let data = defaults.data(forKey: key),
            let value = try? JSONDecoder().decode(
                SourceSwitchPreferences.self,
                from: data
            )
        else {
            return SourceSwitchPreferences()
        }
        return value
    }

    func save(_ preferences: SourceSwitchPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}

@MainActor
private final class UserDefaultsBookDetailPreferencesRepository:
    BookDetailPreferencesRepository
{
    private let defaults: UserDefaults
    private let key = "bookDetail.preferences.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> BookDetailPreferences {
        guard
            let data = defaults.data(forKey: key),
            let value = try? JSONDecoder().decode(
                BookDetailPreferences.self,
                from: data
            )
        else {
            return BookDetailPreferences()
        }
        return value
    }

    func save(_ preferences: BookDetailPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}

@MainActor
private final class UserDefaultsHTTPTextToSpeechSelectionPersistence:
    HTTPTextToSpeechSelectionPersistence
{
    private let defaults: UserDefaults
    private let key = "reader.httpTTS.selectedEngineID"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func selectedHTTPTextToSpeechEngineID() -> Int64? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return Int64(defaults.integer(forKey: key))
    }

    func saveSelectedHTTPTextToSpeechEngineID(_ id: Int64?) {
        if let id {
            defaults.set(id, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

@MainActor
private final class SelectableSpeechSynthesizer:
    NSObject, SystemSpeechSynthesizing,
    @preconcurrency AVAudioPlayerDelegate
{
    private let system: any SystemSpeechSynthesizing
    private let engineStore: HTTPTextToSpeechEngineStore
    private let audioLoader: any HTTPTextToSpeechAudioLoading
    private var usesHTTP = false
    private var playbackTask: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var playbackContinuation: CheckedContinuation<Bool, Never>?
    private var onEvent:
        (@MainActor @Sendable (SystemSpeechEvent) -> Void)?

    init(
        system: any SystemSpeechSynthesizing,
        engineStore: HTTPTextToSpeechEngineStore,
        audioLoader: any HTTPTextToSpeechAudioLoading
    ) {
        self.system = system
        self.engineStore = engineStore
        self.audioLoader = audioLoader
    }

    func speak(
        _ segments: [ReadAloudSegment],
        relativeRate: Float,
        onEvent: @escaping @MainActor @Sendable (SystemSpeechEvent) -> Void
    ) {
        stop()
        guard let engine = engineStore.effectiveEngine else {
            usesHTTP = false
            system.speak(
                segments,
                relativeRate: relativeRate,
                onEvent: onEvent
            )
            return
        }
        usesHTTP = true
        self.onEvent = onEvent
        let speed = min(50, max(5, Int((relativeRate * 10).rounded())))
        playbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                for segment in segments {
                    try Task.checkCancellation()
                    self.onEvent?(.started(segmentID: segment.id))
                    let data = try await self.audioLoader.load(
                        engine: engine,
                        text: segment.text,
                        speed: speed
                    )
                    try Task.checkCancellation()
                    guard await self.play(data) else { return }
                    self.onEvent?(.finished(segmentID: segment.id))
                }
            } catch is CancellationError {
                return
            } catch {
                self.onEvent?(.failed(message: "在线朗读失败"))
            }
        }
    }

    func pause() {
        if usesHTTP {
            player?.pause()
        } else {
            system.pause()
        }
    }

    func resume() {
        if usesHTTP {
            _ = player?.play()
        } else {
            system.resume()
        }
    }

    func stop() {
        system.stop()
        playbackTask?.cancel()
        playbackTask = nil
        player?.stop()
        player = nil
        finishPlayback(false)
        onEvent = nil
        usesHTTP = false
    }

    private func play(_ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
                let player = try AVAudioPlayer(data: data)
                self.player = player
                playbackContinuation = continuation
                player.delegate = self
                if !player.play() { finishPlayback(false) }
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    private func finishPlayback(_ succeeded: Bool) {
        guard let continuation = playbackContinuation else { return }
        playbackContinuation = nil
        continuation.resume(returning: succeeded)
    }

    func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        self.player = nil
        finishPlayback(flag)
    }

    func audioPlayerDecodeErrorDidOccur(
        _ player: AVAudioPlayer,
        error: (any Error)?
    ) {
        self.player = nil
        finishPlayback(false)
    }
}

@MainActor
private final class UserDefaultsRootVisibilityPreferencesRepository:
    RootVisibilityPreferencesRepository
{
    private let defaults: UserDefaults
    private let key = "root.visibility.preferences.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> RootVisibilityPreferences {
        guard
            let data = defaults.data(forKey: key),
            let value = try? JSONDecoder().decode(
                RootVisibilityPreferences.self,
                from: data
            )
        else {
            return RootVisibilityPreferences()
        }
        return value
    }

    func save(_ preferences: RootVisibilityPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}

@MainActor
private final class UITestSystemSpeechSynthesizer:
    SystemSpeechSynthesizing
{
    func speak(
        _ segments: [ReadAloudSegment],
        relativeRate: Float,
        onEvent: @escaping @MainActor @Sendable (SystemSpeechEvent) -> Void
    ) {
        if let first = segments.first {
            onEvent(.started(segmentID: first.id))
        }
    }

    func pause() {}
    func resume() {}
    func stop() {}
}

@MainActor
final class NativeTextPaginator: ReaderImageAttachmentPaginating {
    func pages(
        content: String,
        viewport: ReaderViewport,
        typography: ReaderTypography
    ) -> [ReaderLayoutPage] {
        pages(
            content: content,
            viewport: viewport,
            typography: typography,
            imageAttachments: []
        )
    }

    func pages(
        content: String,
        viewport: ReaderViewport,
        typography: ReaderTypography,
        imageAttachments: [ReaderImageAttachmentLayout]
    ) -> [ReaderLayoutPage] {
        let source = content as NSString
        guard source.length > 0 else { return [] }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = typography.lineSpacing
        let font = UIFont.systemFont(
            ofSize: typography.fontSize,
            weight: readerFontWeight(typography.textWeight)
        )
        paragraph.paragraphSpacing = font.lineHeight
            * Double(typography.paragraphSpacing) / 10
        paragraph.firstLineHeadIndent = (
            typography.paragraphIndent as NSString
        ).size(withAttributes: [.font: font]).width
        let attributed = NSMutableAttributedString(
            string: content,
            attributes: [
                .font: font,
                .paragraphStyle: paragraph,
                .kern: typography.fontSize * typography.letterSpacing,
            ]
        )
        for attachmentLayout in imageAttachments.sorted(
            by: { $0.layoutCharacterOffset > $1.layoutCharacterOffset }
        ) {
            let offset = attachmentLayout.layoutCharacterOffset
            guard offset >= 0, offset < source.length else { continue }
            let attachment = NSTextAttachment()
            attachment.bounds = CGRect(
                x: attachmentLayout.size.horizontalInset,
                y: 0,
                width: attachmentLayout.size.width,
                height: attachmentLayout.size.height
            )
            attributed.replaceCharacters(
                in: NSRange(location: offset, length: 1),
                with: NSAttributedString(attachment: attachment)
            )
        }
        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var result: [ReaderLayoutPage] = []
        var consumed = 0

        while consumed < source.length {
            let container = NSTextContainer(
                size: CGSize(
                    width: viewport.width,
                    height: viewport.height
                )
            )
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            let glyphRange = layout.glyphRange(for: container)
            let characterRange = layout.characterRange(
                forGlyphRange: glyphRange,
                actualGlyphRange: nil
            )
            guard
                characterRange.length > 0,
                characterRange.location >= consumed
            else { break }
            result.append(
                ReaderLayoutPage(
                    startCharacterOffset: characterRange.location,
                    characterCount: characterRange.length
                )
            )
            consumed = NSMaxRange(characterRange)
        }

        if result.isEmpty {
            return [
                ReaderLayoutPage(
                    startCharacterOffset: 0,
                    characterCount: source.length
                )
            ]
        }
        return result
    }
}

private func readerFontWeight(_ rawValue: Int) -> UIFont.Weight {
    switch rawValue {
    case 1: .bold
    case 2: .light
    default: .regular
    }
}

@MainActor
private final class AVSystemSpeechSynthesizer:
    NSObject, SystemSpeechSynthesizing,
    @preconcurrency AVSpeechSynthesizerDelegate
{
    private let synthesizer = AVSpeechSynthesizer()
    private var segmentIDs: [ObjectIdentifier: String] = [:]
    private var onEvent:
        (@MainActor @Sendable (SystemSpeechEvent) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(
        _ segments: [ReadAloudSegment],
        relativeRate: Float,
        onEvent: @escaping @MainActor @Sendable (SystemSpeechEvent) -> Void
    ) {
        stop()
        self.onEvent = onEvent
        let rate = min(
            AVSpeechUtteranceMaximumSpeechRate,
            max(
                AVSpeechUtteranceMinimumSpeechRate,
                AVSpeechUtteranceDefaultSpeechRate * relativeRate
            )
        )
        for segment in segments {
            let utterance = AVSpeechUtterance(string: segment.text)
            utterance.rate = rate
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            segmentIDs[ObjectIdentifier(utterance)] = segment.id
            synthesizer.speak(utterance)
        }
    }

    func pause() {
        _ = synthesizer.pauseSpeaking(at: .word)
    }

    func resume() {
        _ = synthesizer.continueSpeaking()
    }

    func stop() {
        _ = synthesizer.stopSpeaking(at: .immediate)
        segmentIDs.removeAll()
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        guard let id = segmentIDs[ObjectIdentifier(utterance)] else { return }
        onEvent?(.started(segmentID: id))
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        guard
            let id = segmentIDs.removeValue(
                forKey: ObjectIdentifier(utterance)
            )
        else { return }
        onEvent?(.finished(segmentID: id))
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        guard
            segmentIDs.removeValue(
                forKey: ObjectIdentifier(utterance)
            ) != nil
        else { return }
        onEvent?(.cancelled)
    }
}
