import Foundation
import Observation
import UIKit
import VHOSCore

enum DiscoveryKind: String, CaseIterable, Identifiable {
  case passiveCAN = "Passive CAN"
  case legacyOBD = "Allowlisted legacy OBD"

  var id: String { rawValue }
}

enum DiscoveryLedgerReadState: Equatable, Sendable {
  case notLoaded
  case available
  case unavailable(String)

  var isAvailable: Bool {
    if case .available = self { return true }
    return false
  }

  var statusLabel: String {
    switch self {
    case .notLoaded: "NOT LOADED"
    case .available: "AVAILABLE"
    case .unavailable: "UNAVAILABLE"
    }
  }

  var failureDetail: String? {
    if case .unavailable(let detail) = self { return detail }
    return nil
  }
}

/// A terminal test transition is app-local and never initiates bulk BLE work or recorder control.
/// Retained-log transfer is an explicit action on the Evidence screen.
enum DiscoveryGatewayOffloadPolicy {
  static func permits(
    transitionState: DiscoveryTestRunDraftState,
    acquisitionAuthority: DiscoveryMutationAuthority?,
    hasMatchingRecorderSession: Bool
  ) -> Bool {
    _ = transitionState
    _ = acquisitionAuthority
    _ = hasMatchingRecorderSession
    return false
  }
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
  private let evidenceOutboxBackground = EvidenceOutboxBackgroundCoordinator()
  private let evidenceWorkCoordinator = EvidenceWorkCoordinator()
  private let evidenceOutboxUploader = EvidenceOutboxUploader()
  private let synchronizedReferenceStore = SynchronizedReferenceStore()
  private let discoveryEvidence = DiscoveryEvidencePersistenceWorker()
  private let debugEvidenceAnnotationStore: DebugEvidenceAnnotationStore
  private var evidenceAutomationTask: Task<Void, Never>?
  private var canResearchTask: Task<Void, Never>?
  private var passiveCANExportTask: Task<Void, Never>?
  private var evidencePreparationTask: Task<Void, Never>?
  private var canResearchRevision: UInt64 = 0
  private var preparedEvidenceArtifactIdentities: Set<String> = []
  private var lastQueuedCaptureSyncGeneration: UInt64 = 0
  private var discoveryEvidenceFullyQueued = false
  private var preparedDiscoveryArtifactIdentities: Set<String> = []
  private static let evidenceEndpointDefaultsKey = "vhos.evidence-outbox.endpoint.v1"
  private static let evidenceAutomaticDefaultsKey = "vhos.evidence-outbox.automatic.v1"
  private static let debugUnverifiedWorkspaceDefaultsKey =
    "vhos.debug-unverified-evidence-workspace.v1"

  var errorMessage: String?
  var noticeMessage: String?
  private(set) var debugUnverifiedEvidenceModeActive = false
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
  var canResearchInProgress = false
  var canUnitsReport: CANUnitsReport?
  var canUnitsMessage = "No retained CAN unit analysis is available on this iPhone."
  /// Rolling live windows per pinned candidate field, fed by the passive
  /// CAN stream. Separate from `canUnitsReport`, which analyzes RETAINED
  /// evidence: the live lane answers "what is on the bus now", the report
  /// answers "what was in the archive". They share their transform math
  /// (CANUnitsAnalyzer.projectLive) so they can never disagree.
  private(set) var canLiveUnits = CANLiveUnitsAccumulator()
  /// Bumped on every accepted live sample so SwiftUI re-renders; the
  /// accumulator itself is a value type held privately.
  private(set) var canLiveUnitsRevision: UInt64 = 0
  /// Ticks while the live section is visible so freshness decays visibly
  /// even when the bus goes quiet.
  private(set) var canLiveUnitsClock = Date()
  private var canLiveUnitsSessionKey: String?
  var passiveCANPreparedExportURL: URL?
  var passiveCANExportInProgress = false
  var preparedEvidenceSyncURLs: [URL] = []
  var preparedEvidenceSyncHasMore = false
  var evidencePreparationInProgress = false
  var evidencePreparationMessage =
    "Prepare a bounded page of independently checksummed recovery artifacts."
  var discoveryMarkers: [StoredDiscoveryMarker] = []
  var discoveryMarkerMessage = "No synchronized Discovery markers are retained."
  var discoveryTestRuns: [DiscoveryTestRunDraft] = []
  var debugEvidenceAnnotations: [DebugEvidenceAnnotationRecord] = []
  var debugEvidenceObservations: [PassiveCANObservation] = []
  private var debugPinnedRunObservations: [String: PassiveCANObservation] = [:]
  var debugEvidenceAnnotationMessage = "No Debug evidence labels are retained."
  var discoveryTestRunLedgerReadState: DiscoveryLedgerReadState = .notLoaded
  var discoveryMarkerLedgerReadState: DiscoveryLedgerReadState = .notLoaded
  var discoveryDraftPreparedExportURLs: [URL] = []
  var discoveryDraftPreparedExportHasMore = false

  var discoveryMutationLedgersAvailable: Bool {
    discoveryTestRunLedgerReadState.isAvailable
      && discoveryMarkerLedgerReadState.isAvailable
  }

  var discoveryLedgerFailureDetail: String? {
    var failures: [String] = []
    if let detail = discoveryTestRunLedgerReadState.failureDetail {
      failures.append("Test-run ledger: \(detail)")
    }
    if let detail = discoveryMarkerLedgerReadState.failureDetail {
      failures.append("Marker ledger: \(detail)")
    }
    return failures.isEmpty ? nil : failures.joined(separator: " ")
  }

  var activeDiscoveryTestRun: DiscoveryTestRunDraft? {
    discoveryTestRuns.last(where: { $0.state == .active })
  }

  var discoveryTimelineCurrent: Bool {
    (try? currentDiscoveryObservation()) != nil
  }

  var localEvidenceTimelineCurrent: Bool {
    (try? currentDiscoveryObservation(allowLocalEvidenceOnly: true)) != nil
  }

  var developmentEvidenceLabTimelineAvailable: Bool {
    (try? currentDiscoveryObservation(allowDevelopmentEvidenceLab: true)) != nil
  }

  var debugUnverifiedTimelineAvailable: Bool {
    #if DEBUG
      !availableDebugEvidenceObservations.isEmpty
    #else
      false
    #endif
  }

  var availableDebugEvidenceObservations: [PassiveCANObservation] {
    #if DEBUG
      var observationsByID: [String: PassiveCANObservation] = [:]
      for record in debugEvidenceAnnotations {
        observationsByID[record.sourceObservation.id] = record.sourceObservation
      }
      for observation in debugEvidenceObservations {
        observationsByID[observation.id] = observation
      }
      for observation in debugPinnedRunObservations.values {
        observationsByID[observation.id] = observation
      }
      if let latest = gateway.latestCANObservation {
        observationsByID[latest.id] = latest
      }
      // Freshest-by-monotonic-clock order (2026-08-24 incident: the old
      // "largest sessionID first" sort let a wrapped legacy session value
      // win selection forever, stamping every marker with one frozen
      // evidence coordinate). Session ids are opaque labels, never a
      // recency signal; DiscoveryBindingPolicy owns the ordering rule.
      return DiscoveryBindingPolicy.presentationOrder(
        Array(observationsByID.values))
    #else
      []
    #endif
  }

