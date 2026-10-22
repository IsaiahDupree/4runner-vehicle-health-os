import Foundation

public enum DiscoveryProtocol: String, Codable, CaseIterable, Sendable {
  case can11Bit500K = "CAN_11_500"
  case can29Bit500K = "CAN_29_500"
  case can11Bit250K = "CAN_11_250"
  case can29Bit250K = "CAN_29_250"
  case iso9141 = "ISO_9141_2"
  case iso14230Fast = "ISO_14230_FAST"
  case iso14230Slow = "ISO_14230_SLOW"
  case j1850PWM = "J1850_PWM"
  case j1850VPW = "J1850_VPW"

  public var isPassiveCAN: Bool {
    switch self {
    case .can11Bit500K, .can29Bit500K, .can11Bit250K, .can29Bit250K: true
    default: false
    }
  }

  public var canExtended: Bool? {
    switch self {
    case .can11Bit500K, .can11Bit250K: false
    case .can29Bit500K, .can29Bit250K: true
    default: nil
    }
  }

  public var canBitrateBps: UInt32? {
    switch self {
    case .can11Bit500K, .can29Bit500K: 500_000
    case .can11Bit250K, .can29Bit250K: 250_000
    default: nil
    }
  }
}

public enum DiscoveryPhase: String, Codable, Sendable {
  case passiveListen = "PASSIVE_LISTEN"
  case interpreterRead = "INTERPRETER_ALLOWLISTED_READ"
}

public struct DiscoveryCandidate: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let protocolID: DiscoveryProtocol
  public let phase: DiscoveryPhase
  public let boundedWindowSeconds: Int
  public let allowlistEntryID: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case protocolID = "protocolId"
    case phase
    case boundedWindowSeconds
    case allowlistEntryID = "allowlistEntryId"
  }

  public init(
    id: UUID = UUID(),
    protocolID: DiscoveryProtocol,
    phase: DiscoveryPhase,
    boundedWindowSeconds: Int,
    allowlistEntryID: String? = nil
  ) {
    self.id = id
    self.protocolID = protocolID
    self.phase = phase
    self.boundedWindowSeconds = boundedWindowSeconds
    self.allowlistEntryID = allowlistEntryID
  }
}

public struct ProtocolDiscoveryPlan: Codable, Equatable, Sendable, Identifiable {
  public let contract: String
  public let contractVersion: String
  public let id: UUID
  public let createdAt: String
  public let candidates: [DiscoveryCandidate]
  public let stopOnFirstConfirmedRead: Bool

  public init(
    contract: String = "discovery.plan",
    contractVersion: String = "1.0.0",
    id: UUID = UUID(),
    createdAt: String,
    candidates: [DiscoveryCandidate],
    stopOnFirstConfirmedRead: Bool = true
  ) {
    self.contract = contract
    self.contractVersion = contractVersion
    self.id = id
    self.createdAt = createdAt
    self.candidates = candidates
    self.stopOnFirstConfirmedRead = stopOnFirstConfirmedRead
  }

  public static func passiveCANBaseline(createdAt: String) -> ProtocolDiscoveryPlan {
    ProtocolDiscoveryPlan(
      createdAt: createdAt,
      candidates: [
        DiscoveryCandidate(
          protocolID: .can11Bit500K, phase: .passiveListen, boundedWindowSeconds: 10),
        DiscoveryCandidate(
          protocolID: .can29Bit500K, phase: .passiveListen, boundedWindowSeconds: 10),
        DiscoveryCandidate(
          protocolID: .can11Bit250K, phase: .passiveListen, boundedWindowSeconds: 10),
        DiscoveryCandidate(
          protocolID: .can29Bit250K, phase: .passiveListen, boundedWindowSeconds: 10),
      ]
    )
  }

  public static func legacyInterpreterBaseline(createdAt: String) -> ProtocolDiscoveryPlan {
    let allowlist = "obd.standard.supported-pids"
    return ProtocolDiscoveryPlan(
      createdAt: createdAt,
      candidates: [
        DiscoveryCandidate(
          protocolID: .iso9141, phase: .interpreterRead, boundedWindowSeconds: 10,
          allowlistEntryID: allowlist),
        DiscoveryCandidate(
          protocolID: .iso14230Fast, phase: .interpreterRead, boundedWindowSeconds: 10,
          allowlistEntryID: allowlist),
        DiscoveryCandidate(
          protocolID: .iso14230Slow, phase: .interpreterRead, boundedWindowSeconds: 10,
          allowlistEntryID: allowlist),
        DiscoveryCandidate(
          protocolID: .j1850PWM, phase: .interpreterRead, boundedWindowSeconds: 10,
          allowlistEntryID: allowlist),
        DiscoveryCandidate(
          protocolID: .j1850VPW, phase: .interpreterRead, boundedWindowSeconds: 10,
          allowlistEntryID: allowlist),
      ]
    )
  }
}

public struct DiscoverySafetyContext: Equatable, Sendable {
  public let vehicleMotion: VehicleMotion
  public let explicitUserApproval: Bool
  public let captureAlreadyActive: Bool
  public let gatewayListenOnly: Bool
  public let capabilities: Set<GatewayCapability>

  public init(
    vehicleMotion: VehicleMotion,
    explicitUserApproval: Bool,
    captureAlreadyActive: Bool,
    gatewayListenOnly: Bool,
    capabilities: Set<GatewayCapability>
  ) {
    self.vehicleMotion = vehicleMotion
    self.explicitUserApproval = explicitUserApproval
    self.captureAlreadyActive = captureAlreadyActive
    self.gatewayListenOnly = gatewayListenOnly
    self.capabilities = capabilities
  }
}

