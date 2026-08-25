import CryptoKit
import Foundation
import Testing

@testable import VHOSCore

private let finalizerCaptureID = "capture_01K3J000000000000000000001"
private let finalizerVehicleID = "veh_01K3J000000000000000000002"
private let finalizerRunID = "run_01K3J000000000000000000003"
private let finalizerMarkerID = "marker_01K3J000000000000000000004"
private let finalizerGatewayID = "esp32-9454c5b08d14"

private struct FinalizerEndedDraftFixture: Codable {
  let contract = "vhos.ios.discovery-test-run-draft"
  let contractVersion = "1.0.0"
  let id: String
  let templateID: String
  let templateVersion: String
  let captureID: String
  let gatewayID: String
  let gatewaySessionID: UInt32
  let startedAt: String
  let startMonotonicMicroseconds: UInt64
  let firstSourceSequence: UInt64
  let acquisitionAuthority: DiscoveryMutationAuthority?
  let ownerSafetyAcknowledgedAt: String?
  let state: String
  let endedAt: String?
  let endMonotonicMicroseconds: UInt64?
  let lastSourceSequence: UInt64?

  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion, id, templateVersion, startedAt
    case startMonotonicMicroseconds, firstSourceSequence, acquisitionAuthority
    case ownerSafetyAcknowledgedAt, state, endedAt, endMonotonicMicroseconds
    case lastSourceSequence
    case templateID = "templateId"
    case captureID = "captureId"
    case gatewayID = "gatewayId"
    case gatewaySessionID = "gatewaySessionId"
  }
}

@Test func finalizedCaptureStorePersistsAndReloadsExactOfflineEvidence() throws {
  let directory = finalizerTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let input = try finalizerInput()
  let store = FinalizedCaptureStore(storageDirectory: directory)

  let committed = try store.finalize(input)
  #expect(committed.capture.authority == .observed)
  #expect(committed.capture.wallClockBasis == .evidenceIngestionTime)
  #expect(committed.capture.retainedRecordCount == 3)
  #expect(committed.capture.firstSourceSequence == 100)
  #expect(committed.capture.lastSourceSequence == 102)
  #expect(committed.capture.eventMarkers.map(\.id) == [finalizerMarkerID])
  #expect(committed.manifest.terminalRun.id == finalizerRunID)
  #expect(committed.manifest.archiveByteCount == input.archiveNDJSON.count)

  let archiveURL = store.archiveDirectory.appendingPathComponent(committed.archiveFileName)
  let manifestURL = store.manifestDirectory.appendingPathComponent(committed.manifestFileName)
  let profileURL = store.vehicleProfileDirectory.appendingPathComponent(
    committed.vehicleProfileFileName)
  #expect(try Data(contentsOf: archiveURL) == input.archiveNDJSON)
  #expect(try Data(contentsOf: profileURL) == input.vehicleProfileArtifact)
  #expect(try Data(contentsOf: manifestURL) == VHOSJSON.encoder().encode(committed.manifest))

  let restarted = FinalizedCaptureStore(storageDirectory: directory)
  let reloaded = try restarted.load()
  #expect(reloaded.recovery == nil)
  #expect(reloaded.entries == [committed])
  #expect(try restarted.capture(id: finalizerCaptureID) == committed.capture)
}

@Test func finalizedCaptureStoreSerializesConcurrentWritersAcrossInstances() async throws {
  let directory = finalizerTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let firstStore = FinalizedCaptureStore(storageDirectory: directory)
  let secondStore = FinalizedCaptureStore(storageDirectory: directory)
  let input = try finalizerInput()

  let outcomes = await withTaskGroup(of: String.self, returning: [String].self) { group in
    for store in [firstStore, secondStore] {
      group.addTask {
        do {
          _ = try store.finalize(input)
          return "SAVED"
        } catch DiscoveryCaptureFinalizationError.duplicateCaptureIdentity {
          return "DUPLICATE"
        } catch {
          return "UNEXPECTED:\(error.localizedDescription)"
        }
      }
    }
    var values: [String] = []
    for await value in group { values.append(value) }
    return values
  }

  #expect(outcomes.filter { $0 == "SAVED" }.count == 1)
  #expect(outcomes.filter { $0 == "DUPLICATE" }.count == 1)
  #expect(try FinalizedCaptureStore(storageDirectory: directory).captures().count == 1)
}

