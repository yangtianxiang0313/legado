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
    let response = try await boundary.execute(fixture.request, sourceID: nil, trace: trace)
    let responseBody = HTTPBodyEnvelope(body: response.body)
    let result = ExecutionResult(
      type: "http_response",
      value: .object([
        "status": .number(JSONNumber(Int64(response.statusCode))),
        "effective_url": .string(response.effectiveURL.absoluteString),
        "body": .object([
          "byte_count": .number(JSONNumber(Int64(responseBody.byteCount))),
          "sha256": .string(responseBody.sha256),
        ]),
      ])
    )
    let traceSnapshot = await trace.snapshot()
    let envelope = ExecutionEnvelope(
      fixtureID: fixture.definition.id,
      engine: ExecutionEngine(
        platform: .ios,
        revision: "conformance-scaffold-v1",
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
}
