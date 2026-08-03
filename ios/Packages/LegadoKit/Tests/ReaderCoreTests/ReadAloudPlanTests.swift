@testable import ReaderCore
import XCTest

final class ReadAloudPlanTests: XCTestCase {
  func testPlanMatchesAndroidMultilineQueueAndSkipsPunctuation() {
    let content = "第一段\n\n？！…\n第二段\n   \n第三段"

    let segments = ReadAloudPlan.segments(content: content)

    XCTAssertEqual(
      segments.map(\.text),
      ["第一段", "第二段", "第三段"]
    )
    XCTAssertEqual(
      segments.map(\.startOffset),
      [
        (content as NSString).range(of: "第一段").location,
        (content as NSString).range(of: "第二段").location,
        (content as NSString).range(of: "第三段").location,
      ]
    )
    XCTAssertEqual(
      segments.map(\.id),
      segments.map { "read-aloud-\($0.startOffset)" }
    )
  }

  func testPlanResumesInsideParagraphUsingUTF16Offset() {
    let content = "开头🚀目标文字\n下一段"
    let offset = (content as NSString).range(of: "目标").location

    let segments = ReadAloudPlan.segments(
      content: content,
      startingAt: offset
    )

    XCTAssertEqual(segments.map(\.text), ["目标文字", "下一段"])
    XCTAssertEqual(segments.first?.startOffset, offset)
  }

  func testAndroidSpeechRateMapping() {
    XCTAssertEqual(ReadAloudPlan.speechRate(preference: 7), 1.2)
  }

  func testReadAloudPreferencesUseAndroidRangeAndFollowSystemSemantics() {
    XCTAssertEqual(
      ReadAloudPreferences(
        followsSystemRate: false,
        speechRatePreference: 15
      ).relativeRate,
      2
    )
    XCTAssertEqual(
      ReadAloudPreferences(
        followsSystemRate: true,
        speechRatePreference: 45
      ).relativeRate,
      1
    )
    XCTAssertEqual(
      ReadAloudPreferences(
        followsSystemRate: false,
        speechRatePreference: 99
      ).speechRatePreference,
      45
    )
  }
}
