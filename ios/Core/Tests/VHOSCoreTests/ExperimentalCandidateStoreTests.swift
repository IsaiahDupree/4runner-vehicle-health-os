import CryptoKit
import Foundation
import Testing

@testable import VHOSCore

private let storedCandidateCaptureID = "capture_01K3H000000000000000000001"
private let storedCandidateVehicleID = "veh_01K3H000000000000000000002"
private let storedCandidateMarkerID = "marker_01K3H000000000000000000003"
private let storedCandidateID = "candidate_01K3H000000000000000000004"

private struct CandidateEndedDraftFixture: Codable {
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

@Test func experimentalCandidateStoreSavesListsAndReloadsFullyOffline() throws {
  let directory = candidateTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = ExperimentalCandidateStore(storageDirectory: directory)

  #expect(try store.list().isEmpty)
  #expect(!FileManager.default.fileExists(atPath: store.ledgerURL.path))

  let finalized = try storedCandidateFinalizedStore(root: directory)
  let capture = finalized.capture
  let candidate = try storedCandidate(capture: capture)
  let saved = try store.save(
    candidate: candidate,
    finalizedCaptureStore: finalized.store,
    savedAt: "2026-08-24T21:00:00Z")

  #expect(saved.authority == .candidate)
  #expect(saved.candidate.authority == .candidate)
  #expect(!saved.promotionAllowed)
  #expect(saved.captureProvenance.count == 1)
  #expect(saved.captureProvenance[0].archiveSHA256 == capture.archiveSHA256)
  #expect(saved.captureProvenance[0].manifestSHA256 == capture.manifestSHA256)
  #expect(saved.captureProvenance[0].wallClockBasis == .evidenceIngestionTime)
  #expect(saved.captureProvenance[0].gatewaySessionIDs == capture.gatewaySessionIDs)
  #expect(saved.captureProvenance[0].eventMarkerIDs == [storedCandidateMarkerID])
  #expect(saved.captureProvenance[0].acquisitionAuthority == .localEvidenceOnly)
  #expect(saved.evidenceReferences.contains("capture-archive-sha256:\(capture.archiveSHA256)"))
  #expect(saved.candidateSHA256.count == 64)
  #expect(saved.provenanceSHA256.count == 64)

  let committed = try Data(contentsOf: store.ledgerURL)
  #expect(committed.last == 0x0A)
  let restartedStore = ExperimentalCandidateStore(storageDirectory: directory)
  let reloaded = try restartedStore.load()
  #expect(reloaded.recovery == nil)
  #expect(reloaded.entries == [saved])
  #expect(try Data(contentsOf: restartedStore.ledgerURL) == committed)
}

@Test func developmentEvidenceLabCandidateRemainsVisibleAndNonPromotable() throws {
  let directory = candidateTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let candidateStore = ExperimentalCandidateStore(storageDirectory: directory)
  let finalized = try storedCandidateFinalizedStore(
    root: directory,
    acquisitionAuthority: .developmentEvidenceLab)
  let saved = try candidateStore.save(
    candidate: storedCandidate(capture: finalized.capture),
    finalizedCaptureStore: finalized.store,
    savedAt: "2026-08-24T21:00:00Z")

  #expect(saved.captureProvenance[0].acquisitionAuthority == .developmentEvidenceLab)
  #expect(
    saved.evidenceReferences.contains(
      "capture-acquisition-authority:DEVELOPMENT_EVIDENCE_LAB"))
  #expect(saved.authority == .candidate)
  #expect(!saved.promotionAllowed)
  #expect(saved.candidate.authority == .candidate)
}

@Test func experimentalCandidateStoreRejectsDuplicateCandidateWithoutMutatingLedger() throws {
  let directory = candidateTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = ExperimentalCandidateStore(storageDirectory: directory)
  let finalized = try storedCandidateFinalizedStore(root: directory)
  let capture = finalized.capture
  let candidate = try storedCandidate(capture: capture)
  _ = try store.save(
    candidate: candidate,
    finalizedCaptureStore: finalized.store,
    savedAt: "2026-08-24T21:00:00Z")
  let committed = try Data(contentsOf: store.ledgerURL)

  #expect(throws: ExperimentalCandidateStoreError.self) {
    try store.save(
      candidate: candidate,
      finalizedCaptureStore: finalized.store,
      savedAt: "2026-08-24T21:00:01Z")
  }
  #expect(try Data(contentsOf: store.ledgerURL) == committed)
}

