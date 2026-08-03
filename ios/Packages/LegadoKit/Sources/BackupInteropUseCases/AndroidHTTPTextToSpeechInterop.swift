import AndroidBackupInterop
import AppUseCases
import LegadoCore

public enum AndroidHTTPTextToSpeechInteropAdapter {
  public static func restoreValues(
    _ documents: [AndroidHTTPTextToSpeechDTO]
  ) -> [HTTPTextToSpeechEngine] {
    documents.map {
      HTTPTextToSpeechEngine(
        id: $0.integer("id") ?? 0,
        name: $0.string("name") ?? "",
        url: $0.string("url") ?? "",
        contentType: $0.string("contentType"),
        concurrentRate: $0.string("concurrentRate"),
        loginURL: $0.string("loginUrl"),
        loginUI: $0.string("loginUi"),
        header: $0.string("header"),
        jsLib: $0.string("jsLib"),
        enabledCookieJar: $0.boolean("enabledCookieJar"),
        loginCheckJS: $0.string("loginCheckJs"),
        lastUpdateTime: $0.integer("lastUpdateTime") ?? 0
      )
    }
  }

  public static func backupDocuments(
    _ values: [HTTPTextToSpeechEngine]
  ) -> [AndroidHTTPTextToSpeechDTO] {
    values.map {
      AndroidHTTPTextToSpeechDTO(values: [
        "id": .number(JSONNumber($0.id)),
        "name": .string($0.name),
        "url": .string($0.url),
        "contentType": string($0.contentType),
        "concurrentRate": string($0.concurrentRate),
        "loginUrl": string($0.loginURL),
        "loginUi": string($0.loginUI),
        "header": string($0.header),
        "jsLib": string($0.jsLib),
        "enabledCookieJar": $0.enabledCookieJar.map(JSONValue.bool),
        "loginCheckJs": string($0.loginCheckJS),
        "lastUpdateTime": .number(JSONNumber($0.lastUpdateTime)),
      ])
    }
  }

  private static func string(_ value: String?) -> JSONValue? {
    value.map(JSONValue.string)
  }
}
