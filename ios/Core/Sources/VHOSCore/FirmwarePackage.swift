import CryptoKit
import Foundation

public struct FirmwareManifest: Codable, Equatable, Sendable {
  public let contract: String
  public let contractVersion: String
  public let packageID: UUID
  public let releaseChannel: String
  public let createdAt: String
  public let firmwareVersion: String
  public let firmwareBuildID: String
  public let firmwareSHA256: String
  public let firmwareSizeBytes: Int
  public let supportedHardwareRevisions: [String]
  public let minimumBootloaderVersion: String?
  public let minimumSupplyMillivolts: Int
  public let requiredCapabilities: [GatewayCapability]

  private enum CodingKeys: String, CodingKey {
    case contract
    case contractVersion
    case packageID = "packageId"
    case releaseChannel
    case createdAt
    case firmwareVersion
    case firmwareBuildID = "firmwareBuildId"
    case firmwareSHA256 = "firmwareSha256"
    case firmwareSizeBytes
    case supportedHardwareRevisions
    case minimumBootloaderVersion
    case minimumSupplyMillivolts
    case requiredCapabilities
  }

  public init(
    contract: String = "firmware.manifest",
    contractVersion: String = "1.0.0",
    packageID: UUID = UUID(),
    releaseChannel: String,
    createdAt: String,
    firmwareVersion: String,
    firmwareBuildID: String,
    firmwareSHA256: String,
    firmwareSizeBytes: Int,
    supportedHardwareRevisions: [String],
    minimumBootloaderVersion: String?,
    minimumSupplyMillivolts: Int,
    requiredCapabilities: Set<GatewayCapability> = [.otaAB, .otaSignedImage, .otaRollbackSelfTest]
  ) {
    self.contract = contract
    self.contractVersion = contractVersion
    self.packageID = packageID
    self.releaseChannel = releaseChannel
    self.createdAt = createdAt
    self.firmwareVersion = firmwareVersion
    self.firmwareBuildID = firmwareBuildID
    self.firmwareSHA256 = firmwareSHA256
    self.firmwareSizeBytes = firmwareSizeBytes
    self.supportedHardwareRevisions = supportedHardwareRevisions
    self.minimumBootloaderVersion = minimumBootloaderVersion
    self.minimumSupplyMillivolts = minimumSupplyMillivolts
    self.requiredCapabilities = requiredCapabilities.sorted { $0.rawValue < $1.rawValue }
  }
}

public struct VerifiedFirmwarePackage: Equatable, Sendable {
  public let manifest: FirmwareManifest
  public let manifestData: Data
  public let firmware: Data
  public let signature: Data
  public let packageData: Data

  public init(
    manifest: FirmwareManifest,
    manifestData: Data,
    firmware: Data,
    signature: Data,
    packageData: Data
  ) {
    self.manifest = manifest
    self.manifestData = manifestData
    self.firmware = firmware
    self.signature = signature
    self.packageData = packageData
  }
}

public struct FirmwarePreflightContext: Sendable {
  public let handshake: GatewayHandshake
  public let health: GatewayHealth
  public let bootloaderVersion: String?

  public init(handshake: GatewayHandshake, health: GatewayHealth, bootloaderVersion: String?) {
    self.handshake = handshake
    self.health = health
    self.bootloaderVersion = bootloaderVersion
  }
}

public enum FirmwarePackageError: Error, Equatable, LocalizedError {
  case incompleteHeader
  case invalidMagic
  case unsupportedFormatVersion(UInt16)
  case invalidLength
  case manifestDecode
  case invalidManifestContract
  case firmwareLengthMismatch
  case firmwareHashMismatch
  case invalidPublicKey
  case invalidSignature
  case vehicleNotParked
  case captureActive
  case gatewayNotListenOnly
  case supplyVoltageUnavailable
  case supplyVoltageTooLow(required: Int, actual: Int)
  case hardwareRevisionUnsupported(String)
  case missingCapability(GatewayCapability)
  case imageTooLarge(maximum: Int, actual: Int)
  case bootloaderVersionUnavailable
  case bootloaderVersionTooOld(required: String, actual: String)
  case firmwareDowngrade(current: String, proposed: String)

