import BackupInteropUseCases
import Foundation
import Testing

@Suite("Android bookshelf list interop")
struct AndroidBookshelfListInteropTests {
  @Test func decodesAndReencodesAndroidBookshelfContract() throws {
    let data = Data(
      #"[{"name":"星河","author":"远山","intro":"科幻"},{"name":"无名","author":null}]"#.utf8
    )
    let values = try AndroidBookshelfListCodec.decode(data)
    #expect(values == [
      .init(name: "星河", author: "远山", intro: "科幻"),
      .init(name: "无名"),
    ])
    let encoded = try AndroidBookshelfListCodec.encode(values)
    #expect(try AndroidBookshelfListCodec.decode(encoded) == values)
    #expect(try AndroidAssociatedImportClassifier.classifyJSON(encoded)
      == .bookshelfList)
  }

  @Test func rejectsObjectsThatOnlyLookLikeBookshelfEntries() {
    #expect(throws: AndroidBookshelfListError.invalidField("author")) {
      try AndroidBookshelfListCodec.decode(Data(
        #"[{"name":"错误","author":42}]"#.utf8
      ))
    }
  }
}
