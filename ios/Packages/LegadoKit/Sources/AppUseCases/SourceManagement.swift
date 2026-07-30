import Foundation

public enum SourceManagementFilter: Equatable, Sendable {
  case all
  case enabled
  case disabled
  case exploreEnabled
  case exploreDisabled
  case ungrouped
  case group(String)
}

public enum SourceManagementSort: String, CaseIterable, Sendable {
  case defaultOrder
  case name
  case url
  case updated
  case enabled
}

public enum SourceBulkMutation: Equatable, Sendable {
  case setEnabled(Bool)
  case setExploreEnabled(Bool)
  case moveToTop
  case moveToBottom
  case addGroup(String)
  case removeGroup(String)
}

public enum SourceManagementPolicy {
  public static func visibleSources(
    _ sources: [BookSourceDraft],
    query: String,
    filter: SourceManagementFilter,
    sort: SourceManagementSort,
    ascending: Bool
  ) -> [BookSourceDraft] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let filtered = sources.filter { source in
      matches(source, filter: filter)
        && (
          query.isEmpty
            || source.name.localizedCaseInsensitiveContains(query)
            || source.sourceURL.localizedCaseInsensitiveContains(query)
            || source.group.localizedCaseInsensitiveContains(query)
        )
    }
    return stableSort(filtered, by: sort, ascending: ascending)
  }

  public static func selectAll(
    visibleIDs: [String]
  ) -> Set<String> {
    Set(visibleIDs)
  }

  public static func invertSelection(
    _ selection: Set<String>,
    visibleIDs: [String]
  ) -> Set<String> {
    Set(visibleIDs).subtracting(selection)
  }

  public static func fillSelectionInterval(
    _ selection: Set<String>,
    visibleIDs: [String]
  ) -> Set<String> {
    let positions = visibleIDs.indices.filter {
      selection.contains(visibleIDs[$0])
    }
    guard let first = positions.first, let last = positions.last else {
      return selection
    }
    var result = selection
    result.formUnion(visibleIDs[first...last])
    return result
  }

  public static func applying(
    _ mutation: SourceBulkMutation,
    to sources: [BookSourceDraft],
    selectedIDs: Set<String>
  ) -> [BookSourceDraft] {
    guard !selectedIDs.isEmpty else { return sources }
    let selected = sources.enumerated()
      .filter { selectedIDs.contains($0.element.sourceURL) }
      .sorted {
        let lhsOrder = $0.element.importMetadata?.customOrder ?? 0
        let rhsOrder = $1.element.importMetadata?.customOrder ?? 0
        return lhsOrder == rhsOrder
          ? $0.offset < $1.offset
          : lhsOrder < rhsOrder
      }
    let minOrder = sources
      .compactMap { $0.importMetadata?.customOrder }
      .min() ?? 0
    let maxOrder = sources
      .compactMap { $0.importMetadata?.customOrder }
      .max() ?? 0
    let orderUpdates = Dictionary(
      uniqueKeysWithValues: selected.enumerated().map { index, value in
        let order: Int32
        switch mutation {
        case .moveToTop:
          order = Int32(clamping: Int64(minOrder) - 1 - Int64(index))
        case .moveToBottom:
          order = Int32(clamping: Int64(maxOrder) + 1 + Int64(index))
        default:
          order = value.element.importMetadata?.customOrder ?? 0
        }
        return (value.element.sourceURL, order)
      }
    )
    return sources.map { source in
      guard selectedIDs.contains(source.sourceURL) else { return source }
      var changed = source
      var metadata = changed.importMetadata ?? .init()
      switch mutation {
      case .setEnabled(let enabled):
        metadata.enabled = enabled
      case .setExploreEnabled(let enabled):
        metadata.enabledExplore = enabled
      case .moveToTop, .moveToBottom:
        metadata.customOrder = orderUpdates[source.sourceURL]
          ?? metadata.customOrder
      case .addGroup(let group):
        changed.group = adding(group, to: changed.group)
      case .removeGroup(let group):
        changed.group = removing(group, from: changed.group)
      }
      changed.importMetadata = metadata
      return changed
    }
  }

  public static func exportData(
    _ sources: [BookSourceDraft],
    selectedIDs: Set<String>
  ) throws -> Data {
    let selected = sources.filter {
      selectedIDs.contains($0.sourceURL)
    }
    let objects = selected.map(exportObject)
    return try JSONSerialization.data(
      withJSONObject: objects,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
  }

  private static func matches(
    _ source: BookSourceDraft,
    filter: SourceManagementFilter
  ) -> Bool {
    let metadata = source.importMetadata ?? .init()
    switch filter {
    case .all:
      return true
    case .enabled:
      return metadata.enabled
    case .disabled:
      return !metadata.enabled
    case .exploreEnabled:
      return metadata.enabledExplore
    case .exploreDisabled:
      return !metadata.enabledExplore
    case .ungrouped:
      return groups(source.group).isEmpty
    case .group(let group):
      return groups(source.group).contains(group)
    }
  }

  private static func stableSort(
    _ sources: [BookSourceDraft],
    by sort: SourceManagementSort,
    ascending: Bool
  ) -> [BookSourceDraft] {
    sources.enumerated().sorted { lhs, rhs in
      let comparison: ComparisonResult
      switch sort {
      case .defaultOrder:
        let left = lhs.element.importMetadata?.customOrder ?? 0
        let right = rhs.element.importMetadata?.customOrder ?? 0
        comparison = left == right
          ? .orderedSame
          : left < right ? .orderedAscending : .orderedDescending
      case .name:
        comparison = lhs.element.name.localizedStandardCompare(
          rhs.element.name
        )
      case .url:
        comparison = lhs.element.sourceURL.compare(rhs.element.sourceURL)
      case .updated:
        let left = lhs.element.importMetadata?.lastUpdateTime ?? 0
        let right = rhs.element.importMetadata?.lastUpdateTime ?? 0
        comparison = left == right
          ? .orderedSame
          : left > right ? .orderedAscending : .orderedDescending
      case .enabled:
        let left = lhs.element.importMetadata?.enabled ?? true
        let right = rhs.element.importMetadata?.enabled ?? true
        comparison = left == right
          ? lhs.element.name.localizedStandardCompare(rhs.element.name)
          : left ? .orderedAscending : .orderedDescending
      }
      if comparison == .orderedSame {
        return lhs.offset < rhs.offset
      }
      return ascending
        ? comparison == .orderedAscending
        : comparison == .orderedDescending
    }.map(\.element)
  }

  private static func groups(_ value: String) -> [String] {
    value.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private static func adding(_ group: String, to value: String) -> String {
    let group = group.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !group.isEmpty else { return value }
    var values = groups(value)
    if !values.contains(group) {
      values.append(group)
    }
    return values.joined(separator: ",")
  }

  private static func removing(
    _ group: String,
    from value: String
  ) -> String {
    let group = group.trimmingCharacters(in: .whitespacesAndNewlines)
    return groups(value)
      .filter { $0 != group }
      .joined(separator: ",")
  }

  private static func exportObject(
    _ source: BookSourceDraft
  ) -> [String: Any] {
    var object: [String: Any] = [:]
    if
      let raw = source.rawDefinition,
      let decoded = try? JSONSerialization.jsonObject(with: raw),
      let fields = decoded as? [String: Any]
    {
      object = fields
    }
    object["bookSourceUrl"] = source.sourceURL
    object["bookSourceName"] = source.name
    object["bookSourceGroup"] = source.group
    object["bookSourceComment"] = source.comment
    object["loginUrl"] = source.loginURL
    object["searchUrl"] = source.searchURL
    object["exploreUrl"] = source.exploreURL
    let metadata = source.importMetadata ?? .init()
    object["enabled"] = metadata.enabled
    object["enabledExplore"] = metadata.enabledExplore
    object["lastUpdateTime"] = metadata.lastUpdateTime
    object["customOrder"] = metadata.customOrder
    return object
  }
}
