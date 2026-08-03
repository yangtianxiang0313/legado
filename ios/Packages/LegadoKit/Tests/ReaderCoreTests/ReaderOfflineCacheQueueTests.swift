import ReaderCore
import Testing

@Test func offlineCacheSummaryClearKeepsActiveQueue() {
  var queue = ReaderOfflineCacheQueue()
  let first = queue.register(bookID: "book://first")
  let second = queue.register(bookID: "book://second")
  queue.enqueue([1, 2, 3], for: first)
  queue.begin(1, for: first)
  queue.enqueue([5, 6], for: second)
  queue.recordTerminalFailure(for: first)
  queue.recordTerminalSuccess(for: second)

  #expect(queue.summary.androidDisplayText == "正在下载:1|等待中:4|失败:1|成功:1")
  queue.clearResults()

  #expect(queue.summary.androidDisplayText == "正在下载:1|等待中:4|失败:0|成功:0")
  #expect(queue.registeredModelCount == 2)
  #expect(queue.state(for: first)?.waitingChapterIndices == [2, 3])
  #expect(queue.state(for: first)?.downloadingChapterIndices == [1])
}

@Test func offlineCacheOrdinaryFailureStopsAtThirdAttempt() throws {
  var queue = ReaderOfflineCacheQueue()
  let model = queue.register(bookID: "book://retry")
  queue.enqueue([7], for: model)

  for attempt in 1...3 {
    queue.begin(7, for: model)
    let result = queue.fail(7, kind: .ordinary, for: model)
    let transition = try #require(result)
    #expect(transition.errorCount == attempt)
    #expect(transition.waitingDuringBackoff)
    #expect(transition.requeued == (attempt < 3))
  }
  #expect(queue.state(for: model)?.isStop == true)
}

@Test func offlineCacheConcurrentFailureDoesNotConsumeBudget() throws {
  var queue = ReaderOfflineCacheQueue()
  let model = queue.register(bookID: "book://concurrent")
  queue.enqueue([8], for: model)
  queue.begin(8, for: model)

  let result = queue.fail(8, kind: .concurrent, for: model)
  let transition = try #require(result)
  #expect(transition.errorCount == 0)
  #expect(transition.requeued)
  #expect(transition.state.waitingChapterIndices == [8])
}

@Test func offlineCacheCloseDetachesRegistryButPreservesInflightSnapshot() throws {
  var queue = ReaderOfflineCacheQueue()
  let old = queue.register(bookID: "book://close")
  queue.enqueue([2, 3, 4], for: old)
  queue.begin(2, for: old)

  let result = queue.close(old)
  let closed = try #require(result)
  #expect(queue.registeredModelCount == 0)
  #expect(closed.isStop)
  #expect(closed.isRun)
  #expect(closed.waitingChapterIndices.isEmpty)
  #expect(closed.downloadingChapterIndices == [2])

  let fresh = queue.register(bookID: "book://close")
  #expect(fresh != old)
}