@Test func experimentalCandidateStoreSerializesConcurrentWritersAcrossInstances() async throws {
  let directory = candidateTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let firstStore = ExperimentalCandidateStore(storageDirectory: directory)
  let secondStore = ExperimentalCandidateStore(storageDirectory: directory)
  let finalized = try storedCandidateFinalizedStore(root: directory)
  let capture = finalized.capture
  let candidate = try storedCandidate(capture: capture)

  let outcomes = await withTaskGroup(of: String.self, returning: [String].self) { group in
    for store in [firstStore, secondStore] {
      group.addTask {
        do {
          _ = try store.save(
            candidate: candidate,
            finalizedCaptureStore: finalized.store,
            savedAt: "2026-08-24T21:00:00Z")
          return "SAVED"
        } catch ExperimentalCandidateStoreError.duplicateCandidateIdentity {
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
  #expect(try ExperimentalCandidateStore(storageDirectory: directory).list().count == 1)
}

@Test func experimentalCandidateStoreRejectsTamperedPromotionAuthorityWithoutRewritingEvidence()
  throws
{
  let directory = candidateTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = ExperimentalCandidateStore(storageDirectory: directory)
  let finalized = try storedCandidateFinalizedStore(root: directory)
  let capture = finalized.capture
  _ = try store.save(
    candidate: storedCandidate(capture: capture),
    finalizedCaptureStore: finalized.store,
    savedAt: "2026-08-24T21:00:00Z")

  let original = try Data(contentsOf: store.ledgerURL)
  let originalText = try #require(String(data: original, encoding: .utf8))
  let tamperedText = originalText.replacingOccurrences(
    of: "\"promotion_allowed\":false",
    with: "\"promotion_allowed\":true")
  #expect(tamperedText != originalText)
  let tampered = try #require(tamperedText.data(using: .utf8))
  try tampered.write(to: store.ledgerURL)

  #expect(throws: AppendOnlyNDJSONLedgerError.self) {
    try ExperimentalCandidateStore(storageDirectory: directory).load()
  }
  #expect(try Data(contentsOf: store.ledgerURL) == tampered)
}

@Test func experimentalCandidateStoreRecoversOnlyAnInterruptedUncommittedTail() throws {
  let directory = candidateTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = ExperimentalCandidateStore(storageDirectory: directory)
  let finalized = try storedCandidateFinalizedStore(root: directory)
  let capture = finalized.capture
  let saved = try store.save(
    candidate: storedCandidate(capture: capture),
    finalizedCaptureStore: finalized.store,
    savedAt: "2026-08-24T21:00:00Z")
  let committed = try Data(contentsOf: store.ledgerURL)
  let interruptedTail = Data("{\"candidate\":".utf8)
  let handle = try FileHandle(forWritingTo: store.ledgerURL)
  try handle.seekToEnd()
  try handle.write(contentsOf: interruptedTail)
  try handle.close()

  let recovered = try ExperimentalCandidateStore(storageDirectory: directory).load()
  #expect(recovered.entries == [saved])
  #expect(recovered.recovery?.quarantinedByteCount == interruptedTail.count)
  #expect(try Data(contentsOf: store.ledgerURL) == committed)
  let quarantineURL = try #require(recovered.recovery?.quarantineURL)
  #expect(try Data(contentsOf: quarantineURL) == interruptedTail)
}

@Test func experimentalCandidateStoreRequiresExactMarkerAndCaptureProvenance() throws {
  let directory = candidateTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let finalized = try storedCandidateFinalizedStore(root: directory)
  let capture = finalized.capture
  let candidate = try storedCandidate(
    capture: capture,
    eventMarkerIDs: ["marker_01K3H000000000000000000099"])
  let store = ExperimentalCandidateStore(storageDirectory: directory)

  #expect(throws: ExperimentalCandidateStoreError.self) {
    try store.save(
      candidate: candidate,
      finalizedCaptureStore: finalized.store,
      savedAt: "2026-08-24T21:00:00Z")
  }
  #expect(!FileManager.default.fileExists(atPath: store.ledgerURL.path))
}

@Test func experimentalCandidateStoreRejectsTamperedFinalizedArtifactsBeforeLedgerMutation()
  throws
{
  let directory = candidateTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let finalized = try storedCandidateFinalizedStore(root: directory)
  let candidate = try storedCandidate(capture: finalized.capture)
  let archiveURL = finalized.store.archiveDirectory.appendingPathComponent(
    "\(finalized.capture.archiveSHA256).ndjson")
  try Data("tampered finalized archive".utf8).write(to: archiveURL, options: [.atomic])
  let store = ExperimentalCandidateStore(storageDirectory: directory)

  #expect(throws: DiscoveryCaptureFinalizationError.self) {
    try store.save(
      candidate: candidate,
      finalizedCaptureStore: finalized.store,
      savedAt: "2026-08-24T21:00:00Z")
  }
  #expect(!FileManager.default.fileExists(atPath: store.ledgerURL.path))
}

@Test func reloadedExperimentalCandidateStillCannotPassSignalPromotionGate() throws {
  let directory = candidateTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let finalized = try storedCandidateFinalizedStore(root: directory)
  let capture = finalized.capture
  let candidate = try storedCandidate(capture: capture, proposedCanonicalSignalID: "transmission.selector")
  let store = ExperimentalCandidateStore(storageDirectory: directory)
  _ = try store.save(
    candidate: candidate,
    finalizedCaptureStore: finalized.store,
    savedAt: "2026-08-24T21:00:00Z")
  let reloaded = try #require(try store.list().first?.candidate)
  let items = try SignalValidationRequirement.allCases.map {
    try SignalValidationItem(
      requirement: $0,
      status: .satisfied,
      evidenceReferences: ["sha256:\(String(repeating: "e", count: 64))"],
      rationale: "Test-only assertion; exact evidence resolution remains unavailable in v1.")
  }
  let approval = try SignalValidationApproval(
    reviewerID: "reviewer_01K3H000000000000000000005",
    reviewedAt: "2026-08-24T21:01:00Z",
    decision: .approve,
    evidenceReference: "review-envelope:unsigned-test",
    note: "Unsigned test fixture cannot grant vehicle authority.")
  let checklist = try SignalValidationChecklist(
    candidateID: reloaded.id,
    evaluatedAt: "2026-08-24T21:01:00Z",
    items: items,
    approval: approval)
  let decision = try SignalPromotionGate.evaluate(
    candidate: reloaded,
    checklist: checklist,
    evaluatedAt: "2026-08-24T21:01:01Z")

  #expect(!decision.promotionAllowed)
  #expect(decision.authority == .candidate)
  #expect(decision.blockers.contains("VERIFIED_EVIDENCE_RESOLVER_REQUIRED"))
  #expect(decision.blockers.contains("SIGNED_REVIEWER_APPROVAL_REQUIRED"))
}

private func storedCandidateFinalizedStore(
  root: URL,
  acquisitionAuthority: DiscoveryMutationAuthority = .localEvidenceOnly
) throws -> (store: FinalizedCaptureStore, capture: CaptureSession) {
  let gatewayID = "esp32-9454c5b08d14"
  let marker = try EventMarker(
    id: storedCandidateMarkerID,
    captureID: storedCandidateCaptureID,
    gatewaySessionID: 42,
    gatewayMonotonicMicroseconds: 1_500_000,
    recordedAt: "2026-08-24T20:59:56Z",
    kind: .selectorPark,
    label: "Owner marked selector Park",
    source: .user,
    nearestCANSequence: 101)
  let profile = Data(
    "{\"contract\":\"vhos.test.vehicle-profile\",\"vehicle_id\":\"\(storedCandidateVehicleID)\"}"
      .utf8)
  let profileSHA = SHA256.hash(data: profile).map { String(format: "%02x", $0) }.joined()
  let archive = try PassiveCANEvidenceArchive.encodeNDJSON([
    storedCandidateObservation(
      gatewayID: gatewayID, sequence: 100, monotonic: 1_000_000,
      ingestedAt: "2026-08-24T20:59:55Z"),
    storedCandidateObservation(
      gatewayID: gatewayID, sequence: 101, monotonic: 1_500_000,
      ingestedAt: "2026-08-24T20:59:56Z"),
    storedCandidateObservation(
      gatewayID: gatewayID, sequence: 102, monotonic: 2_000_000,
      ingestedAt: "2026-08-24T20:59:57Z"),
  ])
  let draft = CandidateEndedDraftFixture(
    id: "run_01K3H000000000000000000005",
    templateID: DiscoveryMutationPolicy.parkSelectorBootstrapTemplateID,
    templateVersion: "1.1.0",
    captureID: storedCandidateCaptureID,
    gatewayID: gatewayID,
    gatewaySessionID: 42,
    startedAt: "2026-08-24T20:59:55Z",
    startMonotonicMicroseconds: 1_000_000,
    firstSourceSequence: 100,
    acquisitionAuthority: acquisitionAuthority,
    ownerSafetyAcknowledgedAt: acquisitionAuthority.requiresOwnerSafetyAcknowledgement
      ? "2026-08-24T20:59:55Z" : nil,
    state: "ENDED",
    endedAt: "2026-08-24T20:59:57Z",
    endMonotonicMicroseconds: 2_000_000,
    lastSourceSequence: 102)
  let terminalRun = try DiscoveryCaptureTerminalRun(
    canonicalEndedDraft: VHOSJSON.encoder().encode(draft))
  let input = DiscoveryCaptureFinalizationInput(
    captureID: storedCandidateCaptureID,
    vehicleID: storedCandidateVehicleID,
    vehicleProfileArtifact: profile,
    vehicleProfileSHA256: profileSHA,
    archiveNDJSON: archive,
    gateway: try CaptureGatewayProvenance(
      gatewayID: gatewayID,
      hardwareRevision: "mrdiy-v13",
      firmwareVersion: "0.4.0",
      firmwareBuildID: "build-field-return",
      protocolVersion: "1.0.0",
      activeConfigID: "config.listen-only",
      activeConfigVersion: "1.0.0"),
    terminalRun: terminalRun,
    eventMarkers: [marker],
    finalizedAt: "2026-08-24T20:59:58Z")
  let store = FinalizedCaptureStore(
    storageDirectory: root.appendingPathComponent("FinalizedEvidence", isDirectory: true))
  let entry = try store.finalize(input)
  return (store, entry.capture)
}

private func storedCandidateObservation(
  gatewayID: String,
  sequence: UInt64,
  monotonic: UInt64,
  ingestedAt: String
) -> PassiveCANObservation {
  PassiveCANObservation(
    gatewayID: gatewayID,
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

private func storedCandidate(
  capture: CaptureSession,
  eventMarkerIDs: [String] = [storedCandidateMarkerID],
  proposedCanonicalSignalID: String? = nil
) throws -> CandidateSignal {
  try CandidateSignal(
    id: storedCandidateID,
    createdAt: "2026-08-24T21:00:00Z",
    candidateSemantic: "transmission.selector-candidate",
    proposedCanonicalSignalID: proposedCanonicalSignalID,
    field: CandidateFieldDefinition(
      protocolID: .can11Bit500K,
      identifier: 0x2D0,
      extended: false,
      byteOffset: 2,
      bitOffset: 0,
      bitLength: 7,
      byteOrder: .bigEndian,
      signed: false),
    metrics: CandidateSignalMetrics(
      correlation: nil,
      repeatability: nil,
      falseActivationCount: 0,
      analyzedObservationCount: 256,
      analyzedCaptureCount: 1,
      controlledTestCount: 1,
      behaviorShape: .stateCode,
      algorithmID: "discovery.retained-field-statistics",
      algorithmVersion: "1.0.0"),
    reviewState: .needsMoreData,
    captureIDs: [capture.id],
    testTemplateIDs: ["discovery.transmission.selector-bootstrap"],
    eventMarkerIDs: eventMarkerIDs,
    independentEvidenceReferences: [],
    sourceReferences: ["capture-archive-sha256:\(capture.archiveSHA256)"])
}

private func candidateTemporaryDirectory() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    "vhos-experimental-candidates-\(UUID().uuidString.lowercased())",
    isDirectory: true)
}