public enum DiscoverySafetyError: Error, Equatable, LocalizedError {
  case vehicleNotParked
  case approvalRequired
  case captureAlreadyActive
  case missingCapability(GatewayCapability)
  case emptyPlan
  case invalidWindow(Int)
  case passiveCandidateHasAllowlist
  case passiveCandidateRequiresCAN
  case interpreterAllowlistInvalid

  public var errorDescription: String? {
    switch self {
    case .vehicleNotParked: "Vehicle motion must be deterministically PARKED."
    case .approvalRequired: "Explicit user approval is required for a discovery experiment."
    case .captureAlreadyActive: "Stop and persist the active capture before starting discovery."
    case .missingCapability(let capability):
      "Gateway is missing required capability \(capability.rawValue)."
    case .emptyPlan: "Discovery plan has no candidates."
    case .invalidWindow(let seconds):
      "Discovery window must be between 1 and 30 seconds; received \(seconds)."
    case .passiveCandidateHasAllowlist: "A passive candidate must not issue a diagnostic request."
    case .passiveCandidateRequiresCAN:
      "PASSIVE_LISTEN candidates must use a CAN protocol candidate."
    case .interpreterAllowlistInvalid:
      "Interpreter discovery may use only obd.standard.supported-pids."
    }
  }
}

extension ProtocolDiscoveryPlan {
  public func validateSafety(in context: DiscoverySafetyContext) throws {
    guard context.vehicleMotion == .parked else { throw DiscoverySafetyError.vehicleNotParked }
    guard context.explicitUserApproval else { throw DiscoverySafetyError.approvalRequired }
    guard !context.captureAlreadyActive else { throw DiscoverySafetyError.captureAlreadyActive }
    guard context.capabilities.contains(.signedExperimentPlan) else {
      throw DiscoverySafetyError.missingCapability(.signedExperimentPlan)
    }
    guard !candidates.isEmpty else { throw DiscoverySafetyError.emptyPlan }

    for candidate in candidates {
      guard (1...30).contains(candidate.boundedWindowSeconds) else {
        throw DiscoverySafetyError.invalidWindow(candidate.boundedWindowSeconds)
      }
      switch candidate.phase {
      case .passiveListen:
        guard context.capabilities.contains(.passiveCapture) else {
          throw DiscoverySafetyError.missingCapability(.passiveCapture)
        }
        guard context.gatewayListenOnly else {
          throw DiscoverySafetyError.missingCapability(.passiveCapture)
        }
        guard candidate.protocolID.isPassiveCAN else {
          throw DiscoverySafetyError.passiveCandidateRequiresCAN
        }
        guard candidate.allowlistEntryID == nil else {
          throw DiscoverySafetyError.passiveCandidateHasAllowlist
        }
      case .interpreterRead:
        guard context.capabilities.contains(.allowlistedDiagnosticRead) else {
          throw DiscoverySafetyError.missingCapability(.allowlistedDiagnosticRead)
        }
        guard candidate.allowlistEntryID == "obd.standard.supported-pids" else {
          throw DiscoverySafetyError.interpreterAllowlistInvalid
        }
      }
    }
  }
}

public enum DiscoveryOutcome: String, Codable, Sendable {
  case noLock = "NO_LOCK"
  case passiveLock = "PASSIVE_LOCK"
  case readConfirmed = "READ_CONFIRMED"
  case rejectedError = "REJECTED_ERROR"
  case inconclusive = "INCONCLUSIVE"
}

public struct ProtocolExperimentResult: Codable, Equatable, Sendable {
  public let contract: String
  public let contractVersion: String
  public let experimentID: UUID
  public let captureID: String
  public let candidate: DiscoveryCandidate
  public let outcome: DiscoveryOutcome
  public let startedAt: String
  public let endedAt: String
  public let receivedRecords: UInt64
  public let droppedRecords: UInt64
  public let errorCount: UInt64
  public let stableIdentifierCount: UInt64
  public let evidenceReferences: [String]
  public let manifestSHA256: String

  private enum CodingKeys: String, CodingKey {
    case contract
    case contractVersion
    case experimentID = "experimentId"
    case captureID = "captureId"
    case candidate
    case outcome
    case startedAt
    case endedAt
    case receivedRecords
    case droppedRecords
    case errorCount
    case stableIdentifierCount
    case evidenceReferences
    case manifestSHA256 = "manifestSha256"
  }

  public init(
    contract: String = "discovery.result",
    contractVersion: String = "1.0.0",
    experimentID: UUID,
    captureID: String,
    candidate: DiscoveryCandidate,
    outcome: DiscoveryOutcome,
    startedAt: String,
    endedAt: String,
    receivedRecords: UInt64,
    droppedRecords: UInt64,
    errorCount: UInt64,
    stableIdentifierCount: UInt64,
    evidenceReferences: [String],
    manifestSHA256: String
  ) {
    self.contract = contract
    self.contractVersion = contractVersion
    self.experimentID = experimentID
    self.captureID = captureID
    self.candidate = candidate
    self.outcome = outcome
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.receivedRecords = receivedRecords
    self.droppedRecords = droppedRecords
    self.errorCount = errorCount
    self.stableIdentifierCount = stableIdentifierCount
    self.evidenceReferences = evidenceReferences
    self.manifestSHA256 = manifestSHA256
  }
}
