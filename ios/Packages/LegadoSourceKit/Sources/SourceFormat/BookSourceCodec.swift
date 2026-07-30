import Foundation
import LegadoCore

public enum BookSourceCodec {
  public static func decode(_ data: Data, maximumDepth: Int = 128) throws -> BookSourceDTO {
    try BookSourceDTO(jsonValue: JSONValueCodec.decode(data, maximumDepth: maximumDepth))
  }

  public static func encode(_ source: BookSourceDTO) throws -> Data {
    try JSONValueCodec.encode(source.jsonValue)
  }

  public static func decodeMany(
    _ data: Data,
    maximumDepth: Int = 128
  ) throws -> [BookSourceDTO] {
    let value = try JSONValueCodec.decode(
      data,
      maximumDepth: maximumDepth
    )
    switch value {
    case .object:
      return [try BookSourceDTO(jsonValue: value)]
    case .array(let values):
      return try values.map(BookSourceDTO.init(jsonValue:))
    default:
      throw SourceFormatError.expectedObject
    }
  }
}