  func discoveryMutationAuthority(
    for template: TestTemplate,
    allowLocalEvidenceOnly: Bool = false,
    allowDevelopmentEvidenceLab: Bool = false,
    allowUnrestrictedEvidenceWorkspace: Bool = false
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
        hasCurrentParkedAuthority: gateway.hasCurrentParkedAuthority),
      allowLocalEvidenceOnly: allowLocalEvidenceOnly,
      allowDevelopmentEvidenceLab: allowDevelopmentEvidenceLab,
      allowUnrestrictedEvidenceWorkspace: allowUnrestrictedEvidenceWorkspace)
  }

  func setDebugUnverifiedEvidenceMode(_ active: Bool) {
    #if DEBUG
      debugUnverifiedEvidenceModeActive =
        active && DiscoveryMutationPolicy.unrestrictedEvidenceWorkspaceAvailable
      UserDefaults.standard.set(
        debugUnverifiedEvidenceModeActive,
        forKey: Self.debugUnverifiedWorkspaceDefaultsKey)
    #else
      debugUnverifiedEvidenceModeActive = false
    #endif
  }

  func refreshDebugEvidenceAnnotations() {
    #if DEBUG
      let store = debugEvidenceAnnotationStore
      Task { [weak self] in
        do {
          let loaded = try await Task.detached(priority: .utility) {
            try store.load()
          }.value
          guard let self else { return }
          self.debugEvidenceAnnotations = loaded.records
          self.debugEvidenceAnnotationMessage = Self.debugAnnotationMessage(for: loaded)
        } catch {
          guard let self else { return }
          self.debugEvidenceAnnotations = []
          self.debugEvidenceAnnotationMessage =
            "Debug evidence labels failed closed: \(error.localizedDescription)"
        }
      }
    #else
      debugEvidenceAnnotationMessage = "Debug evidence labeling is unavailable in Release builds."
    #endif
  }

  func appendDebugEvidenceLabel(
    label: String,
    note: String,
    observationID: String
  ) {
    appendDebugEvidenceAnnotation(
      markerKind: nil,
      label: label,
      note: note,
      observationID: observationID)
  }

  func appendDebugEvidenceMarker(
    label: String,
    note: String,
    observationID: String
  ) {
    appendDebugEvidenceAnnotation(
      markerKind: .custom,
      label: label,
      note: note,
      observationID: observationID)
  }

  private func appendDebugEvidenceAnnotation(
    markerKind: DiscoveryMarkerKind?,
    label: String,
    note: String,
    observationID: String
  ) {
    #if DEBUG
      guard debugUnverifiedEvidenceModeActive else {
        errorMessage = AppModelError.debugModeNeeded.localizedDescription
        return
      }
      let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedLabel.isEmpty else {
        errorMessage = AppModelError.debugLabelNeeded.localizedDescription
        return
      }
      guard let observation = debugEvidenceObservation(withID: observationID) else {
        errorMessage = AppModelError.debugObservationNeeded.localizedDescription
        return
      }
      persistDebugEvidenceAnnotation(
        markerKind: markerKind,
        label: trimmedLabel,
        note: note.trimmingCharacters(in: .whitespacesAndNewlines),
        observation: observation)
    #else
      errorMessage = AppModelError.debugModeNeeded.localizedDescription
    #endif
  }

  private func debugEvidenceObservation(withID id: String) -> PassiveCANObservation? {
    for observation in availableDebugEvidenceObservations where observation.id == id {
      return observation
    }
    return nil
  }

  func hasDebugEvidenceObservation(gatewayID: String, sessionID: UInt32) -> Bool {
    #if DEBUG
      availableDebugEvidenceObservations.contains {
        $0.gatewayID == gatewayID && $0.sessionID == sessionID
      }
    #else
      false
    #endif
  }

  private func persistDebugEvidenceAnnotation(
    markerKind: DiscoveryMarkerKind?,
    label: String,
    note: String,
    observation: PassiveCANObservation
  ) {
    #if DEBUG
      let marker = markerKind
      let time = Self.timestamp()
      let store = debugEvidenceAnnotationStore
      Task { [weak self] in
        do {
          let loaded = try await Task.detached(priority: .utility) {
            if let marker {
              try store.appendEventMarker(
                appendedAt: time,
                markerKind: marker,
                label: label,
                note: note,
                observation: observation)
            } else {
              try store.appendLabel(
                appendedAt: time,
                label: label,
                note: note,
                observation: observation)
            }
            return try store.load()
          }.value
          guard let self else { return }
          self.debugEvidenceAnnotations = loaded.records
          self.debugEvidenceAnnotationMessage = Self.debugAnnotationMessage(for: loaded)
          self.noticeMessage =
            "DEBUG_UNVERIFIED evidence was appended to exact observation \(observation.id)."
          self.errorMessage = nil
        } catch {
          self?.errorMessage = error.localizedDescription
        }
      }
    #else
      errorMessage = AppModelError.debugModeNeeded.localizedDescription
    #endif
  }

  private static func debugAnnotationMessage(
    for loaded: DebugEvidenceAnnotationLoadResult
  ) -> String {
    let retained =
      loaded.records.isEmpty
      ? "No Debug evidence labels are retained."
      : "\(loaded.records.count) DEBUG_UNVERIFIED label or event record(s) retained."
    guard let recovery = loaded.recovery else { return retained }
    return retained
      + " Recovered an interrupted append and quarantined "
      + "\(recovery.quarantinedByteCount) unfinished byte(s)."
  }

  private init() {
    let store = KeyStore(service: "com.isaiahdupree.VehicleHealthOS")
    let support =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    debugEvidenceAnnotationStore = DebugEvidenceAnnotationStore(
      storageDirectory: support.appendingPathComponent(
        "VHOSDebugEvidenceAnnotations/v1", isDirectory: true))
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
    #if DEBUG
      let storedDebugPreference = UserDefaults.standard.object(
        forKey: Self.debugUnverifiedWorkspaceDefaultsKey)
      debugUnverifiedEvidenceModeActive =
        DiscoveryMutationPolicy.unrestrictedEvidenceWorkspaceAvailable
        && (storedDebugPreference == nil
          || UserDefaults.standard.bool(forKey: Self.debugUnverifiedWorkspaceDefaultsKey))
    #endif
    evidenceOutboxTokenConfigured =
      (try? store.data(for: .evidenceOutboxBearerToken)) != nil
    refreshEvidenceOutboxStatus()
    Task { @MainActor [weak self] in await self?.refreshSynchronizedReferenceStatus() }
    refreshCANResearch()
    refreshDiscoveryEvidence()
    refreshDebugEvidenceAnnotations()
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
    guard evidencePreparationTask == nil else { return }
    evidencePreparationTask = Task { [weak self] in
      guard let self else { return }
      await self.queueEvidencePageForAI(mode: .manual(maximumArtifacts: 8))
      self.evidencePreparationTask = nil
    }
  }

  @discardableResult
  private func queueEvidencePageForAI(
    mode: EvidenceOutboxEnqueueMode
  ) async -> Bool {
    guard gateway.portableFrameIntegrityError == nil else {
      evidenceOutboxMessage =
        "Portable evidence integrity is unresolved; automatic queueing remains blocked."
      return false
    }
    evidencePreparationInProgress = true
    defer { evidencePreparationInProgress = false }
    do {
      let knownIdentities = try await evidenceOutboxBackground.knownArtifactIdentities()
      let maximumArtifacts: Int
      switch mode {
      case .automatic:
        maximumArtifacts = EvidenceOutboxBackgroundCoordinator.automaticPageSize
      case .manual(let requested):
        maximumArtifacts = requested
      }
      let snapshot = try await gateway.makePortableEvidenceWorkSnapshot(
        excludingArtifactIdentities: knownIdentities,
        maximumArtifacts: maximumArtifacts)
      let page = try await evidenceWorkCoordinator.prepareEvidencePage(
        snapshot,
        creator: evidenceBundleCreator,
        outputDirectory: evidenceTemporaryDirectory)
      let result = try await evidenceOutboxBackground.enqueuePage(
        page.artifacts.map {
          EvidenceOutboxFileArtifact(
            identity: $0.artifactIdentity,
            url: $0.url,
            contentType: $0.contentType,
            expectedByteCount: $0.byteCount,
            expectedSHA256: $0.sha256)
        },
        mode: mode)
      refreshEvidenceOutboxStatus()
      evidenceOutboxMessage =
        "Queued \(result.insertedPackages) new artifact(s), confirmed "
        + "\(result.deduplicatedPackages + result.skippedKnownArtifacts) existing; "
        + (page.hasMore
          ? "more immutable evidence remains for the next bounded cycle."
          : "every immutable generation and import-lineage artifact is represented.")
      errorMessage = nil
      return !page.hasMore
    } catch {
      if error is PortableFrameStoreError {
        gateway.reportPortableFrameIntegrityFailure(error)
      }
      errorMessage = error.localizedDescription
      evidenceOutboxMessage = "Evidence queueing failed closed: \(error.localizedDescription)"
      return false
    }
  }

  private var evidenceBundleCreator: EvidenceBundleCreator {
    let info = Bundle.main.infoDictionary
    return EvidenceBundleCreator(
      platform: "IOS",
      applicationID: Bundle.main.bundleIdentifier ?? "com.isaiahdupree.VehicleHealthOS",
      applicationVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
      deviceModel: UIDevice.current.model)
  }

  private var evidenceTemporaryDirectory: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "VehicleHealthOS-Evidence", isDirectory: true)
  }

  private var discoveryEvidenceTemporaryDirectory: URL {
    evidenceTemporaryDirectory.appendingPathComponent("DiscoverySegments", isDirectory: true)
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
    defer { evidenceOutboxUploadInProgress = false }
    do {
      for record in try await evidenceOutboxBackground.pendingRecords(maximumCount: 8) {
        do {
          try await evidenceOutboxUploader.upload(
            record,
            payloadURL: try await evidenceOutboxBackground.payloadURL(for: record),
            endpoint: endpoint,
            bearerToken: token
          )
          try await evidenceOutboxBackground.markUploaded(record)
          evidenceOutboxMessage = "Uploaded evidence package \(record.id.uuidString)."
        } catch {
          try? await evidenceOutboxBackground.markAttempt(
            record, error: error.localizedDescription)
          evidenceOutboxMessage = "Private upload paused: \(error.localizedDescription)"
          await reloadEvidenceOutboxStatus()
          return
        }
      }
    } catch {
      evidenceOutboxMessage = error.localizedDescription
    }
    await reloadEvidenceOutboxStatus()
  }

  private func runEvidenceAutomationCycle() async {
    await retainStandardOBDReferences()
    let generation = gateway.captureSyncCompletionGeneration
    if generation > lastQueuedCaptureSyncGeneration {
      refreshCANResearch()
      let complete = await queueEvidencePageForAI(mode: .automatic)
      if complete { lastQueuedCaptureSyncGeneration = generation }
    }
    if !discoveryEvidenceFullyQueued, discoveryMutationLedgersAvailable,
      !discoveryTestRuns.isEmpty || !discoveryMarkers.isEmpty
    {
      await queueDiscoveryDraftEvidenceForAI()
    }
    if automaticEvidenceUpload { await processEvidenceOutbox() }
  }

  func recordTechstreamReference(signalID: String, valueText: String, unit: String) async {
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
      _ = try await synchronizedReferenceStore.append(sample)
      await refreshSynchronizedReferenceStatus()
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
      try requireDiscoveryMutationLedgers()
      guard let run = activeDiscoveryTestRun,
        DiscoveryMutationPolicy.testRunIdentityMatches(
          template: template,
          templateID: run.templateID,
          templateVersion: run.templateVersion)
      else {
        throw AppModelError.discoveryTestRunRequired
      }
      let runUsesDevelopmentEvidenceLab =
        run.acquisitionAuthority == .developmentEvidenceLab
      let runUsesDebugUnverified = run.acquisitionAuthority == .debugUnverified
      let currentAuthority = discoveryMutationAuthority(
        for: template,
        allowLocalEvidenceOnly: run.acquisitionAuthority == .localEvidenceOnly,
        allowDevelopmentEvidenceLab: runUsesDevelopmentEvidenceLab,
        allowUnrestrictedEvidenceWorkspace: runUsesDebugUnverified)
      guard run.acquisitionAuthority?.permitsContinuation(with: currentAuthority) == true
      else {
        throw AppModelError.discoveryEvidenceAuthorityRequired
      }
      let observation = try currentDiscoveryObservation(
        allowLocalEvidenceOnly: run.acquisitionAuthority == .localEvidenceOnly,
        allowDevelopmentEvidenceLab: runUsesDevelopmentEvidenceLab,
        allowUnrestrictedEvidenceWorkspace: runUsesDebugUnverified,
        preferredGatewayID: runUsesDebugUnverified ? run.gatewayID : nil,
        preferredSessionID: runUsesDebugUnverified ? run.gatewaySessionID : nil,
        lastRecordedMarker: lastRecordedMarkerContext(forTestRunID: run.id))
      if run.templateID == DiscoveryMutationPolicy.parkSelectorBootstrapTemplateID,
        !runUsesDebugUnverified
      {
        let storedMarkers = bootstrapMarkerRecords(for: run)
        let recorded = storedMarkers.map {
          DiscoveryOrderedMarkerRequirement(kind: $0.marker.kind, label: $0.label)
        }
        guard
          DiscoveryMutationPolicy.nextParkSelectorBootstrapMarker(after: recorded)
            == DiscoveryOrderedMarkerRequirement(kind: kind, label: label)
        else { throw AppModelError.discoveryMarkerSequenceRequired }
        if let last = storedMarkers.last {
          let remaining =
            DiscoveryMutationPolicy.parkSelectorBootstrapDwellRemainingMicroseconds(
              after: DiscoveryOrderedMarkerRequirement(
                kind: last.marker.kind, label: last.label),
              lastMarkerMonotonicMicroseconds: last.marker.gatewayMonotonicMicroseconds,
              currentMonotonicMicroseconds: observation.monotonicMicroseconds)
          guard remaining == 0 else {
            throw AppModelError.discoveryMarkerDwellRequired(
              Int((remaining + 999_999) / 1_000_000))
          }
        }
      }
      let recordedAt = Self.timestamp()
      Task { @MainActor [weak self] in
        guard let self else { return }
        do {
          let stored = try await self.discoveryEvidence.append(
            template: template,
            testRun: run,
            kind: kind,
            label: label,
            observation: observation,
            recordedAt: recordedAt)
          self.discoveryEvidenceFullyQueued = false
          await self.reloadDiscoveryEvidence()
          self.discoveryMarkerMessage =
            "Recorded \(stored.marker.kind.rawValue) at source sequence \(observation.sourceSequence)."
          self.noticeMessage = self.discoveryMarkerMessage
          self.errorMessage = nil
        } catch {
          self.errorMessage = error.localizedDescription
        }
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func beginDiscoveryTestRun(
    template: TestTemplate,
    allowLocalEvidenceOnly: Bool = false,
    allowDevelopmentEvidenceLab: Bool = false,
    ownerSafetyAcknowledgedAt: String?
  ) {
    do {
      try requireDiscoveryMutationLedgers()
      guard
        let acquisitionAuthority = discoveryMutationAuthority(
          for: template,
          allowLocalEvidenceOnly: allowLocalEvidenceOnly,
          allowDevelopmentEvidenceLab: allowDevelopmentEvidenceLab,
          allowUnrestrictedEvidenceWorkspace: debugUnverifiedEvidenceModeActive)
      else {
        throw AppModelError.discoveryEvidenceAuthorityRequired
      }
      let observation = try currentDiscoveryObservation(
        allowLocalEvidenceOnly: allowLocalEvidenceOnly,
        allowDevelopmentEvidenceLab: allowDevelopmentEvidenceLab,
        allowUnrestrictedEvidenceWorkspace: debugUnverifiedEvidenceModeActive)
      let recordedAt = Self.timestamp()
      guard
        DiscoveryMutationPolicy.ownerSafetyAcknowledgementIsValid(
          ownerSafetyAcknowledgedAt,
          runStartedAt: recordedAt,
          required: acquisitionAuthority.requiresOwnerSafetyAcknowledgement)
      else { throw AppModelError.discoveryOwnerSafetyAcknowledgementRequired }
      Task { @MainActor [weak self] in
        guard let self else { return }
        do {
          let run = try await self.discoveryEvidence.beginTestRun(
            template: template,
            observation: observation,
            recordedAt: recordedAt,
            acquisitionAuthority: acquisitionAuthority,
            ownerSafetyAcknowledgedAt: ownerSafetyAcknowledgedAt)
          if acquisitionAuthority == .debugUnverified {
            self.debugPinnedRunObservations[run.id] = observation
          }
          self.discoveryEvidenceFullyQueued = false
          await self.reloadDiscoveryEvidence()
          self.noticeMessage =
            "Test run draft \(run.id) began on gateway session \(run.gatewaySessionID)."
          self.errorMessage = nil
        } catch {
          self.errorMessage = error.localizedDescription
        }
      }
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
      try requireDiscoveryTestRunLedger()
      if state == .ended { try requireDiscoveryMutationLedgers() }
      guard let run = activeDiscoveryTestRun else {
        throw AppModelError.discoveryTestRunRequired
      }
      let runUsesDevelopmentEvidenceLab =
        run.acquisitionAuthority == .developmentEvidenceLab
      let runUsesDebugUnverified = run.acquisitionAuthority == .debugUnverified
      let endObservation =
        state == .ended
        ? try currentDiscoveryObservation(
          allowLocalEvidenceOnly: run.acquisitionAuthority == .localEvidenceOnly,
          allowDevelopmentEvidenceLab: runUsesDevelopmentEvidenceLab,
          allowUnrestrictedEvidenceWorkspace: runUsesDebugUnverified,
          preferredGatewayID: runUsesDebugUnverified ? run.gatewayID : nil,
          preferredSessionID: runUsesDebugUnverified ? run.gatewaySessionID : nil) : nil
      var discoveryAuthority: DiscoveryMutationAuthority?
      if state == .ended {
        if run.templateID == DiscoveryMutationPolicy.parkSelectorBootstrapTemplateID {
          let template = try DiscoveryMutationPolicy.parkSelectorBootstrapTemplate()
          guard
            DiscoveryMutationPolicy.testRunIdentityMatches(
              template: template,
              templateID: run.templateID,
              templateVersion: run.templateVersion)
          else { throw AppModelError.discoveryTestRunRequired }
          discoveryAuthority = discoveryMutationAuthority(
            for: template,
            allowLocalEvidenceOnly: run.acquisitionAuthority == .localEvidenceOnly,
            allowDevelopmentEvidenceLab: runUsesDevelopmentEvidenceLab,
            allowUnrestrictedEvidenceWorkspace: runUsesDebugUnverified)
          guard
            run.acquisitionAuthority?.permitsContinuation(with: discoveryAuthority) == true
          else {
            throw AppModelError.discoveryEvidenceAuthorityRequired
          }
          if !runUsesDebugUnverified {
            guard
              DiscoveryMutationPolicy.parkSelectorBootstrapIsComplete(
                orderedBootstrapMarkers(for: run))
            else { throw AppModelError.discoveryTestIncomplete }
            if let last = bootstrapMarkerRecords(for: run).last,
              let endObservation
            {
              let remaining =
                DiscoveryMutationPolicy.parkSelectorBootstrapDwellRemainingMicroseconds(
                  after: DiscoveryOrderedMarkerRequirement(
                    kind: last.marker.kind, label: last.label),
                  lastMarkerMonotonicMicroseconds: last.marker.gatewayMonotonicMicroseconds,
                  currentMonotonicMicroseconds: endObservation.monotonicMicroseconds)
              guard remaining == 0 else {
                throw AppModelError.discoveryMarkerDwellRequired(
                  Int((remaining + 999_999) / 1_000_000))
              }
            }
          }
        } else if !runUsesDebugUnverified {
          guard gateway.hasCurrentParkedAuthority else {
            throw AppModelError.discoveryParkedStateRequired
          }
        }
      }
      let recordedAt = Self.timestamp()
      Task { @MainActor [weak self] in
        guard let self else { return }
        do {
          let updated = try await self.discoveryEvidence.transitionTestRun(
            run,
            to: state,
            observation: endObservation,
            recordedAt: recordedAt)
          self.discoveryEvidenceFullyQueued = false
          await self.reloadDiscoveryEvidence()
          self.discoveryMarkerMessage =
            "Test run draft \(updated.id) is \(updated.state.rawValue)."
          await self.queueDiscoveryDraftEvidenceForAI()
          let hasMatchingRecorderSession =
            self.gateway.state == .vhosConnected
            && self.gateway.hasCurrentGatewayHealth
            && self.gateway.handshake?.gatewayID == run.gatewayID
            && self.gateway.health?.captureSessionID == run.gatewaySessionID
          if state == .ended, run.acquisitionAuthority?.isAppLocalEvidenceOnly == true {
            self.noticeMessage =
              "App-local evidence test ended. Append-only iPhone frames and markers are retained and queued for experimental analysis; no gateway command or PARKED claim was issued. Recover gateway history later from Evidence."
            self.errorMessage = nil
          } else if state == .ended,
            DiscoveryGatewayOffloadPolicy.permits(
              transitionState: state,
              acquisitionAuthority: run.acquisitionAuthority,
              hasMatchingRecorderSession: hasMatchingRecorderSession)
          {
            do {
              try self.gateway.pauseCaptureAndDownloadHistory()
              self.noticeMessage =
                "Test ended and retained. The recorder is pausing, offloading the current and previous CAN history, then resuming automatically."
              self.errorMessage = nil
            } catch {
              self.noticeMessage =
                "Test ended and its append-only markers are retained, but automatic CAN-history offload could not start."
              self.errorMessage = error.localizedDescription
            }
          } else if state == .ended {
            self.noticeMessage =
              "Legacy test ended with all append-only markers retained. Its pre-upgrade acquisition scope was not recorded, so the app issued no gateway command; recover history manually from Evidence."
            self.errorMessage = nil
          } else if state == .aborted,
            run.acquisitionAuthority?.isAppLocalEvidenceOnly == true
          {
            self.noticeMessage =
              "App-local evidence test aborted. Previously recorded iPhone frames and markers remain append-only evidence; no gateway command or PARKED claim was issued."
            self.errorMessage = nil
          } else if DiscoveryGatewayOffloadPolicy.permits(
            transitionState: state,
            acquisitionAuthority: run.acquisitionAuthority,
            hasMatchingRecorderSession: hasMatchingRecorderSession)
          {
            do {
              try self.gateway.pauseCaptureAndDownloadHistory()
              self.noticeMessage =
                "Test aborted and its markers remain append-only evidence. The matching recorder session is pausing, offloading retained CAN history, then resuming automatically."
              self.errorMessage = nil
            } catch {
              self.noticeMessage =
                "Test aborted and its markers remain append-only evidence, but recovery offload for the matching recorder session could not start."
              self.errorMessage = error.localizedDescription
            }
          } else {
            self.noticeMessage =
              "Test run draft aborted; all previously recorded markers remain append-only evidence. Open Evidence after reconnecting to recover its retained gateway session."
            self.errorMessage = nil
          }
          if state == .ended {
            self.noticeMessage =
              "Test ended. Frames and markers are retained for analysis; the recorder remains live and bulk transfer waits for an explicit Evidence action."
            self.errorMessage = nil
          } else if state == .aborted {
            self.noticeMessage =
              "Test aborted. Existing frames and markers remain append-only evidence; no recorder command was sent."
            self.errorMessage = nil
          }
        } catch {
          self.errorMessage = error.localizedDescription
        }
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func orderedBootstrapMarkers(
    for run: DiscoveryTestRunDraft
  ) -> [DiscoveryOrderedMarkerRequirement] {
    bootstrapMarkerRecords(for: run).map {
      DiscoveryOrderedMarkerRequirement(kind: $0.marker.kind, label: $0.label)
    }
  }

  private func bootstrapMarkerRecords(
    for run: DiscoveryTestRunDraft
  ) -> [StoredDiscoveryMarker] {
    discoveryMarkers.filter { $0.testRunID == run.id }
  }

  private func refreshDiscoveryEvidence() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.reloadDiscoveryEvidence()
    }
  }

  private func reloadDiscoveryEvidence() async {
    do {
      discoveryTestRuns = try await discoveryEvidence.testRuns()
      discoveryTestRunLedgerReadState = .available
    } catch {
      discoveryTestRuns = []
      discoveryTestRunLedgerReadState = .unavailable(error.localizedDescription)
    }

    do {
      discoveryMarkers = try await discoveryEvidence.markers()
      discoveryMarkerLedgerReadState = .available
    } catch {
      discoveryMarkers = []
      discoveryMarkerLedgerReadState = .unavailable(error.localizedDescription)
    }

    await refreshDebugRunObservationPins()

    if let failure = discoveryLedgerFailureDetail {
      discoveryMarkerMessage =
        "Discovery evidence read failed closed. \(failure) Committed ledger bytes remain untouched; no record was skipped, deleted, rewritten, or used for authority."
      return
    }

    let retainedMessage =
      discoveryMarkers.isEmpty
      ? "No synchronized Discovery markers are retained."
      : "\(discoveryMarkers.count) append-only Discovery marker(s) retained on this iPhone."
    let recoveries = await discoveryEvidence.recoveryReports()
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
  }

  private func refreshDebugRunObservationPins() async {
    #if DEBUG
      let activeRuns = discoveryTestRuns.filter {
        $0.state == .active && $0.acquisitionAuthority == .debugUnverified
      }
      var retained: [String: PassiveCANObservation] = [:]
      for run in activeRuns {
        if let existing = debugPinnedRunObservations[run.id],
          existing.gatewayID == run.gatewayID,
          existing.sessionID == run.gatewaySessionID,
          existing.sourceSequence == run.firstSourceSequence
        {
          retained[run.id] = existing
          continue
        }
        if let observation = try? await gateway.retainedPassiveCANObservation(
          gatewayID: run.gatewayID,
          sessionID: run.gatewaySessionID,
          sourceSequence: run.firstSourceSequence)
        {
          retained[run.id] = observation
        }
      }
      debugPinnedRunObservations = retained
    #else
      debugPinnedRunObservations = [:]
    #endif
  }

  func retryDiscoveryEvidenceLoad() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.reloadDiscoveryEvidence()
      if let failure = self.discoveryLedgerFailureDetail {
        self.errorMessage = failure
        self.noticeMessage = nil
      } else {
        self.errorMessage = nil
        self.noticeMessage =
          "Discovery evidence ledgers were re-read without changing retained bytes."
      }
    }
  }

  private func requireDiscoveryTestRunLedger() throws {
    guard discoveryTestRunLedgerReadState.isAvailable else {
      throw AppModelError.discoveryLedgerUnavailable(
        discoveryTestRunLedgerReadState.failureDetail ?? "The test-run ledger has not loaded.")
    }
  }

  private func requireDiscoveryMutationLedgers() throws {
    guard discoveryMutationLedgersAvailable else {
      throw AppModelError.discoveryLedgerUnavailable(
        discoveryLedgerFailureDetail ?? "The Discovery evidence ledgers have not loaded.")
    }
  }

  private func queueDiscoveryDraftEvidenceForAI() async {
    do {
      let knownIdentities = try await evidenceOutboxBackground.knownArtifactIdentities()
      let page = try await discoveryEvidence.prepareExportPage(
        excludingArtifactIdentities: knownIdentities,
        maximumArtifacts: EvidenceOutboxBackgroundCoordinator.automaticPageSize,
        outputDirectory: discoveryEvidenceTemporaryDirectory)
      let result = try await evidenceOutboxBackground.enqueuePage(
        page.artifacts.map {
          EvidenceOutboxFileArtifact(
            identity: $0.identity,
            url: $0.url,
            contentType: "application/vnd.vhos.discovery-draft-evidence+json",
            expectedByteCount: $0.byteCount,
            expectedSHA256: $0.sha256)
        },
        mode: .automatic)
      discoveryEvidenceFullyQueued = !page.hasMore
      refreshEvidenceOutboxStatus()
      evidenceOutboxMessage =
        "Queued \(result.insertedPackages) new Discovery segment(s), confirmed "
        + "\(result.deduplicatedPackages + result.skippedKnownArtifacts) existing; "
        + (page.hasMore
          ? "more bounded Discovery evidence remains for the next automatic cycle."
          : "every append-only Discovery ledger record is represented.")
      if automaticEvidenceUpload { await processEvidenceOutbox() }
    } catch {
      evidenceOutboxMessage =
        "Discovery draft evidence remains local: \(error.localizedDescription)"
    }
  }

  /// The last marker already committed for a test run, as forward-progress
  /// context for the binding policy: a second tap in the same gateway
  /// session must land strictly later on the monotonic clock.
  func lastRecordedMarkerContext(forTestRunID runID: String?)
    -> DiscoveryBindingPolicy.RecordedMarkerContext?
  {
    guard let runID else { return nil }
    return discoveryMarkers
      .filter { $0.testRunID == runID && $0.hasPlausibleSession }
      .max { $0.marker.gatewayMonotonicMicroseconds < $1.marker.gatewayMonotonicMicroseconds }
      .map {
        DiscoveryBindingPolicy.RecordedMarkerContext(
          gatewaySessionID: $0.gatewaySessionID,
          gatewayMonotonicMicroseconds: $0.marker.gatewayMonotonicMicroseconds)
      }
  }

  /// What the next marker would bind to right now, for the active run's
  /// authority mode — the SAME selection the writer uses, exposed so the
  /// readiness card can never promise one binding while the ledger
  /// records another (2026-08-24 incident: the card showed the live
  /// observation while debug-workspace markers bound to an archive pick).
  func discoveryBindingPreview(
    allowLocalEvidenceOnly: Bool = false,
    allowDevelopmentEvidenceLab: Bool = false,
    allowUnrestrictedEvidenceWorkspace: Bool = false,
    preferredGatewayID: String? = nil,
    preferredSessionID: UInt32? = nil,
    testRunID: String? = nil
  ) -> PassiveCANObservation? {
    try? currentDiscoveryObservation(
      allowLocalEvidenceOnly: allowLocalEvidenceOnly,
      allowDevelopmentEvidenceLab: allowDevelopmentEvidenceLab,
      allowUnrestrictedEvidenceWorkspace: allowUnrestrictedEvidenceWorkspace,
      preferredGatewayID: preferredGatewayID,
      preferredSessionID: preferredSessionID,
      lastRecordedMarker: lastRecordedMarkerContext(forTestRunID: testRunID))
  }

  private func currentDiscoveryObservation(
    allowLocalEvidenceOnly: Bool = false,
    allowDevelopmentEvidenceLab: Bool = false,
    allowUnrestrictedEvidenceWorkspace: Bool = false,
    preferredGatewayID: String? = nil,
    preferredSessionID: UInt32? = nil,
    lastRecordedMarker: DiscoveryBindingPolicy.RecordedMarkerContext? = nil
  ) throws -> PassiveCANObservation {
    #if DEBUG
      if allowUnrestrictedEvidenceWorkspace, !availableDebugEvidenceObservations.isEmpty {
        switch DiscoveryBindingPolicy.selectBindingObservation(
          from: availableDebugEvidenceObservations,
          preferredGatewayID: preferredGatewayID,
          preferredSessionID: preferredSessionID,
          lastRecordedMarker: lastRecordedMarker)
        {
        case .success(let observation):
          return observation
        case .failure(.timelineStalled):
          throw AppModelError.discoveryMarkerTimelineStalled
        case .failure:
          throw AppModelError.discoveryCurrentTimelineRequired
        }
      }
      if allowDevelopmentEvidenceLab {
        guard let observation = gateway.latestCANObservation,
          observation.listenOnly,
          (try? PassiveCANEvidenceArchive.validate(observation)) != nil,
          let receivedAt = gateway.latestCANObservationReceivedAt,
          (0...DiscoveryMutationPolicy.freshnessLimitSeconds).contains(
            Date().timeIntervalSince(receivedAt)),
          gateway.health?.listenOnly != false,
          gateway.health?.vehicleMotion != .moving,
          gateway.handshake?.listenOnly != false,
          gateway.handshake.map({ $0.gatewayID == observation.gatewayID }) ?? true
        else { throw AppModelError.discoveryCurrentTimelineRequired }
        return try Self.requireForwardProgress(observation, after: lastRecordedMarker)
      }
    #endif

    guard gateway.state == .vhosConnected,
      let handshake = gateway.handshake,
      handshake.listenOnly,
      let observation = gateway.latestCANObservation,
      observation.gatewayID == handshake.gatewayID, observation.listenOnly,
      let receivedAt = gateway.latestCANObservationReceivedAt
    else { throw AppModelError.discoveryCurrentTimelineRequired }
    let age = Date().timeIntervalSince(receivedAt)
    guard age >= 0, age <= 5 else { throw AppModelError.discoveryCurrentTimelineRequired }
    if allowLocalEvidenceOnly {
      return try Self.requireForwardProgress(observation, after: lastRecordedMarker)
    }
    guard gateway.hasCurrentGatewayHealth,
      let health = gateway.health,
      health.listenOnly,
      let currentSessionID = health.captureSessionID,
      observation.sessionID == currentSessionID
    else { throw AppModelError.discoveryCurrentTimelineRequired }
    return try Self.requireForwardProgress(observation, after: lastRecordedMarker)
  }

  /// Two markers may never share an evidence coordinate: within one
  /// gateway session, each new marker must bind strictly later on the
  /// monotonic clock than the run's previous marker. A stalled timeline
  /// (frozen replay archive, wedged frame stream) surfaces as an error
  /// instead of silently appending duplicate coordinates to the
  /// append-only ledger.
  private static func requireForwardProgress(
    _ observation: PassiveCANObservation,
    after lastRecordedMarker: DiscoveryBindingPolicy.RecordedMarkerContext?
  ) throws -> PassiveCANObservation {
    if let last = lastRecordedMarker,
      observation.sessionID == last.gatewaySessionID,
      observation.monotonicMicroseconds <= last.gatewayMonotonicMicroseconds
    {
      throw AppModelError.discoveryMarkerTimelineStalled
    }
    return observation
  }

  func pauseDownloadAndResumeGatewayHistory() {
    do {
      guard gateway.state == .vhosConnected else {
        throw AppModelError.gatewayHealthRequired
      }
      guard gateway.hasCurrentParkedAuthority else {
        throw AppModelError.discoveryParkedStateRequired
      }
      guard gateway.canStartOwnerTriggeredHistoryTransfer else {
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

  func synchronizedReferenceExportURL() async throws -> URL {
    try await synchronizedReferenceStore.exportURL()
  }

  func prepareDiscoveryDraftEvidenceExport() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        if !self.discoveryDraftPreparedExportHasMore,
          !self.discoveryDraftPreparedExportURLs.isEmpty
        {
          self.preparedDiscoveryArtifactIdentities.removeAll()
          self.discoveryDraftPreparedExportURLs.removeAll()
        }
        let page = try await self.discoveryEvidence.prepareExportPage(
          excludingArtifactIdentities: self.preparedDiscoveryArtifactIdentities,
          maximumArtifacts: 8,
          outputDirectory: self.discoveryEvidenceTemporaryDirectory)
        for artifact in page.artifacts
        where self.preparedDiscoveryArtifactIdentities.insert(artifact.identity).inserted {
          self.discoveryDraftPreparedExportURLs.append(artifact.url)
        }
        self.discoveryDraftPreparedExportHasMore = page.hasMore
        self.noticeMessage =
          "Prepared \(self.discoveryDraftPreparedExportURLs.count) bounded Discovery segment(s). "
          + (page.hasMore
            ? "Prepare the next page to cover the remaining immutable ledger cursors."
            : "This share set covers every Discovery binding, test-run snapshot, and marker.")
        self.errorMessage = nil
      } catch {
        self.discoveryDraftPreparedExportURLs.removeAll()
        self.preparedDiscoveryArtifactIdentities.removeAll()
        self.discoveryDraftPreparedExportHasMore = false
        self.errorMessage = error.localizedDescription
      }
    }
  }

  private func retainStandardOBDReferences() async {
    do {
      let references = try gateway.standardOBDSamples.map { sample in
        try SynchronizedReferenceSample(
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
      }
      let inserted = try await synchronizedReferenceStore.append(references)
      if inserted > 0 {
        await refreshSynchronizedReferenceStatus()
        synchronizedReferenceMessage = "Retained \(inserted) new standard OBD reference sample(s)."
      }
    } catch {
      synchronizedReferenceMessage = "Reference retention paused: \(error.localizedDescription)"
    }
  }

  private func refreshSynchronizedReferenceStatus() async {
    do {
      synchronizedReferenceCount = try await synchronizedReferenceStore.count()
      if synchronizedReferenceCount > 0 {
        synchronizedReferenceMessage =
          "\(synchronizedReferenceCount) append-only synchronized reference sample(s) retained."
      }
    } catch {
      synchronizedReferenceCount = 0
      synchronizedReferenceMessage =
        "Synchronized reference evidence is unavailable: \(error.localizedDescription)"
    }
  }

  private func refreshEvidenceOutboxStatus() {
    Task { @MainActor [weak self] in
      await self?.reloadEvidenceOutboxStatus()
    }
  }

  private func reloadEvidenceOutboxStatus() async {
    do {
      let status = try await evidenceOutboxBackground.status()
      evidenceOutboxPendingCount = status.pendingCount
      evidenceOutboxUploadedCount = status.acknowledgedUploadCount
      if status.pendingCount == 0 {
        evidenceOutboxMessage = "No evidence is queued."
      }
    } catch {
      evidenceOutboxMessage = "Evidence outbox status failed closed: \(error.localizedDescription)"
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

  func preparePassiveCANExport() {
    guard passiveCANExportTask == nil else { return }
    passiveCANExportInProgress = true
    passiveCANExportTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.passiveCANExportInProgress = false
        self.passiveCANExportTask = nil
      }
      do {
        let snapshot = try await self.gateway.makePassiveCANWorkSnapshot()
        let export = try await self.evidenceWorkCoordinator.preparePassiveCANExport(
          snapshot,
          outputDirectory: self.evidenceTemporaryDirectory)
        self.passiveCANPreparedExportURL = export.url
        self.noticeMessage =
          "Prepared \(export.recordCount.formatted()) recent validated CAN observations"
          + (export.excludesEarlierCaptureBytes
            ? " from the bounded 16 MiB research window; older source logs remain unchanged."
            : ".")
        self.errorMessage = nil
      } catch {
        if error is PortableFrameStoreError {
          self.gateway.reportPortableFrameIntegrityFailure(error)
        }
        self.errorMessage = error.localizedDescription
      }
    }
  }

  /// Feed the newest passive CAN observation into the live windows.
  ///
  /// Only listen-only frames from the connected gateway's CURRENT capture
  /// session are accepted, and a session change clears every window —
  /// blending two capture sessions into one rolling graph would present a
  /// discontinuity as if it were vehicle behavior.
  func ingestLiveCANObservation(_ observation: PassiveCANObservation?) {
    ingestLiveCANObservations(observation.map { [$0] } ?? [])
  }

  /// Drain an arrival-ordered recent gateway window into the live channels.
  ///
  /// This is intentionally idempotent. The gateway retains a bounded recent
  /// window, so processing the whole window on navigation and after a
  /// coalesced UI update cannot lose a matching frame or double-count one.
  func ingestLiveCANObservations(_ observations: [PassiveCANObservation]) {
    guard gateway.state == .vhosConnected,
      let gatewayID = gateway.handshake?.gatewayID,
      let sessionID = gateway.health?.captureSessionID
    else {
      resetLiveCANContext()
      return
    }
    let sessionKey = "\(gatewayID):\(sessionID)"
    if canLiveUnitsSessionKey != sessionKey {
      let hadSamples = canLiveUnits.hasSamples
      canLiveUnits.reset()
      canLiveUnitsSessionKey = sessionKey
      if hadSamples {
        canLiveUnitsRevision &+= 1
        canLiveUnitsClock = Date()
      }
    }
    let updated = canLiveUnits.ingestCurrentSession(
      observations, gatewayID: gatewayID, sessionID: sessionID)
    guard !updated.isEmpty else { return }
    canLiveUnitsRevision &+= 1
    canLiveUnitsClock = Date()
  }

  private func resetLiveCANContext() {
    guard canLiveUnitsSessionKey != nil || canLiveUnits.hasSamples else { return }
    canLiveUnits.reset()
    canLiveUnitsSessionKey = nil
    canLiveUnitsRevision &+= 1
    canLiveUnitsClock = Date()
  }

  /// Advance the freshness clock so a quiet bus visibly decays to STALE
  /// rather than sitting frozen at its last value.
  func tickLiveCANClock() { canLiveUnitsClock = Date() }

  /// Candidate fields that have actually produced a live sample, in
  /// catalog order — the selectable set.
  var liveCANFields: [CANLiveFieldDescriptor] {
    _ = canLiveUnitsRevision
    return canLiveUnits.observedFields
  }

  /// Recently observed exact raw identifiers, including identifiers that
  /// also feed separate pinned candidate fields. Raw frames never acquire a
  /// signal name or unit.
  var liveRawCANIdentifiers: [CANLiveRawIdentifierDescriptor] {
    _ = canLiveUnitsRevision
    return canLiveUnits.observedRawIdentifiers
  }

  func liveCANChannel(for fieldID: String) -> CANLiveChannel? {
    _ = canLiveUnitsRevision
    return canLiveUnits.channel(for: fieldID, now: canLiveUnitsClock)
  }

  func liveRawCANChannel(for identifierID: String) -> CANLiveRawChannel? {
    _ = canLiveUnitsRevision
    return canLiveUnits.rawChannel(for: identifierID, now: canLiveUnitsClock)
  }

  func refreshCANResearch() {
    canResearchRevision &+= 1
    let revision = canResearchRevision
    canResearchTask?.cancel()
    canResearchInProgress = true
    canResearchMessage = "Analyzing a bounded immutable evidence snapshot…"
    canResearchTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.canResearchRevision == revision {
          self.canResearchInProgress = false
          self.canResearchTask = nil
        }
      }
      do {
        let currentStandardSamples = self.gateway.standardOBDSamples.filter(
          self.gateway.isCurrentStandardOBDSample)
        let snapshot = try await self.gateway.makePassiveCANWorkSnapshot()
        let report = try await self.evidenceWorkCoordinator.analyzePassiveCAN(snapshot)
        let unitsSnapshot = try await self.gateway.makePassiveCANWorkSnapshot()
        let unitsReport = try await self.evidenceWorkCoordinator.analyzeCANUnits(
          unitsSnapshot,
          standardSamples: currentStandardSamples)
        let sampleSnapshot = try await self.gateway.makePassiveCANWorkSnapshot(
          maximumObservationCount: 2_048)
        let recent = try await self.evidenceWorkCoordinator.recentPassiveCAN(
          sampleSnapshot,
          limit: 512)
        guard !Task.isCancelled, self.canResearchRevision == revision else { return }
        self.debugEvidenceObservations = recent.observations
        self.canUnitsReport = unitsReport
        self.canUnitsMessage =
          "Analyzed \(unitsReport.observationCount.formatted()) retained observations across "
          + "\(unitsReport.sessionCount.formatted()) sessions. Unit transforms and derived values remain unverified."
        self.canResearchReport = report
        self.canResearchMessage =
          report.map {
            "Analyzed \($0.recordCount.formatted()) retained records across "
              + "\($0.sessionCount) sessions; owner health remains blocked."
          }
          ?? "No retained CAN evidence is stored. Synchronize a gateway capture to create research graphs."
      } catch is CancellationError {
        // A newer immutable snapshot owns the visible result.
      } catch {
        guard self.canResearchRevision == revision else { return }
        if error is PortableFrameStoreError {
          self.gateway.reportPortableFrameIntegrityFailure(error)
        }
        self.canUnitsReport = nil
        self.canUnitsMessage =
          "Retained CAN unit analysis failed closed: \(error.localizedDescription)"
        self.canResearchReport = nil
        self.canResearchMessage =
          "Retained CAN analysis failed closed: \(error.localizedDescription)"
      }
    }
  }

  func bleConnectionTraceExportURL() throws -> URL {
    try gateway.bleConnectionTraceExportURL()
  }

  func prepareEvidenceSyncExportPage(reset: Bool = false) {
    guard evidencePreparationTask == nil else { return }
    if reset {
      preparedEvidenceArtifactIdentities.removeAll()
      preparedEvidenceSyncURLs.removeAll()
      preparedEvidenceSyncHasMore = false
    }
    evidencePreparationInProgress = true
    evidencePreparationTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.evidencePreparationInProgress = false
        self.evidencePreparationTask = nil
      }
      do {
        let snapshot = try await self.gateway.makePortableEvidenceWorkSnapshot(
          excludingArtifactIdentities: self.preparedEvidenceArtifactIdentities,
          maximumArtifacts: 8)
        let page = try await self.evidenceWorkCoordinator.prepareEvidencePage(
          snapshot,
          creator: self.evidenceBundleCreator,
          outputDirectory: self.evidenceTemporaryDirectory)
        for artifact in page.artifacts
        where self.preparedEvidenceArtifactIdentities.insert(artifact.artifactIdentity).inserted {
          self.preparedEvidenceSyncURLs.append(artifact.url)
        }
        self.preparedEvidenceSyncHasMore = page.hasMore
        self.evidencePreparationMessage =
          "Prepared \(self.preparedEvidenceSyncURLs.count) artifact(s). "
          + (page.hasMore
            ? "More immutable generations remain; prepare the next bounded page."
            : "This share set now covers every verified generation and import-lineage artifact.")
        self.errorMessage = nil
      } catch {
        if error is PortableFrameStoreError {
          self.gateway.reportPortableFrameIntegrityFailure(error)
        }
        self.errorMessage = error.localizedDescription
        self.evidencePreparationMessage =
          "Recovery bundle preparation failed closed: \(error.localizedDescription)"
      }
    }
  }

  func importEvidenceSync(from url: URL) {
    let hasAccess = url.startAccessingSecurityScopedResource()
    Task { @MainActor [weak self] in
      defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
      guard let self else { return }
      do {
        let summary = try await self.gateway.importEvidenceSync(from: url)
        self.noticeMessage =
          "Bundle \(summary.bundleID.uuidString) verified; appended \(summary.appendedRecords) of \(summary.verifiedRecords) frames."
        self.errorMessage = nil
      } catch {
        self.errorMessage = error.localizedDescription
      }
    }
  }

  func importDebugPassiveCAN(from url: URL) {
    #if DEBUG
      guard debugUnverifiedEvidenceModeActive,
        DiscoveryMutationAuthority.debugUnverified.permitsEvidenceWorkspaceOperation(
          .importPassiveEvidence)
      else {
        errorMessage = AppModelError.debugModeNeeded.localizedDescription
        return
      }
      let hasAccess = url.startAccessingSecurityScopedResource()
      Task { @MainActor [weak self] in
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        guard let self else { return }
        do {
          let summary = try await self.gateway.importDebugPassiveCAN(from: url)
          self.noticeMessage =
            "DEBUG_UNVERIFIED import decoded \(summary.decodedRecords) real passive CAN records across \(summary.sessionCount) sessions and appended \(summary.appendedRecords) new records."
          self.errorMessage = nil
          self.refreshCANResearch()
        } catch {
          self.errorMessage = error.localizedDescription
        }
      }
    #else
      errorMessage = AppModelError.debugModeNeeded.localizedDescription
    #endif
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
  case discoveryMarkerTimelineStalled
  case discoveryCapabilityRequired
  case discoveryEvidenceAuthorityRequired
  case discoveryOwnerSafetyAcknowledgementRequired
  case discoveryMarkerSequenceRequired
  case discoveryMarkerDwellRequired(Int)
  case discoveryTestIncomplete
  case discoveryLedgerUnavailable(String)

  case debugModeNeeded
  case debugLabelNeeded
  case debugObservationNeeded

  var errorDescription: String? {
    switch self {
    case .debugModeNeeded:
      "Enable the Debug-only DEBUG_UNVERIFIED workspace before appending labels."
    case .debugLabelNeeded:
      "Enter a label before appending the record."
    case .debugObservationNeeded:
      "Select a real retained or live passive CAN observation before appending the record."
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
    case .discoveryMarkerTimelineStalled:
      "The gateway evidence timeline has not advanced since this run's previous marker, so a new marker would reuse the same evidence coordinate. Wait for fresh CAN frames (or a fresh capture session) and mark again."
    case .discoveryCapabilityRequired:
      "The verified gateway does not advertise every capability required by this versioned Discovery test template."
    case .discoveryEvidenceAuthorityRequired:
      "This test requires either fresh deterministic PARKED authority or the exact passive Park-selector bootstrap with current listen-only capture evidence."
    case .discoveryOwnerSafetyAcknowledgementRequired:
      "Confirm the physical safety setup and begin this app-local evidence run within five minutes. The confirmation is single-use and cannot be synthesized by the run."
    case .discoveryMarkerSequenceRequired:
      "The Park-selector bootstrap accepts one exact marker at a time in the required P/R/N/D/P sequence. Abort and restart if the retained sequence is not canonical."
    case .discoveryMarkerDwellRequired(let seconds):
      "Hold the current selector position for \(seconds) more second\(seconds == 1 ? "" : "s") before recording the next transition. The gateway monotonic clock enforces this interval."
    case .discoveryTestIncomplete:
      "Complete every ordered Park-selector bootstrap marker before ending this evidence session."
    case .discoveryLedgerUnavailable(let detail):
      "Discovery evidence remains fail-closed because a required append-only ledger is unavailable. \(detail) No committed record was skipped, deleted, or rewritten."
    }
  }
}
