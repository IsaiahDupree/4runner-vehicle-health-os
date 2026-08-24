import Foundation

public enum DiscoveryMutationAuthority: String, Equatable, Sendable {
  case parked = "PARKED"
  case passiveParkSelectorBootstrap = "PASSIVE_PARK_SELECTOR_BOOTSTRAP"
}

public struct DiscoveryOrderedMarkerRequirement: Equatable, Sendable {
  public let kind: DiscoveryMarkerKind
  public let label: String

  public init(kind: DiscoveryMarkerKind, label: String) {
    self.kind = kind
    self.label = label
  }
}

public struct DiscoveryMutationContext: Equatable, Sendable {
  public let connectionState: GatewayConnectionState
  public let handshake: GatewayHandshake?
  public let health: GatewayHealth?
  public let healthAgeSeconds: TimeInterval?
  public let observation: PassiveCANObservation?
  public let observationAgeSeconds: TimeInterval?
  public let hasCurrentParkedAuthority: Bool

  public init(
    connectionState: GatewayConnectionState,
    handshake: GatewayHandshake?,
    health: GatewayHealth?,
    healthAgeSeconds: TimeInterval?,
    observation: PassiveCANObservation?,
    observationAgeSeconds: TimeInterval?,
    hasCurrentParkedAuthority: Bool
  ) {
    self.connectionState = connectionState
    self.handshake = handshake
    self.health = health
    self.healthAgeSeconds = healthAgeSeconds
    self.observation = observation
    self.observationAgeSeconds = observationAgeSeconds
    self.hasCurrentParkedAuthority = hasCurrentParkedAuthority
  }
}

/// Fail-closed authority for app-local Discovery evidence mutations.
///
/// The bootstrap exception is intentionally narrow: it permits only passive, append-only event
/// markers needed to discover the Park-selector signal. It never represents PARKED authority and
/// must not be reused for OTA, active diagnostics, or arbitrary engineering controls.
public enum DiscoveryMutationPolicy {
  public static let parkSelectorBootstrapTemplateID =
    "discovery.transmission.selector-bootstrap"
  public static let freshnessLimitSeconds: TimeInterval = 5
  /// Minimum labeled dwell after each selector-position marker before the next selector marker.
  ///
  /// This uses the gateway monotonic clock, not iPhone wall time, so an app suspension, clock
  /// correction, or reconnect cannot manufacture a completed hold interval.
  public static let minimumParkSelectorDwellMicroseconds: UInt64 = 8_000_000
  /// Reserve enough flash for a bounded field test plus its recorder metadata.
  ///
  /// The gateway reports this value from the same storage used by the retained CAN recorder.
  /// A low-but-nonzero value is not sufficient evidence that a complete experiment can be
  /// persisted. The August 22 field return began a selector test with only 67,791 bytes free;
  /// write failures were already cumulative and the retained session could not be recovered
  /// from the normal capture archive.
  public static let minimumDiscoveryStorageFreeBytes: UInt64 = 128 * 1_024
  public static let parkSelectorBootstrapMarkerRequirements: [DiscoveryOrderedMarkerRequirement] = [
    .init(kind: .custom, label: "SAFETY SETUP CONFIRMED"),
    .init(kind: .selectorPark, label: "SELECTOR: PARK"),
    .init(kind: .selectorReverse, label: "SELECTOR: REVERSE"),
    .init(kind: .selectorNeutral, label: "SELECTOR: NEUTRAL"),
    .init(kind: .selectorDrive, label: "SELECTOR: DRIVE"),
    .init(kind: .selectorPark, label: "SELECTOR: PARK (RETURN)"),
  ]

  public static func authority(
    for template: TestTemplate,
    context: DiscoveryMutationContext
  ) -> DiscoveryMutationAuthority? {
    guard (try? template.validateContract()) != nil,
      context.connectionState == .vhosConnected,
      let handshake = context.handshake,
      let health = context.health,
      let healthAge = context.healthAgeSeconds,
      let observation = context.observation,
      let observationAge = context.observationAgeSeconds,
      (0...freshnessLimitSeconds).contains(healthAge),
      (0...freshnessLimitSeconds).contains(observationAge),
      handshake.listenOnly, health.listenOnly, observation.listenOnly,
      health.captureActive,
      captureWritePathIsHealthy(health),
      captureStorageHasHeadroom(health),
      template.requiredGatewayCapabilities.allSatisfy(handshake.capabilities.contains),
      observation.gatewayID == handshake.gatewayID,
      let captureSessionID = health.captureSessionID,
      observation.sessionID == captureSessionID
    else { return nil }

    if template.requiredVehicleMotion == .parked,
      context.hasCurrentParkedAuthority,
      health.vehicleMotion == .parked
    {
      return .parked
    }

    guard isCanonicalParkSelectorBootstrap(template) else { return nil }
    if !context.hasCurrentParkedAuthority, health.vehicleMotion == .unknown {
      return .passiveParkSelectorBootstrap
    }
    if context.hasCurrentParkedAuthority, health.vehicleMotion == .parked {
      return .parked
    }
    return nil
  }

