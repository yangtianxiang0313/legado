import AppUseCases
import Foundation

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
        var sources = try await loadSources()
        if let index = sources.firstIndex(where: {
            $0.sourceURL == source.sourceURL
        }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
        defaults.set(
            try JSONEncoder().encode(sources),
            forKey: storageKey
        )
    }

    func resetSources() async throws {
        defaults.removeObject(forKey: storageKey)
    }
}
