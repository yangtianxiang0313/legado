import AndroidBackupInterop
import Foundation
import LegadoCore
import ReaderCore

public struct AndroidReaderConfigBundle: Equatable, Sendable {
  public let styles: [AndroidReaderConfigDTO]
  public let sharedStyle: AndroidReaderConfigDTO?

  public init(
    styles: [AndroidReaderConfigDTO],
    sharedStyle: AndroidReaderConfigDTO?
  ) {
    self.styles = styles
    self.sharedStyle = sharedStyle
  }

  public init(stylesData: Data?, sharedStyleData: Data?) throws {
    styles = try stylesData.map { try AndroidReaderConfigCodec.decodeList($0) } ?? []
    sharedStyle = try sharedStyleData.map {
      try AndroidReaderConfigCodec.decodeShared($0)
    }
  }

  public func encodedStyles() throws -> Data {
    try AndroidReaderConfigCodec.encodeList(styles)
  }

  public func encodedSharedStyle() throws -> Data? {
    try sharedStyle.map(AndroidReaderConfigCodec.encodeShared)
  }

  public var projection: AndroidReaderConfigProjection? {
    guard let sharedStyle else { return nil }
    return AndroidReaderConfigProjection(
      fontSize: sharedStyle.integer("textSize").map(Double.init),
      lineSpacing: sharedStyle.integer("lineSpacingExtra").map(Double.init),
      pageAnimation: sharedStyle.integer("pageAnim").map(Int.init),
      layout: AndroidReaderLayoutProjection(
        textWeight: sharedStyle.integer("textBold").map(Int.init),
        letterSpacing: decimal(sharedStyle, "letterSpacing"),
        paragraphSpacing: sharedStyle.integer("paragraphSpacing").map(Int.init),
        paragraphIndent: string(sharedStyle, "paragraphIndent"),
        titleMode: sharedStyle.integer("titleMode").map(Int.init),
        paddingTop: sharedStyle.integer("paddingTop").map(Int.init),
        paddingBottom: sharedStyle.integer("paddingBottom").map(Int.init),
        paddingLeft: sharedStyle.integer("paddingLeft").map(Int.init),
        paddingRight: sharedStyle.integer("paddingRight").map(Int.init)
      )
    )
  }

  public func applying(_ preferences: ReaderPreferences)
    -> AndroidReaderConfigBundle
  {
    var fields = sharedStyle?.rawFields ?? [:]
    fields["textSize"] = .number(
      JSONNumber(Int64(preferences.fontSize.rounded()))
    )
    fields["lineSpacingExtra"] = .number(
      JSONNumber(Int64(preferences.lineSpacing.rounded()))
    )
    fields["pageAnim"] = .number(
      JSONNumber(Int64(preferences.pageAnimation))
    )
    fields["textBold"] = .number(
      JSONNumber(Int64(preferences.layout.textWeight))
    )
    if let number = try? JSONNumber(
      validating: String(preferences.layout.letterSpacing)
    ) {
      fields["letterSpacing"] = .number(number)
    }
    fields["paragraphSpacing"] = .number(
      JSONNumber(Int64(preferences.layout.paragraphSpacing))
    )
    fields["paragraphIndent"] = .string(preferences.layout.paragraphIndent)
    fields["titleMode"] = .number(
      JSONNumber(Int64(preferences.layout.titleMode))
    )
    fields["paddingTop"] = .number(
      JSONNumber(Int64(preferences.layout.paddingTop))
    )
    fields["paddingBottom"] = .number(
      JSONNumber(Int64(preferences.layout.paddingBottom))
    )
    fields["paddingLeft"] = .number(
      JSONNumber(Int64(preferences.layout.paddingLeft))
    )
    fields["paddingRight"] = .number(
      JSONNumber(Int64(preferences.layout.paddingRight))
    )
    let updated = try? AndroidReaderConfigDTO(jsonValue: .object(fields))
    return AndroidReaderConfigBundle(
      styles: styles,
      sharedStyle: updated ?? sharedStyle
    )
  }

  private func decimal(
    _ document: AndroidReaderConfigDTO,
    _ key: String
  ) -> Double? {
    guard case .number(let number) = document.rawFields[key] else {
      return nil
    }
    return Double(number.rawToken)
  }

  private func string(
    _ document: AndroidReaderConfigDTO,
    _ key: String
  ) -> String? {
    guard case .string(let value) = document.rawFields[key] else {
      return nil
    }
    return value
  }
}
