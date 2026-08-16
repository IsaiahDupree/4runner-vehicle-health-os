import Foundation
import Testing

@testable import VHOSCore

private let discoveryCapabilities: Set<GatewayCapability> = [
  .passiveCapture, .signedExperimentPlan, .allowlistedDiagnosticRead,
]

@Test func passiveDiscoveryRequiresParkedApprovedListenOnlyGateway() throws {
  let plan = ProtocolDiscoveryPlan.passiveCANBaseline(createdAt: "2026-08-16T12:00:00Z")
  let safe = DiscoverySafetyContext(
    vehicleMotion: .parked,
    explicitUserApproval: true,
    captureAlreadyActive: false,
    gatewayListenOnly: true,
    capabilities: discoveryCapabilities
  )
  try plan.validateSafety(in: safe)

  let moving = DiscoverySafetyContext(
    vehicleMotion: .moving,
    explicitUserApproval: true,
    captureAlreadyActive: false,
    gatewayListenOnly: true,
    capabilities: discoveryCapabilities
  )
  #expect(throws: DiscoverySafetyError.vehicleNotParked) { try plan.validateSafety(in: moving) }
}

@Test func legacyDiscoveryIsConstrainedToSemanticAllowlist() throws {
  let valid = ProtocolDiscoveryPlan.legacyInterpreterBaseline(createdAt: "2026-08-16T12:00:00Z")
  let context = DiscoverySafetyContext(
    vehicleMotion: .parked,
    explicitUserApproval: true,
    captureAlreadyActive: false,
    gatewayListenOnly: true,
    capabilities: discoveryCapabilities
  )
  try valid.validateSafety(in: context)

  let invalid = ProtocolDiscoveryPlan(
    createdAt: "2026-08-16T12:00:00Z",
    candidates: [
      DiscoveryCandidate(
        protocolID: .iso9141,
        phase: .interpreterRead,
        boundedWindowSeconds: 10,
        allowlistEntryID: "raw.can.transmit"
      )
    ]
  )
  #expect(throws: DiscoverySafetyError.interpreterAllowlistInvalid) {
    try invalid.validateSafety(in: context)
  }
}
