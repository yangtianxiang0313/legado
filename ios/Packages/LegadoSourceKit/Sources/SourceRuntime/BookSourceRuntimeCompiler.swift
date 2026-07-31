import Foundation
import LegadoCore
import SourceFormat

public enum BookSourceRuntimeCompilerError:
  Error,
  Equatable,
  Sendable
{
  case missingSourceURL
}

/// User-owned metadata may diverge from the last imported JSON document.
///
/// The App can supply those values, but it must not interpret rule fields.
public struct BookSourceRuntimeOverrides: Equatable, Sendable {
  public let sourceURL: String?
  public let sourceName: String?
  public let group: String?
  public let originOrder: Int?
  public let enabled: Bool?
  public let enabledExplore: Bool?
  public let exploreURL: String?
  public let sourceUserVariable: String

  public init(
    sourceURL: String? = nil,
    sourceName: String? = nil,
    group: String? = nil,
    originOrder: Int? = nil,
    enabled: Bool? = nil,
    enabledExplore: Bool? = nil,
    exploreURL: String? = nil,
    sourceUserVariable: String = ""
  ) {
    self.sourceURL = sourceURL
    self.sourceName = sourceName
    self.group = group
    self.originOrder = originOrder
    self.enabled = enabled
    self.enabledExplore = enabledExplore
    self.exploreURL = exploreURL
    self.sourceUserVariable = sourceUserVariable
  }
}

public struct CompiledBookSourceRuntime: Equatable, Sendable {
  public let id: String
  public let name: String
  public let group: String
  public let enabled: Bool
  public let definition: SourceSearchDefinition
  public let exploreDefinition: SourceExploreDefinition?

  public init(
    id: String,
    name: String,
    group: String,
    enabled: Bool,
    definition: SourceSearchDefinition,
    exploreDefinition: SourceExploreDefinition?
  ) {
    self.id = id
    self.name = name
    self.group = group
    self.enabled = enabled
    self.definition = definition
    self.exploreDefinition = exploreDefinition
  }
}

public enum BookSourceRuntimeCompiler {
  public static func compile(
    _ data: Data,
    overrides: BookSourceRuntimeOverrides =
      BookSourceRuntimeOverrides()
  ) throws -> CompiledBookSourceRuntime {
    try compile(
      BookSourceCodec.decode(data),
      overrides: overrides
    )
  }

  public static func compile(
    _ source: BookSourceDTO,
    overrides: BookSourceRuntimeOverrides =
      BookSourceRuntimeOverrides()
  ) throws -> CompiledBookSourceRuntime {
    let sourceURL = preferred(
      overrides.sourceURL,
      fieldString(source.bookSourceUrl)
    )
    guard !sourceURL.isEmpty else {
      throw BookSourceRuntimeCompilerError.missingSourceURL
    }
    let sourceName = preferred(
      overrides.sourceName,
      fieldString(source.bookSourceName)
    )
    let group = preferred(
      overrides.group,
      fieldString(source.bookSourceGroup)
    )
    let search = try fieldObject(
      source.ruleSearch,
      fallback: SearchRuleDTO(jsonValue: .object([:]))
    )
    let explore = try fieldObject(
      source.ruleExplore,
      fallback: ExploreRuleDTO(jsonValue: .object([:]))
    )
    let bookInfo = try fieldObject(
      source.ruleBookInfo,
      fallback: BookInfoRuleDTO(jsonValue: .object([:]))
    )
    let toc = try fieldObject(
      source.ruleToc,
      fallback: TocRuleDTO(jsonValue: .object([:]))
    )
    let content = try fieldObject(
      source.ruleContent,
      fallback: ContentRuleDTO(jsonValue: .object([:]))
    )
    let runtime = HTMLCSSSourceDefinition(
      searchURLTemplate: fieldString(source.searchUrl),
      search: searchRules(search),
      explore: exploreRules(explore),
      bookInfo: BookInfoRules(
        name: .optional(fieldString(bookInfo.name)),
        author: .optional(fieldString(bookInfo.author)),
        intro: .optional(fieldString(bookInfo.intro)),
        kind: .optional(fieldString(bookInfo.kind)),
        wordCount: .optional(fieldString(bookInfo.wordCount)),
        lastChapter: .optional(
          fieldString(bookInfo.lastChapter)
        ),
        coverURL: .optional(
          fieldString(bookInfo.coverUrl),
          value: .src
        ),
        tocURL: .optional(
          fieldString(bookInfo.tocUrl),
          value: .href
        ),
        allowsRename:
          !fieldString(bookInfo.canReName).isEmpty
      ),
      toc: TOCRules(
        list: fieldString(toc.chapterList),
        name: .optional(fieldString(toc.chapterName)),
        url: .optional(
          fieldString(toc.chapterUrl),
          value: .href
        ),
        isVIP: .optional(fieldString(toc.isVip)),
        isPay: .optional(fieldString(toc.isPay)),
        isVolume: .optional(fieldString(toc.isVolume)),
        nextTocURL: optionalURLRule(toc.nextTocUrl)
      ),
      content: ContentRules(
        title: .optional(fieldString(content.title)),
        content: .optional(
          fieldString(content.content),
          value: .html
        ),
        nextContentURL: optionalURLRule(
          content.nextContentUrl
        ),
        webJS: nonEmpty(fieldString(content.webJs)),
        sourceRegex: nonEmpty(
          fieldString(content.sourceRegex)
        ),
        replaceRegex: nonEmpty(
          fieldString(content.replaceRegex)
        )
      )
    )
    let definition = SourceSearchDefinition(
      sourceURL: sourceURL,
      sourceName: sourceName.isEmpty ? sourceURL : sourceName,
      originOrder:
        overrides.originOrder
        ?? Int(fieldInt32(source.customOrder)),
      bookURLPattern: nonEmpty(
        fieldString(source.bookUrlPattern)
      ),
      sourceHeaders: sourceHeaders(source),
      enabledCookieJar:
        fieldBool(source.enabledCookieJar, fallback: true),
      loginCheckScript: nonEmpty(
        fieldString(source.loginCheckJs)
      ),
      scriptLibrary: scriptLibrary(source.jsLib),
      sourceUserVariable: overrides.sourceUserVariable,
      runtime: runtime
    )
    let catalog = preferred(
      overrides.exploreURL,
      fieldString(source.exploreUrl)
    )
    let enabledExplore =
      overrides.enabledExplore
      ?? fieldBool(source.enabledExplore, fallback: true)
    return CompiledBookSourceRuntime(
      id: sourceURL,
      name: sourceName.isEmpty ? sourceURL : sourceName,
      group: group,
      enabled:
        overrides.enabled
        ?? fieldBool(source.enabled, fallback: true),
      definition: definition,
      exploreDefinition: catalog.isEmpty
        ? nil
        : SourceExploreDefinition(
          source: definition,
          enabled: enabledExplore,
          catalog: catalog
        )
    )
  }