  public var errorDescription: String? {
    switch self {
    case .incompleteHeader: "Firmware package header is incomplete."
    case .invalidMagic: "Firmware package magic is invalid."
    case .unsupportedFormatVersion(let version):
      "Unsupported firmware package format version \(version)."
    case .invalidLength: "Firmware package lengths are invalid or incomplete."
    case .manifestDecode: "Firmware manifest is not valid canonical JSON."
    case .invalidManifestContract: "Firmware manifest contract is unsupported."
    case .firmwareLengthMismatch: "Firmware size does not match its signed manifest."
    case .firmwareHashMismatch: "Firmware SHA-256 does not match its signed manifest."
    case .invalidPublicKey: "Release public key must be a 32-byte Ed25519 key."
    case .invalidSignature: "Firmware package signature is invalid."
    case .vehicleNotParked: "Vehicle motion must be deterministically PARKED before an update."
    case .captureActive: "Stop and persist the active capture before an update."
    case .gatewayNotListenOnly: "Gateway must remain in listen-only mode before an update."
    case .supplyVoltageUnavailable: "Gateway supply voltage is unavailable."
    case .supplyVoltageTooLow(let required, let actual):
      "Supply voltage is below the package minimum: required \(required) mV, received \(actual) mV."
    case .hardwareRevisionUnsupported(let revision):
      "Firmware does not support gateway hardware revision \(revision)."
    case .missingCapability(let capability):
      "Gateway is missing required capability \(capability.rawValue)."
    case .imageTooLarge(let maximum, let actual):
      "Firmware image is too large: maximum \(maximum), received \(actual) bytes."
    case .bootloaderVersionUnavailable:
      "Bootloader version is required by this package but unavailable."
    case .bootloaderVersionTooOld(let required, let actual):
      "Bootloader \(actual) is older than required version \(required)."
    case .firmwareDowngrade(let current, let proposed):
      "Firmware downgrade is blocked: current \(current), proposed \(proposed)."
    }
  }
}

public enum FirmwarePackageCodec {
  public static let magic = Data([0x56, 0x48, 0x55, 0x50])  // VHUP
  public static let formatVersion: UInt16 = 1
  public static let headerLength = 16

  public static func verify(_ data: Data, releasePublicKey: Data) throws -> VerifiedFirmwarePackage
  {
    guard data.count >= headerLength else { throw FirmwarePackageError.incompleteHeader }
    guard data.prefix(4) == magic else { throw FirmwarePackageError.invalidMagic }
    let version = data.readUInt16BigEndian(at: 4)
    guard version == formatVersion else {
      throw FirmwarePackageError.unsupportedFormatVersion(version)
    }

    let manifestLength = Int(data.readUInt32BigEndian(at: 6))
    let firmwareLength = Int(data.readUInt32BigEndian(at: 10))
    let signatureLength = Int(data.readUInt16BigEndian(at: 14))
    let expectedLength = headerLength + manifestLength + firmwareLength + signatureLength
    guard manifestLength > 0, firmwareLength > 0, signatureLength > 0, expectedLength == data.count
    else {
      throw FirmwarePackageError.invalidLength
    }

    let manifestStart = headerLength
    let firmwareStart = manifestStart + manifestLength
    let signatureStart = firmwareStart + firmwareLength
    let manifestData = Data(data[manifestStart..<firmwareStart])
    let firmware = Data(data[firmwareStart..<signatureStart])
    let signature = Data(data[signatureStart..<expectedLength])
    guard let manifest = try? VHOSJSON.decoder().decode(FirmwareManifest.self, from: manifestData)
    else {
      throw FirmwarePackageError.manifestDecode
    }
    guard manifest.contract == "firmware.manifest", manifest.contractVersion == "1.0.0" else {
      throw FirmwarePackageError.invalidManifestContract
    }
    guard manifest.firmwareSizeBytes == firmware.count else {
      throw FirmwarePackageError.firmwareLengthMismatch
    }
    guard manifest.firmwareSHA256.lowercased() == SHA256.hash(data: firmware).hexString else {
      throw FirmwarePackageError.firmwareHashMismatch
    }
    guard releasePublicKey.count == 32,
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: releasePublicKey)
    else {
      throw FirmwarePackageError.invalidPublicKey
    }

