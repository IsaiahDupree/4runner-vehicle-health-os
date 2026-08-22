import Foundation
import Testing

@testable import VHOSCore

@Test func deployedGatewayHealthPreservesCaptureSessionLineage() throws {
  let payload = Data(
    """
    {"bus_error_count":0,"bus_off_count":0,"capture_active":true,"capture_observed_frames":4895,"capture_retained_records":336,"capture_session_id":122561546,"contract":"gateway.health","contract_version":"1.0.0","dropped_frames":0,"listen_only":true,"observed_at":"monotonic_us:42","received_frames":4895,"storage_free_bytes":890000,"supply_millivolts":null,"vehicle_motion":"UNKNOWN"}
    """.utf8)

  let health = try VHOSJSON.decoder().decode(GatewayHealth.self, from: payload)

  #expect(health.captureObservedFrames == 4_895)
  #expect(health.captureRetainedRecords == 336)
  #expect(health.captureSessionID == 122_561_546)
}

@Test func parkSelectorBootstrapAllowsOnlyFreshSessionBoundPassiveEvidence() throws {
  let template = try DiscoveryMutationPolicy.parkSelectorBootstrapTemplate()
  let context = makeMutationContext(motion: .unknown)

  #expect(
    DiscoveryMutationPolicy.authority(for: template, context: context)
      == .passiveParkSelectorBootstrap)
  #expect(!context.hasCurrentParkedAuthority)

  #expect(
    DiscoveryMutationPolicy.authority(
      for: template,
      context: makeMutationContext(motion: .unknown, healthAge: 5.001)) == nil)
  #expect(
    DiscoveryMutationPolicy.authority(
      for: template,
      context: makeMutationContext(motion: .unknown, observationAge: 5.001)) == nil)
  #expect(
    DiscoveryMutationPolicy.authority(
      for: template,
      context: makeMutationContext(motion: .unknown, observationSessionID: 43)) == nil)
  #expect(
    DiscoveryMutationPolicy.authority(
      for: template,
      context: makeMutationContext(motion: .moving)) == nil)
}

@Test func unknownMotionDoesNotOpenArbitraryDiscoveryTemplate() throws {
  let template = try TestTemplate(
    id: "discovery.transmission.not-the-bootstrap",
    templateVersion: "1.0.0",
    title: "Unknown motion test",
    category: .transmission,
    hypothesis: "This must remain blocked even though it requests passive capture.",
    requiredVehicleMotion: .unknown,
    safetyInstructions: ["Remain stationary."],
    requiredGatewayCapabilities: [.passiveCapture],
    targetedValidationRequirements: [.targetVehicleCapture],
    steps: [
      try TestStep(
        id: "discovery.transmission.not-the-bootstrap.step.1",
        sequence: 1,
        instruction: "Mark an event.",
        expectedMarkerKind: .custom)
    ])

  #expect(
    DiscoveryMutationPolicy.authority(
      for: template,
      context: makeMutationContext(motion: .unknown)) == nil)
}

@Test func bootstrapCannotReuseTheCanonicalIdentityWithAlteredSafetyText() throws {
  let canonical = try DiscoveryMutationPolicy.parkSelectorBootstrapTemplate()
  let altered = try TestTemplate(
    id: canonical.id,
    templateVersion: canonical.templateVersion,
    title: canonical.title,
    category: canonical.category,
    hypothesis: canonical.hypothesis,
    requiredVehicleMotion: canonical.requiredVehicleMotion,
    safetyInstructions: ["Remain near the vehicle."],
    requiredGatewayCapabilities: canonical.requiredGatewayCapabilities,
    targetedValidationRequirements: canonical.targetedValidationRequirements,
    steps: canonical.steps)

  #expect(
    DiscoveryMutationPolicy.authority(
      for: altered,
      context: makeMutationContext(motion: .unknown)) == nil)
}

@Test func bootstrapMarkersAreExactOrderedAndComplete() {
  let requirements = DiscoveryMutationPolicy.parkSelectorBootstrapMarkerRequirements
  #expect(DiscoveryMutationPolicy.nextParkSelectorBootstrapMarker(after: []) == requirements[0])
  #expect(
    DiscoveryMutationPolicy.nextParkSelectorBootstrapMarker(after: [requirements[0]])
      == requirements[1])
  #expect(!DiscoveryMutationPolicy.parkSelectorBootstrapIsComplete(Array(requirements.dropLast())))
  #expect(DiscoveryMutationPolicy.parkSelectorBootstrapIsComplete(requirements))

  let reordered = [requirements[1], requirements[0]]
  #expect(DiscoveryMutationPolicy.nextParkSelectorBootstrapMarker(after: reordered) == nil)
  #expect(!DiscoveryMutationPolicy.parkSelectorBootstrapIsComplete(reordered))

  let injected = [
    requirements[0],
    DiscoveryOrderedMarkerRequirement(kind: .custom, label: "EVENT"),
  ]
  #expect(DiscoveryMutationPolicy.nextParkSelectorBootstrapMarker(after: injected) == nil)
  #expect(!DiscoveryMutationPolicy.parkSelectorBootstrapIsComplete(injected))
}