  private static func searchRules(
    _ rule: SearchRuleDTO
  ) -> SearchRules {
    SearchRules(
      list: fieldString(rule.bookList),
      name: .optional(fieldString(rule.name)),
      author: .optional(fieldString(rule.author)),
      intro: .optional(fieldString(rule.intro)),
      kind: .optional(fieldString(rule.kind)),
      wordCount: .optional(fieldString(rule.wordCount)),
      lastChapter: .optional(
        fieldString(rule.lastChapter)
      ),
      bookURL: .optional(
        fieldString(rule.bookUrl),
        value: .href
      ),
      coverURL: .optional(
        fieldString(rule.coverUrl),
        value: .src
      )
    )
  }

  private static func exploreRules(
    _ rule: ExploreRuleDTO
  ) -> SearchRules {
    SearchRules(
      list: fieldString(rule.bookList),
      name: .optional(fieldString(rule.name)),
      author: .optional(fieldString(rule.author)),
      intro: .optional(fieldString(rule.intro)),
      kind: .optional(fieldString(rule.kind)),
      wordCount: .optional(fieldString(rule.wordCount)),
      lastChapter: .optional(
        fieldString(rule.lastChapter)
      ),
      bookURL: .optional(
        fieldString(rule.bookUrl),
        value: .href
      ),
      coverURL: .optional(
        fieldString(rule.coverUrl),
        value: .src
      )
    )
  }

  private static func sourceHeaders(
    _ source: BookSourceDTO
  ) -> [SourceHeaderField] {
    let value: JSONValue?
    switch source.header {
    case .value(let raw):
      value = try? JSONValueCodec.decode(Data(raw.utf8))
    default:
      value = source.rawValue(for: "header")
    }
    guard case .object(let fields) = value else {
      return []
    }
    return fields.compactMap { name, value in
      guard case .string(let string) = value else {
        return nil
      }
      return try? SourceHeaderField(
        name: name,
        value: string
      )
    }.sorted {
      let left = $0.name.lowercased()
      let right = $1.name.lowercased()
      return left == right
        ? $0.name < $1.name
        : left < right
    }
  }

  private static func scriptLibrary(
    _ field: SourceField<String>
  ) -> SourceScriptLibrary? {
    guard let source = nonEmpty(fieldString(field)) else {
      return nil
    }
    if
      let value = try? JSONValueCodec.decode(Data(source.utf8)),
      case .object = value
    {
      return nil
    }
    return SourceScriptLibrary(source: source)
  }

  private static func optionalURLRule(
    _ field: SourceField<String>
  ) -> HTMLCSSRule? {
    nonEmpty(fieldString(field)).map {
      HTMLCSSRule($0, value: .href)
    }
  }

  private static func fieldString(
    _ field: SourceField<String>
  ) -> String {
    guard case .value(let value) = field else {
      return ""
    }
    return value.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
  }

  private static func fieldBool(
    _ field: SourceField<Bool>,
    fallback: Bool
  ) -> Bool {
    guard case .value(let value) = field else {
      return fallback
    }
    return value
  }

  private static func fieldInt32(
    _ field: SourceField<Int32>
  ) -> Int32 {
    guard case .value(let value) = field else {
      return 0
    }
    return value
  }

  private static func fieldObject<Value>(
    _ field: SourceField<Value>,
    fallback: @autoclosure () throws -> Value
  ) throws -> Value
  where Value: Equatable & Sendable {
    guard case .value(let value) = field else {
      return try fallback()
    }
    return value
  }

  private static func preferred(
    _ override: String?,
    _ stored: String
  ) -> String {
    override?.trimmingCharacters(
      in: .whitespacesAndNewlines
    ) ?? stored
  }

  private static func nonEmpty(
    _ value: String
  ) -> String? {
    value.isEmpty ? nil : value
  }
}
