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