@Test func canonicalBootstrapCanFinishIfParkAuthorityArrivesDuringTheRun() throws {
  let template = try DiscoveryMutationPolicy.parkSelectorBootstrapTemplate()
  #expect(
    DiscoveryMutationPolicy.authority(
      for: template,
      context: makeMutationContext(motion: .parked, parkedAuthority: true)) == .parked)
}

@Test func bootstrapRunIdentityRequiresExactTemplateVersion() throws {
  let template = try DiscoveryMutationPolicy.parkSelectorBootstrapTemplate()
  #expect(
    DiscoveryMutationPolicy.testRunIdentityMatches(
      template: template,
      templateID: template.id,
      templateVersion: template.templateVersion))
  #expect(
    !DiscoveryMutationPolicy.testRunIdentityMatches(
      template: template,
      templateID: template.id,
      templateVersion: "0.9.0"))
  #expect(
    !DiscoveryMutationPolicy.testRunIdentityMatches(
      template: template,
      templateID: "discovery.transmission.other",
      templateVersion: template.templateVersion))
}

@Test func parkedDiscoveryRetainsExistingFreshAuthorityGate() throws {
  let template = try TestTemplate(
    id: "discovery.brakes.parked-regression",
    templateVersion: "1.0.0",
    title: "Parked brake test",
    category: .brakes,
    hypothesis: "The established deterministic PARKED path remains available.",
    requiredVehicleMotion: .parked,
    safetyInstructions: ["Keep the vehicle in Park."],
    requiredGatewayCapabilities: [.passiveCapture],
    targetedValidationRequirements: [.targetVehicleCapture],
    steps: [
      try TestStep(
        id: "discovery.brakes.parked-regression.step.1",
        sequence: 1,
        instruction: "Press the brake.",
        expectedMarkerKind: .brakePressed)
    ])

  #expect(
    DiscoveryMutationPolicy.authority(
      for: template,
      context: makeMutationContext(motion: .parked, parkedAuthority: true)) == .parked)
  #expect(
    DiscoveryMutationPolicy.authority(
      for: template,
      context: makeMutationContext(motion: .parked, parkedAuthority: false)) == nil)
  #expect(
    DiscoveryMutationPolicy.authority(
      for: template,
      context: makeMutationContext(motion: .unknown, parkedAuthority: false)) == nil)
}

private func makeMutationContext(
  motion: VehicleMotion,
  parkedAuthority: Bool = false,
  healthAge: TimeInterval = 0.5,
  observationAge: TimeInterval = 0.25,
  observationSessionID: UInt32 = 42
) -> DiscoveryMutationContext {
  let gatewayID = "esp32-9454c5b08d14"
  let handshake = GatewayHandshake(
    gatewayID: gatewayID,
    hardwareRevision: "MRDIY-ESP32-V1.3",
    firmwareVersion: "0.1.0-dev.34",
    firmwareBuildID: "test-build",
    protocolVersion: "1.0.0",
    activeConfigID: "toyota-4runner-2005",
    activeConfigVersion: "0.1.0",
    listenOnly: true,
    capabilities: [.passiveCapture],
    otaUploadURL: nil,
    otaMaximumImageBytes: nil)
  let health = GatewayHealth(
    observedAt: "monotonic_us:1000000",
    vehicleMotion: motion,
    supplyMillivolts: nil,
    receivedFrames: 100,
    droppedFrames: 0,
    busErrorCount: 0,
    busOffCount: 0,
    storageFreeBytes: 1_000_000,
    captureActive: true,
    listenOnly: true,
    captureSessionID: 42)
  let observation = PassiveCANObservation(
    gatewayID: gatewayID,
    sessionID: observationSessionID,
    sourceSequence: 99,
    monotonicMicroseconds: 1_000_000,
    bitrateBps: 500_000,
    identifier: 0x2C4,
    extended: false,
    remoteRequest: false,
    listenOnly: true,
    dataLength: 8,
    data: [0, 0, 0, 0, 0, 0, 0, 0],
    evidenceSource: "ble-live",
    ingestedAt: "2026-08-22T14:42:25Z")
  return DiscoveryMutationContext(
    connectionState: .vhosConnected,
    handshake: handshake,
    health: health,
    healthAgeSeconds: healthAge,
    observation: observation,
    observationAgeSeconds: observationAge,
    hasCurrentParkedAuthority: parkedAuthority)
}
