import AndroidBackupInterop
import AppUseCases
import LegadoCore

public enum AndroidRSSInteropAdapter {
  public static func restoreSources(
    _ documents: [AndroidRSSSourceDTO]
  ) -> [RSSSource] {
    documents.map { value in
      RSSSource(
        sourceURL: value.string("sourceUrl") ?? "",
        sourceName: value.string("sourceName") ?? "",
        sourceIcon: value.string("sourceIcon") ?? "",
        sourceGroup: value.string("sourceGroup"),
        sourceComment: value.string("sourceComment"),
        enabled: value.boolean("enabled") ?? true,
        variableComment: value.string("variableComment"),
        jsLib: value.string("jsLib"),
        enabledCookieJar: value.boolean("enabledCookieJar"),
        concurrentRate: value.string("concurrentRate"),
        header: value.string("header"),
        loginURL: value.string("loginUrl"),
        loginUI: value.string("loginUi"),
        loginCheckJS: value.string("loginCheckJs"),
        coverDecodeJS: value.string("coverDecodeJs"),
        sortURL: value.string("sortUrl"),
        singleURL: value.boolean("singleUrl") ?? false,
        articleStyle: Int(value.integer("articleStyle") ?? 0),
        ruleArticles: value.string("ruleArticles"),
        ruleNextPage: value.string("ruleNextPage"),
        ruleTitle: value.string("ruleTitle"),
        rulePubDate: value.string("rulePubDate"),
        ruleDescription: value.string("ruleDescription"),
        ruleImage: value.string("ruleImage"),
        ruleLink: value.string("ruleLink"),
        ruleContent: value.string("ruleContent"),
        contentWhitelist: value.string("contentWhitelist"),
        contentBlacklist: value.string("contentBlacklist"),
        shouldOverrideURLLoading: value.string("shouldOverrideUrlLoading"),
        style: value.string("style"),
        enableJS: value.boolean("enableJs") ?? true,
        loadWithBaseURL: value.boolean("loadWithBaseUrl") ?? true,
        injectJS: value.string("injectJs"),
        lastUpdateTime: value.integer("lastUpdateTime") ?? 0,
        customOrder: Int(value.integer("customOrder") ?? 0)
      )
    }
  }

  public static func backupSources(
    _ values: [RSSSource]
  ) -> [AndroidRSSSourceDTO] {
    values.map { value in
      AndroidRSSSourceDTO(values: [
        "sourceUrl": .string(value.sourceURL),
        "sourceName": .string(value.sourceName),
        "sourceIcon": .string(value.sourceIcon),
        "sourceGroup": string(value.sourceGroup),
        "sourceComment": string(value.sourceComment),
        "enabled": .bool(value.enabled),
        "variableComment": string(value.variableComment),
        "jsLib": string(value.jsLib),
        "enabledCookieJar": value.enabledCookieJar.map(JSONValue.bool),
        "concurrentRate": string(value.concurrentRate),
        "header": string(value.header),
        "loginUrl": string(value.loginURL),
        "loginUi": string(value.loginUI),
        "loginCheckJs": string(value.loginCheckJS),
        "coverDecodeJs": string(value.coverDecodeJS),
        "sortUrl": string(value.sortURL),
        "singleUrl": .bool(value.singleURL),
        "articleStyle": .number(JSONNumber(Int64(value.articleStyle))),
        "ruleArticles": string(value.ruleArticles),
        "ruleNextPage": string(value.ruleNextPage),
        "ruleTitle": string(value.ruleTitle),
        "rulePubDate": string(value.rulePubDate),
        "ruleDescription": string(value.ruleDescription),
        "ruleImage": string(value.ruleImage),
        "ruleLink": string(value.ruleLink),
        "ruleContent": string(value.ruleContent),
        "contentWhitelist": string(value.contentWhitelist),
        "contentBlacklist": string(value.contentBlacklist),
        "shouldOverrideUrlLoading": string(value.shouldOverrideURLLoading),
        "style": string(value.style),
        "enableJs": .bool(value.enableJS),
        "loadWithBaseUrl": .bool(value.loadWithBaseURL),
        "injectJs": string(value.injectJS),
        "lastUpdateTime": .number(JSONNumber(value.lastUpdateTime)),
        "customOrder": .number(JSONNumber(Int64(value.customOrder))),
      ])
    }
  }

  public static func restoreStars(
    _ documents: [AndroidRSSStarDTO]
  ) -> [RSSStar] {
    documents.map { value in
      RSSStar(
        origin: value.string("origin") ?? "",
        sort: value.string("sort") ?? "",
        title: value.string("title") ?? "",
        starTime: value.integer("starTime") ?? 0,
        link: value.string("link") ?? "",
        pubDate: value.string("pubDate"),
        description: value.string("description"),
        content: value.string("content"),
        image: value.string("image"),
        variable: value.string("variable")
      )
    }
  }

  public static func backupStars(
    _ values: [RSSStar]
  ) -> [AndroidRSSStarDTO] {
    values.map { value in
      AndroidRSSStarDTO(values: [
        "origin": .string(value.origin),
        "sort": .string(value.sort),
        "title": .string(value.title),
        "starTime": .number(JSONNumber(value.starTime)),
        "link": .string(value.link),
        "pubDate": string(value.pubDate),
        "description": string(value.description),
        "content": string(value.content),
        "image": string(value.image),
        "variable": string(value.variable),
      ])
    }
  }

  private static func string(_ value: String?) -> JSONValue? {
    value.map(JSONValue.string)
  }
}
