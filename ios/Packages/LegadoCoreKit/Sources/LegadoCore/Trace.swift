public enum SourceStage: String, CaseIterable, Codable, Sendable {
  case sourceLoad = "source_load"
  case sourceValidation = "source_validation"
  case urlTemplate = "url_template"
  case ruleCompilation = "rule_compilation"
  case policy = "policy"
  case rateLimit = "rate_limit"
  case requestBuild = "request_build"
  case transport = "transport"
  case responseDecode = "response_decode"
  case documentCreation = "document_creation"
  case listSelection = "list_selection"
  case fieldEvaluation = "field_evaluation"
  case urlCompletion = "url_completion"
  case script = "script"
  case webView = "web_view"
  case contentNormalization = "content_normalization"
  case resultMapping = "result_mapping"
}

public enum TraceEventKind: String, Codable, Sendable {
  case entered
  case completed
  case failed
  case cancelled
}

public struct TraceEvent: Codable, Equatable, Sendable {
  public let sequence: Int
  public let stage: SourceStage
  public let kind: TraceEventKind
  public let issueCode: IssueCode?

  public init(
    sequence: Int,
    stage: SourceStage,
    kind: TraceEventKind,
    issueCode: IssueCode? = nil
  ) {
    self.sequence = sequence
    self.stage = stage
    self.kind = kind
    self.issueCode = issueCode
  }
}

public struct Trace: Codable, Equatable, Sendable {
  public let id: TraceID
  public let events: [TraceEvent]

  public init(id: TraceID, events: [TraceEvent]) {
    self.id = id
    self.events = events
  }
}

public actor TraceRecorder {
  public nonisolated let id: TraceID

  private var events: [TraceEvent] = []
  private var nextSequence = 0

  public init(id: TraceID) {
    self.id = id
  }

  public func entered(_ stage: SourceStage) {
    append(stage: stage, kind: .entered)
  }

  public func completed(_ stage: SourceStage) {
    append(stage: stage, kind: .completed)
  }

  public func failed(_ stage: SourceStage, code: IssueCode) {
    append(stage: stage, kind: .failed, issueCode: code)
  }

  public func cancelled(_ stage: SourceStage) {
    append(stage: stage, kind: .cancelled)
  }

  public func snapshot() -> Trace {
    Trace(id: id, events: events)
  }

  private func append(stage: SourceStage, kind: TraceEventKind, issueCode: IssueCode? = nil) {
    events.append(
      TraceEvent(sequence: nextSequence, stage: stage, kind: kind, issueCode: issueCode)
    )
    nextSequence += 1
  }
}

public struct Traced<Value: Sendable>: Sendable {
  public let value: Value
  public let trace: Trace

  public init(value: Value, trace: Trace) {
    self.value = value
    self.trace = trace
  }
}

extension Traced: Equatable where Value: Equatable {}
extension Traced: Codable where Value: Codable {}
