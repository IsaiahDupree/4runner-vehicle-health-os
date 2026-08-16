import Foundation

public enum VehicleMotion: String, Codable, CaseIterable, Sendable {
  case unknown = "UNKNOWN"
  case parked = "PARKED"
  case moving = "MOVING"
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
    bootloaderVersion: String? = nil
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
  public let storageFreeBytes: UInt64
  public let captureActive: Bool
  public let listenOnly: Bool

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
    storageFreeBytes: UInt64,
    captureActive: Bool,
    listenOnly: Bool
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