@Test func finalizerRejectsMissingProvenanceWithoutPublishingAnyEvidence() throws {
  let directory = finalizerTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let valid = try finalizerInput()
  let incompleteGateway = try CaptureGatewayProvenance(
    gatewayID: finalizerGatewayID,
    hardwareRevision: "mrdiy-v13",
    firmwareVersion: "0.4.0",
    firmwareBuildID: nil,
    protocolVersion: "1.0.0",
    activeConfigID: "config.listen-only",
    activeConfigVersion: "1.0.0")
  let incomplete = DiscoveryCaptureFinalizationInput(
    captureID: valid.captureID,
    vehicleID: valid.vehicleID,
    vehicleProfileArtifact: valid.vehicleProfileArtifact,
    vehicleProfileSHA256: valid.vehicleProfileSHA256,
    archiveNDJSON: valid.archiveNDJSON,
    gateway: incompleteGateway,
    terminalRun: valid.terminalRun,
    eventMarkers: valid.eventMarkers,
    finalizedAt: valid.finalizedAt)
  let store = FinalizedCaptureStore(storageDirectory: directory)

  #expect(throws: DiscoveryCaptureFinalizationError.incompleteGatewayProvenance) {
    try store.finalize(incomplete)
  }
  #expect(!FileManager.default.fileExists(atPath: store.ledgerURL.path))
  #expect(!FileManager.default.fileExists(atPath: store.archiveDirectory.path))
}

@Test func terminalRunBindsExactEndedDraftScopeAcknowledgementAndDigest() throws {
  let canonical = try finalizerEndedDraftBytes()
  let terminal = try DiscoveryCaptureTerminalRun(canonicalEndedDraft: canonical)
  #expect(terminal.acquisitionAuthority == .localEvidenceOnly)
  #expect(terminal.ownerSafetyAcknowledgedAt == "2026-08-24T21:00:00Z")
  #expect(terminal.terminalState == "ENDED")
  #expect(terminal.terminalSnapshotCanonicalJSON == canonical)
  #expect(terminal.terminalSnapshotSHA256.count == 64)
  try terminal.validateContract()

  #expect(throws: DiscoveryCaptureFinalizationError.invalidTerminalRun) {
    try DiscoveryCaptureTerminalRun(
      canonicalEndedDraft: finalizerEndedDraftBytes(state: "ACTIVE"))
  }
  #expect(throws: DiscoveryCaptureFinalizationError.invalidTerminalRun) {
    try DiscoveryCaptureTerminalRun(
      canonicalEndedDraft: finalizerEndedDraftBytes(ownerSafetyAcknowledgedAt: nil))
  }
  #expect(throws: DiscoveryCaptureFinalizationError.invalidTerminalRun) {
    try DiscoveryCaptureTerminalRun(
      canonicalEndedDraft: finalizerEndedDraftBytes(
        acquisitionAuthority: .parked,
        ownerSafetyAcknowledgedAt: "2026-08-24T21:00:00Z"))
  }
  #expect(throws: DiscoveryCaptureFinalizationError.invalidTerminalRun) {
    try DiscoveryCaptureTerminalRun(
      canonicalEndedDraft: finalizerEndedDraftBytes(
        templateID: "discovery.engine.rpm-sweep",
        acquisitionAuthority: .passiveParkSelectorBootstrap,
        ownerSafetyAcknowledgedAt: nil))
  }
  #expect(throws: DiscoveryCaptureFinalizationError.invalidTerminalRun) {
    try DiscoveryCaptureTerminalRun(
      canonicalEndedDraft: finalizerEndedDraftBytes(templateVersion: "1.0.0"))
  }
  var nonCanonical = canonical
  nonCanonical.append(0x20)
  #expect(throws: DiscoveryCaptureFinalizationError.invalidTerminalRun) {
    try DiscoveryCaptureTerminalRun(canonicalEndedDraft: nonCanonical)
  }
}

