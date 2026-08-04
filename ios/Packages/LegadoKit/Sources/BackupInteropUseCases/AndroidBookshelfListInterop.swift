import AppUseCases
import Foundation
import LegadoCore

public enum AndroidBookshelfListError: Error, Equatable, Sendable {
  case expectedArray
  case expectedObject
  case invalidField(String)
}

public struct AndroidBookshelfListEntry: Equatable, Hashable, Sendable {
  public let name: String
  public let author: String
  public let intro: String

  public init(name: String, author: String = "", intro: String = "") {
    self.name = name
    self.author = author
    self.intro = intro
  }
}

public enum AndroidBookshelfListCodec {
  public static func decode(_ data: Data) throws
    -> [AndroidBookshelfListEntry]
  {
    guard case .array(let values) = try JSONValueCodec.decode(data) else {
      throw AndroidBookshelfListError.expectedArray
    }
    return try values.map { value in
      guard case .object(let fields) = value else {
        throw AndroidBookshelfListError.expectedObject
      }
      return AndroidBookshelfListEntry(
        name: try string(fields["name"], field: "name"),
        author: try string(fields["author"], field: "author"),
        intro: try string(fields["intro"], field: "intro")
      )
    }
  }

  public static func encode(_ values: [AndroidBookshelfListEntry]) throws
    -> Data
  {
    try JSONValueCodec.encode(.array(values.map { value in
      .object([
        "name": .string(value.name),
        "author": .string(value.author),
        "intro": .string(value.intro),
      ])
    }))
  }

  public static func export(_ books: [ShelfBookItem]) throws -> Data {
    try encode(books.map {
      AndroidBookshelfListEntry(
        name: $0.candidate.name,
        author: $0.candidate.author,
        intro: $0.candidate.displayIntro
      )
    })
  }

  private static func string(
    _ value: JSONValue?,
    field: String
  ) throws -> String {
    guard let value else { return "" }
    if case .null = value { return "" }
    guard case .string(let text) = value else {
      throw AndroidBookshelfListError.invalidField(field)
    }
    return text
  }
}
