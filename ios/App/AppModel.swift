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
  private let evidenceOutboxStore = EvidenceOutboxStore()
  private let evidenceOutboxUploader = EvidenceOutboxUploader()
  private let synchronizedReferenceStore = SynchronizedReferenceStore()
  private let discoveryEvidenceStore = DiscoveryEvidenceStore()
  private var evidenceAutomationTask: Task<Void, Never>?
  private var lastQueuedCaptureSyncGeneration: UInt64 = 0
  private static let evidenceEndpointDefaultsKey = "vhos.evidence-outbox.endpoint.v1"
  private static let evidenceAutomaticDefaultsKey = "vhos.evidence-outbox.automatic.v1"

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
  var evidenceOutboxEndpoint = ""
  var automaticEvidenceUpload = true
  var evidenceOutboxPendingCount = 0
  var evidenceOutboxUploadedCount = 0
  var evidenceOutboxMessage = "Private evidence outbox is initializing."
  var evidenceOutboxUploadInProgress = false
  var evidenceOutboxTokenConfigured = false
  var synchronizedReferenceCount = 0
  var synchronizedReferenceMessage = "No synchronized reference samples recorded."
  var canResearchReport: PassiveCANResearchReport?
  var canResearchMessage = "No retained CAN evidence has been analyzed on this iPhone."
  var discoveryMarkers: [StoredDiscoveryMarker] = []
  var discoveryMarkerMessage = "No synchronized Discovery markers are retained."
  var discoveryTestRuns: [DiscoveryTestRunDraft] = []

  var activeDiscoveryTestRun: DiscoveryTestRunDraft? {
    discoveryTestRuns.last(where: { $0.state == .active })
  }

  var discoveryTimelineCurrent: Bool {
    (try? currentDiscoveryObservation()) != nil
  }

  func discoveryMutationAuthority(
    for template: TestTemplate
  ) -> DiscoveryMutationAuthority? {
    let now = Date()
    let healthAge = gateway.lastHealthReceivedAt.map { now.timeIntervalSince($0) }
    let observationAge = gateway.latestCANObservationReceivedAt.map { now.timeIntervalSince($0) }
    return DiscoveryMutationPolicy.authority(
      for: template,
      context: DiscoveryMutationContext(
        connectionState: gateway.state,
        handshake: gateway.handshake,
        health: gateway.health,
        healthAgeSeconds: healthAge,
        observation: gateway.latestCANObservation,
        observationAgeSeconds: observationAge,
        hasCurrentParkedAuthority: gateway.hasCurrentParkedAuthority))
  }

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
    evidenceOutboxEndpoint =
      UserDefaults.standard.string(
        forKey: Self.evidenceEndpointDefaultsKey) ?? ""
    if UserDefaults.standard.object(forKey: Self.evidenceAutomaticDefaultsKey) != nil {
      automaticEvidenceUpload = UserDefaults.standard.bool(
        forKey: Self.evidenceAutomaticDefaultsKey)
    }
    evidenceOutboxTokenConfigured =
      (try? store.data(for: .evidenceOutboxBearerToken)) != nil
    refreshEvidenceOutboxStatus()
    refreshSynchronizedReferenceStatus()
    refreshCANResearch()
    refreshDiscoveryEvidence()
  }

  func startEvidenceAutomation() {
    guard evidenceAutomationTask == nil else { return }
    evidenceAutomationTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.runEvidenceAutomationCycle()
        try? await Task.sleep(for: .seconds(5))
      }
    }
  }

  func configureEvidenceOutbox(endpointText: String, bearerToken: String) {
    do {
      let trimmed = endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let endpoint = URL(string: trimmed), endpoint.scheme?.lowercased() == "https",
        endpoint.host != nil
      else { throw EvidenceOutboxStoreError.httpsEndpointRequired }
      let token = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
      if !token.isEmpty {
        guard token.count >= 32 else { throw AppModelError.evidenceTokenTooShort }
        try keyStore.set(Data(token.utf8), for: .evidenceOutboxBearerToken)
      }
      guard (try keyStore.data(for: .evidenceOutboxBearerToken)) != nil else {
        throw AppModelError.evidenceTokenRequired
      }
      evidenceOutboxEndpoint = endpoint.absoluteString
      evidenceOutboxTokenConfigured = true
      UserDefaults.standard.set(endpoint.absoluteString, forKey: Self.evidenceEndpointDefaultsKey)
      evidenceOutboxMessage =
        "Private HTTPS inbox configured; queued packages can upload automatically."
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func setAutomaticEvidenceUpload(_ enabled: Bool) {
    automaticEvidenceUpload = enabled
    UserDefaults.standard.set(enabled, forKey: Self.evidenceAutomaticDefaultsKey)
    if enabled { Task { await processEvidenceOutbox() } }
  }

  func queueCurrentEvidenceForAI() {
    do {
      let url = try evidenceSyncExportURL()
      let payload = try Data(contentsOf: url, options: [.mappedIfSafe])
      let (_, inserted) = try evidenceOutboxStore.enqueue(
        payload: payload,
        contentType: "application/vnd.vhos.evidence-sync+zip"
      )
      refreshEvidenceOutboxStatus()
      evidenceOutboxMessage =
        inserted
        ? "Checksummed evidence queued in the private outbox."
        : "This exact evidence hash is already present in the private outbox."
      if automaticEvidenceUpload { Task { await processEvidenceOutbox() } }
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func processEvidenceOutbox() async {
    guard !evidenceOutboxUploadInProgress else { return }
    guard automaticEvidenceUpload || evidenceOutboxPendingCount > 0 else { return }
    guard let endpoint = URL(string: evidenceOutboxEndpoint),
      let tokenData = try? keyStore.data(for: .evidenceOutboxBearerToken),
      let token = String(data: tokenData, encoding: .utf8), !token.isEmpty
    else {
      refreshEvidenceOutboxStatus()
      evidenceOutboxMessage =
        evidenceOutboxPendingCount == 0
        ? "No evidence is queued. Configure a private HTTPS inbox for automatic AI pickup."
        : "Evidence is safely queued locally; configure a private HTTPS inbox to upload it."
      return
    }
    evidenceOutboxUploadInProgress = true
    defer {
      evidenceOutboxUploadInProgress = false
      refreshEvidenceOutboxStatus()
    }
    do {
      for record in try evidenceOutboxStore.records().filter({ $0.uploadedAt == nil }).prefix(8) {
        do {
          try await evidenceOutboxUploader.upload(
            record,
            payloadURL: try evidenceOutboxStore.payloadURL(for: record),
            endpoint: endpoint,
            bearerToken: token
          )
          try evidenceOutboxStore.markUploaded(record)
          evidenceOutboxMessage = "Uploaded evidence package \(record.id.uuidString)."
        } catch {
          try? evidenceOutboxStore.markAttempt(record, error: error.localizedDescription)
          evidenceOutboxMessage = "Private upload paused: \(error.localizedDescription)"
          return
        }
      }
    } catch {
      evidenceOutboxMessage = error.localizedDescription
    }
  }

  private func runEvidenceAutomationCycle() async {
    retainStandardOBDReferences()
    let generation = gateway.captureSyncCompletionGeneration
    if generation > lastQueuedCaptureSyncGeneration {
      lastQueuedCaptureSyncGeneration = generation
      refreshCANResearch()
      queueCurrentEvidenceForAI()
    }
    if automaticEvidenceUpload { await processEvidenceOutbox() }
  }

  func recordTechstreamReference(signalID: String, valueText: String, unit: String) {
    do {
      let observation = try currentDiscoveryObservation()
      guard let value = Double(valueText.trimmingCharacters(in: .whitespacesAndNewlines)),
        value.isFinite
      else { throw AppModelError.referenceValueInvalid }
      let sample = try SynchronizedReferenceSample(
        gatewayMonotonicMicroseconds: observation.monotonicMicroseconds,
        signalID: signalID,
        value: value,
        unit: unit,
        source: "TECHSTREAM",
        recordedAt: Self.timestamp(),
        nearestCANSequence: observation.sourceSequence,
        evidenceNote:
          "Owner-entered Toyota Techstream Data List value aligned to the latest gateway CAN observation."
      )
      _ = try synchronizedReferenceStore.append(sample)
      refreshSynchronizedReferenceStatus()
      synchronizedReferenceMessage =
        "Recorded \(signalID) at gateway monotonic \(observation.monotonicMicroseconds) µs."
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func recordDiscoveryMarker(
    template: TestTemplate,
    kind: DiscoveryMarkerKind,
    label: String
  ) {
    do {
      guard gateway.state == .vhosConnected, gateway.health != nil,
        gateway.handshake != nil
      else {
        throw AppModelError.gatewayHealthRequired
      }
      guard discoveryMutationAuthority(for: template) != nil else {
        throw AppModelError.discoveryEvidenceAuthorityRequired
      }
      let observation = try currentDiscoveryObservation()
      guard let run = activeDiscoveryTestRun,
        DiscoveryMutationPolicy.testRunIdentityMatches(
          template: template,
          templateID: run.templateID,
          templateVersion: run.templateVersion)
      else {
        throw AppModelError.discoveryTestRunRequired
      }
      if run.templateID == DiscoveryMutationPolicy.parkSelectorBootstrapTemplateID {
        let recorded = orderedBootstrapMarkers(for: run)
        guard
          DiscoveryMutationPolicy.nextParkSelectorBootstrapMarker(after: recorded)
            == DiscoveryOrderedMarkerRequirement(kind: kind, label: label)
        else { throw AppModelError.discoveryMarkerSequenceRequired }
      }
      let stored = try discoveryEvidenceStore.append(
        template: template,
        testRun: run,
        kind: kind,
        label: label,
        observation: observation,
        recordedAt: Self.timestamp())
      refreshDiscoveryEvidence()
      discoveryMarkerMessage =
        "Recorded \(stored.marker.kind.rawValue) at source sequence \(observation.sourceSequence)."
      noticeMessage = discoveryMarkerMessage
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func beginDiscoveryTestRun(template: TestTemplate) {
    do {
      guard gateway.state == .vhosConnected, gateway.health != nil,
        gateway.handshake != nil
      else {
        throw AppModelError.gatewayHealthRequired
      }
      guard discoveryMutationAuthority(for: template) != nil else {
        throw AppModelError.discoveryEvidenceAuthorityRequired
      }
      let observation = try currentDiscoveryObservation()
      let run = try discoveryEvidenceStore.beginTestRun(
        template: template,
        observation: observation,
        recordedAt: Self.timestamp())
      refreshDiscoveryEvidence()
      noticeMessage =
        "Test run draft \(run.id) began on gateway session \(run.gatewaySessionID)."
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func endDiscoveryTestRun() {
    transitionDiscoveryTestRun(to: .ended)
  }

  func abortDiscoveryTestRun() {
    transitionDiscoveryTestRun(to: .aborted)
  }

  private func transitionDiscoveryTestRun(to state: DiscoveryTestRunDraftState) {
    do {
      guard let run = activeDiscoveryTestRun else {
        throw AppModelError.discoveryTestRunRequired
      }
      if state == .ended {
        if run.templateID == DiscoveryMutationPolicy.parkSelectorBootstrapTemplateID {
          let template = try DiscoveryMutationPolicy.parkSelectorBootstrapTemplate()
          guard
            DiscoveryMutationPolicy.testRunIdentityMatches(
              template: template,
              templateID: run.templateID,
              templateVersion: run.templateVersion)
          else { throw AppModelError.discoveryTestRunRequired }
          guard discoveryMutationAuthority(for: template) != nil else {
            throw AppModelError.discoveryEvidenceAuthorityRequired
          }
          guard
            DiscoveryMutationPolicy.parkSelectorBootstrapIsComplete(
              orderedBootstrapMarkers(for: run))
          else { throw AppModelError.discoveryTestIncomplete }
        } else {
          guard gateway.hasCurrentParkedAuthority else {
            throw AppModelError.discoveryParkedStateRequired
          }
        }
      }
      let endObservation = state == .ended ? try currentDiscoveryObservation() : nil
      let updated = try discoveryEvidenceStore.transitionTestRun(
        run,
        to: state,
        observation: endObservation,
        recordedAt: Self.timestamp())
      refreshDiscoveryEvidence()
      noticeMessage =
        state == .ended
        ? "Test run draft ended. Finalization waits for retained archive and manifest hashes."
        : "Test run draft aborted; all previously recorded markers remain append-only evidence."
      discoveryMarkerMessage = "Test run draft \(updated.id) is \(updated.state.rawValue)."
      queueDiscoveryDraftEvidenceForAI()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func orderedBootstrapMarkers(
    for run: DiscoveryTestRunDraft
  ) -> [DiscoveryOrderedMarkerRequirement] {
    discoveryMarkers.filter { $0.testRunID == run.id }.map {
      DiscoveryOrderedMarkerRequirement(kind: $0.marker.kind, label: $0.label)
    }
  }

  private func refreshDiscoveryEvidence() {
    do {
      discoveryMarkers = try discoveryEvidenceStore.markers()
      discoveryTestRuns = try discoveryEvidenceStore.testRuns()
      let retainedMessage =
        discoveryMarkers.isEmpty
        ? "No synchronized Discovery markers are retained."
        : "\(discoveryMarkers.count) append-only Discovery marker(s) retained on this iPhone."
      let recoveries = discoveryEvidenceStore.recoveryReports
      if let latestRecovery = recoveries.last {
        let recoveredFiles = Set(recoveries.map(\.sourceFileName)).sorted()
          .joined(separator: ", ")
        let quarantinedByteCount = recoveries.reduce(0) {
          $0 + $1.quarantinedByteCount
        }
        discoveryMarkerMessage =
          "\(retainedMessage) Recovered \(recoveries.count) interrupted ledger append(s) in "
          + "\(recoveredFiles); quarantined \(quarantinedByteCount) uncommitted tail byte(s). "
          + "Latest quarantine: \(latestRecovery.quarantineURL.lastPathComponent)."
      } else {
        discoveryMarkerMessage = retainedMessage
      }
    } catch {
      discoveryMarkers = []
      discoveryTestRuns = []
      discoveryMarkerMessage =
        "Discovery marker ledger failed closed: \(error.localizedDescription)"
    }
  }

  private func queueDiscoveryDraftEvidenceForAI() {
    do {
      let url = try discoveryEvidenceStore.exportURL(generatedAt: Self.timestamp())
      let payload = try Data(contentsOf: url, options: [.mappedIfSafe])
      let (_, inserted) = try evidenceOutboxStore.enqueue(
        payload: payload,
        contentType: "application/vnd.vhos.discovery-draft-evidence+json")
      refreshEvidenceOutboxStatus()
      if inserted {
        evidenceOutboxMessage =
          "Checksummed Discovery draft evidence queued in the private outbox."
      }
      if automaticEvidenceUpload { Task { await processEvidenceOutbox() } }
    } catch {
      evidenceOutboxMessage =
        "Discovery draft evidence remains local: \(error.localizedDescription)"
    }
  }

  private func currentDiscoveryObservation() throws -> PassiveCANObservation {
    guard gateway.hasCurrentGatewayHealth, gateway.state == .vhosConnected,
      let handshake = gateway.handshake,
      let health = gateway.health, handshake.listenOnly, health.listenOnly,
      let observation = gateway.latestCANObservation,
      observation.gatewayID == handshake.gatewayID, observation.listenOnly,
      let currentSessionID = health.captureSessionID,
      observation.sessionID == currentSessionID,
      let receivedAt = gateway.latestCANObservationReceivedAt
    else { throw AppModelError.discoveryCurrentTimelineRequired }
    let age = Date().timeIntervalSince(receivedAt)
    guard age >= 0, age <= 5 else { throw AppModelError.discoveryCurrentTimelineRequired }
    return observation
  }

  func pauseDownloadAndResumeGatewayHistory() {
    do {
      guard gateway.state == .vhosConnected else {
        throw AppModelError.gatewayHealthRequired
      }
      try gateway.pauseCaptureAndDownloadHistory()
      noticeMessage =
        "The recorder will pause briefly, download retained history, and resume automatically."
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func resumeGatewayCapture() {
    do {
      guard gateway.state == .vhosConnected else {
        throw AppModelError.gatewayHealthRequired
      }
      try gateway.resumeCaptureLogging()
      noticeMessage = "Passive CAN recording resume requested."
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func synchronizedReferenceExportURL() throws -> URL {
    try synchronizedReferenceStore.exportURL()
  }

  func discoveryDraftEvidenceExportURL() throws -> URL {
    try discoveryEvidenceStore.exportURL(generatedAt: Self.timestamp())
  }

  private func retainStandardOBDReferences() {
    do {
      var inserted = 0
      for sample in gateway.standardOBDSamples {
        let reference = try SynchronizedReferenceSample(
          gatewayMonotonicMicroseconds: sample.gatewayMonotonicMicroseconds,
          signalID: "reference.\(sample.signalID)",
          value: sample.value,
          unit: sample.unit,
          source: "SAE_J1979",
          recordedAt: sample.observedAt,
          nearestCANSequence: sample.sourceSequence,
          evidenceNote:
            "Standard read-only Mode 01 PID 0x\(String(format: "%02X", sample.pid)); definition revision \(sample.definitionRevision)."
        )
        if try synchronizedReferenceStore.append(reference) { inserted += 1 }
      }
      if inserted > 0 {
        refreshSynchronizedReferenceStatus()
        synchronizedReferenceMessage = "Retained \(inserted) new standard OBD reference sample(s)."
      }
    } catch {
      synchronizedReferenceMessage = "Reference retention paused: \(error.localizedDescription)"
    }
  }

  private func refreshSynchronizedReferenceStatus() {
    synchronizedReferenceCount = ((try? synchronizedReferenceStore.samples()) ?? []).count
    if synchronizedReferenceCount > 0 {
      synchronizedReferenceMessage =
        "\(synchronizedReferenceCount) append-only synchronized reference sample(s) retained."
    }
  }

  private func refreshEvidenceOutboxStatus() {
    let records = (try? evidenceOutboxStore.records()) ?? []
    evidenceOutboxPendingCount = records.filter { $0.uploadedAt == nil }.count
    evidenceOutboxUploadedCount = records.filter { $0.uploadedAt != nil }.count
    if records.isEmpty {
      evidenceOutboxMessage = "No evidence is queued."
    }
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
      guard gateway.hasCurrentGatewayHealth else {
        throw AppModelError.gatewayHealthRequired
      }
      guard gateway.hasCurrentParkedAuthority else {
        throw AppModelError.discoveryParkedStateRequired
      }
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
      guard gateway.hasCurrentParkedAuthority else {
        throw AppModelError.discoveryParkedStateRequired
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
      guard gateway.hasCurrentParkedAuthority else {
        throw AppModelError.discoveryParkedStateRequired
      }
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

  func refreshCANResearch() {
    do {
      let observations = try gateway.storedPassiveCANObservations()
      guard !observations.isEmpty else {
        canResearchReport = nil
        canResearchMessage =
          "No retained CAN evidence is stored. Synchronize a gateway capture to create research graphs."
        return
      }
      let report = try PassiveCANResearchAnalyzer.analyze(observations)
      canResearchReport = report
      canResearchMessage =
        "Analyzed \(report.recordCount.formatted()) retained records across \(report.sessionCount) sessions; owner health remains blocked."
    } catch {
      canResearchReport = nil
      canResearchMessage = "Retained CAN analysis failed closed: \(error.localizedDescription)"
    }
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
        noticeMessage =
          "Verified \(artifact.artifactID) and prepared it for owner-approved handoff."
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
  case evidenceTokenRequired
  case evidenceTokenTooShort
  case currentCANReferenceRequired
  case referenceValueInvalid
  case discoveryParkedStateRequired
  case discoveryCaptureRequired
  case discoveryTestRunRequired
  case discoveryInteractiveTestUnavailable
  case discoveryCurrentTimelineRequired
  case discoveryCapabilityRequired
  case discoveryEvidenceAuthorityRequired
  case discoveryMarkerSequenceRequired
  case discoveryTestIncomplete

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
    case .evidenceTokenRequired:
      "Enter a private evidence inbox bearer token before enabling uploads."
    case .evidenceTokenTooShort:
      "The private evidence inbox bearer token must contain at least 32 characters."
    case .currentCANReferenceRequired:
      "A current gateway CAN observation is required to timestamp a Techstream reference value."
    case .referenceValueInvalid:
      "Enter a finite numeric Techstream reference value."
    case .discoveryParkedStateRequired:
      "Discovery engineering controls require a fresh verified gateway health report that deterministically says PARKED."
    case .discoveryCaptureRequired:
      "Start the passive recorder before adding synchronized Discovery event markers."
    case .discoveryTestRunRequired:
      "Begin the matching Discovery test run before recording event markers."
    case .discoveryInteractiveTestUnavailable:
      "This procedure is not available in iPhone driver-interaction mode. A passenger-supervised workflow is required."
    case .discoveryCurrentTimelineRequired:
      "A listen-only CAN observation from the verified gateway within the last five seconds is required for Discovery timeline evidence."
    case .discoveryCapabilityRequired:
      "The verified gateway does not advertise every capability required by this versioned Discovery test template."
    case .discoveryEvidenceAuthorityRequired:
      "This test requires either fresh deterministic PARKED authority or the exact passive Park-selector bootstrap with current listen-only capture evidence."
    case .discoveryMarkerSequenceRequired:
      "The Park-selector bootstrap accepts one exact marker at a time in the required P/R/N/D/P sequence. Abort and restart if the retained sequence is not canonical."
    case .discoveryTestIncomplete:
      "Complete every ordered Park-selector bootstrap marker before ending this evidence session."
    }
  }
}
