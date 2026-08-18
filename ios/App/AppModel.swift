import Foundation
import Observation
import UIKit
import VHOSCore

enum DiscoveryKind: String, CaseIterable, Identifiable {
  case passiveCAN = "Passive CAN"
  case legacyOBD = "Allowlisted legacy OBD"

  var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
  static let shared = AppModel()

  let gateway: GatewayBLEClient
  let releaseHub = ReleaseHubClient()
  private let keyStore: KeyStore
  private let experimentSigner: ExperimentSigner
  private let otaUploader = WiFiOTAUploader()
  private let temporaryGatewayNetwork = TemporaryGatewayNetwork()

  var errorMessage: String?
  var noticeMessage: String?
  var verifiedFirmware: VerifiedFirmwarePackage?
  var selectedFirmwareName: String?
  var releasePublicKeyConfigured = false
  var experimentSigningKeyConfigured = false
  var lastSubmittedExperimentID: UUID?
  var lastSubmittedExperimentKind: DiscoveryKind?
  var lastSubmittedExperimentAt: Date?
  var updateInProgress = false
  var uploadProgressDescription: String?

  private init() {
    let store = KeyStore(service: "com.isaiahdupree.VehicleHealthOS")
    keyStore = store
    experimentSigner = ExperimentSigner(keyStore: store)
    gateway = GatewayBLEClient.shared
    if (try? store.data(for: .firmwareReleasePublicKey)) == nil,
      let url = Bundle.main.url(
        forResource: "mrdiy-v13-development-release-ed25519", withExtension: "base64"),
      let text = try? String(contentsOf: url, encoding: .utf8),
      let key = try? ReleasePublicKeyParser.parse(text)
    {
      try? store.set(key, for: .firmwareReleasePublicKey)
    }
    releasePublicKeyConfigured = (try? store.data(for: .firmwareReleasePublicKey)) != nil
    experimentSigningKeyConfigured =
      (try? store.data(for: .experimentSigningPrivateKey)) != nil
  }