@Test func terminalRunPreservesDevelopmentEvidenceLabAsUnverifiedLocalScope() throws {
  let canonical = try finalizerEndedDraftBytes(
    acquisitionAuthority: .developmentEvidenceLab,
    ownerSafetyAcknowledgedAt: "2026-08-24T20:59:59Z")
  let terminal = try DiscoveryCaptureTerminalRun(canonicalEndedDraft: canonical)

  #expect(terminal.acquisitionAuthority == .developmentEvidenceLab)
  #expect(terminal.acquisitionAuthority.isAppLocalEvidenceOnly)
  #expect(!terminal.acquisitionAuthority.permitsGatewayCaptureControl)
  try terminal.validateContract()

  #expect(throws: DiscoveryCaptureFinalizationError.invalidTerminalRun) {
    try DiscoveryCaptureTerminalRun(
      canonicalEndedDraft: finalizerEndedDraftBytes(
        acquisitionAuthority: .developmentEvidenceLab,
        ownerSafetyAcknowledgedAt: nil))
  }
  #expect(throws: DiscoveryCaptureFinalizationError.invalidTerminalRun) {
    try DiscoveryCaptureTerminalRun(
      canonicalEndedDraft: finalizerEndedDraftBytes(
        acquisitionAuthority: .developmentEvidenceLab,
        ownerSafetyAcknowledgedAt: "2026-08-24T21:00:01Z"))
  }
  #expect(throws: DiscoveryCaptureFinalizationError.invalidTerminalRun) {
    try DiscoveryCaptureTerminalRun(
      canonicalEndedDraft: finalizerEndedDraftBytes(
        acquisitionAuthority: .developmentEvidenceLab,
        ownerSafetyAcknowledgedAt: "2026-08-24T20:54:59Z"))
  }
  #expect(throws: DiscoveryCaptureFinalizationError.invalidTerminalRun) {
    try DiscoveryCaptureTerminalRun(
      canonicalEndedDraft: finalizerEndedDraftBytes(
        templateID: "discovery.brakes.pulse",
        acquisitionAuthority: .developmentEvidenceLab))
  }
}

@Test func terminalRunPreservesDebugUnverifiedProvenanceForAnyValidEvidenceTemplate() throws {
  let canonical = try finalizerEndedDraftBytes(
    templateID: "discovery.brakes.offline-labeling",
    templateVersion: "1.0.0",
    acquisitionAuthority: .debugUnverified,
    ownerSafetyAcknowledgedAt: nil)
  let terminal = try DiscoveryCaptureTerminalRun(canonicalEndedDraft: canonical)

  #expect(terminal.acquisitionAuthority == .debugUnverified)
  #expect(terminal.acquisitionAuthority.rawValue == "DEBUG_UNVERIFIED")
  #expect(terminal.acquisitionAuthority.isAppLocalEvidenceOnly)
  #expect(!terminal.acquisitionAuthority.permitsGatewayCaptureControl)
  #expect(!terminal.acquisitionAuthority.claimsParkedAuthority)
  #expect(!terminal.acquisitionAuthority.permitsSignalPromotion)
  #expect(terminal.ownerSafetyAcknowledgedAt == nil)
  try terminal.validateContract()

  #expect(throws: DiscoveryCaptureFinalizationError.invalidTerminalRun) {
    try DiscoveryCaptureTerminalRun(
      canonicalEndedDraft: finalizerEndedDraftBytes(
        templateID: "discovery.brakes.offline-labeling",
        templateVersion: "1.0.0",
        acquisitionAuthority: .debugUnverified,
        ownerSafetyAcknowledgedAt: "2026-08-24T21:00:00Z"))
  }
}

@Test func finalizerRejectsCommitTimeBeforeArchiveEndWithoutPublishingEvidence() throws {
  let directory = finalizerTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let valid = try finalizerInput()
  let futureArchive = try PassiveCANEvidenceArchive.encodeNDJSON([
    finalizerObservation(sequence: 100, monotonic: 1_000_000, ingestedAt: "2026-08-24T21:00:00Z"),
    finalizerObservation(sequence: 101, monotonic: 1_500_000, ingestedAt: "2026-08-24T21:00:01Z"),
    finalizerObservation(sequence: 102, monotonic: 2_000_000, ingestedAt: "2026-08-24T21:00:05Z"),
  ])
  let input = DiscoveryCaptureFinalizationInput(
    captureID: valid.captureID,
    vehicleID: valid.vehicleID,
    vehicleProfileArtifact: valid.vehicleProfileArtifact,
    vehicleProfileSHA256: valid.vehicleProfileSHA256,
    archiveNDJSON: futureArchive,
    gateway: valid.gateway,
    terminalRun: valid.terminalRun,
    eventMarkers: valid.eventMarkers,
    finalizedAt: "2026-08-24T21:00:03Z")
  let store = FinalizedCaptureStore(storageDirectory: directory)

  #expect(throws: DiscoveryCaptureFinalizationError.invalidManifest) {
    try store.finalize(input)
  }
  #expect(!FileManager.default.fileExists(atPath: store.ledgerURL.path))
  #expect(!FileManager.default.fileExists(atPath: store.archiveDirectory.path))
}

