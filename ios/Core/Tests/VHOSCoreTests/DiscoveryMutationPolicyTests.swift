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

@Test func discoveryRequiresHealthyPersistenceAndStorageHeadroom() throws {
  let template = try DiscoveryMutationPolicy.parkSelectorBootstrapTemplate()

  #expect(
    DiscoveryMutationPolicy.authority(
      for: template,
      context: makeMutationContext(motion: .unknown, captureQueueDroppedRecords: 1)) == nil)
  #expect(
    DiscoveryMutationPolicy.authority(
      for: template,
      context: makeMutationContext(motion: .unknown, captureStorageWriteFailures: 1)) == nil)
  #expect(
    DiscoveryMutationPolicy.authority(
      for: template,
      context: makeMutationContext(
        motion: .unknown,
        storageFreeBytes: DiscoveryMutationPolicy.minimumDiscoveryStorageFreeBytes - 1)) == nil)
  #expect(
    DiscoveryMutationPolicy.authority(
      for: template,
      context: makeMutationContext(
        motion: .unknown,
        storageFreeBytes: DiscoveryMutationPolicy.minimumDiscoveryStorageFreeBytes))
      == .passiveParkSelectorBootstrap)
  #expect(!DiscoveryMutationPolicy.captureWritePathIsHealthy(nil))
  #expect(!DiscoveryMutationPolicy.captureStorageHasHeadroom(nil))
}

@Test func explicitLocalEvidenceScopeCanBypassRecorderTelemetryButNotLiveCANIdentity() throws {
  let template = try DiscoveryMutationPolicy.parkSelectorBootstrapTemplate()
  let context = makeMutationContext(motion: .unknown, includeHealth: false)

  #expect(DiscoveryMutationPolicy.authority(for: template, context: context) == nil)
  #expect(
    DiscoveryMutationPolicy.authority(
      for: template,
      context: context,
      allowLocalEvidenceOnly: true) == .localEvidenceOnly)

  #expect(
    DiscoveryMutationPolicy.authority(
      for: template,
      context: makeMutationContext(motion: .moving),
      allowLocalEvidenceOnly: true) == nil)
  #expect(
    DiscoveryMutationPolicy.authority(
      for: template,
      context: makeMutationContext(motion: .unknown, observationAge: 5.001),
      allowLocalEvidenceOnly: true) == nil)
  #expect(
    DiscoveryMutationPolicy.authority(
      for: template,
      context: makeMutationContext(motion: .unknown, observationGatewayID: "other-gateway"),
      allowLocalEvidenceOnly: true) == nil)
  #expect(
    DiscoveryMutationPolicy.authority(
      for: template,
      context: makeMutationContext(motion: .unknown, observationListenOnly: false),
      allowLocalEvidenceOnly: true) == nil)
  #expect(
    DiscoveryMutationPolicy.authority(
      for: template,
      context: makeMutationContext(motion: .unknown, handshakeListenOnly: false),
      allowLocalEvidenceOnly: true) == nil)
  #expect(
    DiscoveryMutationPolicy.authority(
      for: template,
      context: makeMutationContext(motion: .unknown, includesPassiveCapability: false),
      allowLocalEvidenceOnly: true) == nil)
  #expect(
    DiscoveryMutationPolicy.authority(
      for: template,
      context: makeMutationContext(
        motion: .unknown,
        connectionState: .disconnected,
        includeHealth: false),
      allowLocalEvidenceOnly: true) == nil)
}

@Test func developmentEvidenceLabRelaxesEntryGatesButPreservesLiveEvidenceIntegrity() throws {
  let template = try DiscoveryMutationPolicy.parkSelectorBootstrapTemplate()
  let relaxedContext = makeMutationContext(
    motion: .unknown,
    connectionState: .disconnected,
    includeHealth: false,
    includeHandshake: false,
    includesPassiveCapability: false)

  #if DEBUG
    #expect(DiscoveryMutationPolicy.developmentEvidenceLabAvailable)
    #expect(
      DiscoveryMutationPolicy.authority(
        for: template,
        context: relaxedContext,
        allowDevelopmentEvidenceLab: true) == .developmentEvidenceLab)
    #expect(
      DiscoveryMutationPolicy.authority(
        for: template,
        context: makeMutationContext(
          motion: .unknown,
          observationAge: DiscoveryMutationPolicy.freshnessLimitSeconds + 0.001,
          connectionState: .disconnected,
          includeHealth: false,
          includeHandshake: false),
        allowDevelopmentEvidenceLab: true) == nil)
    #expect(
      DiscoveryMutationPolicy.authority(
        for: template,
        context: makeMutationContext(
          motion: .unknown,
          connectionState: .disconnected,
          includeHealth: false,
          includeHandshake: false,
          includeObservation: false),
        allowDevelopmentEvidenceLab: true) == nil)
    #expect(
      DiscoveryMutationPolicy.authority(
        for: template,
        context: makeMutationContext(
          motion: .unknown,
          connectionState: .disconnected,
          includeHealth: false,
          includeHandshake: false,
          observationListenOnly: false),
        allowDevelopmentEvidenceLab: true) == nil)
    #expect(
      DiscoveryMutationPolicy.authority(
        for: template,
        context: makeMutationContext(motion: .moving),
        allowDevelopmentEvidenceLab: true) == nil)
    #expect(
      DiscoveryMutationPolicy.authority(
        for: template,
        context: makeMutationContext(motion: .unknown, healthListenOnly: false),
        allowDevelopmentEvidenceLab: true) == nil)
    #expect(
      DiscoveryMutationPolicy.authority(
        for: template,
        context: makeMutationContext(motion: .unknown, handshakeListenOnly: false),
        allowDevelopmentEvidenceLab: true) == nil)
    #expect(
      DiscoveryMutationPolicy.authority(
        for: template,
        context: makeMutationContext(
          motion: .unknown,
          observationGatewayID: "conflicting-gateway"),
        allowDevelopmentEvidenceLab: true) == nil)
  #else
    #expect(!DiscoveryMutationPolicy.developmentEvidenceLabAvailable)
    #expect(
      DiscoveryMutationPolicy.authority(
        for: template,
        context: relaxedContext,
        allowDevelopmentEvidenceLab: true) == nil)
  #endif
}