  func importReleasePublicKey(_ text: String) {
    do {
      let key = try ReleasePublicKeyParser.parse(text)
      try keyStore.set(key, for: .firmwareReleasePublicKey)
      releasePublicKeyConfigured = true
      verifiedFirmware = nil
      selectedFirmwareName = nil
      noticeMessage = "Release verification key saved in Keychain."
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func importFirmware(from url: URL) {
    let hasAccess = url.startAccessingSecurityScopedResource()
    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
    do {
      guard let key = try keyStore.data(for: .firmwareReleasePublicKey) else {
        throw AppModelError.releaseKeyRequired
      }
      let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
      let verified = try FirmwarePackageCodec.verify(bytes, releasePublicKey: key)
      verifiedFirmware = verified
      selectedFirmwareName = url.lastPathComponent
      noticeMessage = "Signature and firmware hash verified."
      errorMessage = nil
    } catch {
      verifiedFirmware = nil
      selectedFirmwareName = nil
      errorMessage = error.localizedDescription
    }
  }

  func runDiscovery(_ kind: DiscoveryKind, explicitApproval: Bool) {
    do {
      guard let handshake = gateway.handshake, let health = gateway.health else {
        throw AppModelError.gatewayHealthRequired
      }
      let now = Self.timestamp()
      let plan: ProtocolDiscoveryPlan =
        switch kind {
        case .passiveCAN: .passiveCANBaseline(createdAt: now)
        case .legacyOBD: .legacyInterpreterBaseline(createdAt: now)
        }
      let context = DiscoverySafetyContext(
        vehicleMotion: health.vehicleMotion,
        explicitUserApproval: explicitApproval,
        captureAlreadyActive: health.captureActive,
        gatewayListenOnly: handshake.listenOnly && health.listenOnly,
        capabilities: handshake.capabilities
      )
      try plan.validateSafety(in: context)
      let approval = ExperimentApproval(approvedAt: now, plan: plan)
      let envelope = try experimentSigner.sign(approval)
      try gateway.sendSignedExperimentPlan(envelope)
      experimentSigningKeyConfigured = true
      lastSubmittedExperimentID = plan.id
      lastSubmittedExperimentKind = kind
      lastSubmittedExperimentAt = Date()
      noticeMessage = "Signed semantic experiment plan sent."
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func installVerifiedFirmware() async {
    var packageForRecovery: VerifiedFirmwarePackage?
    var joinedSSID: String?
    var uploadAccepted = false
    do {
      guard let package = verifiedFirmware else { throw AppModelError.verifiedFirmwareRequired }
      packageForRecovery = package
      guard let handshake = gateway.handshake, gateway.health != nil else {
        throw AppModelError.gatewayHealthRequired
      }
      guard handshake.capabilities.contains(.otaSignedImage),
        handshake.capabilities.contains(.otaAB),
        handshake.capabilities.contains(.otaRollbackSelfTest)
      else {
        throw AppModelError.signedOTACapabilityRequired
      }
      updateInProgress = true
      uploadProgressDescription = "Pausing and flushing the passive recorder…"
      try gateway.setCaptureLogging(false)
      try await waitForCapturePause()
      guard let pausedHealth = gateway.health else { throw AppModelError.gatewayHealthRequired }
      try package.validatePreflight(
        .init(
          handshake: handshake,
          health: pausedHealth,
          bootloaderVersion: handshake.bootloaderVersion
        ))
      uploadProgressDescription = "Requesting an authenticated temporary OTA network over BLE…"
      try gateway.activateTemporaryOTANetwork(for: package)
      let session = try await waitForOTANetwork(packageID: package.manifest.packageID)
      guard session.gatewayID == nil || session.gatewayID == handshake.gatewayID else {
        throw AppModelError.otaGatewayIdentityMismatch
      }
      guard let ssid = session.ssid, let passphrase = session.passphrase,
        let uploadValue = session.uploadURL, let uploadURL = URL(string: uploadValue),
        let token = session.bearerToken
      else { throw AppModelError.otaSessionIncomplete }
      joinedSSID = ssid
      uploadProgressDescription = "Joining \(ssid) for this update only…"
      try await temporaryGatewayNetwork.join(ssid: ssid, passphrase: passphrase)
      uploadProgressDescription = "Uploading the verified signed image to the inactive slot…"
      let response = try await otaUploader.upload(
        firmware: package.firmware,
        to: uploadURL,
        bearerToken: token
      )
      uploadAccepted = true
      uploadProgressDescription = response
      noticeMessage = response
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
    if let joinedSSID { temporaryGatewayNetwork.remove(ssid: joinedSSID) }
    if !uploadAccepted, let packageForRecovery {
      gateway.cancelTemporaryOTANetwork(for: packageForRecovery)
      try? gateway.setCaptureLogging(true)
      uploadProgressDescription = nil
    }
    updateInProgress = false
  }

  private func waitForCapturePause() async throws {
    for _ in 0..<40 {
      if gateway.captureLogIndex?.logging == false, gateway.health?.captureActive == false {
        return
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    throw AppModelError.capturePauseTimedOut
  }

  private func waitForOTANetwork(packageID: UUID) async throws -> GatewayOTAStatus {
    for _ in 0..<60 {
      if let status = gateway.otaStatus, status.packageID == packageID {
        if status.networkReady { return status }
        if [
          "FAILED", "EXPIRED", "CANCELLED", "ROLLED_BACK", "NOT_ACTIVATED",
          "BOOT_SELECTION_FAILED",
        ].contains(status.state) {
          throw AppModelError.otaSessionRejected(status.detail)
        }
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    throw AppModelError.otaSessionTimedOut
  }

  func evidenceExportURL() throws -> URL {
    guard let handshake = gateway.handshake, let health = gateway.health else {
      throw AppModelError.gatewayHealthRequired
    }
    let handoff = AgentEvidenceHandoff(
      generatedAt: Self.timestamp(),
      handshake: handshake,
      health: health,
      experimentResults: gateway.experimentResults
    )
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "VehicleHealthOS-Evidence", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("agent-evidence-handoff.json")
    try handoff.encoded().write(to: url, options: .atomic)
    return url
  }

  func passiveCANExportURL() throws -> URL {
    try gateway.captureLogExportURL()
  }

  func bleConnectionTraceExportURL() throws -> URL {
    try gateway.bleConnectionTraceExportURL()
  }

  func evidenceSyncExportURL() throws -> URL {
    let info = Bundle.main.infoDictionary
    return try gateway.evidenceSyncExportURL(
      applicationID: Bundle.main.bundleIdentifier ?? "com.isaiahdupree.VehicleHealthOS",
      applicationVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
      deviceModel: UIDevice.current.model
    )
  }

  func importEvidenceSync(from url: URL) {
    let hasAccess = url.startAccessingSecurityScopedResource()
    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
    do {
      let summary = try gateway.importEvidenceSync(from: url)
      noticeMessage =
        "Bundle \(summary.bundleID.uuidString) verified; appended \(summary.appendedRecords) of \(summary.verifiedRecords) frames."
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func stageRelease(_ artifact: ReleaseArtifact) async {
    do {
      let url = try await releaseHub.stage(artifact)
      if artifact.kind == .esp32VHOSOTA {
        importFirmware(from: url)
        if errorMessage == nil {
          noticeMessage = "Verified OBD firmware staged. Complete safety preflight in Firmware."
        }
      } else {
        noticeMessage = "Verified \(artifact.artifactID) and prepared it for owner-approved handoff."
        errorMessage = nil
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  static func timestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
  }
}

enum AppModelError: Error, LocalizedError {
  case releaseKeyRequired
  case gatewayHealthRequired
  case verifiedFirmwareRequired
  case otaURLRequired
  case signedOTACapabilityRequired
  case capturePauseTimedOut
  case otaSessionIncomplete
  case otaSessionTimedOut
  case otaSessionRejected(String)
  case otaGatewayIdentityMismatch

  var errorDescription: String? {
    switch self {
    case .releaseKeyRequired:
      "Import the trusted Ed25519 release public key before selecting firmware."
    case .gatewayHealthRequired: "A VHOS gateway handshake and current health report are required."
    case .verifiedFirmwareRequired: "Select and verify a .vhosota firmware package first."
    case .otaURLRequired: "The gateway handshake did not advertise a valid local OTA upload URL."
    case .signedOTACapabilityRequired:
      "This gateway firmware does not advertise signed A/B Wi-Fi OTA with rollback."
    case .capturePauseTimedOut:
      "The passive recorder did not confirm a flushed, paused state before OTA."
    case .otaSessionIncomplete:
      "The encrypted BLE OTA response did not include complete temporary-network credentials."
    case .otaSessionTimedOut:
      "The gateway did not open its temporary OTA network before the commissioning timeout."
    case .otaSessionRejected(let detail): "The gateway rejected the OTA session: \(detail)"
    case .otaGatewayIdentityMismatch:
      "The temporary OTA session came from a different gateway identity than the BLE handshake."
    }
  }
}