    let signedDigest = SHA256.hash(data: manifestData + firmware)
    guard publicKey.isValidSignature(signature, for: Data(signedDigest)) else {
      throw FirmwarePackageError.invalidSignature
    }
    return VerifiedFirmwarePackage(
      manifest: manifest,
      manifestData: manifestData,
      firmware: firmware,
      signature: signature,
      packageData: data
    )
  }

  public static func makeForSigning(
    manifest: FirmwareManifest,
    firmware: Data,
    signature: Data
  ) throws -> Data {
    let manifestData = try VHOSJSON.encoder().encode(manifest)
    guard manifestData.count <= Int(UInt32.max), firmware.count <= Int(UInt32.max),
      signature.count <= Int(UInt16.max)
    else {
      throw FirmwarePackageError.invalidLength
    }
    var data = Data()
    data.append(magic)
    data.appendBigEndian(formatVersion)
    data.appendBigEndian(UInt32(manifestData.count))
    data.appendBigEndian(UInt32(firmware.count))
    data.appendBigEndian(UInt16(signature.count))
    data.append(manifestData)
    data.append(firmware)
    data.append(signature)
    return data
  }

  public static func signingDigest(manifest: FirmwareManifest, firmware: Data) throws -> Data {
    let manifestData = try VHOSJSON.encoder().encode(manifest)
    return Data(SHA256.hash(data: manifestData + firmware))
  }
}

extension VerifiedFirmwarePackage {
  public func validatePreflight(_ context: FirmwarePreflightContext) throws {
    guard context.health.vehicleMotion == .parked else {
      throw FirmwarePackageError.vehicleNotParked
    }
    guard !context.health.captureActive else { throw FirmwarePackageError.captureActive }
    guard context.handshake.listenOnly, context.health.listenOnly else {
      throw FirmwarePackageError.gatewayNotListenOnly
    }
    guard let supply = context.health.supplyMillivolts else {
      throw FirmwarePackageError.supplyVoltageUnavailable
    }
    guard supply >= manifest.minimumSupplyMillivolts else {
      throw FirmwarePackageError.supplyVoltageTooLow(
        required: manifest.minimumSupplyMillivolts, actual: supply)
    }
    guard manifest.supportedHardwareRevisions.contains(context.handshake.hardwareRevision) else {
      throw FirmwarePackageError.hardwareRevisionUnsupported(context.handshake.hardwareRevision)
    }
    for capability in manifest.requiredCapabilities
    where !context.handshake.capabilities.contains(capability) {
      throw FirmwarePackageError.missingCapability(capability)
    }
    if let maximum = context.handshake.otaMaximumImageBytes, firmware.count > maximum {
      throw FirmwarePackageError.imageTooLarge(maximum: maximum, actual: firmware.count)
    }
    if let required = manifest.minimumBootloaderVersion {
      guard let actual = context.bootloaderVersion else {
        throw FirmwarePackageError.bootloaderVersionUnavailable
      }
      guard VersionNumber(actual) >= VersionNumber(required) else {
        throw FirmwarePackageError.bootloaderVersionTooOld(required: required, actual: actual)
      }
    }
    guard
      VersionNumber(manifest.firmwareVersion) >= VersionNumber(context.handshake.firmwareVersion)
    else {
      throw FirmwarePackageError.firmwareDowngrade(
        current: context.handshake.firmwareVersion,
        proposed: manifest.firmwareVersion
      )
    }
  }
}

private struct VersionNumber: Comparable {
  let components: [Int]

  init(_ value: String) {
    components = value.split(separator: ".").map { component in
      Int(component.prefix(while: { $0.isNumber })) ?? 0
    }
  }

  static func < (lhs: VersionNumber, rhs: VersionNumber) -> Bool {
    let count = max(lhs.components.count, rhs.components.count)
    for index in 0..<count {
      let left = index < lhs.components.count ? lhs.components[index] : 0
      let right = index < rhs.components.count ? rhs.components[index] : 0
      if left != right { return left < right }
    }
    return false
  }
}

extension SHA256.Digest {
  fileprivate var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

extension Data {
  fileprivate mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
    var bigEndian = value.bigEndian
    Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
  }

  fileprivate func readUInt16BigEndian(at offset: Int) -> UInt16 {
    (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
  }

  fileprivate func readUInt32BigEndian(at offset: Int) -> UInt32 {
    (UInt32(self[offset]) << 24)
      | (UInt32(self[offset + 1]) << 16)
      | (UInt32(self[offset + 2]) << 8)
      | UInt32(self[offset + 3])
  }
}
