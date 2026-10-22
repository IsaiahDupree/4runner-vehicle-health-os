import Foundation
import Testing

@testable import VHOSCore

@Test func outboxEnvelopeBindsPayloadAndDeniesVehicleAuthority() throws {
  let payload = Data("immutable evidence".utf8)
  let envelope = try EvidenceOutboxEnvelope(
    packageID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
    createdAt: "2026-08-18T12:00:00Z",
    contentType: "application/vnd.vhos.evidence-sync+zip",
    payload: payload
  )
  try envelope.validate(payload: payload)
  #expect(envelope.byteCount == payload.count)
  #expect(envelope.sha256.count == 64)
  #expect(envelope.authority.mayInterpret)
  #expect(!envelope.authority.mayActivateExperiment)
  #expect(!envelope.authority.mayEmitVehicleFrames)
}

@Test func outboxEnvelopeRejectsPayloadSubstitution() throws {
  let envelope = try EvidenceOutboxEnvelope(
    contentType: "application/vnd.vhos.agent-evidence+json",
    payload: Data("first".utf8)
  )
  #expect(throws: EvidenceOutboxError.invalidEnvelope) {
    try envelope.validate(payload: Data("second".utf8))
  }
}

@Test func discoveryDraftOutboxEnvelopeRoundTripsWithNoVehicleAuthority() throws {
  let payload = Data("{\"contract\":\"vhos.discovery-draft-evidence\"}".utf8)
  let envelope = try EvidenceOutboxEnvelope(
    packageID: UUID(uuidString: "22222222-3333-4444-8555-666666666666")!,
    createdAt: "2026-08-22T18:00:00Z",
    contentType: "application/vnd.vhos.discovery-draft-evidence+json",
    payload: payload
  )

  let encoded = try VHOSJSON.encoder().encode(envelope)
  let decoded = try VHOSJSON.decoder().decode(EvidenceOutboxEnvelope.self, from: encoded)
  try decoded.validate(payload: payload)

  #expect(decoded == envelope)
  #expect(decoded.contentType == "application/vnd.vhos.discovery-draft-evidence+json")
  #expect(decoded.authority.mayInterpret)
  #expect(decoded.authority.mayProposeExperiment)
  #expect(!decoded.authority.mayActivateExperiment)
  #expect(!decoded.authority.mayEmitVehicleFrames)
}

@Test func outboxEnvelopeRejectsLeapSecondAtCreationAndAfterDecode() throws {
  let payload = Data("immutable evidence".utf8)
  #expect(throws: EvidenceOutboxError.invalidEnvelope) {
    _ = try EvidenceOutboxEnvelope(
      createdAt: "2026-08-22T18:00:60Z",
      contentType: "application/vnd.vhos.evidence-sync+zip",
      payload: payload)
  }

  let valid = try EvidenceOutboxEnvelope(
    createdAt: "2026-08-22T18:00:59Z",
    contentType: "application/vnd.vhos.evidence-sync+zip",
    payload: payload)
  var object = try #require(
    JSONSerialization.jsonObject(with: VHOSJSON.encoder().encode(valid)) as? [String: Any])
  object["created_at"] = "2026-08-22T18:00:60Z"
  let decoded = try VHOSJSON.decoder().decode(
    EvidenceOutboxEnvelope.self,
    from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))

  #expect(throws: EvidenceOutboxError.invalidEnvelope) {
    try decoded.validate(payload: payload)
  }
}
