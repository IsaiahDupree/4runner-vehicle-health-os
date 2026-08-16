import CryptoKit
import Foundation
import Testing

@testable import VHOSCore

@Test func signedFirmwarePackageVerifiesAndPassesPreflight() throws {
  let firmware = Data("real-test-firmware-bytes".utf8)
  let key = Curve25519.Signing.PrivateKey()
  let manifest = FirmwareManifest(
    releaseChannel: "development",
    createdAt: "2026-08-16T12:00:00Z",
    firmwareVersion: "1.1.0",
    firmwareBuildID: "build-101",
    firmwareSHA256: SHA256.hash(data: firmware).map { String(format: "%02x", $0) }.joined(),
    firmwareSizeBytes: firmware.count,
    supportedHardwareRevisions: ["WICAN-PRO-V1.51"],
    minimumBootloaderVersion: "1.0.0",
    minimumSupplyMillivolts: 11_800
  )
  let digest = try FirmwarePackageCodec.signingDigest(manifest: manifest, firmware: firmware)
  let signature = try key.signature(for: digest)
  let bytes = try FirmwarePackageCodec.makeForSigning(
    manifest: manifest, firmware: firmware, signature: signature)
  let verified = try FirmwarePackageCodec.verify(
    bytes, releasePublicKey: key.publicKey.rawRepresentation)

  let handshake = GatewayHandshake(
    gatewayID: "gateway-1",
    hardwareRevision: "WICAN-PRO-V1.51",
    firmwareVersion: "1.0.0",
    firmwareBuildID: "build-100",
    protocolVersion: "1.0.0",
    activeConfigID: "cfg",
    activeConfigVersion: "1.0.0",
    listenOnly: true,
    capabilities: [.otaAB, .otaSignedImage, .otaRollbackSelfTest],
    otaUploadURL: "http://192.168.80.1/upload/ota.bin",
    otaMaximumImageBytes: 2_048_000
  )
  let health = GatewayHealth(
    observedAt: "2026-08-16T12:00:01Z",
    vehicleMotion: .parked,
    supplyMillivolts: 12_400,
    receivedFrames: 0,
    droppedFrames: 0,
    busErrorCount: 0,
    busOffCount: 0,
    storageFreeBytes: 1_000_000,
    captureActive: false,
    listenOnly: true
  )
  try verified.validatePreflight(
    .init(handshake: handshake, health: health, bootloaderVersion: "1.0.0"))
}

@Test func firmwarePackageRejectsTamperingAndMovingVehicle() throws {
  let firmware = Data([1, 2, 3, 4])
  let key = Curve25519.Signing.PrivateKey()
  let manifest = FirmwareManifest(
    releaseChannel: "development",
    createdAt: "2026-08-16T12:00:00Z",
    firmwareVersion: "1.0.0",
    firmwareBuildID: "build-1",
    firmwareSHA256: SHA256.hash(data: firmware).map { String(format: "%02x", $0) }.joined(),
    firmwareSizeBytes: firmware.count,
    supportedHardwareRevisions: ["A1"],
    minimumBootloaderVersion: nil,
    minimumSupplyMillivolts: 11_800
  )
  let digest = try FirmwarePackageCodec.signingDigest(manifest: manifest, firmware: firmware)
  let signature = try key.signature(for: digest)
  let originalBytes = try FirmwarePackageCodec.makeForSigning(
    manifest: manifest, firmware: firmware, signature: signature)
  let verified = try FirmwarePackageCodec.verify(
    originalBytes, releasePublicKey: key.publicKey.rawRepresentation)
  let handshake = GatewayHandshake(
    gatewayID: "gateway-1", hardwareRevision: "A1", firmwareVersion: "1.0.0",
    firmwareBuildID: "build-1", protocolVersion: "1.0.0", activeConfigID: "cfg",
    activeConfigVersion: "1.0.0", listenOnly: true,
    capabilities: [.otaAB, .otaSignedImage, .otaRollbackSelfTest], otaUploadURL: nil,
    otaMaximumImageBytes: 1024)
  let moving = GatewayHealth(
    observedAt: "2026-08-16T12:00:01Z", vehicleMotion: .moving,
    supplyMillivolts: 12_400, receivedFrames: 0, droppedFrames: 0, busErrorCount: 0,
    busOffCount: 0, storageFreeBytes: 1, captureActive: false, listenOnly: true)
  #expect(throws: FirmwarePackageError.vehicleNotParked) {
    try verified.validatePreflight(
      .init(handshake: handshake, health: moving, bootloaderVersion: nil))
  }

  var bytes = originalBytes
  bytes[FirmwarePackageCodec.headerLength + 4] ^= 0x01
  #expect(throws: Error.self) {
    try FirmwarePackageCodec.verify(bytes, releasePublicKey: key.publicKey.rawRepresentation)
  }
}