@Test func finalizerRejectsUnboundMarkerAndReversedArchiveWithoutMutation() throws {
  let valid = try finalizerInput()
  let wrongMarker = try EventMarker(
    id: finalizerMarkerID,
    captureID: finalizerCaptureID,
    gatewaySessionID: 99,
    gatewayMonotonicMicroseconds: 1_500_000,
    recordedAt: "2026-08-24T21:00:01Z",
    kind: .selectorPark,
    label: "Selector Park",
    source: .user,
    nearestCANSequence: 101)
  let unbound = DiscoveryCaptureFinalizationInput(
    captureID: valid.captureID,
    vehicleID: valid.vehicleID,
    vehicleProfileArtifact: valid.vehicleProfileArtifact,
    vehicleProfileSHA256: valid.vehicleProfileSHA256,
    archiveNDJSON: valid.archiveNDJSON,
    gateway: valid.gateway,
    terminalRun: valid.terminalRun,
    eventMarkers: [wrongMarker],
    finalizedAt: valid.finalizedAt)
  #expect(throws: DiscoveryCaptureFinalizationError.self) {
    try DiscoveryCaptureFinalizer.finalize(unbound)
  }

  let reversed = try PassiveCANEvidenceArchive.encodeNDJSON([
    finalizerObservation(sequence: 101, monotonic: 1_500_000, ingestedAt: "2026-08-24T21:00:01Z"),
    finalizerObservation(sequence: 100, monotonic: 1_000_000, ingestedAt: "2026-08-24T21:00:00Z"),
  ])
  // The canonical archive encoder sorts this fixture. Reverse the committed canonical lines to
  // model a byte-exact but invalid append history without changing either JSON record.
  let lines = reversed.split(separator: 0x0A)
  var reversedBytes = Data()
  for line in lines.reversed() {
    reversedBytes.append(contentsOf: line)
    reversedBytes.append(0x0A)
  }
  let reversedInput = DiscoveryCaptureFinalizationInput(
    captureID: valid.captureID,
    vehicleID: valid.vehicleID,
    vehicleProfileArtifact: valid.vehicleProfileArtifact,
    vehicleProfileSHA256: valid.vehicleProfileSHA256,
    archiveNDJSON: reversedBytes,
    gateway: valid.gateway,
    terminalRun: valid.terminalRun,
    eventMarkers: valid.eventMarkers,
    finalizedAt: valid.finalizedAt)
  #expect(throws: DiscoveryCaptureFinalizationError.self) {
    try DiscoveryCaptureFinalizer.finalize(reversedInput)
  }
}

@Test func finalizedCaptureLedgerRecoversOnlyInterruptedTailAndPreservesArtifacts() throws {
  let directory = finalizerTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = FinalizedCaptureStore(storageDirectory: directory)
  let committed = try store.finalize(finalizerInput())
  let committedLedger = try Data(contentsOf: store.ledgerURL)
  let interrupted = Data("{\"capture\":".utf8)
  let handle = try FileHandle(forWritingTo: store.ledgerURL)
  try handle.seekToEnd()
  try handle.write(contentsOf: interrupted)
  try handle.close()

  let recovered = try FinalizedCaptureStore(storageDirectory: directory).load()
  #expect(recovered.entries == [committed])
  #expect(recovered.recovery?.quarantinedByteCount == interrupted.count)
  #expect(try Data(contentsOf: store.ledgerURL) == committedLedger)
  let quarantineURL = try #require(recovered.recovery?.quarantineURL)
  #expect(try Data(contentsOf: quarantineURL) == interrupted)
}

