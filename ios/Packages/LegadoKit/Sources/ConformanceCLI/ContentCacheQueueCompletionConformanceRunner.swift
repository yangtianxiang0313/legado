import Foundation
import LegadoCore
import SourceRuntime

struct ContentCacheQueueCompletionConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum ContentCacheQueueCompletionConformanceRunner {
  static let fixtureID = "sl-content-cache-queue-completion-runtime-001"

  static func run(
    fixtureDirectory: URL
  ) async throws -> ContentCacheQueueCompletionConformanceRun {
    let caseDocument = try json(
      at: fixtureDirectory.appendingPathComponent("case.json")
    )
    let inputDocument = try json(
      at: fixtureDirectory.appendingPathComponent("input.json")
    )
    guard
      case .object(let caseRoot) = caseDocument,
      caseRoot["id"] == .string(fixtureID),
      case .object(let determinism)? = caseRoot["determinism"],
      case .string(let origin)? = determinism["logical_origin"],
      case .object(let inputRoot) = inputDocument,
      case .array(let inputCases)? = inputRoot["cases"]
    else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }

    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporary,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporary) }
    let cache = SourceContentCache(root: temporary)

    var plans: [JSONValue] = []
    var cases: [JSONValue] = []
    for value in inputCases {
      guard
        case .object(let inputCase) = value,
        case .string(let id)? = inputCase["id"],
        inputCase["operation"]
          == .string("content_cache_queue_completion"),
        case .object(let arguments)? = inputCase["arguments"],
        case .object(let request)? = inputCase["request"],
        request["method"] == .string("GET"),
        case .string(let target)? = request["target"],
        target.hasPrefix("/")
      else {
        throw SourcePipelineConformanceError.invalidSourceDefinition
      }
      plans.append(requestPlan(url: origin + target))
      cases.append(
        .object([
          "id": .string(id),
          "operation": .string("content_cache_queue_completion"),
          "result": try await projection(
            arguments,
            cache: cache
          ),
          "issue": .null,
        ])
      )
    }

    let canonicalPlans = JSONValue.array(plans)
    let artifact = JSONValue.object([
      "schema_version": number(1),
      "fixture_id": .string(fixtureID),
      "engine": .object([
        "platform": .string("ios"),
        "revision": .string("conformance-content-cache-v1"),
        "compatibility_profile": .string("android-legado-v1"),
      ]),
      "request_plan": canonicalPlans,
      "decode": .null,
      "stages": .array([]),
      "result": .object([
        "type": .string("source_pipeline"),
        "value": .object([
          "portable_known_projection": .object([
            "cases": .array(cases)
          ])
        ]),
      ]),
      "issues": .array([]),
    ])
    return ContentCacheQueueCompletionConformanceRun(
      artifact: artifact,
      requestPlan: canonicalPlans
    )
  }

  private static func projection(
    _ arguments: [String: JSONValue],
    cache: SourceContentCache
  ) async throws -> JSONValue {
    switch try string("mode", in: arguments) {
    case "content_presence":
      return try await contentPresence(arguments, cache: cache)
    case "text_cache_lifecycle":
      return try await textLifecycle(arguments, cache: cache)
    case "image_completion":
      return try await imageCompletion(arguments, cache: cache)
    case "queue_range_stop_resume":
      return try await queueRangeStopResume(arguments)
    case "retry_budget":
      return try await retryBudget(arguments)
    case "success_cancel":
      return try await successCancel(arguments)
    case "registry_cleanup":
      return try await registryCleanup(arguments)
    default:
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
  }

  private static func contentPresence(
    _ arguments: [String: JSONValue],
    cache: SourceContentCache
  ) async throws -> JSONValue {
    let remote = try book(arguments)
    let chapter = try chapter(arguments)
    let volumeTitle = try string("volume_title", in: arguments)
    let local = SourceCacheBook(
      url: remote.url + "/local",
      name: remote.name + " Local",
      isLocalText: false
    )
    try await cache.clear(book: remote)
    return .object([
      "local_txt_without_file": .bool(
        await cache.hasContent(book: local, chapter: chapter)
      ),
      "pseudo_volume_without_file": .bool(
        await cache.hasContent(
          book: remote,
          chapter: SourceCacheChapter(
            url: "\(volumeTitle)::marker",
            title: volumeTitle,
            index: 1,
            isVolume: true
          )
        )
      ),
      "ordinary_volume_without_file": .bool(
        await cache.hasContent(
          book: remote,
          chapter: SourceCacheChapter(
            url: "/volume/ordinary",
            title: volumeTitle,
            index: 2,
            isVolume: true
          )
        )
      ),
      "remote_chapter_without_file": .bool(
        await cache.hasContent(book: remote, chapter: chapter)
      ),
    ])
  }

  private static func textLifecycle(
    _ arguments: [String: JSONValue],
    cache: SourceContentCache
  ) async throws -> JSONValue {
    let book = try book(arguments)
    let chapter = try chapter(arguments)
    try await cache.clear(book: book)
    let before = await cache.hasContent(book: book, chapter: chapter)
    try await cache.saveText("", book: book, chapter: chapter)
    let afterEmpty = await cache.hasContent(book: book, chapter: chapter)
    try await cache.saveText(
      string("content", in: arguments),
      book: book,
      chapter: chapter
    )
    let afterText = await cache.hasContent(book: book, chapter: chapter)
    let stored = try await cache.text(book: book, chapter: chapter)
    let files = try await cache.chapterFiles(book: book)
    try await cache.deleteText(book: book, chapter: chapter)
    return .object([
      "before_save": .bool(before),
      "after_empty_save": .bool(afterEmpty),
      "after_text_save": .bool(afterText),
      "stored_content": stored.map(JSONValue.string) ?? .null,
      "chapter_files": .array(files.map(JSONValue.string)),
      "expected_file_name": .string(
        SourceContentCache.chapterFileName(
          index: chapter.index,
          title: chapter.title
        )
      ),
      "after_delete": .bool(
        await cache.hasContent(book: book, chapter: chapter)
      ),
    ])
  }

  private static func imageCompletion(
    _ arguments: [String: JSONValue],
    cache: SourceContentCache
  ) async throws -> JSONValue {
    let book = try book(arguments)
    let chapter = try chapter(arguments)
    let missing = try string("missing_image_url", in: arguments)
    let valid = try string("valid_svg_url", in: arguments)
    try await cache.clear(book: book)
    let withoutText = try await cache.hasImageContent(
      book: book,
      chapter: chapter
    )
    try await cache.saveText(
      string("plain_content", in: arguments),
      book: book,
      chapter: chapter
    )
    let plainTextComplete = try await cache.hasImageContent(
      book: book,
      chapter: chapter
    )
    try await cache.saveText(
      "<p>text</p><img src=\"\(missing)\">",
      book: book,
      chapter: chapter
    )
    let missingImageComplete = try await cache.hasImageContent(
      book: book,
      chapter: chapter
    )
    try await cache.writeImage(
      Data("not-an-image".utf8),
      sourceURL: missing,
      book: book
    )
    let invalidImageComplete = try await cache.hasImageContent(
      book: book,
      chapter: chapter
    )
    let invalidDeleted = !(await cache.imageExists(
      sourceURL: missing,
      book: book
    ))
    try await cache.saveText(
      "<p>text</p><img src=\"\(valid)\">",
      book: book,
      chapter: chapter
    )
    try await cache.writeImage(
      Data(try string("valid_svg", in: arguments).utf8),
      sourceURL: valid,
      book: book
    )
    let validComplete = try await cache.hasImageContent(
      book: book,
      chapter: chapter
    )
    return .object([
      "without_text": .bool(withoutText),
      "plain_text_complete": .bool(plainTextComplete),
      "text_file_present": .bool(
        await cache.hasContent(book: book, chapter: chapter)
      ),
      "missing_image_complete": .bool(missingImageComplete),
      "invalid_image_complete": .bool(invalidImageComplete),
      "invalid_image_deleted": .bool(invalidDeleted),
      "valid_svg_complete": .bool(validComplete),
      "valid_svg_retained": .bool(
        await cache.imageExists(sourceURL: valid, book: book)
      ),
    ])
  }

  private static func queueRangeStopResume(
    _ arguments: [String: JSONValue]
  ) async throws -> JSONValue {
    let bookURL = try string("book_url", in: arguments)
    let registry = SourceCacheQueueRegistry()
    let model = await registry.model(for: bookURL)
    let firstStart = try integer("first_start", in: arguments)
    let firstEnd = try integer("first_end", in: arguments)
    await model.addDownload(
      firstStart...firstEnd
    )
    let secondStart = try integer("second_start", in: arguments)
    let secondEnd = try integer("second_end", in: arguments)
    await model.addDownload(
      secondStart...secondEnd
    )
    let before = await model.snapshot()
    let registeredBefore = await registry.contains(bookURL)
    await model.stop()
    let afterStop = await model.snapshot()
    let registeredAfter = await registry.contains(bookURL)
    let resume = try integer("resume_index", in: arguments)
    await model.addDownload(resume...resume)
    return .object([
      "before_stop": snapshot(before),
      "registered_before_stop": .bool(registeredBefore),
      "after_stop": snapshot(afterStop),
      "registered_after_stop": .bool(registeredAfter),
      "after_resume": snapshot(await model.snapshot()),
    ])
  }

  private static func retryBudget(
    _ arguments: [String: JSONValue]
  ) async throws -> JSONValue {
    let bookURL = try string("book_url", in: arguments)
    let chapterURL = try string("chapter_url", in: arguments)
    let index = try integer("chapter_index", in: arguments)
    let key = bookURL + chapterURL
    let ordinary = SourceCacheQueueModel(bookURL: bookURL)
    await ordinary.addDownload(index...index)
    var attempts: [JSONValue] = []
    for attempt in 1...3 {
      await ordinary.beginAttempt(index)
      let transition = await ordinary.recordFailure(
        index: index,
        key: key,
        kind: .ordinary
      )
      attempts.append(
        .object([
          "attempt": number(attempt),
          "error_count": number(transition.errorCount),
          "waiting_during_backoff": .bool(
            transition.waitingDuringBackoff
          ),
          "requeued": .bool(transition.requeued),
        ])
      )
    }

    let concurrentIndex = try integer(
      "concurrent_index",
      in: arguments
    )
    let concurrent = SourceCacheQueueModel(
      bookURL: bookURL + "/concurrent"
    )
    let concurrentKey = key + "/concurrent"
    await concurrent.addDownload(concurrentIndex...concurrentIndex)
    await concurrent.beginAttempt(concurrentIndex)
    let concurrentTransition = await concurrent.recordFailure(
      index: concurrentIndex,
      key: concurrentKey,
      kind: .concurrent
    )

    let stoppedIndex = try integer("stopped_index", in: arguments)
    let stopped = SourceCacheQueueModel(bookURL: bookURL + "/stopped")
    let stoppedKey = key + "/stopped"
    await stopped.addDownload(stoppedIndex...stoppedIndex)
    await stopped.beginAttempt(stoppedIndex)
    _ = await stopped.beginFailure(
      index: stoppedIndex,
      key: stoppedKey,
      kind: .ordinary
    )
    await stopped.stop()
    let stoppedRequeued = await stopped.finishFailure(
      index: stoppedIndex,
      key: stoppedKey,
      kind: .ordinary
    )
    return .object([
      "ordinary_attempts": .array(attempts),
      "ordinary_is_stop_after_budget": .bool(
        (await ordinary.snapshot()).isStopped
      ),
      "concurrent_error_count": number(
        concurrentTransition.errorCount
      ),
      "concurrent_requeued": .bool(concurrentTransition.requeued),
      "stopped_error_count": number(
        await stopped.errorCount(for: stoppedKey)
      ),
      "stopped_requeued": .bool(stoppedRequeued),
      "stopped_is_stop": .bool(
        (await stopped.snapshot()).isStopped
      ),
    ])
  }

  private static func successCancel(
    _ arguments: [String: JSONValue]
  ) async throws -> JSONValue {
    let bookURL = try string("book_url", in: arguments)
    let chapterURL = try string("chapter_url", in: arguments)
    let successIndex = try integer("success_index", in: arguments)
    let successKey = bookURL + chapterURL
    let success = SourceCacheQueueModel(bookURL: bookURL)
    await success.addDownload(successIndex...successIndex)
    await success.beginAttempt(successIndex)
    await success.setErrorCount(2, for: successKey)
    await success.completeSuccess(index: successIndex, key: successKey)

    let cancelIndex = try integer("cancel_index", in: arguments)
    let cancel = SourceCacheQueueModel(bookURL: bookURL + "/cancel")
    await cancel.addDownload(cancelIndex...cancelIndex)
    await cancel.beginAttempt(cancelIndex)
    await cancel.cancel(index: cancelIndex)

    let stoppedIndex = try integer(
      "stopped_cancel_index",
      in: arguments
    )
    let stopped = SourceCacheQueueModel(bookURL: bookURL + "/stopped")
    await stopped.addDownload(stoppedIndex...stoppedIndex)
    await stopped.beginAttempt(stoppedIndex)
    await stopped.stop()
    await stopped.cancel(index: stoppedIndex)
    return .object([
      "success_recorded": .bool(
        await success.containsSuccess(successKey)
      ),
      "success_removed_prior_error": .bool(
        await success.errorCount(for: successKey) == 0
      ),
      "success_removed_on_download": .bool(
        !(await success.containsDownloading(successIndex))
      ),
      "cancel_requeued": .bool(
        await cancel.containsWaiting(cancelIndex)
      ),
      "stopped_cancel_requeued": .bool(
        await stopped.containsWaiting(stoppedIndex)
      ),
    ])
  }

  private static func registryCleanup(
    _ arguments: [String: JSONValue]
  ) async throws -> JSONValue {
    let bookURL = try string("book_url", in: arguments)
    let index = try integer("chapter_index", in: arguments)
    let registry = SourceCacheQueueRegistry()
    let model = await registry.model(for: bookURL)
    await model.addDownload(index...index)
    await registry.finish(bookURL)
    let retained = await registry.contains(bookURL)
    await model.prepareWaitingRetryWithoutQueuedWork()
    let isStopped = (await model.snapshot()).isStopped
    await registry.finish(bookURL)
    return .object([
      "registered_initially": .bool(true),
      "registry_retained_with_wait": .bool(retained),
      "is_stop_with_only_waiting_retry": .bool(isStopped),
      "registry_removed_with_only_waiting_retry": .bool(
        !(await registry.contains(bookURL))
      ),
    ])
  }

  private static func book(
    _ arguments: [String: JSONValue]
  ) throws -> SourceCacheBook {
    SourceCacheBook(
      url: try string("book_url", in: arguments),
      name: try string("book_name", in: arguments)
    )
  }

  private static func chapter(
    _ arguments: [String: JSONValue],
    index: Int? = nil
  ) throws -> SourceCacheChapter {
    SourceCacheChapter(
      url: try optionalString(
        "chapter_url",
        in: arguments,
        fallback: "/chapter/\(index ?? 0)"
      ),
      title: try optionalString(
        "chapter_title",
        in: arguments,
        fallback: "Chapter \(index ?? 0)"
      ),
      index: index ?? optionalInteger(
        "chapter_index",
        in: arguments,
        fallback: 0
      )
    )
  }

  private static func snapshot(
    _ value: SourceCacheQueueSnapshot
  ) -> JSONValue {
    .object([
      "wait_indices": .array(value.waitingIndices.map(number)),
      "on_download_indices": .array(
        value.downloadingIndices.map(number)
      ),
      "wait_count": number(value.waitingCount),
      "on_download_count": number(value.downloadingCount),
      "is_run": .bool(value.isRunning),
      "is_stop": .bool(value.isStopped),
    ])
  }

  private static func requestPlan(url: String) -> JSONValue {
    .object([
      "method": .string("GET"),
      "url": .string(url),
      "headers": .array([]),
      "body": .null,
      "timeout_ms": .null,
    ])
  }

  private static func number(_ value: Int) -> JSONValue {
    .number(JSONNumber(Int64(value)))
  }

  private static func string(
    _ key: String,
    in values: [String: JSONValue]
  ) throws -> String {
    guard case .string(let value)? = values[key] else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    return value
  }

  private static func optionalString(
    _ key: String,
    in values: [String: JSONValue],
    fallback: String
  ) throws -> String {
    if values[key] == nil {
      return fallback
    }
    return try string(key, in: values)
  }

  private static func integer(
    _ key: String,
    in values: [String: JSONValue]
  ) throws -> Int {
    guard case .number(let value)? = values[key],
      let integer = Int(value.rawToken)
    else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    return integer
  }

  private static func optionalInteger(
    _ key: String,
    in values: [String: JSONValue],
    fallback: Int
  ) -> Int {
    guard case .number(let value)? = values[key],
      let integer = Int(value.rawToken)
    else {
      return fallback
    }
    return integer
  }

  private static func json(at url: URL) throws -> JSONValue {
    do {
      return try JSONValueCodec.decode(
        Data(contentsOf: url, options: [.mappedIfSafe])
      )
    } catch {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
  }
}
