import Observation
import ReaderCore

@MainActor
public protocol ReaderPreferencesRepository: AnyObject {
  func load() -> ReaderPreferences
  func save(_ preferences: ReaderPreferences)
}

@MainActor
@Observable
public final class ReaderPreferencesStore {
  public private(set) var value: ReaderPreferences

  private let repository: any ReaderPreferencesRepository

  public init(repository: any ReaderPreferencesRepository) {
    self.repository = repository
    let loaded = repository.load().normalized()
    value = loaded
    repository.save(loaded)
  }

  public func setDarkTheme(_ enabled: Bool) {
    update { $0.darkTheme = enabled }
  }

  public func setBrightness(_ brightness: Double) {
    update { $0.brightness = brightness }
  }

  public func setFontSize(_ fontSize: Double) {
    update { $0.fontSize = fontSize }
  }

  public func setLineSpacing(_ lineSpacing: Double) {
    update { $0.lineSpacing = lineSpacing }
  }

  public func setAutoPageEnabled(_ enabled: Bool) {
    update { $0.autoPageEnabled = enabled }
  }

  public func setPreDownloadCount(_ count: Int) {
    update { $0.preDownloadCount = count }
  }

  public func reset() {
    value = ReaderPreferences()
    repository.save(value)
  }

  public func replace(_ preferences: ReaderPreferences) {
    let updated = preferences.normalized()
    value = updated
    repository.save(updated)
  }

  public func apply(_ projection: AndroidReaderConfigProjection) {
    let updated = projection.applying(to: value)
    guard updated != value else { return }
    value = updated
    repository.save(updated)
  }

  private func update(
    _ mutation: (inout ReaderPreferences) -> Void
  ) {
    var updated = value
    mutation(&updated)
    updated.normalize()
    guard updated != value else { return }
    value = updated
    repository.save(updated)
  }
}
