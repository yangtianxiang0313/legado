import AppUseCases
import Foundation
import SourceRuntime

actor UserDefaultsSourceCatalogRepository: SourceCatalogRepository {
    private let defaults: UserDefaults
    private let storageKey = "legado.bookSources.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadSources() async throws -> [BookSourceDraft] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return try JSONDecoder().decode([BookSourceDraft].self, from: data)
    }

    func saveSource(_ source: BookSourceDraft) async throws {
        try await saveSources([source])
    }

    func saveSources(_ imported: [BookSourceDraft]) async throws {
        var sources = try await loadSources()
        for source in imported {
            if let index = sources.firstIndex(where: {
                $0.sourceURL == source.sourceURL
            }) {
                sources[index] = source
            } else {
                sources.append(source)
            }
        }
        defaults.set(
            try JSONEncoder().encode(sources),
            forKey: storageKey
        )
    }

    func replaceSources(_ sources: [BookSourceDraft]) async throws {
        defaults.set(
            try JSONEncoder().encode(sources),
            forKey: storageKey
        )
    }

    func resetSources() async throws {
        defaults.removeObject(forKey: storageKey)
    }
}

actor UserDefaultsSourceCookiePersistence: SourceCookiePersisting {
    private let defaults: UserDefaults
    private let storageKey = "legado.sourceCookies.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadPersistentCookie(
        for domain: String
    ) async throws -> String? {
        defaults.dictionary(forKey: storageKey)?[domain] as? String
    }

    func savePersistentCookie(
        _ cookie: String?,
        for domain: String
    ) async throws {
        var values = defaults.dictionary(forKey: storageKey) ?? [:]
        values[domain] = cookie
        defaults.set(values, forKey: storageKey)
    }
}
