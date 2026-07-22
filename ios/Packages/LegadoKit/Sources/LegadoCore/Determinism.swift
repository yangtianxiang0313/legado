import Foundation

public protocol Clock: Sendable {
  var now: Date { get }
}

public struct SystemClock: Clock {
  public init() {}

  public var now: Date {
    Date()
  }
}

public protocol IDGenerating: Sendable {
  func makeTraceID() -> TraceID
}

public struct UUIDIDGenerator: IDGenerating {
  public init() {}

  public func makeTraceID() -> TraceID {
    TraceID(rawValue: UUID().uuidString.lowercased())
  }
}
