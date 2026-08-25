import Foundation

public enum DiscoveryMutationAuthority: String, Codable, Equatable, Sendable {
  case parked = "PARKED"
  case passiveParkSelectorBootstrap = "PASSIVE_PARK_SELECTOR_BOOTSTRAP"
  /// Explicit, owner-acknowledged scope for app-local, append-only selector evidence.
  ///
  /// This value is deliberately not PARKED authority. Callers must never reuse it for OTA,
  /// diagnostic transmission, gateway capture control, arbitrary CAN writes, or vehicle control.
  case localEvidenceOnly = "LOCAL_EVIDENCE_ONLY"
  /// Debug-build-only acquisition scope that relaxes Discovery entry/readiness gates while
  /// retaining real, listen-only CAN lineage.
  ///
  /// This value is persisted so development evidence can never be mistaken for normal local
  /// acquisition or PARKED authority. Release builds may decode existing records, but the policy
  /// cannot issue this authority outside a Debug build.
  case developmentEvidenceLab = "DEVELOPMENT_EVIDENCE_LAB"
  /// Debug-build-only authority for an app-local evidence workspace.
  ///
  /// Unlike `developmentEvidenceLab`, this scope is not a live-acquisition safety exception. It
  /// exists so developers can import, replay, label, mark, and analyze already-saved or currently
  /// observed passive evidence without first manufacturing connection, recorder, freshness,
  /// handshake, or PARKED state. Its raw value is the immutable provenance classification: any
  /// artifact created under this scope must remain visibly DEBUG/UNVERIFIED.
  ///
  /// Release builds may decode persisted evidence carrying this value, but cannot issue or
  /// continue the authority.
  case debugUnverified = "DEBUG_UNVERIFIED"

  /// App-local evidence scopes are permanently ineligible for gateway commands and authority
  /// promotion, even if recorder health or a PARKED report appears later.
  public var isAppLocalEvidenceOnly: Bool {
    self == .localEvidenceOnly || self == .developmentEvidenceLab || self == .debugUnverified
  }

  /// Positive capability allowlist for capture-control commands. Adding a future authority case
  /// fails closed until this exhaustive switch is deliberately updated.
  public var permitsGatewayCaptureControl: Bool {
    switch self {
    case .parked, .passiveParkSelectorBootstrap:
      true
    case .localEvidenceOnly, .developmentEvidenceLab, .debugUnverified:
      false
    }
  }

  public var requiresOwnerSafetyAcknowledgement: Bool {
    switch self {
    case .localEvidenceOnly, .developmentEvidenceLab:
      true
    case .parked, .passiveParkSelectorBootstrap, .debugUnverified:
      false
    }
  }

  /// Only deterministic gateway PARKED authority may claim PARKED state. App-local evidence
  /// scopes never inherit this merely because a label or candidate resembles a selector signal.
  public var claimsParkedAuthority: Bool { self == .parked }

  /// Acquisition scope alone is never sufficient to promote a signal. Promotion remains behind
  /// the independent validation/reviewer evidence contract, and DEBUG_UNVERIFIED is permanently
  /// ineligible.
  public var permitsSignalPromotion: Bool { false }

  /// Positive allowlist for the Debug-only, app-local evidence workspace. All vehicle-side or
  /// authority-escalating operations are represented explicitly and denied by omission.
  public func permitsEvidenceWorkspaceOperation(
    _ operation: DiscoveryEvidenceWorkspaceOperation
  ) -> Bool {
    guard self == .debugUnverified else { return false }
    #if DEBUG
      return switch operation {
      case .importPassiveEvidence, .replayPassiveEvidence, .appendLabel,
        .appendEventMarker, .analyzeCandidate:
        true
      case .gatewayCommand, .gatewayCaptureControl, .ota, .diagnosticRequest, .canWrite,
        .vehicleControl, .assertParkedAuthority, .promoteSignal:
        false
      }
    #else
      return false
    #endif
  }

  /// Whether a fresh policy result may continue a run sealed with this acquisition scope.
  /// App-local scopes require an exact match. The narrow passive bootstrap may continue if the
  /// stronger deterministic PARKED result arrives, but its persisted acquisition scope and
  /// command permissions remain unchanged.
  public func permitsContinuation(with current: DiscoveryMutationAuthority?) -> Bool {
    switch self {
    case .parked:
      current == .parked
    case .passiveParkSelectorBootstrap:
      current == .passiveParkSelectorBootstrap || current == .parked
    case .localEvidenceOnly:
      current == .localEvidenceOnly
    case .developmentEvidenceLab, .debugUnverified:
      #if DEBUG
        current == self
      #else
        false
      #endif
    }
  }
}

/// Complete action surface considered by the app-local Debug evidence workspace.
///
/// Keeping denied vehicle-side operations in the same `CaseIterable` enum lets tests prove that
/// adding a new operation fails closed until the positive allowlist is deliberately updated.
public enum DiscoveryEvidenceWorkspaceOperation: String, Codable, CaseIterable, Sendable {
  case importPassiveEvidence = "IMPORT_PASSIVE_EVIDENCE"
  case replayPassiveEvidence = "REPLAY_PASSIVE_EVIDENCE"
  case appendLabel = "APPEND_LABEL"
  case appendEventMarker = "APPEND_EVENT_MARKER"
  case analyzeCandidate = "ANALYZE_CANDIDATE"
  case gatewayCommand = "GATEWAY_COMMAND"
  case gatewayCaptureControl = "GATEWAY_CAPTURE_CONTROL"
  case ota = "OTA"
  case diagnosticRequest = "DIAGNOSTIC_REQUEST"
  case canWrite = "CAN_WRITE"
  case vehicleControl = "VEHICLE_CONTROL"
  case assertParkedAuthority = "ASSERT_PARKED_AUTHORITY"
  case promoteSignal = "PROMOTE_SIGNAL"
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
  /// A safety confirmation arms one app-local run. Its timestamp must be captured when the owner
  /// confirms, rather than synthesized later from the run-start timestamp.
  public static let ownerSafetyAcknowledgementValiditySeconds: TimeInterval = 300
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

