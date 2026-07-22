import Foundation
import LegadoCore
import SourceFormat
import SourceRuntime
import TestSupport

public enum ConformanceRunnerError: String, Error, Equatable, Sendable {
  case losslessInvariantViolation = "lossless_invariant_violation"
}

public enum ConformanceRunner {
  public static func run(fixtureDirectory: URL) async throws -> Data {
    switch try FixtureLoader.loadForConformance(from: fixtureDirectory) {
    case .sourceRoundTrip(let fixture):
      return try runSourceRoundTrip(fixture)
    case .transport(let fixture):
      return try await runTransport(fixture)
    }
  }

  private static func runTransport(_ fixture: LoadedFixture) async throws -> Data {
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

  private static func runSourceRoundTrip(_ fixture: LoadedSourceRoundTripFixture) throws -> Data {
    let canonicalInput = try JSONValueCodec.decode(fixture.sourceData)
    let source = try BookSourceCodec.decode(fixture.sourceData)
    let roundTripData = try BookSourceCodec.encode(source)
    let roundTrip = try JSONValueCodec.decode(roundTripData)
    let roundTripSource = try BookSourceCodec.decode(roundTripData)
    guard CanonicalJSONComparator.compare(expected: canonicalInput, actual: roundTrip) == .equal else {
      throw ConformanceRunnerError.losslessInvariantViolation
    }
    let stages = try [
      ExecutionStage(stage: .sourceLoad, outcome: .completed),
      ExecutionStage(stage: .sourceValidation, outcome: .completed),
      ExecutionStage(stage: .resultMapping, outcome: .completed),
    ]
    let envelope = ExecutionEnvelope(
      fixtureID: fixture.definition.id,
      engine: ExecutionEngine(
        platform: .ios,
        revision: "conformance-source-format-v1",
        compatibilityProfile: fixture.definition.compatibilityProfile
      ),
      requestPlan: [],
      decode: nil,
      stages: stages,
      result: ExecutionResult(
        type: "book_source_round_trip",
        value: .object([
          "fixture_integrity": .object(["canonical_input": canonicalInput]),
          "portable_known_projection": BookSourceComparisonProjection.portableKnownFields(
            input: source,
            roundTrip: roundTripSource
          ),
          "ios_lossless_extension": .object(["canonical_round_trip": roundTrip]),
        ])
      ),
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
