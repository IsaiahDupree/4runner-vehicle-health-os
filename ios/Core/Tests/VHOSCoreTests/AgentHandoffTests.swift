import Foundation
import Testing

@testable import VHOSCore

@Test func agentHandoffDeniesVehicleAuthority() throws {
  let handshake = GatewayHandshake(
    gatewayID: "gateway-1",
    hardwareRevision: "A1",
    firmwareVersion: "1.0.0",
    firmwareBuildID: "build-1",
    protocolVersion: "1.0.0",
    activeConfigID: "cfg",
    activeConfigVersion: "1.0.0",
    listenOnly: true,
    capabilities: [.evidenceExport],
    otaUploadURL: nil,
    otaMaximumImageBytes: nil
  )
  let health = GatewayHealth(
    observedAt: "2026-08-16T12:00:00Z",
    vehicleMotion: .parked,
    supplyMillivolts: 12_400,
    receivedFrames: 0,
    droppedFrames: 0,
    busErrorCount: 0,
    busOffCount: 0,
    storageFreeBytes: 1,
    captureActive: false,
    listenOnly: true
  )
  let handoff = AgentEvidenceHandoff(
    generatedAt: "2026-08-16T12:00:00Z",
    handshake: handshake,
    health: health,
    experimentResults: []
  )
  let encoded = try handoff.encoded()
  let decoded = try VHOSJSON.decoder().decode(AgentEvidenceHandoff.self, from: encoded)
  #expect(decoded.authority.mayInterpretEvidence)
  #expect(!decoded.authority.mayActivateVehicleExperiment)
  #expect(!decoded.authority.mayEmitRawVehicleFrames)
}