  /// The relaxed Evidence Lab path is physically absent from Release policy execution.
  public static var developmentEvidenceLabAvailable: Bool {
    #if DEBUG
      true
    #else
      false
    #endif
  }

  /// The unrestricted evidence workspace is compiled out as an issuable/continuable authority in
  /// Release. Persisted DEBUG_UNVERIFIED records remain decodable for honest provenance display.
  public static var unrestrictedEvidenceWorkspaceAvailable: Bool {
    #if DEBUG
      true
    #else
      false
    #endif
  }

  /// Issues the no-context, app-local evidence authority used by import/replay tooling.
  ///
  /// No gateway, vehicle, recorder, handshake, freshness, or pre-import verification state is
  /// accepted because none is required and none may be converted into vehicle-side authority.
  public static func unrestrictedEvidenceWorkspaceAuthority(
    requested: Bool
  ) -> DiscoveryMutationAuthority? {
    #if DEBUG
      requested ? .debugUnverified : nil
    #else
      nil
    #endif
  }

  /// Validates the explicit owner confirmation bound to an app-local acquisition scope.
  ///
  /// Equality is accepted because the canonical ISO-8601 writer records whole seconds, so a real
  /// confirmation followed immediately by Begin can share the same encoded timestamp.
  public static func ownerSafetyAcknowledgementIsValid(
    _ acknowledgedAt: String?,
    runStartedAt: String,
    required: Bool
  ) -> Bool {
    guard required else { return acknowledgedAt == nil }
    let formatter = ISO8601DateFormatter()
    guard let acknowledgedAt, let acknowledgement = formatter.date(from: acknowledgedAt),
      let start = formatter.date(from: runStartedAt), acknowledgement <= start
    else { return false }
    return start.timeIntervalSince(acknowledgement)
      <= ownerSafetyAcknowledgementValiditySeconds
  }

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
    context: DiscoveryMutationContext,
    allowLocalEvidenceOnly: Bool = false,
    allowDevelopmentEvidenceLab: Bool = false,
    allowUnrestrictedEvidenceWorkspace: Bool = false
  ) -> DiscoveryMutationAuthority? {
    guard (try? template.validateContract()) != nil else { return nil }

    // This is intentionally separate from DEVELOPMENT_EVIDENCE_LAB. It permits app-local labels
    // and candidate work for any valid test template without changing the existing live-evidence
    // lab's fresh/listen-only/canonical-selector contract.
    if allowUnrestrictedEvidenceWorkspace {
      return unrestrictedEvidenceWorkspaceAuthority(requested: true)
    }

    #if DEBUG
      // Evidence Lab deliberately relaxes connection, handshake availability,
      // advertised-capability, recorder, storage, and PARKED gates. It still requires a real,
      // fresh accepted observation and fails closed on any evidence that the bus is not
      // listen-only, the vehicle is MOVING, or a present handshake belongs to another gateway.
      // It is limited to the exact canonical selector procedure and returns a distinct
      // non-authority scope.
      if allowDevelopmentEvidenceLab,
        isCanonicalParkSelectorBootstrap(template),
        let observation = context.observation,
        let observationAge = context.observationAgeSeconds,
        (0...freshnessLimitSeconds).contains(observationAge),
        (try? PassiveCANEvidenceArchive.validate(observation)) != nil,
        observation.listenOnly,
        context.health?.listenOnly != false,
        context.health?.vehicleMotion != .moving,
        context.handshake?.listenOnly != false,
        context.handshake.map({ $0.gatewayID == observation.gatewayID }) ?? true
      {
        return .developmentEvidenceLab
      }
    #endif

    guard
      context.connectionState == .vhosConnected,
      let handshake = context.handshake,
      let observation = context.observation,
      let observationAge = context.observationAgeSeconds,
      (0...freshnessLimitSeconds).contains(observationAge),
      handshake.listenOnly, observation.listenOnly,
      template.requiredGatewayCapabilities.allSatisfy(handshake.capabilities.contains),
      observation.gatewayID == handshake.gatewayID
    else { return nil }

    // When the owner explicitly chose local evidence-only acquisition, keep that scope narrow and
    // stable even if a fresh PARKED/recorder report arrives a moment later. The caller persists
    // this returned authority in the append-only run record; it must never be silently upgraded.
    if allowLocalEvidenceOnly,
      isCanonicalParkSelectorBootstrap(template),
      context.health?.vehicleMotion != .moving
    {
      return .localEvidenceOnly
    }

    if let health = context.health,
      let healthAge = context.healthAgeSeconds,
      (0...freshnessLimitSeconds).contains(healthAge),
      health.listenOnly,
      health.captureActive,
      captureWritePathIsHealthy(health),
      captureStorageHasHeadroom(health),
      let captureSessionID = health.captureSessionID,
      observation.sessionID == captureSessionID
    {
      if template.requiredVehicleMotion == .parked,
        context.hasCurrentParkedAuthority,
        health.vehicleMotion == .parked
      {
        return .parked
      }

      if isCanonicalParkSelectorBootstrap(template) {
        if !context.hasCurrentParkedAuthority, health.vehicleMotion == .unknown {
          return .passiveParkSelectorBootstrap
        }
        if context.hasCurrentParkedAuthority, health.vehicleMotion == .parked {
          return .parked
        }
      }
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
