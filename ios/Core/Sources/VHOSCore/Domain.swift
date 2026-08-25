import Foundation

public enum VehicleMotion: String, Codable, CaseIterable, Sendable {
  case unknown = "UNKNOWN"
  case parked = "PARKED"
  case moving = "MOVING"
}

public enum PassiveCANScanState: String, Codable, CaseIterable, Sendable {
  case probing500K = "PROBING_500K"
  case probing250K = "PROBING_250K"
  case locked500K = "LOCKED_500K"
  case locked250K = "LOCKED_250K"
  case error = "ERROR"
}

public enum GatewayConnectionState: String, Codable, Sendable {
  case disconnected = "DISCONNECTED"
  case scanning = "SCANNING"
  case connecting = "CONNECTING"
  case factoryCompatible = "FACTORY_COMPATIBLE"
  case vhosConnected = "VHOS_CONNECTED"
  case degraded = "DEGRADED"
  case updating = "UPDATING"
  case failed = "FAILED"
}

public enum GatewayCapability: String, Codable, CaseIterable, Hashable, Sendable {
  case passiveCapture = "capture.passive"
  case signedExperimentPlan = "experiment.signed-plan"
  case allowlistedDiagnosticRead = "diagnostic.allowlisted-read"
  case otaAB = "ota.ab"
  case otaSignedImage = "ota.signed-image"
  case otaRollbackSelfTest = "ota.rollback-self-test"
  case evidenceExport = "evidence.export"
  case persistentEvidenceLog = "evidence.persistent-log"
}

public struct GatewayHandshake: Codable, Equatable, Sendable {
  public let contract: String
  public let contractVersion: String
  public let gatewayID: String
  public let hardwareRevision: String
  public let firmwareVersion: String
  public let firmwareBuildID: String
  public let bootloaderVersion: String?
  public let protocolVersion: String
  public let activeConfigID: String
  public let activeConfigVersion: String
  public let listenOnly: Bool
  public let capabilities: Set<GatewayCapability>
  public let otaUploadURL: String?
  public let otaMaximumImageBytes: Int?
  public let resetReason: Int?

  private enum CodingKeys: String, CodingKey {
    case contract
    case contractVersion
    case gatewayID = "gatewayId"
    case hardwareRevision
    case firmwareVersion
    case firmwareBuildID = "firmwareBuildId"
    case bootloaderVersion
    case protocolVersion
    case activeConfigID = "activeConfigId"
    case activeConfigVersion
    case listenOnly
    case capabilities
    case otaUploadURL = "otaUploadUrl"
    case otaMaximumImageBytes
    case resetReason
  }

  public init(
    contract: String = "gateway.handshake",
    contractVersion: String = "1.0.0",
    gatewayID: String,
    hardwareRevision: String,
    firmwareVersion: String,
    firmwareBuildID: String,
    protocolVersion: String,
    activeConfigID: String,
    activeConfigVersion: String,
    listenOnly: Bool,
    capabilities: Set<GatewayCapability>,
    otaUploadURL: String?,
    otaMaximumImageBytes: Int?,
    bootloaderVersion: String? = nil,
    resetReason: Int? = nil
  ) {
    self.contract = contract
    self.contractVersion = contractVersion
    self.gatewayID = gatewayID
    self.hardwareRevision = hardwareRevision
    self.firmwareVersion = firmwareVersion
    self.firmwareBuildID = firmwareBuildID
    self.bootloaderVersion = bootloaderVersion
    self.protocolVersion = protocolVersion
    self.activeConfigID = activeConfigID
    self.activeConfigVersion = activeConfigVersion
    self.listenOnly = listenOnly
    self.capabilities = capabilities
    self.otaUploadURL = otaUploadURL
    self.otaMaximumImageBytes = otaMaximumImageBytes
    self.resetReason = resetReason
  }
}

public struct GatewayHealth: Codable, Equatable, Sendable {
  public let contract: String
  public let contractVersion: String
  public let observedAt: String
  public let vehicleMotion: VehicleMotion
  public let supplyMillivolts: Int?
  public let receivedFrames: UInt64
  public let droppedFrames: UInt64
  public let busErrorCount: UInt64
  public let busOffCount: UInt64
  public let storageFreeBytes: UInt64?
  public let captureActive: Bool
  public let listenOnly: Bool
  public let canBitrateBps: UInt32?
  public let canControllerRunning: Bool?
  public let canExtendedFrames: UInt64?
  public let canFrames250k: UInt64?
  public let canFrames500k: UInt64?
  public let canPassiveLock: Bool?
  public let canScanCycles: UInt32?
  public let canScanState: PassiveCANScanState?
  public let canStandardFrames: UInt64?
  public let canTwaiReceiveMissedFrames: UInt64?
  public let canTwaiReceiveOverrunFrames: UInt64?
  public let canTwaiReceiveQueueDepth: UInt32?
  public let canTwaiReceiveQueueCapacity: UInt32?
  public let canObserverQueueDroppedFrames: UInt64?
  public let canObserverQueueDepth: UInt32?
  public let canObserverQueueHighWater: UInt32?
  public let canObserverQueueCapacity: UInt32?
  public let passiveCanCandidate: String?
  public let captureCurrentRecords: UInt32?
  public let captureObservedFrames: UInt64?
  public let capturePreviousRecords: UInt32?
  public let captureQueueDroppedRecords: UInt64?
  public let captureRetainedRecords: UInt64?
  public let captureSampleSuppressedFrames: UInt64?
  public let captureSampledFrames: UInt64?
  public let captureSessionID: UInt32?
  public let captureStorageWriteFailures: UInt64?