@Test func discoveryAuthorityCapabilitiesFailClosedForAppLocalScopes() {
  #expect(DiscoveryMutationAuthority.parked.permitsGatewayCaptureControl)
  #expect(DiscoveryMutationAuthority.passiveParkSelectorBootstrap.permitsGatewayCaptureControl)
  #expect(!DiscoveryMutationAuthority.localEvidenceOnly.permitsGatewayCaptureControl)
  #expect(!DiscoveryMutationAuthority.developmentEvidenceLab.permitsGatewayCaptureControl)
  #expect(!DiscoveryMutationAuthority.parked.requiresOwnerSafetyAcknowledgement)
  #expect(DiscoveryMutationAuthority.localEvidenceOnly.requiresOwnerSafetyAcknowledgement)
  #expect(DiscoveryMutationAuthority.developmentEvidenceLab.requiresOwnerSafetyAcknowledgement)
  #expect(
    DiscoveryMutationAuthority.passiveParkSelectorBootstrap.permitsContinuation(with: .parked))
  #expect(
    !DiscoveryMutationAuthority.localEvidenceOnly.permitsContinuation(
      with: .developmentEvidenceLab))
  #expect(
    !DiscoveryMutationAuthority.developmentEvidenceLab.permitsContinuation(
      with: .localEvidenceOnly))
  #expect(
    DiscoveryMutationAuthority.developmentEvidenceLab.permitsContinuation(
      with: .developmentEvidenceLab))
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
      context: makeMutationContext(motion: .unknown),
      allowLocalEvidenceOnly: true) == nil)
  #expect(
    DiscoveryMutationPolicy.authority(
      for: template,
      context: makeMutationContext(motion: .unknown),
      allowDevelopmentEvidenceLab: true) == nil)
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
  #expect(
    DiscoveryMutationPolicy.authority(
      for: altered,
      context: makeMutationContext(
        motion: .unknown,
        connectionState: .disconnected,
        includeHealth: false,
        includeHandshake: false),
      allowDevelopmentEvidenceLab: true) == nil)
}

@Test func appLocalSafetyAcknowledgementMustBeExplicitCurrentAndPrecedeRunStart() {
  #expect(
    DiscoveryMutationPolicy.ownerSafetyAcknowledgementIsValid(
      "2026-08-24T20:59:59Z",
      runStartedAt: "2026-08-24T21:00:00Z",
      required: true))
  #expect(
    DiscoveryMutationPolicy.ownerSafetyAcknowledgementIsValid(
      "2026-08-24T21:00:00Z",
      runStartedAt: "2026-08-24T21:00:00Z",
      required: true))
  #expect(
    !DiscoveryMutationPolicy.ownerSafetyAcknowledgementIsValid(
      nil,
      runStartedAt: "2026-08-24T21:00:00Z",
      required: true))
  #expect(
    !DiscoveryMutationPolicy.ownerSafetyAcknowledgementIsValid(
      "2026-08-24T21:00:01Z",
      runStartedAt: "2026-08-24T21:00:00Z",
      required: true))
  #expect(
    !DiscoveryMutationPolicy.ownerSafetyAcknowledgementIsValid(
      "2026-08-24T20:54:59Z",
      runStartedAt: "2026-08-24T21:00:00Z",
      required: true))
  #expect(
    DiscoveryMutationPolicy.ownerSafetyAcknowledgementIsValid(
      nil,
      runStartedAt: "not-needed-for-parked",
      required: false))
  #expect(
    !DiscoveryMutationPolicy.ownerSafetyAcknowledgementIsValid(
      "2026-08-24T21:00:00Z",
      runStartedAt: "2026-08-24T21:00:00Z",
      required: false))
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