  /// Discovery is an evidence-producing workflow, so missing persistence telemetry fails closed.
  public static func captureWritePathIsHealthy(_ health: GatewayHealth?) -> Bool {
    guard let health,
      let queueDroppedRecords = health.captureQueueDroppedRecords,
      let storageWriteFailures = health.captureStorageWriteFailures
    else { return false }
    return queueDroppedRecords == 0 && storageWriteFailures == 0
  }

  /// A recorder with too little remaining flash may still stream live frames, but it cannot be
  /// trusted to retain the complete experiment needed for replay and candidate validation.
  public static func captureStorageHasHeadroom(_ health: GatewayHealth?) -> Bool {
    guard let freeBytes = health?.storageFreeBytes else { return false }
    return freeBytes >= minimumDiscoveryStorageFreeBytes
  }

  public static func nextParkSelectorBootstrapMarker(
    after recorded: [DiscoveryOrderedMarkerRequirement]
  ) -> DiscoveryOrderedMarkerRequirement? {
    guard recorded.count < parkSelectorBootstrapMarkerRequirements.count,
      Array(parkSelectorBootstrapMarkerRequirements.prefix(recorded.count)) == recorded
    else { return nil }
    return parkSelectorBootstrapMarkerRequirements[recorded.count]
  }

  public static func parkSelectorBootstrapIsComplete(
    _ recorded: [DiscoveryOrderedMarkerRequirement]
  ) -> Bool {
    recorded == parkSelectorBootstrapMarkerRequirements
  }

  /// Remaining gateway-monotonic dwell required before another selector marker may be appended.
  /// The initial safety-confirmation marker deliberately has no dwell; every physical selector
  /// marker after it must remain in place for the full interval before the next transition or the
  /// immutable test-run end.
  public static func parkSelectorBootstrapDwellRemainingMicroseconds(
    after lastRecorded: DiscoveryOrderedMarkerRequirement?,
    lastMarkerMonotonicMicroseconds: UInt64?,
    currentMonotonicMicroseconds: UInt64
  ) -> UInt64 {
    guard let lastRecorded, lastRecorded.kind != .custom else { return 0 }
    guard let lastMarkerMonotonicMicroseconds,
      currentMonotonicMicroseconds >= lastMarkerMonotonicMicroseconds
    else { return minimumParkSelectorDwellMicroseconds }
    let elapsed = currentMonotonicMicroseconds - lastMarkerMonotonicMicroseconds
    return elapsed >= minimumParkSelectorDwellMicroseconds
      ? 0 : minimumParkSelectorDwellMicroseconds - elapsed
  }

  public static func testRunIdentityMatches(
    template: TestTemplate,
    templateID: String,
    templateVersion: String
  ) -> Bool {
    template.id == templateID && template.templateVersion == templateVersion
  }

  public static func parkSelectorBootstrapTemplate() throws -> TestTemplate {
    let labels: [(String, DiscoveryMarkerKind)] = [
      ("Confirm wheels chocked, parking brake set, engine OFF, ignition ON", .custom),
      ("Move selector to PARK and hold", .selectorPark),
      ("With foot brake held, move selector to REVERSE and hold", .selectorReverse),
      ("Move selector to NEUTRAL and hold", .selectorNeutral),
      ("Move selector to DRIVE and hold", .selectorDrive),
      ("Return selector to PARK and hold", .selectorPark),
    ]
    let steps = try labels.enumerated().map { index, item in
      try TestStep(
        id: "discovery.transmission.selector-bootstrap.step.\(index + 1)",
        sequence: index + 1,
        instruction: item.0,
        suggestedDurationSeconds: index == 0 ? nil : 8,
        expectedMarkerKind: item.1)
    }
    return try TestTemplate(
      id: parkSelectorBootstrapTemplateID,
      templateVersion: "1.1.0",
      title: "Park / Selector Bootstrap",
      category: .transmission,
      hypothesis:
        "Collect labeled passive CAN evidence for P, R, N, and D so a deterministic Park signal can be discovered and independently validated.",
      requiredVehicleMotion: .unknown,
      safetyInstructions: [
        "Use level ground. Chock the wheels, set the parking brake, keep the engine OFF, turn ignition ON, and hold the foot brake while moving the selector. This evidence-only test never declares PARKED and never unlocks OTA or active diagnostics."
      ],
      requiredGatewayCapabilities: [.passiveCapture],
      targetedValidationRequirements: [
        .targetVehicleCapture, .repeatabilityAcrossControlledTests,
        .independentCorroboration, .goldenReplay,
      ],
      steps: steps)
  }

  private static func isCanonicalParkSelectorBootstrap(_ template: TestTemplate) -> Bool {
    guard let canonical = try? parkSelectorBootstrapTemplate() else { return false }
    return template == canonical
  }
}
