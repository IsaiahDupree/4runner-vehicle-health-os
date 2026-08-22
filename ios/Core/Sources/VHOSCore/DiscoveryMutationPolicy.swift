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
  public static let parkSelectorBootstrapMarkerRequirements: [
    DiscoveryOrderedMarkerRequirement
  ] = [
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
        suggestedDurationSeconds: index == 0 ? nil : 4,
        expectedMarkerKind: item.1)
    }
    return try TestTemplate(
      id: parkSelectorBootstrapTemplateID,
      templateVersion: "1.0.0",
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
