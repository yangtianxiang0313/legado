import LegadoCore
import Observation

public struct AppThemeProfile: Codable, Equatable, Identifiable, Sendable {
  public var id: String { name }
  public var name: String
  public var isNightTheme: Bool
  public var primaryColor: String
  public var accentColor: String
  public var backgroundColor: String
  public var bottomBackgroundColor: String
  public var unknownFields: [String: JSONValue]

  public init(
    name: String,
    isNightTheme: Bool,
    primaryColor: String,
    accentColor: String,
    backgroundColor: String,
    bottomBackgroundColor: String,
    unknownFields: [String: JSONValue] = [:]
  ) {
    self.name = name
    self.isNightTheme = isNightTheme
    self.primaryColor = primaryColor
    self.accentColor = accentColor
    self.backgroundColor = backgroundColor
    self.bottomBackgroundColor = bottomBackgroundColor
    self.unknownFields = unknownFields
  }
}

public protocol AppThemeProfileRepository: Sendable {
  func appThemeProfiles() async throws -> [AppThemeProfile]
  func restoreAndroidThemeProfiles(_ values: [AppThemeProfile]) async throws
}

public extension AppThemeProfileRepository {
  func appThemeProfiles() async throws -> [AppThemeProfile] { [] }
  func restoreAndroidThemeProfiles(_ values: [AppThemeProfile]) async throws {}
}

@MainActor
public protocol AppThemeSelectionPersistence: AnyObject {
  func selectedThemeName() -> String?
  func saveSelectedThemeName(_ value: String?)
}

@MainActor
@Observable
public final class AppThemeProfileStore {
  public private(set) var profiles: [AppThemeProfile] = []
  public private(set) var selectedName: String?
  public private(set) var errorMessage: String?

  public var selectedProfile: AppThemeProfile? {
    profiles.first { $0.name == selectedName }
  }

  private let repository: any AppThemeProfileRepository
  private let selection: any AppThemeSelectionPersistence

  public init(
    repository: any AppThemeProfileRepository,
    selection: any AppThemeSelectionPersistence
  ) {
    self.repository = repository
    self.selection = selection
    selectedName = selection.selectedThemeName()
  }

  public func reload() async {
    do {
      profiles = try await repository.appThemeProfiles()
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      if let selectedName,
         !profiles.contains(where: { $0.name == selectedName })
      {
        self.selectedName = nil
        selection.saveSelectedThemeName(nil)
      }
      errorMessage = nil
    } catch {
      errorMessage = "无法读取主题模板"
    }
  }

  public func select(_ name: String?) {
    guard name == nil || profiles.contains(where: { $0.name == name }) else {
      return
    }
    selectedName = name
    selection.saveSelectedThemeName(name)
  }
}