@Test func bootstrapSelectorDwellUsesTheGatewayMonotonicClock() {
  let requirements = DiscoveryMutationPolicy.parkSelectorBootstrapMarkerRequirements
  let minimum = DiscoveryMutationPolicy.minimumParkSelectorDwellMicroseconds

  #expect(
    DiscoveryMutationPolicy.parkSelectorBootstrapDwellRemainingMicroseconds(
      after: nil,
      lastMarkerMonotonicMicroseconds: nil,
      currentMonotonicMicroseconds: 10) == 0)
  #expect(
    DiscoveryMutationPolicy.parkSelectorBootstrapDwellRemainingMicroseconds(
      after: requirements[0],
      lastMarkerMonotonicMicroseconds: 10,
      currentMonotonicMicroseconds: 10) == 0)
  #expect(
    DiscoveryMutationPolicy.parkSelectorBootstrapDwellRemainingMicroseconds(
      after: requirements[1],
      lastMarkerMonotonicMicroseconds: 1_000_000,
      currentMonotonicMicroseconds: 1_000_000) == minimum)
  #expect(
    DiscoveryMutationPolicy.parkSelectorBootstrapDwellRemainingMicroseconds(
      after: requirements[1],
      lastMarkerMonotonicMicroseconds: 1_000_000,
      currentMonotonicMicroseconds: 5_000_000) == 4_000_000)
  #expect(
    DiscoveryMutationPolicy.parkSelectorBootstrapDwellRemainingMicroseconds(
      after: requirements[1],
      lastMarkerMonotonicMicroseconds: 1_000_000,
      currentMonotonicMicroseconds: 9_000_000) == 0)
  #expect(
    DiscoveryMutationPolicy.parkSelectorBootstrapDwellRemainingMicroseconds(
      after: requirements[1],
      lastMarkerMonotonicMicroseconds: 9_000_000,
      currentMonotonicMicroseconds: 1_000_000) == minimum)
  #expect(
    DiscoveryMutationPolicy.parkSelectorBootstrapDwellRemainingMicroseconds(
      after: requirements[1],
      lastMarkerMonotonicMicroseconds: nil,
      currentMonotonicMicroseconds: 9_000_000) == minimum)
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
  observationSessionID: UInt32 = 42,
  storageFreeBytes: UInt64 = 1_000_000,
  captureQueueDroppedRecords: UInt64? = 0,
  captureStorageWriteFailures: UInt64? = 0,
  connectionState: GatewayConnectionState = .vhosConnected,
  includeHealth: Bool = true,
  includeHandshake: Bool = true,
  includeObservation: Bool = true,
  handshakeListenOnly: Bool = true,
  healthListenOnly: Bool = true,
  observationListenOnly: Bool = true,
  includesPassiveCapability: Bool = true,
  observationGatewayID: String? = nil
) -> DiscoveryMutationContext {
  let gatewayID = "esp32-9454c5b08d14"
  let handshake = includeHandshake ? GatewayHandshake(
    gatewayID: gatewayID,
    hardwareRevision: "MRDIY-ESP32-V1.3",
    firmwareVersion: "0.1.0-dev.34",
    firmwareBuildID: "test-build",
    protocolVersion: "1.0.0",
    activeConfigID: "toyota-4runner-2005",
    activeConfigVersion: "0.1.0",
    listenOnly: handshakeListenOnly,
    capabilities: includesPassiveCapability ? [.passiveCapture] : [],
    otaUploadURL: nil,
    otaMaximumImageBytes: nil) : nil
  let health = includeHealth ? GatewayHealth(
    observedAt: "monotonic_us:1000000",
    vehicleMotion: motion,
    supplyMillivolts: nil,
    receivedFrames: 100,
    droppedFrames: 0,
    busErrorCount: 0,
    busOffCount: 0,
    storageFreeBytes: storageFreeBytes,
    captureActive: true,
    listenOnly: healthListenOnly,
    captureQueueDroppedRecords: captureQueueDroppedRecords,
    captureSessionID: 42,
    captureStorageWriteFailures: captureStorageWriteFailures) : nil
  let observation = includeObservation ? PassiveCANObservation(
    gatewayID: observationGatewayID ?? gatewayID,
    sessionID: observationSessionID,
    sourceSequence: 99,
    monotonicMicroseconds: 1_000_000,
    bitrateBps: 500_000,
    identifier: 0x2C4,
    extended: false,
    remoteRequest: false,
    listenOnly: observationListenOnly,
    dataLength: 8,
    data: [0, 0, 0, 0, 0, 0, 0, 0],
    evidenceSource: "ble-live",
    ingestedAt: "2026-08-22T14:42:25Z") : nil
  return DiscoveryMutationContext(
    connectionState: connectionState,
    handshake: handshake,
    health: health,
    healthAgeSeconds: healthAge,
    observation: observation,
    observationAgeSeconds: observationAge,
    hasCurrentParkedAuthority: parkedAuthority)
}