private func finalizerInput() throws -> DiscoveryCaptureFinalizationInput {
  let profile = Data(
    "{\"contract\":\"vhos.test.vehicle-profile\",\"vehicle_id\":\"\(finalizerVehicleID)\"}"
      .utf8)
  let profileSHA = SHA256.hash(data: profile).map { String(format: "%02x", $0) }.joined()
  let archive = try PassiveCANEvidenceArchive.encodeNDJSON([
    finalizerObservation(sequence: 100, monotonic: 1_000_000, ingestedAt: "2026-08-24T21:00:00Z"),
    finalizerObservation(sequence: 101, monotonic: 1_500_000, ingestedAt: "2026-08-24T21:00:01Z"),
    finalizerObservation(sequence: 102, monotonic: 2_000_000, ingestedAt: "2026-08-24T21:00:02Z"),
  ])
  let gateway = try CaptureGatewayProvenance(
    gatewayID: finalizerGatewayID,
    hardwareRevision: "mrdiy-v13",
    firmwareVersion: "0.4.0",
    firmwareBuildID: "build-field-return",
    protocolVersion: "1.0.0",
    activeConfigID: "config.listen-only",
    activeConfigVersion: "1.0.0")
  let terminalRun = try DiscoveryCaptureTerminalRun(
    canonicalEndedDraft: finalizerEndedDraftBytes())
  let marker = try EventMarker(
    id: finalizerMarkerID,
    captureID: finalizerCaptureID,
    gatewaySessionID: 42,
    gatewayMonotonicMicroseconds: 1_500_000,
    recordedAt: "2026-08-24T21:00:01Z",
    kind: .selectorPark,
    label: "Selector Park",
    source: .user,
    nearestCANSequence: 101)
  return DiscoveryCaptureFinalizationInput(
    captureID: finalizerCaptureID,
    vehicleID: finalizerVehicleID,
    vehicleProfileArtifact: profile,
    vehicleProfileSHA256: profileSHA,
    archiveNDJSON: archive,
    gateway: gateway,
    terminalRun: terminalRun,
    eventMarkers: [marker],
    finalizedAt: "2026-08-24T21:00:03Z",
    notes: "Exact retained selector-bootstrap evidence.")
}

private func finalizerEndedDraftBytes(
  state: String = "ENDED",
  templateID: String = DiscoveryMutationPolicy.parkSelectorBootstrapTemplateID,
  templateVersion: String = "1.1.0",
  acquisitionAuthority: DiscoveryMutationAuthority? = .localEvidenceOnly,
  ownerSafetyAcknowledgedAt: String? = "2026-08-24T21:00:00Z"
) throws -> Data {
  try VHOSJSON.encoder().encode(
    FinalizerEndedDraftFixture(
      id: finalizerRunID,
      templateID: templateID,
      templateVersion: templateVersion,
      captureID: finalizerCaptureID,
      gatewayID: finalizerGatewayID,
      gatewaySessionID: 42,
      startedAt: "2026-08-24T21:00:00Z",
      startMonotonicMicroseconds: 1_000_000,
      firstSourceSequence: 100,
      acquisitionAuthority: acquisitionAuthority,
      ownerSafetyAcknowledgedAt: ownerSafetyAcknowledgedAt,
      state: state,
      endedAt: "2026-08-24T21:00:02Z",
      endMonotonicMicroseconds: 2_000_000,
      lastSourceSequence: 102))
}

private func finalizerObservation(
  sequence: UInt64,
  monotonic: UInt64,
  ingestedAt: String
) -> PassiveCANObservation {
  PassiveCANObservation(
    gatewayID: finalizerGatewayID,
    sessionID: 42,
    sourceSequence: sequence,
    monotonicMicroseconds: monotonic,
    bitrateBps: 500_000,
    identifier: 0x2D0,
    extended: false,
    remoteRequest: false,
    listenOnly: true,
    dataLength: 8,
    data: [0x0A, 0xB7, 0x04, 0, 0, 0, 0, 0],
    evidenceSource: "gateway-flash",
    ingestedAt: ingestedAt)
}

private func finalizerTemporaryDirectory() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    "vhos-finalized-captures-\(UUID().uuidString.lowercased())",
    isDirectory: true)
}
