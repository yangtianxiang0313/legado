import AVFoundation
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

@main
struct LegadoApp: App {
    @State private var router = AppRouter()
    @State private var library: ShelfLibrary
    @State private var sourceCatalog: SourceCatalog
    @State private var readAloud: ReadAloudSession
    @State private var httpTextToSpeechEngines: HTTPTextToSpeechEngineStore
    @State private var dictionaryLookup: DictionaryLookupStore
    @State private var readerPreferences: ReaderPreferencesStore
    @State private var bookDetailPreferences: BookDetailPreferencesStore
    @State private var rootVisibility: RootVisibilityPreferencesStore
    @State private var replacementRules: ReaderReplacementRuleStore
    @State private var ruleSubscriptions: RuleSubscriptionStore
    @State private var rssStore: RSSStore
    @State private var webDAVSettings: WebDAVConnectionSettingsStore
    private let webDAVCredentials: KeychainWebDAVCredentialStore
    private let webDAVClient: any WebDAVConnectionInitializing
    private let backupRestore: AndroidCoreBackupRestoreUseCase
    private let libraryBackup: AndroidLibraryBackupUseCase

    init() {
        let processArguments = ProcessInfo.processInfo.arguments
        let rootVisibilityRepository =
            UserDefaultsRootVisibilityPreferencesRepository()
        let webDAVCredentials = KeychainWebDAVCredentialStore()
        self.webDAVCredentials = webDAVCredentials
        self.webDAVClient = ProcessInfo.processInfo.arguments.contains(
            "--webdav-test-double"
        )
            ? WebDAVFoundationConnectionClient(
                credentials: webDAVCredentials,
                transport: UITestWebDAVTransport()
            )
            : WebDAVFoundationConnectionClient(credentials: webDAVCredentials)
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
        _webDAVSettings = State(
            initialValue: WebDAVConnectionSettingsStore(
                repository: webDAVSettingsRepository
            )
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
        _rootVisibility = State(initialValue: rootVisibilityStore)
        _router = State(
            initialValue: AppRouter(
                selectedRoot: processArguments.contains("--initial-root-explore")
                    && rootVisibilityStore.value.showsExplore
                    ? .explore
                    : .shelf
            )
        )
        do {
            let libraryRepository = try GRDBBookShelfRepository
                .applicationSupport()
            let sourceRepository = UserDefaultsSourceCatalogRepository()
            self.backupRestore = AndroidCoreBackupRestoreUseCase(
                repository: AppAndroidCoreBackupRestoreRepository(
                    repository: libraryRepository,
                    sourceRepository: sourceRepository
                )
            )
            self.libraryBackup = AndroidLibraryBackupUseCase(
                repository: AppAndroidLibraryBackupRepository(
                    repository: libraryRepository
                )
            )
            _library = State(
                initialValue: ShelfLibrary(
                    repository: libraryRepository,
                    readRecordDeviceID: ReadRecordDeviceIdentity.current()
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
            let preferencesRepository =
                UserDefaultsReaderPreferencesRepository()
            if processArguments.contains(
                "--reset-reader-preferences"
            ) {
                preferencesRepository.save(ReaderPreferences())
            }
            _readerPreferences = State(
                initialValue: ReaderPreferencesStore(
                    repository: preferencesRepository
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
                    httpTextToSpeechEngines: httpTextToSpeechEngines,
                    dictionaryLookup: dictionaryLookup,
                    readerPreferences: readerPreferences,
                    bookDetailPreferences: bookDetailPreferences,
                    rootVisibility: rootVisibility,
                    replacementRules: replacementRules,
                    ruleSubscriptions: ruleSubscriptions,
                    rssStore: rssStore,
                    webDAVSettings: webDAVSettings,
                    webDAVCredentials: webDAVCredentials,
                    webDAVClient: webDAVClient,
                    backupRestore: backupRestore,
                    libraryBackup: libraryBackup,
                    startupCase: startupCase
                )
            } else {
                RootShellView(
                    router: router,
                    library: library,
                    sourceCatalog: sourceCatalog,
                    readAloud: readAloud,
                    httpTextToSpeechEngines: httpTextToSpeechEngines,
                    dictionaryLookup: dictionaryLookup,
                    readerPreferences: readerPreferences,
                    bookDetailPreferences: bookDetailPreferences,
                    rootVisibility: rootVisibility,
                    replacementRules: replacementRules,
                    ruleSubscriptions: ruleSubscriptions,
                    rssStore: rssStore,
                    webDAVSettings: webDAVSettings,
                    webDAVCredentials: webDAVCredentials,
                    webDAVClient: webDAVClient,
                    backupRestore: backupRestore,
                    libraryBackup: libraryBackup
                )
            }
        }
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
    let sourceRepository: UserDefaultsSourceCatalogRepository

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

private struct UITestWebDAVTransport: WebDAVHTTPTransport {
    func perform(_ request: URLRequest) async throws -> WebDAVHTTPResponse {
        WebDAVHTTPResponse(statusCode: 207)
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
        guard let engine = engineStore.selectedEngine else {
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
        let attributed = NSMutableAttributedString(
            string: content,
            attributes: [
                .font: UIFont.systemFont(
                    ofSize: typography.fontSize
                ),
                .paragraphStyle: paragraph,
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
