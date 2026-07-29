import Foundation

public protocol SourceRateLimitClock: Sendable {
  func nowMilliseconds() -> Int64
}

public struct SourceSystemMonotonicClock: SourceRateLimitClock {
  public init() {}

  public func nowMilliseconds() -> Int64 {
    Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
  }
}

public enum SourceRateLimitMode: String, Equatable, Sendable {
  case minimumInterval = "minimum_interval"
  case countPerWindow = "count_per_window"
}

public struct SourceRateLimitState: Equatable, Sendable {
  public let sourceKey: String
  public let mode: SourceRateLimitMode
  public let startedAtMilliseconds: Int64
  public let frequency: Int
}

public struct SourceRateLimitPermit: Equatable, Sendable {
  public let sourceKey: String
  public let mode: SourceRateLimitMode

  fileprivate init(sourceKey: String, mode: SourceRateLimitMode) {
    self.sourceKey = sourceKey
    self.mode = mode
  }
}

public struct SourceRateLimitStartResult: Equatable, Sendable {
  public let isActive: Bool
  public let isAllowed: Bool
  public let waitMilliseconds: Int64
  public let state: SourceRateLimitState?
  public let permit: SourceRateLimitPermit?

  fileprivate init(
    isActive: Bool,
    isAllowed: Bool,
    waitMilliseconds: Int64,
    state: SourceRateLimitState?,
    permit: SourceRateLimitPermit?
  ) {
    self.isActive = isActive
    self.isAllowed = isAllowed
    self.waitMilliseconds = waitMilliseconds
    self.state = state
    self.permit = permit
  }
}

public actor SourceRateLimiter {
  private struct Record: Sendable {
    let mode: SourceRateLimitMode
    var startedAtMilliseconds: Int64
    var frequency: Int
  }

  private let clock: any SourceRateLimitClock
  private var records: [String: Record] = [:]

  public init(
    clock: any SourceRateLimitClock = SourceSystemMonotonicClock()
  ) {
    self.clock = clock
  }

  public func start(
    sourceKey: String,
    concurrentRate: String?
  ) -> SourceRateLimitStartResult {
    guard
      let concurrentRate,
      !concurrentRate.isEmpty,
      concurrentRate != "0"
    else {
      return SourceRateLimitStartResult(
        isActive: false,
        isAllowed: true,
        waitMilliseconds: 0,
        state: nil,
        permit: nil
      )
    }

    let slash = concurrentRate.firstIndex(of: "/")
    let mode: SourceRateLimitMode =
      slash != nil && slash != concurrentRate.startIndex
      ? .countPerWindow
      : .minimumInterval
    let now = clock.nowMilliseconds()

    guard var record = records[sourceKey] else {
      let created = Record(
        mode: mode,
        startedAtMilliseconds: now,
        frequency: 1
      )
      records[sourceKey] = created
      return allowed(sourceKey: sourceKey, record: created)
    }

    let waitMilliseconds: Int64
    switch record.mode {
    case .minimumInterval:
      guard let interval = androidInt(concurrentRate) else {
        return allowed(sourceKey: sourceKey, record: record)
      }
      if record.frequency > 0 {
        waitMilliseconds = interval
      } else {
        let nextTime = record.startedAtMilliseconds + interval
        if now >= nextTime {
          record.startedAtMilliseconds = now
          record.frequency = 1
          records[sourceKey] = record
          waitMilliseconds = 0
        } else {
          waitMilliseconds = nextTime - now
        }
      }

    case .countPerWindow:
      guard
        let slash,
        let window = androidInt(concurrentRate[concurrentRate.index(after: slash)...]),
        let count = androidInt(concurrentRate[..<slash])
      else {
        return allowed(sourceKey: sourceKey, record: record)
      }
      let nextTime = record.startedAtMilliseconds + window
      if now >= nextTime {
        record.startedAtMilliseconds = now
        record.frequency = 1
        records[sourceKey] = record
        waitMilliseconds = 0
      } else if Int64(record.frequency) > count {
        waitMilliseconds = nextTime - now
      } else {
        record.frequency += 1
        records[sourceKey] = record
        waitMilliseconds = 0
      }
    }

    if waitMilliseconds > 0 {
      return SourceRateLimitStartResult(
        isActive: true,
        isAllowed: false,
        waitMilliseconds: waitMilliseconds,
        state: state(sourceKey: sourceKey, record: record),
        permit: nil
      )
    }
    return allowed(sourceKey: sourceKey, record: record)
  }

  public func finish(_ permit: SourceRateLimitPermit?) {
    guard
      let permit,
      permit.mode == .minimumInterval,
      var record = records[permit.sourceKey],
      record.mode == .minimumInterval
    else {
      return
    }
    record.frequency -= 1
    records[permit.sourceKey] = record
  }

  private func allowed(
    sourceKey: String,
    record: Record
  ) -> SourceRateLimitStartResult {
    SourceRateLimitStartResult(
      isActive: true,
      isAllowed: true,
      waitMilliseconds: 0,
      state: state(sourceKey: sourceKey, record: record),
      permit: SourceRateLimitPermit(
        sourceKey: sourceKey,
        mode: record.mode
      )
    )
  }

  private func state(
    sourceKey: String,
    record: Record
  ) -> SourceRateLimitState {
    SourceRateLimitState(
      sourceKey: sourceKey,
      mode: record.mode,
      startedAtMilliseconds: record.startedAtMilliseconds,
      frequency: record.frequency
    )
  }

  private func androidInt<S: StringProtocol>(_ value: S) -> Int64? {
    Int32(value).map(Int64.init)
  }
}
