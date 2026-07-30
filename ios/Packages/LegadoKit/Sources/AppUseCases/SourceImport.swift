import Foundation
import SourceFormat

public enum SourceImportError: String, Error, Equatable, Sendable {
  case invalidFormat = "invalid_format"
  case notSource = "not_source"
}

public enum SourceImportGroupMode: String, Codable, Sendable {
  case unchanged
  case replace
  case append
}

public struct SourceImportOptions: Equatable, Sendable {
  public var keepName: Bool
  public var keepGroup: Bool
  public var keepEnable: Bool
  public var group: String?
  public var groupMode: SourceImportGroupMode

  public init(
    keepName: Bool = false,
    keepGroup: Bool = false,
    keepEnable: Bool = false,
    group: String? = nil,
    groupMode: SourceImportGroupMode = .unchanged
  ) {
    self.keepName = keepName
    self.keepGroup = keepGroup
    self.keepEnable = keepEnable
    self.group = group
    self.groupMode = groupMode
  }
}

public struct SourceImportCandidate: Identifiable, Equatable, Sendable {
  public let id: String
  public let incoming: BookSourceDraft
  public let existing: BookSourceDraft?
  public var selected: Bool
  public let isNew: Bool
  public let isUpdate: Bool
}

public enum SourceDefinitionImport {
  public static func decode(_ data: Data) throws -> [BookSourceDraft] {
    let definitions: [BookSourceDTO]
    do {
      definitions = try BookSourceCodec.decodeMany(data)
    } catch {
      throw SourceImportError.invalidFormat
    }
    guard let first = definitions.first else {
      return []
    }
    let firstEdit = try BookSourceEditorCodec.project(first)
    guard !firstEdit.sourceURL.isEmpty else {
      throw SourceImportError.notSource
    }
    return try definitions.map { definition in
      let edit = try BookSourceEditorCodec.project(
        definition
      )
      BookSourceDraft(
        sourceURL: edit.sourceURL,
        name: edit.name,
        loginURL: edit.loginURL,
        group: edit.group,
        comment: edit.comment,
        searchURL: edit.searchURL,
        exploreURL: edit.exploreURL,
        searchRule: edit.searchRule,
        exploreRule: edit.exploreRule,
        bookInfoRule: edit.bookInfoRule,
        tocRule: edit.tocRule,
        contentRule: edit.contentRule,
        importMetadata: BookSourceImportMetadata(
          enabled: edit.enabled,
          enabledExplore: edit.enabledExplore,
          lastUpdateTime: edit.lastUpdateTime,
          customOrder: edit.customOrder
        ),
        rawDefinition: try BookSourceCodec.encode(definition)
      )
    }
  }
}

public enum SourceImportPolicy {
  public static func preview(
    incoming: [BookSourceDraft],
    existing: [BookSourceDraft]
  ) -> [SourceImportCandidate] {
    let current = Dictionary(
      existing.map { ($0.sourceURL, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    return incoming.enumerated().map { index, source in
      let old = current[source.sourceURL]
      let incomingUpdate = source.importMetadata?.lastUpdateTime ?? 0
      let existingUpdate = old?.importMetadata?.lastUpdateTime ?? 0
      let isNew = old == nil
      let isUpdate = old != nil && existingUpdate < incomingUpdate
      return SourceImportCandidate(
        id: "\(index):\(source.sourceURL)",
        incoming: source,
        existing: old,
        selected: isNew || isUpdate,
        isNew: isNew,
        isUpdate: isUpdate
      )
    }
  }

  public static func merge(
    _ candidate: SourceImportCandidate,
    options: SourceImportOptions
  ) -> BookSourceDraft? {
    guard candidate.selected else { return nil }
    var source = candidate.incoming
    if let existing = candidate.existing {
      if options.keepName {
        source.name = existing.name
      }
      if options.keepGroup {
        source.group = existing.group
      }
      var metadata = source.importMetadata ?? .init()
      let oldMetadata = existing.importMetadata ?? .init()
      if options.keepEnable {
        metadata.enabled = oldMetadata.enabled
        metadata.enabledExplore = oldMetadata.enabledExplore
      }
      metadata.customOrder = oldMetadata.customOrder
      source.importMetadata = metadata
    }
    applyGroup(options, to: &source)
    return source.sourceURL.isEmpty ? nil : source
  }

  public static func mergedSelection(
    _ candidates: [SourceImportCandidate],
    options: SourceImportOptions
  ) -> [BookSourceDraft] {
    candidates.compactMap { merge($0, options: options) }
  }

  private static func applyGroup(
    _ options: SourceImportOptions,
    to source: inout BookSourceDraft
  ) {
    let group = options.group?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let group, !group.isEmpty else { return }
    switch options.groupMode {
    case .unchanged:
      return
    case .replace:
      source.group = group
    case .append:
      var groups = source.group
        .split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
      if !groups.contains(group) {
        groups.append(group)
      }
      source.group = groups.joined(separator: ",")
    }
  }
}
