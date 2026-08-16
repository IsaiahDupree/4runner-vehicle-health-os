import Foundation
import Observation
import VHOSCore

enum DiscoveryKind: String, CaseIterable, Identifiable {
  case passiveCAN = "Passive CAN"
  case legacyOBD = "Allowlisted legacy OBD"

  var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
  let gateway: GatewayBLEClient
  private let keyStore: KeyStore
  private let experimentSigner: ExperimentSigner
  private let otaUploader = WiFiOTAUploader()

  var errorMessage: String?
  var noticeMessage: String?
  var verifiedFirmware: VerifiedFirmwarePackage?
  var selectedFirmwareName: String?
  var releasePublicKeyConfigured = false
  var updateInProgress = false
  var uploadProgressDescription: String?

  init() {
    let store = KeyStore(service: "com.isaiahdupree.VehicleHealthOS")
    keyStore = store
    experimentSigner = ExperimentSigner(keyStore: store)
    gateway = GatewayBLEClient()
    releasePublicKeyConfigured = (try? store.data(for: .firmwareReleasePublicKey)) != nil
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
      noticeMessage = "Signed semantic experiment plan sent."
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func installVerifiedFirmware() async {
    do {
      guard let package = verifiedFirmware else { throw AppModelError.verifiedFirmwareRequired }
      guard let handshake = gateway.handshake, let health = gateway.health else {
        throw AppModelError.gatewayHealthRequired
      }
      try package.validatePreflight(
        .init(
          handshake: handshake,
          health: health,
          bootloaderVersion: handshake.bootloaderVersion
        ))
      guard let uploadValue = handshake.otaUploadURL, let uploadURL = URL(string: uploadValue)
      else {
        throw AppModelError.otaURLRequired
      }
      updateInProgress = true
      uploadProgressDescription = "Uploading verified image over the gateway's private network…"
      defer { updateInProgress = false }
      let response = try await otaUploader.upload(firmware: package.firmware, to: uploadURL)
      uploadProgressDescription = response
      noticeMessage = response
      errorMessage = nil
    } catch {
      updateInProgress = false
      uploadProgressDescription = nil
      errorMessage = error.localizedDescription
    }
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

  static func timestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
  }
}

enum AppModelError: Error, LocalizedError {
  case releaseKeyRequired
  case gatewayHealthRequired
  case verifiedFirmwareRequired
  case otaURLRequired

  var errorDescription: String? {
    switch self {
    case .releaseKeyRequired:
      "Import the trusted Ed25519 release public key before selecting firmware."
    case .gatewayHealthRequired: "A VHOS gateway handshake and current health report are required."
    case .verifiedFirmwareRequired: "Select and verify a .vhosota firmware package first."
    case .otaURLRequired: "The gateway handshake did not advertise a valid local OTA upload URL."
    }
  }
}
