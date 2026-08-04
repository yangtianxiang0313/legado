import Testing
@testable import ReaderCore

@Suite("Android content resegment")
struct AndroidContentResegmentTests {
  @Test("skips the duplicated chapter title and joins a broken paragraph")
  func titleAndParagraphJoin() {
    let result = AndroidContentResegment.resegment(
      "第1章 开始\n第一段还没有结束\n第二行结束。",
      chapterName: "第1章 开始",
      random: { 1 }
    )
    #expect(!result.contains("第1章 开始"))
    #expect(result.contains("第一段还没有结束第二行结束。"))
  }

  @Test("normalizes Android quote and speech punctuation")
  func quoteAndSpeechNormalization() {
    let result = AndroidContentResegment.resegment(
      "他说：\"你好。\"她答。\"再见。\"",
      chapterName: "标题",
      random: { 1 }
    )
    #expect(result.contains("他说：“你好。”"))
    #expect(result.contains("她答。\n“再见。”"))
  }

  @Test("injected random stream makes long paragraph splitting replayable")
  func deterministicRandom() {
    let content = "一。二。三。四。五。六。七。八。"
    let first = AndroidContentResegment.resegment(
      content, chapterName: "标题", random: { 0 }
    )
    let second = AndroidContentResegment.resegment(
      content, chapterName: "标题", random: { 0 }
    )
    #expect(first == second)
    #expect(first.components(separatedBy: "\n").count > 1)
  }
}