  // JSONDecoder.convertFromSnakeCase maps `capture_session_id` to `captureSessionId`.
  // Spell the acronym keys explicitly so the deployed firmware's recorder lineage is retained.
  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion, observedAt, vehicleMotion, supplyMillivolts, receivedFrames
    case droppedFrames, busErrorCount, busOffCount, storageFreeBytes, captureActive, listenOnly
    case canBitrateBps, canControllerRunning, canExtendedFrames, canFrames250k, canFrames500k
    case canPassiveLock, canScanCycles, canScanState, canStandardFrames
    case canTwaiReceiveMissedFrames, canTwaiReceiveOverrunFrames, canTwaiReceiveQueueDepth
    case canTwaiReceiveQueueCapacity, canObserverQueueDroppedFrames, canObserverQueueDepth
    case canObserverQueueHighWater, canObserverQueueCapacity, passiveCanCandidate
    case captureCurrentRecords, captureObservedFrames, capturePreviousRecords
    case captureQueueDroppedRecords, captureRetainedRecords, captureSampleSuppressedFrames
    case captureSampledFrames, captureStorageWriteFailures
    case captureSessionID = "captureSessionId"
  }

  public init(
    contract: String = "gateway.health",
    contractVersion: String = "1.0.0",
    observedAt: String,
    vehicleMotion: VehicleMotion,
    supplyMillivolts: Int?,
    receivedFrames: UInt64,
    droppedFrames: UInt64,
    busErrorCount: UInt64,
    busOffCount: UInt64,
    storageFreeBytes: UInt64?,
    captureActive: Bool,
    listenOnly: Bool,
    canBitrateBps: UInt32? = nil,
    canControllerRunning: Bool? = nil,
    canExtendedFrames: UInt64? = nil,
    canFrames250k: UInt64? = nil,
    canFrames500k: UInt64? = nil,
    canPassiveLock: Bool? = nil,
    canScanCycles: UInt32? = nil,
    canScanState: PassiveCANScanState? = nil,
    canStandardFrames: UInt64? = nil,
    canTwaiReceiveMissedFrames: UInt64? = nil,
    canTwaiReceiveOverrunFrames: UInt64? = nil,
    canTwaiReceiveQueueDepth: UInt32? = nil,
    canTwaiReceiveQueueCapacity: UInt32? = nil,
    canObserverQueueDroppedFrames: UInt64? = nil,
    canObserverQueueDepth: UInt32? = nil,
    canObserverQueueHighWater: UInt32? = nil,
    canObserverQueueCapacity: UInt32? = nil,
    passiveCanCandidate: String? = nil,
    captureCurrentRecords: UInt32? = nil,
    captureObservedFrames: UInt64? = nil,
    capturePreviousRecords: UInt32? = nil,
    captureQueueDroppedRecords: UInt64? = nil,
    captureRetainedRecords: UInt64? = nil,
    captureSampleSuppressedFrames: UInt64? = nil,
    captureSampledFrames: UInt64? = nil,
    captureSessionID: UInt32? = nil,
    captureStorageWriteFailures: UInt64? = nil
  ) {
    self.contract = contract
    self.contractVersion = contractVersion
    self.observedAt = observedAt
    self.vehicleMotion = vehicleMotion
    self.supplyMillivolts = supplyMillivolts
    self.receivedFrames = receivedFrames
    self.droppedFrames = droppedFrames
    self.busErrorCount = busErrorCount
    self.busOffCount = busOffCount
    self.storageFreeBytes = storageFreeBytes
    self.captureActive = captureActive
    self.listenOnly = listenOnly
    self.canBitrateBps = canBitrateBps
    self.canControllerRunning = canControllerRunning
    self.canExtendedFrames = canExtendedFrames
    self.canFrames250k = canFrames250k
    self.canFrames500k = canFrames500k
    self.canPassiveLock = canPassiveLock
    self.canScanCycles = canScanCycles
    self.canScanState = canScanState
    self.canStandardFrames = canStandardFrames
    self.canTwaiReceiveMissedFrames = canTwaiReceiveMissedFrames
    self.canTwaiReceiveOverrunFrames = canTwaiReceiveOverrunFrames
    self.canTwaiReceiveQueueDepth = canTwaiReceiveQueueDepth
    self.canTwaiReceiveQueueCapacity = canTwaiReceiveQueueCapacity
    self.canObserverQueueDroppedFrames = canObserverQueueDroppedFrames
    self.canObserverQueueDepth = canObserverQueueDepth
    self.canObserverQueueHighWater = canObserverQueueHighWater
    self.canObserverQueueCapacity = canObserverQueueCapacity
    self.passiveCanCandidate = passiveCanCandidate
    self.captureCurrentRecords = captureCurrentRecords
    self.captureObservedFrames = captureObservedFrames
    self.capturePreviousRecords = capturePreviousRecords
    self.captureQueueDroppedRecords = captureQueueDroppedRecords
    self.captureRetainedRecords = captureRetainedRecords
    self.captureSampleSuppressedFrames = captureSampleSuppressedFrames
    self.captureSampledFrames = captureSampledFrames
    self.captureSessionID = captureSessionID
    self.captureStorageWriteFailures = captureStorageWriteFailures
  }
}

public enum VHOSJSON {
  public static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  public static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }
}
