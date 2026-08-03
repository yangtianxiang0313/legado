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
      lineSpacing: sharedStyle.integer("lineSpacingExtra").map(Double.init)
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
    let updated = try? AndroidReaderConfigDTO(jsonValue: .object(fields))
    return AndroidReaderConfigBundle(
      styles: styles,
      sharedStyle: updated ?? sharedStyle
    )
  }
}
