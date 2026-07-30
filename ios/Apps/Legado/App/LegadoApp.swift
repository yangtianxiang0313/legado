import AVFoundation
import AppNavigation
import AppUseCases
import DatabaseGRDB
import Foundation
import ReaderCore
import SwiftUI

@main
struct LegadoApp: App {
    @State private var router = AppRouter()
    @State private var library: ShelfLibrary
    @State private var sourceCatalog: SourceCatalog
    @State private var readAloud: ReadAloudSession
    @State private var readerPreferences: ReaderPreferencesStore

    init() {
        do {
            _library = State(
                initialValue: ShelfLibrary(
                    repository: try GRDBBookShelfRepository
                        .applicationSupport()
                )
            )
            _sourceCatalog = State(
                initialValue: SourceCatalog(
                    repository: UserDefaultsSourceCatalogRepository()
                )
            )
            let synthesizer: any SystemSpeechSynthesizing =
                ProcessInfo.processInfo.arguments.contains(
                    "--system-read-aloud-test-double"
                )
                ? UITestSystemSpeechSynthesizer()
                : AVSystemSpeechSynthesizer()
            _readAloud = State(
                initialValue: ReadAloudSession(
                    synthesizer: synthesizer
                )
            )
            let preferencesRepository =
                UserDefaultsReaderPreferencesRepository()
            if ProcessInfo.processInfo.arguments.contains(
                "--reset-reader-preferences"
            ) {
                preferencesRepository.save(ReaderPreferences())
            }
            _readerPreferences = State(
                initialValue: ReaderPreferencesStore(
                    repository: preferencesRepository
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
                    readerPreferences: readerPreferences,
                    startupCase: startupCase
                )
            } else {
                RootShellView(
                    router: router,
                    library: library,
                    sourceCatalog: sourceCatalog,
                    readAloud: readAloud,
                    readerPreferences: readerPreferences
                )
            }
        }
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
