import Foundation
import LegadoCore

public enum BookSourceCodec {
  public static func decode(_ data: Data, maximumDepth: Int = 128) throws -> BookSourceDTO {
    try BookSourceDTO(jsonValue: JSONValueCodec.decode(data, maximumDepth: maximumDepth))
  }

  public static func encode(_ source: BookSourceDTO) throws -> Data {
    try JSONValueCodec.encode(source.jsonValue)
  }
}
