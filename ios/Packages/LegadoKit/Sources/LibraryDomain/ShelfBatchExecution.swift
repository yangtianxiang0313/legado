public enum ShelfBatchSkipReason: String, Equatable, Sendable {
  case localBook
  case alreadyUsesTargetSource
  case notEligible
}

public enum ShelfBatchFailureReason: String, Equatable, Sendable {
  case searchFailed
  case tableOfContentsFailed
  case operationFailed
}

public enum ShelfBatchStepOutcome: Equatable, Sendable {
  case committed
  case skipped(ShelfBatchSkipReason)
  case failed(ShelfBatchFailureReason)
}

public enum ShelfBatchItemStatus: Equatable, Sendable {
  case committed
  case skipped(ShelfBatchSkipReason)
  case failed(ShelfBatchFailureReason)
  case cancelled
}

public struct ShelfBatchItemResult: Equatable, Sendable {
  public let bookID: BookID
  public let status: ShelfBatchItemStatus

  public init(bookID: BookID, status: ShelfBatchItemStatus) {
    self.bookID = bookID
    self.status = status
  }
}

public struct ShelfBatchReport: Equatable, Sendable {
  public let results: [ShelfBatchItemResult]

  public init(results: [ShelfBatchItemResult]) {
    self.results = results
  }

  public var committedBookIDs: [BookID] {
    results.compactMap {
      $0.status == .committed ? $0.bookID : nil
    }
  }

  public var failedBookIDs: [BookID] {
    results.compactMap {
      if case .failed = $0.status { return $0.bookID }
      return nil
    }
  }

  public var cancelledBookIDs: [BookID] {
    results.compactMap {
      $0.status == .cancelled ? $0.bookID : nil
    }
  }

  public var isPartialCommit: Bool {
    !committedBookIDs.isEmpty
      && results.contains { $0.status != .committed }
  }
}

public enum ShelfBatchExecution {
  /// Runs in source order and deliberately does not roll back earlier items.
  ///
  /// Android's batch source migration persists each successful book before
  /// advancing to the next. A failure is recorded and processing continues;
  /// cancellation marks the current and remaining books without touching
  /// already committed books.
  public static func run(
    bookIDs: [BookID],
    operation: @escaping @Sendable (BookID) async throws
      -> ShelfBatchStepOutcome
  ) async -> ShelfBatchReport {
    var results: [ShelfBatchItemResult] = []
    for (index, bookID) in bookIDs.enumerated() {
      if Task.isCancelled {
        appendCancelled(
          bookIDs[index...],
          to: &results
        )
        break
      }
      do {
        let outcome = try await operation(bookID)
        results.append(
          ShelfBatchItemResult(
            bookID: bookID,
            status: status(for: outcome)
          )
        )
      } catch is CancellationError {
        appendCancelled(
          bookIDs[index...],
          to: &results
        )
        break
      } catch {
        results.append(
          ShelfBatchItemResult(
            bookID: bookID,
            status: .failed(.operationFailed)
          )
        )
      }
    }
    return ShelfBatchReport(results: results)
  }

  private static func status(
    for outcome: ShelfBatchStepOutcome
  ) -> ShelfBatchItemStatus {
    switch outcome {
    case .committed:
      .committed
    case .skipped(let reason):
      .skipped(reason)
    case .failed(let reason):
      .failed(reason)
    }
  }

  private static func appendCancelled(
    _ bookIDs: ArraySlice<BookID>,
    to results: inout [ShelfBatchItemResult]
  ) {
    results.append(
      contentsOf: bookIDs.map {
        ShelfBatchItemResult(bookID: $0, status: .cancelled)
      }
    )
  }
}
