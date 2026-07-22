import Foundation
import LegadoCore
import SourceRuntime
import TestSupport

public enum ConformanceRunner {
  public static func run(fixtureDirectory: URL) async throws -> Data {
    let fixture = try FixtureLoader.load(from: fixtureDirectory)
    let transport = FixtureTransport(fixture: fixture)
    let boundary = HTTPTransportBoundary(transport: transport)
    let trace = TraceRecorder(id: TraceID(rawValue: "fixture-run"))
    var responses: [(requestCase: FixtureRequestCase, response: HTTPResponse)] = []
    for requestCase in fixture.requestCases {
      let response = try await boundary.execute(requestCase.request, sourceID: nil, trace: trace)
      responses.append((requestCase, response))
    }
    let result: ExecutionResult
    if fixture.definition.transport.mode == .offline, let only = responses.first {
      result = ExecutionResult(type: "http_response", value: responseValue(only.response))
    } else {
      result = ExecutionResult(
        type: "http_response_list",
        value: .array(
          responses.map { item in
            .object([
              "case_id": .string(item.requestCase.id),
              "operation": .string(item.requestCase.operation.rawValue),
              "response": responseValue(item.response),
            ])
          }
        )
      )
    }
    let traceSnapshot = await trace.snapshot()
    let envelope = ExecutionEnvelope(
      fixtureID: fixture.definition.id,
      engine: ExecutionEngine(
        platform: .ios,
        revision: "conformance-source-lab-v1",
        compatibilityProfile: fixture.definition.compatibilityProfile
      ),
      requestPlan: await transport.recordedRequestPlan(),
      decode: nil,
      stages: traceSnapshot.events.compactMap(ExecutionStage.init),
      result: result,
      issues: []
    )
    return try ExecutionEnvelopeCodec.artifactData(envelope)
  }

  private static func responseValue(_ response: HTTPResponse) -> JSONValue {
    let body = HTTPBodyEnvelope(body: response.body)
    return .object([
      "status": .number(JSONNumber(Int64(response.statusCode))),
      "effective_url": .string(response.effectiveURL.absoluteString),
      "body": .object([
        "byte_count": .number(JSONNumber(Int64(body.byteCount))),
        "sha256": .string(body.sha256),
      ]),
    ])
  }
}
