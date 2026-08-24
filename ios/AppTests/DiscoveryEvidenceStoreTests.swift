import CryptoKit
import Foundation
import VHOSCore
import XCTest

@testable import Vehicle_Health_OS

final class DiscoveryEvidenceStoreTests: XCTestCase {
  private let captureID = "capture_01ARZ3NDEKTSV4RRFFQ69G5FAW"
  private let runID = "run_01ARZ3NDEKTSV4RRFFQ69G5FAV"
  private let markerID = "marker_01ARZ3NDEKTSV4RRFFQ69G5FAX"
  private let templateID = "discovery.transmission.selector-bootstrap"
  private let startedAt = "2026-08-22T16:00:00Z"
  private let gatewayID = "esp32-9454c5b08d14"
  private let gatewaySessionID: UInt32 = 42

  func testStaleDiscoveryCallbackStormProducesBoundedFirstAndSummaryEvidence() {
    var coalescer = BLETraceBurstCoalescer(
      event: "STALE_SCAN_DISCOVERY_IGNORED",
      checkpointObservationCount: 128)
    var messages: [String] = []

    for callback in 0..<432 {
      messages.append(contentsOf: coalescer.observe("callback=\(callback)"))
    }
    if let summary = coalescer.flush(reason: "cleanup-complete") {
      messages.append(summary)
    }

    XCTAssertEqual(messages.count, 3)
    XCTAssertEqual(messages.filter { $0.hasSuffix("burst=first") }.count, 1)
    XCTAssertEqual(messages.filter { $0.contains("_COALESCED") }.count, 2)
    XCTAssertTrue(messages[1].contains("count=128"))
    XCTAssertTrue(messages[1].contains("reason=checkpoint"))
    XCTAssertTrue(messages.last?.contains("count=432") == true)
    XCTAssertTrue(messages.last?.contains("suppressed=431") == true)
    XCTAssertTrue(messages.last?.contains("first={callback=0}") == true)
    XCTAssertTrue(messages.last?.contains("last={callback=431}") == true)
  }

  func testPortableIntegrityRuntimeFailureIsStickyAndHidesStaleCountUntilReverified() {
    var latch = PortableFrameIntegrityLatch()
    latch.recordVerified(count: 42)
    XCTAssertEqual(latch.verifiedCount, 42)
    XCTAssertNil(latch.failure)

    latch.recordRuntimeFailure("record index write failed")
    XCTAssertEqual(latch.verifiedCount, 0)
    XCTAssertEqual(latch.failure, "record index write failed")

    // A later successful transport append must not clear or visually mask an unresolved disk
    // integrity failure. Only the explicit full verification path may recover the UI gate.
    latch.recordSuccessfulAppend(count: 43)
    latch.recordRuntimeFailure("later callback noise")
    XCTAssertEqual(latch.verifiedCount, 0)
    XCTAssertEqual(latch.failure, "record index write failed")

    latch.recordVerified(count: 43)
    XCTAssertEqual(latch.verifiedCount, 43)
    XCTAssertNil(latch.failure)
  }

  func testPortableIntegrityFailureRevokesEveryLiveAuthorityPredicate() {
    XCTAssertTrue(
      GatewayEvidenceAuthorityGate.permits(
        evidencePersistenceReady: true,
        portableFrameIntegrityError: nil))
    XCTAssertFalse(
      GatewayEvidenceAuthorityGate.permits(
        evidencePersistenceReady: false,
        portableFrameIntegrityError: nil))
    XCTAssertFalse(
      GatewayEvidenceAuthorityGate.permits(
        evidencePersistenceReady: true,
        portableFrameIntegrityError: "sealed generation digest mismatch"))
  }

  func testAcceptedFrameKeepsOriginalSourceButCannotMutateReplacementSessionUI() {
    let frame = GatewayFrame(
      messageType: .gatewayHealth,
      sequence: 77,
      monotonicMicroseconds: 900_000,
      payload: Data("{\"contract\":\"gateway.health\"}".utf8))
    let accepted = AcceptedGatewayFrameContext(
      frame: frame,
      acceptedLinkSession: 12,
      sourceID: "esp32-original")

    XCTAssertEqual(accepted.frame, frame)
    XCTAssertEqual(accepted.sourceID, "esp32-original")
    XCTAssertTrue(accepted.appliesToCurrentTransportSession(12))
    XCTAssertFalse(accepted.appliesToCurrentTransportSession(13))
  }

  func testUnsolicitedHandshakeCannotRelabelAcceptedEvidenceSource() {
    var registry = ValidatedGatewayIdentityRegistry()
    let physicalSource = "ble-peripheral-physical-a"
    let acceptedWindow = GatewayHandshakeAuthorityWindow(
      responseRequested: true,
      writeAttemptCompleted: true,
      commandQueueDrained: true,
      responseDeadlineActive: true,
      notificationSessionMatches: true,
      streamNotificationsEnabled: true)
    let unsolicitedWindow = GatewayHandshakeAuthorityWindow(
      responseRequested: false,
      writeAttemptCompleted: true,
      commandQueueDrained: true,
      responseDeadlineActive: false,
      notificationSessionMatches: true,
      streamNotificationsEnabled: true)

    // Decoding a claimed identity is not authority. Before the response-window guards accept a
    // handshake, the physical transport remains the only durable source identity.
    XCTAssertNil(registry.identity(for: 12))
    XCTAssertNil(registry.identity(for: 13))
    XCTAssertEqual(
      registry.evidenceSourceID(
        for: 12, physicalTransportSourceID: physicalSource),
      physicalSource)

    // Only the handshake path after its response-window guards may promote the identity.
    XCTAssertTrue(
      registry.promoteHandshakeClaim(
        gatewayID: "gateway-a", linkSession: 12, authorityWindow: acceptedWindow))
    XCTAssertEqual(registry.identity(for: 12), "gateway-a")
    XCTAssertNil(registry.identity(for: 13))

    // An unsolicited decoded handshake claiming gateway B is rejected by the registry itself. It
    // cannot relabel either itself or the valid gateway-A frame that follows, even if a future
    // caller accidentally reaches the promotion API after decoding the rejected payload.
    XCTAssertFalse(
      registry.promoteHandshakeClaim(
        gatewayID: "gateway-b", linkSession: 12, authorityWindow: unsolicitedWindow))
    XCTAssertFalse(
      registry.promoteHandshakeClaim(
        gatewayID: "gateway-b", linkSession: 13, authorityWindow: unsolicitedWindow))
    XCTAssertEqual(
      registry.evidenceSourceID(
        for: 12, physicalTransportSourceID: physicalSource),
      "gateway-a")
    XCTAssertEqual(registry.identity(for: 12), "gateway-a")
    XCTAssertEqual(
      registry.evidenceSourceID(
        for: 13, physicalTransportSourceID: physicalSource),
      physicalSource)
  }

  func testAcceptedFramePersistsOriginalBytesAfterReplacementSessionStarts() async throws {
    let directory = try makePortableStorageDirectory()
    let captureDirectory = directory.appendingPathComponent("Capture", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let worker = GatewayEvidencePersistenceWorker(
      portableFrameStore: PortableFrameStore(fileManager: .default, root: directory),
      captureStore: CaptureLogStore(fileManager: .default, root: captureDirectory))
    let frame = GatewayFrame(
      messageType: .gatewayHealth,
      sequence: 78,
      monotonicMicroseconds: 901_000,
      payload: Data("{\"contract\":\"gateway.health\"}".utf8))
    let accepted = AcceptedGatewayFrameContext(
      frame: frame,
      acceptedLinkSession: 12,
      sourceID: "esp32-original")

    // Session 13 is already active when the serialized evidence tail drains. That invalidates
    // only UI application; the immutable bytes accepted in session 12 still commit under the
    // source identity captured at decode time.
    XCTAssertFalse(accepted.appliesToCurrentTransportSession(13))
    let retainedCount = try await worker.appendAcceptedPortableFrame(
      accepted,
      ingestedAt: "2026-08-22T16:00:02Z")
    XCTAssertEqual(retainedCount, 1)

    let retained = try await worker.portableRecords(limit: 2)
    XCTAssertEqual(retained.count, 1)
    XCTAssertEqual(retained[0].sourceID, "esp32-original")
    XCTAssertEqual(try retained[0].validatedFrame(), frame)
  }

  func testAllOnDiskRecordsRoundTripExactSnakeCaseEncoderOutput() throws {
    let binding = try makeBinding()
    let draft = try makeDraft()
    let marker = try makeMarker()

    let bindingBytes = try VHOSJSON.encoder().encode(binding)
    XCTAssertEqual(
      String(decoding: bindingBytes, as: UTF8.self),
      "{\"contract\":\"vhos.ios.discovery-capture-binding\",\"contract_version\":\"1.0.0\",\"created_at\":\"2026-08-22T16:00:00Z\",\"gateway_id\":\"esp32-9454c5b08d14\",\"gateway_session_id\":42,\"id\":\"capture_01ARZ3NDEKTSV4RRFFQ69G5FAW\"}"
    )
    XCTAssertEqual(
      try VHOSJSON.decoder().decode(DiscoveryCaptureBinding.self, from: bindingBytes), binding)

    let draftBytes = try VHOSJSON.encoder().encode(draft)
    XCTAssertEqual(String(decoding: draftBytes, as: UTF8.self), pinnedActiveDraftLine)
    XCTAssertEqual(
      try VHOSJSON.decoder().decode(DiscoveryTestRunDraft.self, from: draftBytes), draft)

    let markerBytes = try VHOSJSON.encoder().encode(marker)
    XCTAssertEqual(
      String(decoding: markerBytes, as: UTF8.self),
      "{\"contract\":\"vhos.ios.discovery-marker-ledger-record\",\"contract_version\":\"1.0.0\",\"gateway_id\":\"esp32-9454c5b08d14\",\"gateway_session_id\":42,\"marker\":{\"authority\":\"OBSERVED\",\"capture_id\":\"capture_01ARZ3NDEKTSV4RRFFQ69G5FAW\",\"contract\":\"vhos.discovery.event-marker\",\"contract_version\":\"1.0.0\",\"gateway_monotonic_microseconds\":1001,\"gateway_session_id\":42,\"id\":\"marker_01ARZ3NDEKTSV4RRFFQ69G5FAX\",\"kind\":\"CUSTOM\",\"label\":\"SAFETY SETUP CONFIRMED\",\"nearest_can_sequence\":10,\"note\":\"fixture\",\"recorded_at\":\"2026-08-22T16:00:01Z\",\"source\":\"IPHONE\"},\"template_id\":\"discovery.transmission.selector-bootstrap\",\"test_run_id\":\"run_01ARZ3NDEKTSV4RRFFQ69G5FAV\"}"
    )
    XCTAssertEqual(
      try VHOSJSON.decoder().decode(StoredDiscoveryMarker.self, from: markerBytes), marker)
  }

  func testDiscoveryExportPagesEveryAllowedLedgerCursorWithStableIdentities() throws {
    let directory = try makeStorageDirectory()
    let output = directory.appendingPathComponent("Exports", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeBinding(to: directory)
    try ndjson([try makeDraft()]).write(
      to: directory.appendingPathComponent("test-run-drafts.ndjson"), options: [.atomic])

    let markers = try (0..<501).map { index in
      let marker = try EventMarker(
        id: DiscoveryIDGenerator.make(prefix: "marker"),
        captureID: captureID,
        gatewaySessionID: gatewaySessionID,
        gatewayMonotonicMicroseconds: UInt64(1_001 + index),
        recordedAt: "2026-08-22T16:00:01Z",
        kind: .custom,
        label: "LOAD SAMPLE \(index)",
        source: .iPhone,
        nearestCANSequence: UInt64(10 + index),
        note: "bounded export paging regression")
      return try StoredDiscoveryMarker(
        templateID: templateID,
        testRunID: runID,
        gatewayID: gatewayID,
        gatewaySessionID: gatewaySessionID,
        marker: marker)
    }
    try ndjson(markers).write(
      to: directory.appendingPathComponent("event-markers.ndjson"), options: [.atomic])

    let store = DiscoveryEvidenceStore(storageDirectory: directory)
    let first = try store.prepareExportPage(
      excludingArtifactIdentities: [],
      maximumArtifacts: 2,
      outputDirectory: output)
    XCTAssertEqual(first.artifacts.count, 2)
    XCTAssertTrue(first.hasMore)

    let second = try store.prepareExportPage(
      excludingArtifactIdentities: Set(first.artifacts.map(\.identity)),
      maximumArtifacts: 2,
      outputDirectory: output)
    XCTAssertEqual(second.artifacts.count, 2)
    XCTAssertFalse(second.hasMore)
    let allArtifacts = first.artifacts + second.artifacts
    XCTAssertEqual(Set(allArtifacts.map(\.identity)).count, 4)
    XCTAssertTrue(
      allArtifacts.allSatisfy {
        $0.byteCount > 0
          && $0.byteCount
            <= EvidenceOutboxPayloadFileValidator.maximumBytes(
              for: "application/vnd.vhos.discovery-draft-evidence+json")
          && (try? Data(contentsOf: $0.url).count) == $0.byteCount
      })

    let representedMarkerCount = try allArtifacts.reduce(into: 0) { count, artifact in
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: artifact.url)) as? [String: Any])
      guard let segment = object["segment"] as? [String: Any],
        segment["kind"] as? String == "MARKERS"
      else { return }
      count += try XCTUnwrap(segment["record_count"] as? Int)
      XCTAssertEqual(segment["total_record_count"] as? Int, 501)
      XCTAssertEqual((segment["source_sha256"] as? String)?.count, 64)
    }
    XCTAssertEqual(representedMarkerCount, 501)

    let complete = try store.prepareExportPage(
      excludingArtifactIdentities: Set(allArtifacts.map(\.identity)),
      maximumArtifacts: 2,
      outputDirectory: output)
    XCTAssertTrue(complete.artifacts.isEmpty)
    XCTAssertFalse(complete.hasMore)

    let stable = try store.prepareExportPage(
      excludingArtifactIdentities: [],
      maximumArtifacts: 4,
      outputDirectory: output)
    XCTAssertEqual(stable.artifacts.map(\.identity), allArtifacts.map(\.identity))
    XCTAssertFalse(stable.hasMore)
  }

  func testStoreLoadsPinnedExistingSnakeCaseDraftLine() throws {
    let directory = try makeStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeBinding(to: directory)
    try Data((pinnedActiveDraftLine + "\n").utf8).write(
      to: directory.appendingPathComponent("test-run-drafts.ndjson"), options: [.atomic])

    let runs = try DiscoveryEvidenceStore(storageDirectory: directory).testRuns()

    XCTAssertEqual(runs, [try makeDraft()])
  }

  func testStoreLoadsExactFieldIncidentLedgerWithoutChangingBytes() throws {
    let directory = try makeStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bindingLine =
      "{\"contract\":\"vhos.ios.discovery-capture-binding\",\"contract_version\":\"1.0.0\",\"created_at\":\"2026-08-22T15:59:46Z\",\"gateway_id\":\"esp32-9454c5b08d14\",\"gateway_session_id\":3025357416,\"id\":\"capture_01M0N365HHK80GS0MJW4F54R81\"}"
    let runLine =
      "{\"capture_id\":\"capture_01M0N365HHK80GS0MJW4F54R81\",\"contract\":\"vhos.ios.discovery-test-run-draft\",\"contract_version\":\"1.0.0\",\"first_source_sequence\":75610,\"gateway_id\":\"esp32-9454c5b08d14\",\"gateway_session_id\":3025357416,\"id\":\"run_01M0N365J19E37VK1B7VP6MD5N\",\"start_monotonic_microseconds\":142014158,\"started_at\":\"2026-08-22T15:59:46Z\",\"state\":\"ACTIVE\",\"template_id\":\"discovery.transmission.selector-bootstrap\",\"template_version\":\"1.0.0\"}"
    let bindingBytes = Data((bindingLine + "\n").utf8)
    let runBytes = Data((runLine + "\n").utf8)
    let bindingURL = directory.appendingPathComponent("capture-bindings.ndjson")
    let runURL = directory.appendingPathComponent("test-run-drafts.ndjson")
    try bindingBytes.write(to: bindingURL, options: [.atomic])
    try runBytes.write(to: runURL, options: [.atomic])

    let runs = try DiscoveryEvidenceStore(storageDirectory: directory).testRuns()

    XCTAssertEqual(runs.count, 1)
    XCTAssertEqual(runs[0].id, "run_01M0N365J19E37VK1B7VP6MD5N")
    XCTAssertEqual(runs[0].gatewaySessionID, 3_025_357_416)
    XCTAssertEqual(runs[0].state, .active)
    XCTAssertEqual(try Data(contentsOf: bindingURL), bindingBytes)
    XCTAssertEqual(try Data(contentsOf: runURL), runBytes)
  }

  func testSuccessfulPinnedLedgerLoadLeavesCommittedSourceBytesUnchanged() throws {
    let directory = try makeStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeBinding(to: directory)
    let ledgerURL = directory.appendingPathComponent("test-run-drafts.ndjson")
    let originalBytes = Data((pinnedActiveDraftLine + "\n").utf8)
    try originalBytes.write(to: ledgerURL, options: [.atomic])
    let store = DiscoveryEvidenceStore(storageDirectory: directory)

    _ = try store.testRuns()
    _ = try store.testRuns()

    XCTAssertEqual(try Data(contentsOf: ledgerURL), originalBytes)
    XCTAssertTrue(store.recoveryReports.isEmpty)
  }

  func testStoreReplaysMultiSnapshotLifecycleWithoutRewritingLedger() throws {
    let directory = try makeStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeBinding(to: directory)
    let active = try makeDraft()
    let ended = try makeDraft(
      state: .ended,
      endedAt: "2026-08-22T16:00:10Z",
      endMonotonicMicroseconds: 2_000,
      lastSourceSequence: 20)
    let originalBytes = try ndjson([active, ended])
    let ledgerURL = directory.appendingPathComponent("test-run-drafts.ndjson")
    try originalBytes.write(to: ledgerURL, options: [.atomic])

    let runs = try DiscoveryEvidenceStore(storageDirectory: directory).testRuns()

    XCTAssertEqual(runs, [ended])
    XCTAssertEqual(try Data(contentsOf: ledgerURL), originalBytes)
  }

  func testAbortAppendsTerminalSnapshotAndPreservesCommittedPrefix() throws {
    let directory = try makeStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeBinding(to: directory)
    let active = try makeDraft()
    let ledgerURL = directory.appendingPathComponent("test-run-drafts.ndjson")
    let originalPrefix = try ndjson([active])
    try originalPrefix.write(to: ledgerURL, options: [.atomic])
    let store = DiscoveryEvidenceStore(storageDirectory: directory)

    let aborted = try store.transitionTestRun(
      active,
      to: .aborted,
      observation: nil,
      recordedAt: "2026-08-22T16:00:10Z")
    let finalBytes = try Data(contentsOf: ledgerURL)

    XCTAssertTrue(finalBytes.starts(with: originalPrefix))
    XCTAssertGreaterThan(finalBytes.count, originalPrefix.count)
    XCTAssertEqual(aborted.state, .aborted)
    XCTAssertEqual(try store.testRuns(), [aborted])
  }

  func testMalformedCommittedRecordFailsClosedWithoutChangingBytesOrQuarantine() throws {
    let directory = try makeStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeBinding(to: directory)
    let ledgerURL = directory.appendingPathComponent("test-run-drafts.ndjson")
    let malformedBytes = Data("{\"contract\":\"not-a-supported-record\"}\n".utf8)
    try malformedBytes.write(to: ledgerURL, options: [.atomic])
    let store = DiscoveryEvidenceStore(storageDirectory: directory)

    XCTAssertThrowsError(try store.testRuns()) { error in
      XCTAssertEqual(
        error.localizedDescription,
        "The append-only Discovery ledger test-run-drafts.ndjson is invalid at line 1.")
    }
    XCTAssertEqual(try Data(contentsOf: ledgerURL), malformedBytes)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("Quarantine", isDirectory: true).path))
  }

  func testNoncanonicalDiscoverySafetyLedgerFailsClosedWithoutChangingBytes() throws {
    let directory = try makeStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeBinding(to: directory)
    let ledgerURL = directory.appendingPathComponent("test-run-drafts.ndjson")
    let canonical = try VHOSJSON.encoder().encode(makeDraft())
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: canonical) as? [String: Any])
    let noncanonical =
      try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys]
      ) + Data("\n".utf8)
    try noncanonical.write(to: ledgerURL, options: [.atomic])

    let store = DiscoveryEvidenceStore(storageDirectory: directory)
    XCTAssertThrowsError(try store.testRuns()) { error in
      XCTAssertEqual(
        error.localizedDescription,
        "The append-only Discovery ledger test-run-drafts.ndjson is invalid at line 1.")
    }
    XCTAssertEqual(try Data(contentsOf: ledgerURL), noncanonical)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("Quarantine", isDirectory: true).path))
  }

  func testPortableFramesRollIntoImmutableGenerationsAndExportEveryRecord() throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PortableFrameStore(
      fileManager: .default,
      root: directory,
      generationRecordLimit: 2)

    for sequence in 1...5 {
      XCTAssertTrue(try store.append(makePortableRecord(sequence: UInt64(sequence))))
    }

    let exportSet = try store.export(
      applicationID: "com.isaiahdupree.VehicleHealthOS",
      applicationVersion: "0.3.23",
      deviceModel: "iPhone")

    XCTAssertEqual(exportSet.generationCount, 3)
    XCTAssertEqual(exportSet.recordCount, 5)
    XCTAssertEqual(exportSet.artifacts.map(\.recordCount), [2, 2, 1])
    XCTAssertEqual(Set(exportSet.urls).count, 3)
    var recoveredSequences: [UInt64] = []
    for artifact in exportSet.artifacts {
      let imported = try EvidenceSyncBundle.decode(Data(contentsOf: artifact.url))
      XCTAssertEqual(imported.manifest.contractVersion, "2.0.0")
      XCTAssertEqual(
        imported.manifest.recovery?.classification,
        "RECOVERED_PORTABLE_EVIDENCE")
      XCTAssertEqual(imported.manifest.recovery?.vehicleClaimsAuthorized, false)
      XCTAssertEqual(
        imported.manifest.recovery?.sourceLedgerSHA256,
        artifact.sourceLedgerSHA256)
      XCTAssertEqual(imported.manifest.segments.first?.sha256, artifact.sourceLedgerSHA256)
      recoveredSequences.append(
        contentsOf: try imported.records.map { try $0.validatedFrame().sequence })
    }
    XCTAssertEqual(recoveredSequences, [1, 2, 3, 4, 5])

    let reloaded = PortableFrameStore(
      fileManager: .default,
      root: directory,
      generationRecordLimit: 2)
    XCTAssertEqual(try reloaded.count(), 5)
    XCTAssertEqual(try reloaded.records(limit: 3).map(\.sourceSequence), ["3", "4", "5"])
    XCTAssertFalse(try reloaded.append(makePortableRecord(sequence: 5)))
  }

  func testPortableGenerationHashTamperingFailsClosedWithoutHidingActiveEvidence() throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PortableFrameStore(
      fileManager: .default,
      root: directory,
      generationRecordLimit: 1)
    XCTAssertTrue(try store.append(makePortableRecord(sequence: 1)))
    XCTAssertTrue(try store.append(makePortableRecord(sequence: 2)))
    let sealed = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
      ).first(where: { $0.lastPathComponent.hasPrefix("logical-frames-generation-") }))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sealed.path)
    var bytes = try Data(contentsOf: sealed)
    bytes[0] ^= 0x01
    try bytes.write(to: sealed, options: .atomic)

    let reloaded = PortableFrameStore(
      fileManager: .default,
      root: directory,
      generationRecordLimit: 1)
    XCTAssertThrowsError(try reloaded.count()) { error in
      XCTAssertTrue(error is PortableFrameStoreError)
      XCTAssertTrue(error.localizedDescription.contains("no longer matches its immutable SHA-256"))
    }
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("logical-frames.ndjson").path))
  }

  func testPortableGenerationIntegrityManifestRejectsValidSameOrdinalReplacement() throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
      let store = PortableFrameStore(
        fileManager: .default,
        root: directory,
        generationRecordLimit: 1)
      XCTAssertTrue(try store.append(makePortableRecord(sequence: 1)))
      XCTAssertTrue(try store.append(makePortableRecord(sequence: 2)))
      XCTAssertEqual(try store.count(), 2)
    }
    let original = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
      ).first { $0.lastPathComponent.hasPrefix("logical-frames-generation-") })
    let replacementBytes = try ndjson([makePortableRecord(sequence: 99)])
    let replacementDigest = sha256(replacementBytes)
    let replacement = directory.appendingPathComponent(
      "logical-frames-generation-000000000001-\(replacementDigest).ndjson")
    try replacementBytes.write(to: replacement, options: [.atomic])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: original.path)
    try FileManager.default.removeItem(at: original)

    let reloaded = PortableFrameStore(
      fileManager: .default,
      root: directory,
      generationRecordLimit: 1)
    XCTAssertThrowsError(try reloaded.count()) { error in
      XCTAssertTrue(error.localizedDescription.contains("was rebound from immutable SHA-256"))
    }
  }

  func testPortableGenerationIntegrityManifestDeletionFailsClosed() throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
      let store = PortableFrameStore(
        fileManager: .default,
        root: directory,
        generationRecordLimit: 1)
      XCTAssertTrue(try store.append(makePortableRecord(sequence: 1)))
      XCTAssertTrue(try store.append(makePortableRecord(sequence: 2)))
      XCTAssertEqual(try store.count(), 2)
    }
    let manifest = directory.appendingPathComponent("generation-integrity-v1.manifest")
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
    try FileManager.default.removeItem(at: manifest)

    let reloaded = PortableFrameStore(fileManager: .default, root: directory)
    XCTAssertThrowsError(try reloaded.count()) { error in
      XCTAssertTrue(error.localizedDescription.contains("integrity manifest is missing"))
    }
  }

  func testLegacyInventoryMigrationRejectsMoreThanOneUnreceiptedSuffix() throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for ordinal in 1...2 {
      let bytes = try ndjson([makePortableRecord(sequence: UInt64(ordinal))])
      let digest = sha256(bytes)
      try bytes.write(
        to: directory.appendingPathComponent(
          "logical-frames-generation-\(String(format: "%012d", ordinal))-\(digest).ndjson"),
        options: [.atomic])
    }
    try Data("vhos.portable-generation-inventory/1\n".utf8).write(
      to: directory.appendingPathComponent("generation-inventory-v1.anchor"),
      options: [.atomic])
    try Data("0\n".utf8).write(
      to: directory.appendingPathComponent("generation-high-water.txt"),
      options: [.atomic])

    let store = PortableFrameStore(fileManager: .default, root: directory)
    XCTAssertThrowsError(try store.count()) { error in
      XCTAssertTrue(error.localizedDescription.contains("more than one unbound sealed generation"))
    }
  }

  func testLegacyV1InventoryStreamsOversizedActiveAfterExistingSealedPrefixAndRestarts() throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sealedBytes = try ndjson(
      [makePortableRecord(sequence: 1), makePortableRecord(sequence: 2)])
    let sealedDigest = sha256(sealedBytes)
    try sealedBytes.write(
      to: directory.appendingPathComponent(
        "logical-frames-generation-000000000001-\(sealedDigest).ndjson"),
      options: [.atomic])
    let activeBytes = try ndjson(
      (3...12).map { makePortableRecord(sequence: UInt64($0)) })
    try activeBytes.write(
      to: directory.appendingPathComponent("logical-frames.ndjson"), options: [.atomic])
    try Data("vhos.portable-generation-inventory/1\n".utf8).write(
      to: directory.appendingPathComponent("generation-inventory-v1.anchor"),
      options: [.atomic])
    try Data("1\n".utf8).write(
      to: directory.appendingPathComponent("generation-high-water.txt"),
      options: [.atomic])

    let store = PortableFrameStore(
      fileManager: .default,
      root: directory,
      generationByteLimit: 16 * 1_024 * 1_024,
      generationRecordLimit: 3)
    XCTAssertEqual(try store.count(), 12)
    let firstExport = try store.export(
      applicationID: "com.isaiahdupree.VehicleHealthOS",
      applicationVersion: "0.3.23",
      deviceModel: "iPhone")
    XCTAssertEqual(firstExport.artifacts.map(\.recordCount), [2, 3, 3, 3, 1])
    XCTAssertEqual(firstExport.recordCount, 12)
    XCTAssertEqual(
      try String(
        contentsOf: directory.appendingPathComponent("generation-inventory-v1.anchor"),
        encoding: .utf8),
      "vhos.portable-generation-inventory/2\n")
    let preserved = try FileManager.default.contentsOfDirectory(
      at: directory.appendingPathComponent(
        "AnchoredV1ActiveLedgerMigration", isDirectory: true),
      includingPropertiesForKeys: nil)
    XCTAssertTrue(
      try preserved.contains { url in
        guard url.pathExtension == "ndjson" else { return false }
        return try Data(contentsOf: url) == activeBytes
      })

    let reloaded = PortableFrameStore(
      fileManager: .default,
      root: directory,
      generationByteLimit: 16 * 1_024 * 1_024,
      generationRecordLimit: 3)
    XCTAssertEqual(try reloaded.count(), 12)
    XCTAssertFalse(try reloaded.append(makePortableRecord(sequence: 12)))
    let restartExport = try reloaded.export(
      applicationID: "com.isaiahdupree.VehicleHealthOS",
      applicationVersion: "0.3.23",
      deviceModel: "iPhone")
    XCTAssertEqual(restartExport.artifacts.map(\.recordCount), [2, 3, 3, 3, 1])
  }

  func testLegacyV1OversizedActiveMigrationResumesFromContentBoundPublishedSuffix() throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let baseBytes = try ndjson(
      [makePortableRecord(sequence: 1), makePortableRecord(sequence: 2)])
    let baseDigest = sha256(baseBytes)
    try baseBytes.write(
      to: directory.appendingPathComponent(
        "logical-frames-generation-000000000001-\(baseDigest).ndjson"),
      options: [.atomic])
    let activeBytes = try ndjson(
      (3...12).map { makePortableRecord(sequence: UInt64($0)) })
    try activeBytes.write(
      to: directory.appendingPathComponent("logical-frames.ndjson"), options: [.atomic])
    try Data("vhos.portable-generation-inventory/1\n".utf8).write(
      to: directory.appendingPathComponent("generation-inventory-v1.anchor"),
      options: [.atomic])
    try Data("1\n".utf8).write(
      to: directory.appendingPathComponent("generation-high-water.txt"),
      options: [.atomic])

    let migration = directory.appendingPathComponent(
      "AnchoredV1ActiveLedgerMigration", isDirectory: true)
    try FileManager.default.createDirectory(at: migration, withIntermediateDirectories: true)
    let activeDigest = sha256(activeBytes)
    try activeBytes.write(
      to: migration.appendingPathComponent("v1-active-ledger-\(activeDigest).ndjson"),
      options: [.atomic])
    let baseInventoryDigest = sha256(
      Data("vhos.portable-v1-migration-base/1\n1:\(baseDigest)\n".utf8))
    let state: [String: Any] = [
      "contract": "vhos.portable-v1-active-ledger-migration",
      "contract_version": "1.0.0",
      "source_file_name": "v1-active-ledger-\(activeDigest).ndjson",
      "source_ledger_sha256": activeDigest,
      "source_byte_count": activeBytes.count,
      "base_generation_count": 1,
      "base_generation_inventory_sha256": baseInventoryDigest,
    ]
    try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(
      to: migration.appendingPathComponent("migration-state.json"), options: [.atomic])
    let firstSuffixBytes = try ndjson(
      (3...5).map { makePortableRecord(sequence: UInt64($0)) })
    let firstSuffixDigest = sha256(firstSuffixBytes)
    try firstSuffixBytes.write(
      to: directory.appendingPathComponent(
        "logical-frames-generation-000000000002-\(firstSuffixDigest).ndjson"),
      options: [.atomic])

    let resumed = PortableFrameStore(
      fileManager: .default,
      root: directory,
      generationByteLimit: 16 * 1_024 * 1_024,
      generationRecordLimit: 3)
    XCTAssertEqual(try resumed.count(), 12)
    let export = try resumed.export(
      applicationID: "com.isaiahdupree.VehicleHealthOS",
      applicationVersion: "0.3.23",
      deviceModel: "iPhone")
    XCTAssertEqual(export.artifacts.map(\.recordCount), [2, 3, 3, 3, 1])
  }

  func testLegacyV1InventoryRefusesOversizedSealedGenerationBeforeV2Promotion() throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sealedBytes = try ndjson(
      (1...3).map { makePortableRecord(sequence: UInt64($0)) })
    let sealedDigest = sha256(sealedBytes)
    let sealed = directory.appendingPathComponent(
      "logical-frames-generation-000000000001-\(sealedDigest).ndjson")
    try sealedBytes.write(to: sealed, options: [.atomic])
    try Data("vhos.portable-generation-inventory/1\n".utf8).write(
      to: directory.appendingPathComponent("generation-inventory-v1.anchor"),
      options: [.atomic])
    try Data("1\n".utf8).write(
      to: directory.appendingPathComponent("generation-high-water.txt"),
      options: [.atomic])

    let store = PortableFrameStore(
      fileManager: .default,
      root: directory,
      generationByteLimit: 16 * 1_024 * 1_024,
      generationRecordLimit: 2)
    XCTAssertThrowsError(try store.count()) { error in
      XCTAssertTrue(error.localizedDescription.contains("exceeds the bounded generation contract"))
    }
    XCTAssertEqual(try Data(contentsOf: sealed), sealedBytes)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("generation-integrity-v1.manifest").path))
    XCTAssertEqual(
      try String(
        contentsOf: directory.appendingPathComponent("generation-inventory-v1.anchor"),
        encoding: .utf8),
      "vhos.portable-generation-inventory/1\n")
  }

  func testPortableGenerationExportIsByteStableAndContentIdentified() throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PortableFrameStore(fileManager: .default, root: directory)
    XCTAssertTrue(try store.append(makePortableRecord(sequence: 1)))

    let first = try store.export(
      applicationID: "com.isaiahdupree.VehicleHealthOS",
      applicationVersion: "0.3.23",
      deviceModel: "iPhone")
    let firstBytes = try Data(contentsOf: XCTUnwrap(first.urls.first))
    let firstManifest = try EvidenceSyncBundle.decode(firstBytes).manifest

    let second = try store.export(
      applicationID: "com.isaiahdupree.VehicleHealthOS",
      applicationVersion: "0.3.23",
      deviceModel: "iPhone")
    let secondBytes = try Data(contentsOf: XCTUnwrap(second.urls.first))
    let secondManifest = try EvidenceSyncBundle.decode(secondBytes).manifest

    XCTAssertEqual(firstBytes, secondBytes)
    XCTAssertEqual(firstManifest.bundleID, secondManifest.bundleID)
    XCTAssertEqual(firstManifest.createdAt, "2026-08-22T12:00:00Z")
    XCTAssertEqual(firstManifest.createdAt, secondManifest.createdAt)
  }

  func testPortableGenerationInventoryRejectsInteriorAndTrailingDeletion() throws {
    for deleteInterior in [true, false] {
      let directory = try makePortableStorageDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      do {
        let store = PortableFrameStore(
          fileManager: .default,
          root: directory,
          generationRecordLimit: 1)
        for sequence in 1...3 {
          XCTAssertTrue(try store.append(makePortableRecord(sequence: UInt64(sequence))))
        }
        XCTAssertEqual(try store.count(), 3)
      }
      let sealed = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
      )
      .filter { $0.lastPathComponent.hasPrefix("logical-frames-generation-") }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      XCTAssertEqual(sealed.count, 2)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: sealed[deleteInterior ? 0 : 1].path)
      try FileManager.default.removeItem(at: sealed[deleteInterior ? 0 : 1])

      let reloaded = PortableFrameStore(
        fileManager: .default,
        root: directory,
        generationRecordLimit: 1)
      XCTAssertThrowsError(try reloaded.count()) { error in
        if deleteInterior {
          XCTAssertTrue(error.localizedDescription.contains("generation 1 is missing"))
        } else {
          XCTAssertTrue(error.localizedDescription.contains("only 1 generations remain"))
        }
      }
    }
  }

  func testPortableGenerationInventoryCannotRebaselineAfterReceiptDeletion() throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
      let store = PortableFrameStore(
        fileManager: .default,
        root: directory,
        generationRecordLimit: 1)
      XCTAssertTrue(try store.append(makePortableRecord(sequence: 1)))
      XCTAssertTrue(try store.append(makePortableRecord(sequence: 2)))
      XCTAssertEqual(try store.count(), 2)
    }
    try FileManager.default.removeItem(
      at: directory.appendingPathComponent("generation-inventory-v1.anchor"))
    try FileManager.default.removeItem(
      at: directory.appendingPathComponent("generation-high-water.txt"))

    let reloaded = PortableFrameStore(
      fileManager: .default,
      root: directory,
      generationRecordLimit: 1)
    XCTAssertThrowsError(try reloaded.count()) { error in
      XCTAssertTrue(error.localizedDescription.contains("high-water receipt is missing"))
    }
  }

  func testPortableInterruptedTailRecoveryPreservesBytesThenContinuesAndExports() throws {
    let tails = [
      Data([0x00]),
      Data([0xC3]),
      Data("{\"contract\":\"vhos.portable".utf8),
    ]
    for tail in tails {
      let directory = try makePortableStorageDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let active = directory.appendingPathComponent("logical-frames.ndjson")
      let prefix = try ndjson([makePortableRecord(sequence: 1)])
      var interrupted = prefix
      interrupted.append(tail)
      try interrupted.write(to: active, options: [.atomic])

      let store = PortableFrameStore(fileManager: .default, root: directory)
      XCTAssertEqual(try store.count(), 1)
      XCTAssertEqual(try Data(contentsOf: active), prefix)
      let recovery = directory.appendingPathComponent(
        "InterruptedActiveLedger", isDirectory: true)
      let preserved = try FileManager.default.contentsOfDirectory(
        at: recovery, includingPropertiesForKeys: nil)
      XCTAssertEqual(preserved.filter { $0.pathExtension == "ndjson" }.count, 1)
      XCTAssertEqual(preserved.filter { $0.lastPathComponent.hasSuffix("-tail.bin") }.count, 1)
      XCTAssertTrue(
        try preserved.contains { url in
          try Data(contentsOf: url) == interrupted
        })
      XCTAssertTrue(
        try preserved.contains { url in
          try Data(contentsOf: url) == tail
        })

      XCTAssertTrue(try store.append(makePortableRecord(sequence: 2)))
      XCTAssertEqual(try store.count(), 2)
      let export = try store.export(
        applicationID: "com.isaiahdupree.VehicleHealthOS",
        applicationVersion: "0.3.23",
        deviceModel: "iPhone")
      let recovered = try EvidenceSyncBundle.decode(
        Data(contentsOf: XCTUnwrap(export.urls.first)))
      XCTAssertEqual(recovered.records.map(\.sourceSequence), ["1", "2"])
    }
  }

  func testPortableInterruptedFirstAppendPreservesTailAndRestoresEmptyActiveLedger() throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let active = directory.appendingPathComponent("logical-frames.ndjson")
    let interrupted = Data("{\"contract\":\"vhos.portable-logical-frame\"".utf8)
    try interrupted.write(to: active, options: [.atomic])

    let store = PortableFrameStore(fileManager: .default, root: directory)
    XCTAssertEqual(try store.count(), 0)
    XCTAssertEqual(try Data(contentsOf: active), Data())
    let recovery = directory.appendingPathComponent(
      "InterruptedActiveLedger", isDirectory: true)
    let preserved = try FileManager.default.contentsOfDirectory(
      at: recovery, includingPropertiesForKeys: nil)
    XCTAssertTrue(
      try preserved.contains { url in
        try Data(contentsOf: url) == interrupted
      })

    XCTAssertTrue(try store.append(makePortableRecord(sequence: 1)))
    XCTAssertEqual(try store.count(), 1)
  }

  func testPortableCompleteInvalidFinalLineFailsClosedWithoutRecoveryOrRewrite() throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let active = directory.appendingPathComponent("logical-frames.ndjson")
    var bytes = try ndjson([makePortableRecord(sequence: 1)])
    bytes.append(Data("{\"contract\":\"invalid-complete-line\"}\n".utf8))
    try bytes.write(to: active, options: [.atomic])

    let store = PortableFrameStore(fileManager: .default, root: directory)
    XCTAssertThrowsError(try store.count())
    XCTAssertEqual(try Data(contentsOf: active), bytes)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("InterruptedActiveLedger").path))
    let quarantine = directory.appendingPathComponent(
      "LegacyActiveLedgerQuarantine", isDirectory: true)
    let quarantined = try FileManager.default.contentsOfDirectory(
      at: quarantine, includingPropertiesForKeys: nil)
    XCTAssertTrue(
      try quarantined.contains { try Data(contentsOf: $0) == bytes })
  }

  func testPortableBlankAndNoncanonicalCommittedLinesFailClosedWithoutInventoryMutation() throws {
    let canonical = try VHOSJSON.encoder().encode(makePortableRecord(sequence: 1))
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: canonical) as? [String: Any])
    let noncanonical = try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    let invalidLedgers = [
      canonical + Data("\n\n".utf8),
      noncanonical + Data("\n".utf8),
    ]

    for bytes in invalidLedgers {
      let directory = try makePortableStorageDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let active = directory.appendingPathComponent("logical-frames.ndjson")
      try bytes.write(to: active, options: [.atomic])

      let store = PortableFrameStore(fileManager: .default, root: directory)
      XCTAssertThrowsError(try store.count())
      XCTAssertEqual(try Data(contentsOf: active), bytes)
      for name in [
        "generation-inventory-v1.anchor", "generation-high-water.txt",
        "generation-integrity-v1.manifest", "record-index.sqlite3",
      ] {
        XCTAssertFalse(
          FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
      }
      XCTAssertTrue(
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
          .filter { $0.hasPrefix("logical-frames-generation-") }.isEmpty)
    }
  }

  func testPortableMaximumIntegerHighWaterFailsClosedWithoutArithmeticTrapOrMutation() throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
      let store = PortableFrameStore(fileManager: .default, root: directory)
      XCTAssertTrue(try store.append(makePortableRecord(sequence: 1)))
      XCTAssertEqual(try store.count(), 1)
    }
    let highWater = directory.appendingPathComponent("generation-high-water.txt")
    let corrupted = Data("\(Int.max)\n".utf8)
    try corrupted.write(to: highWater, options: [.atomic])
    let active = directory.appendingPathComponent("logical-frames.ndjson")
    let activeBefore = try Data(contentsOf: active)
    let namesBefore = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()

    let reloaded = PortableFrameStore(fileManager: .default, root: directory)
    XCTAssertThrowsError(try reloaded.count()) { error in
      guard case PortableFrameStoreError.invalidGenerationInventoryReceipt = error else {
        return XCTFail("Expected invalid high-water receipt; received \(error)")
      }
    }
    XCTAssertEqual(try Data(contentsOf: highWater), corrupted)
    XCTAssertEqual(try Data(contentsOf: active), activeBefore)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), namesBefore)
  }

  func testMissingAnchorWithExistingIndexDoesNotRecoverTailOrSplitOversizedActive() throws {
    for appendPartialTail in [true, false] {
      let directory = try makePortableStorageDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      do {
        let store = PortableFrameStore(fileManager: .default, root: directory)
        XCTAssertTrue(try store.append(makePortableRecord(sequence: 1)))
        XCTAssertEqual(try store.count(), 1)
      }
      let anchor = directory.appendingPathComponent("generation-inventory-v1.anchor")
      try FileManager.default.removeItem(at: anchor)
      let active = directory.appendingPathComponent("logical-frames.ndjson")
      var bytes = try Data(contentsOf: active)
      if appendPartialTail {
        bytes.append(Data([0x7B, 0x22, 0xC3]))
      } else {
        bytes.append(try ndjson([makePortableRecord(sequence: 2)]))
      }
      try bytes.write(to: active, options: [.atomic])
      let namesBefore = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()

      let reloaded = PortableFrameStore(
        fileManager: .default,
        root: directory,
        generationRecordLimit: 1)
      XCTAssertThrowsError(try reloaded.count()) { error in
        guard case PortableFrameStoreError.missingGenerationInventoryReceipt = error else {
          return XCTFail("Expected missing inventory receipt; received \(error)")
        }
      }
      XCTAssertEqual(try Data(contentsOf: active), bytes)
      XCTAssertEqual(
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), namesBefore)
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("InterruptedActiveLedger").path))
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("LegacyActiveLedgerMigration").path))
    }
  }

  func testOversizedLegacyActiveLedgerStreamsIntoBoundedGenerations() throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let records = (1...25).map { makePortableRecord(sequence: UInt64($0)) }
    let original = try ndjson(records)
    try original.write(
      to: directory.appendingPathComponent("logical-frames.ndjson"), options: [.atomic])

    let store = PortableFrameStore(
      fileManager: .default,
      root: directory,
      generationByteLimit: 16 * 1_024 * 1_024,
      generationRecordLimit: 7)
    XCTAssertEqual(try store.count(), 25)
    let export = try store.export(
      applicationID: "com.isaiahdupree.VehicleHealthOS",
      applicationVersion: "0.3.23",
      deviceModel: "iPhone")
    XCTAssertEqual(export.artifacts.map(\.recordCount), [7, 7, 7, 4])
    XCTAssertEqual(export.recordCount, 25)
    XCTAssertTrue(export.artifacts.allSatisfy { $0.recordCount <= 7 })

    let migration = directory.appendingPathComponent(
      "LegacyActiveLedgerMigration", isDirectory: true)
    let preserved = try FileManager.default.contentsOfDirectory(
      at: migration, includingPropertiesForKeys: nil)
    XCTAssertTrue(
      try preserved.contains { url in
        guard url.pathExtension == "ndjson" else { return false }
        return try Data(contentsOf: url) == original
      })

    let reloaded = PortableFrameStore(
      fileManager: .default,
      root: directory,
      generationByteLimit: 16 * 1_024 * 1_024,
      generationRecordLimit: 7)
    XCTAssertEqual(try reloaded.count(), 25)
    XCTAssertFalse(try reloaded.append(makePortableRecord(sequence: 25)))
  }

  func testOversizedLegacyLedgerRecoversPartialTailBeforeStreamingMigration() throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let prefix = try ndjson((1...12).map { makePortableRecord(sequence: UInt64($0)) })
    let tail = Data([0x7B, 0x22, 0xC3])
    var interrupted = prefix
    interrupted.append(tail)
    try interrupted.write(
      to: directory.appendingPathComponent("logical-frames.ndjson"), options: [.atomic])

    let store = PortableFrameStore(
      fileManager: .default,
      root: directory,
      generationByteLimit: 16 * 1_024 * 1_024,
      generationRecordLimit: 5)
    XCTAssertEqual(try store.count(), 12)
    let export = try store.export(
      applicationID: "com.isaiahdupree.VehicleHealthOS",
      applicationVersion: "0.3.23",
      deviceModel: "iPhone")
    XCTAssertEqual(export.artifacts.map(\.recordCount), [5, 5, 2])
    let recovery = directory.appendingPathComponent(
      "InterruptedActiveLedger", isDirectory: true)
    let preserved = try FileManager.default.contentsOfDirectory(
      at: recovery, includingPropertiesForKeys: nil)
    XCTAssertTrue(try preserved.contains { try Data(contentsOf: $0) == interrupted })
    XCTAssertTrue(try preserved.contains { try Data(contentsOf: $0) == tail })
  }

  func testPortableDiskIndexRebuildsExactlyWithoutHistoricalIdentitySet() throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
      let store = PortableFrameStore(
        fileManager: .default,
        root: directory,
        generationRecordLimit: 7)
      for sequence in 1...120 {
        XCTAssertTrue(try store.append(makePortableRecord(sequence: UInt64(sequence))))
      }
      XCTAssertEqual(try store.count(), 120)
    }
    for suffix in ["", "-wal", "-shm"] {
      let url = directory.appendingPathComponent("record-index.sqlite3\(suffix)")
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
    }

    let rebuilt = PortableFrameStore(
      fileManager: .default,
      root: directory,
      generationRecordLimit: 7)
    XCTAssertEqual(try rebuilt.count(), 120)
    XCTAssertFalse(try rebuilt.append(makePortableRecord(sequence: 120)))
    XCTAssertTrue(try rebuilt.append(makePortableRecord(sequence: 121)))
    XCTAssertEqual(try rebuilt.count(), 121)
  }

  func testPortableRecordIdentityRequiresExactImmutableProvenanceAcrossRestart() throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = makePortableRecord(sequence: 1)
    do {
      let store = PortableFrameStore(fileManager: .default, root: directory)
      XCTAssertTrue(try store.append(original))
      XCTAssertFalse(try store.append(original))
    }

    let reloaded = PortableFrameStore(fileManager: .default, root: directory)
    XCTAssertFalse(try reloaded.append(original))
    XCTAssertThrowsError(
      try reloaded.append(makePortableRecord(sequence: 1, sourceRole: .acSensor))
    ) { error in
      XCTAssertTrue(
        error.localizedDescription.contains("conflicts with different immutable provenance"))
    }
    XCTAssertThrowsError(
      try reloaded.append(
        makePortableRecord(sequence: 1, ingestedAt: "2026-08-22T12:00:01Z"))
    ) { error in
      XCTAssertTrue(
        error.localizedDescription.contains("conflicts with different immutable provenance"))
    }
    XCTAssertEqual(try reloaded.count(), 1)
  }

  func testPortableRecordRejectsConflictingEnvelopeBytesBeforeIdentityDedupe() throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = makePortableRecord(sequence: 1)
    let store = PortableFrameStore(fileManager: .default, root: directory)
    XCTAssertTrue(try store.append(original))

    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: VHOSJSON.encoder().encode(original))
        as? [String: Any])
    object["envelope_base64"] = makePortableRecord(sequence: 2).envelopeBase64
    let conflictingPayload = try VHOSJSON.decoder().decode(
      PortableLogicalFrame.self,
      from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))

    XCTAssertEqual(conflictingPayload.id, original.id)
    XCTAssertThrowsError(try store.append(conflictingPayload))
    XCTAssertEqual(try store.count(), 1)
  }

  func testOversizedSyncImportRejectsBeforeAppendingAnyPortableEvidence() throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PortableFrameStore(fileManager: .default, root: directory)
    XCTAssertTrue(try store.append(makePortableRecord(sequence: 1)))

    let oversizedArchive = Data(repeating: 0x41, count: 18 * 1_024 * 1_024 + 1)
    XCTAssertThrowsError(try store.importBundle(oversizedArchive)) { error in
      XCTAssertEqual(error as? EvidenceSyncError, .archiveTooLarge)
    }

    XCTAssertEqual(try store.count(), 1)
    XCTAssertEqual(try store.records().map(\.sourceSequence), ["1"])
  }

  @MainActor
  func testOversizedSelectedSyncURLIsRejectedBeforeArchiveMaterialization() throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let oversizedURL = directory.appendingPathComponent("oversized-selected.vhossync")
    XCTAssertTrue(FileManager.default.createFile(atPath: oversizedURL.path, contents: nil))
    let handle = try FileHandle(forWritingTo: oversizedURL)
    try handle.truncate(
      atOffset: UInt64(EvidenceSyncBundle.maximumArchiveByteCount + 1))
    try handle.close()

    XCTAssertThrowsError(try GatewayBLEClient.readBoundedEvidenceSyncArchive(from: oversizedURL)) {
      error in
      XCTAssertEqual(error as? EvidenceSyncError, .archiveTooLarge)
    }
    XCTAssertEqual(
      try oversizedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      EvidenceSyncBundle.maximumArchiveByteCount + 1)
  }

  func testSyncImportPreflightsLaterProvenanceCollisionWithoutPartialAppend() throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PortableFrameStore(fileManager: .default, root: directory)
    XCTAssertTrue(try store.append(makePortableRecord(sequence: 1)))
    let activeURL = directory.appendingPathComponent("logical-frames.ndjson")
    let originalLedger = try Data(contentsOf: activeURL)
    let originalGenerationNames = try FileManager.default.contentsOfDirectory(
      atPath: directory.path
    )
    .filter { $0.hasPrefix("logical-frames-generation-") }
    .sorted()

    let archive = try EvidenceSyncBundle.encode(
      records: [
        makePortableRecord(sequence: 2),
        makePortableRecord(sequence: 1, sourceRole: .acSensor),
      ],
      creator: EvidenceBundleCreator(
        platform: "IOS",
        applicationID: "com.isaiahdupree.VehicleHealthOS",
        applicationVersion: "0.3.23",
        deviceModel: "iPhone"),
      createdAt: "2026-08-22T12:00:00Z")

    XCTAssertThrowsError(try store.importBundle(archive)) { error in
      XCTAssertTrue(
        error.localizedDescription.contains("conflicts with different immutable provenance"))
    }
    XCTAssertEqual(try Data(contentsOf: activeURL), originalLedger)
    XCTAssertEqual(try store.count(), 1)
    XCTAssertEqual(try store.records().map(\.sourceSequence), ["1"])
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasPrefix("logical-frames-generation-") }
        .sorted(),
      originalGenerationNames)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("ImportReceipts").path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("ImportIntents").path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("ImportedBundles").path))
  }

  func testSyncImportDurablyReceiptsManifestCreatorRecoveryAndExactRecordLinks() throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let records = [makePortableRecord(sequence: 1), makePortableRecord(sequence: 2)]
    let sourceLedgerDigest = sha256(try ndjson(records))
    let bundleID = try XCTUnwrap(
      UUID(uuidString: "11111111-2222-5333-8444-555555555555"))
    let archive = try EvidenceSyncBundle.encode(
      records: records,
      creator: EvidenceBundleCreator(
        platform: "IOS",
        applicationID: "com.isaiahdupree.VehicleHealthOS",
        applicationVersion: "0.3.23",
        deviceModel: "iPhone17,2"),
      recovery: EvidenceRecoveryMetadata(sourceLedgerSHA256: sourceLedgerDigest),
      bundleID: bundleID,
      createdAt: "2026-08-22T12:00:00Z")
    let store = PortableFrameStore(fileManager: .default, root: directory)

    let first = try store.importBundle(archive)
    let retry = try store.importBundle(archive)

    XCTAssertEqual(first.bundleID, bundleID)
    XCTAssertEqual(first.verifiedRecords, 2)
    XCTAssertEqual(first.appendedRecords, 2)
    XCTAssertEqual(retry.appendedRecords, 0)
    XCTAssertEqual(try store.count(), 2)
    let receiptDirectory = directory.appendingPathComponent("ImportReceipts")
    let receiptURLs = try FileManager.default.contentsOfDirectory(
      at: receiptDirectory, includingPropertiesForKeys: nil)
    XCTAssertEqual(receiptURLs.count, 1)
    let receipt = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: receiptURLs[0])) as? [String: Any])
    XCTAssertEqual(receipt["bundle_id"] as? String, bundleID.uuidString.uppercased())
    XCTAssertEqual(receipt["record_count"] as? Int, 2)
    XCTAssertEqual((receipt["manifest_sha256"] as? String)?.count, 64)
    XCTAssertEqual(receipt["archive_sha256"] as? String, sha256(archive))
    XCTAssertEqual((receipt["record_link_chain_sha256"] as? String)?.count, 64)
    let links = try XCTUnwrap(receipt["record_links"] as? [[String: Any]])
    XCTAssertEqual(links.count, 2)
    XCTAssertEqual(links.map { $0["record_id"] as? String }, records.map(\.id))
    XCTAssertTrue(
      links.allSatisfy { ($0["record_sha256"] as? String)?.count == 64 })
    let creator = try XCTUnwrap(receipt["creator"] as? [String: Any])
    XCTAssertEqual(creator["application_version"] as? String, "0.3.23")
    XCTAssertEqual(creator["device_model"] as? String, "iPhone17,2")
    let recovery = try XCTUnwrap(receipt["recovery"] as? [String: Any])
    XCTAssertEqual(recovery["source_ledger_sha256"] as? String, sourceLedgerDigest)
  }

  func testInterruptedImportRecoversIntentAndReexportsOriginalLineageAfterRestart() throws {
    struct SimulatedPowerLoss: Error {}

    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let records = [makePortableRecord(sequence: 1), makePortableRecord(sequence: 2)]
    let bundleID = try XCTUnwrap(
      UUID(uuidString: "AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEEEE"))
    let archive = try EvidenceSyncBundle.encode(
      records: records,
      creator: EvidenceBundleCreator(
        platform: "ANDROID",
        applicationID: "dev.vhos.headunit",
        applicationVersion: "0.1.0",
        deviceModel: "Q91-A4-CPL"),
      bundleID: bundleID,
      createdAt: "2026-08-22T12:00:00Z")

    do {
      let interrupted = PortableFrameStore(
        fileManager: .default,
        root: directory,
        importLifecycleHook: { phase in
          if case .recordsDurableBeforeReceipt = phase { throw SimulatedPowerLoss() }
        })
      XCTAssertThrowsError(try interrupted.importBundle(archive)) { error in
        XCTAssertTrue(error is SimulatedPowerLoss)
      }
      XCTAssertEqual(
        try FileManager.default.contentsOfDirectory(
          at: directory.appendingPathComponent("ImportIntents"),
          includingPropertiesForKeys: nil
        ).count,
        2)
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("ImportReceipts").path))
    }

    let recovered = PortableFrameStore(fileManager: .default, root: directory)
    XCTAssertEqual(try recovered.count(), 2)
    XCTAssertEqual(try recovered.records().map(\.sourceSequence), ["1", "2"])
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(
        at: directory.appendingPathComponent("ImportIntents"),
        includingPropertiesForKeys: nil
      ).isEmpty)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        at: directory.appendingPathComponent("ImportReceipts"),
        includingPropertiesForKeys: nil
      ).count,
      1)

    let export = try recovered.export(
      applicationID: "com.isaiahdupree.VehicleHealthOS",
      applicationVersion: "0.3.24",
      deviceModel: "iPhone")
    XCTAssertEqual(export.lineageArtifactCount, 2)
    let originalArtifact = try XCTUnwrap(
      export.lineageArtifacts.first {
        $0.contentType == "application/vnd.vhos.evidence-sync+zip"
      })
    XCTAssertEqual(try Data(contentsOf: originalArtifact.url), archive)
    XCTAssertEqual(originalArtifact.sha256, sha256(archive))
    let receiptArtifact = try XCTUnwrap(
      export.lineageArtifacts.first {
        $0.contentType == "application/vnd.vhos.import-provenance-receipt+json"
      })
    let receipt = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: receiptArtifact.url))
        as? [String: Any])
    XCTAssertEqual(receipt["bundle_id"] as? String, bundleID.uuidString.uppercased())
    XCTAssertEqual(receipt["archive_sha256"] as? String, sha256(archive))
    XCTAssertEqual(try recovered.importBundle(archive).appendedRecords, 0)
  }

  func testImportJournalPublishesIntentThenArchiveBeforeAnyRecordAndRecoversEveryCrashPoint()
    throws
  {
    struct SimulatedPowerLoss: Error {}

    let bundleID = try XCTUnwrap(
      UUID(uuidString: "9A4A4A4A-BBBB-5CCC-8DDD-EEEEEEEEEEEE"))
    let archive = try EvidenceSyncBundle.encode(
      records: [makePortableRecord(sequence: 1), makePortableRecord(sequence: 2)],
      creator: EvidenceBundleCreator(
        platform: "IOS",
        applicationID: "com.isaiahdupree.VehicleHealthOS",
        applicationVersion: "0.3.25",
        deviceModel: "iPhone"),
      bundleID: bundleID,
      createdAt: "2026-08-22T12:00:00Z")

    for interruptedPhase in [0, 1] {
      let directory = try makePortableStorageDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      var observedPhases: [Int] = []
      let store = PortableFrameStore(
        fileManager: .default,
        root: directory,
        importLifecycleHook: { phase in
          let ordinal: Int
          switch phase {
          case .intentDurableBeforeArchive: ordinal = 0
          case .archiveDurableBeforeRecords: ordinal = 1
          case .recordsDurableBeforeReceipt: ordinal = 2
          case .receiptDurableBeforeJournalRemoval: ordinal = 3
          }
          observedPhases.append(ordinal)
          if ordinal == interruptedPhase { throw SimulatedPowerLoss() }
        })
      XCTAssertThrowsError(try store.importBundle(archive)) { error in
        XCTAssertTrue(error is SimulatedPowerLoss)
      }
      XCTAssertEqual(observedPhases, Array(0...interruptedPhase))
      let activeURL = directory.appendingPathComponent("logical-frames.ndjson")
      XCTAssertEqual((try? Data(contentsOf: activeURL).count) ?? 0, 0)

      let recovered = PortableFrameStore(fileManager: .default, root: directory)
      if interruptedPhase == 0 {
        // The durable intent existed before the archive. Recovery quarantines that exact
        // pre-append journal and never invents records from an absent archive.
        XCTAssertEqual(try recovered.count(), 0)
        XCTAssertEqual(try recovered.importBundle(archive).appendedRecords, 2)
      } else {
        // The archive-ready marker is the append authority. Restart deterministically replays the
        // preserved archive, then publishes the receipt before deleting the journal.
        XCTAssertEqual(try recovered.count(), 2)
        XCTAssertEqual(try recovered.importBundle(archive).appendedRecords, 0)
      }
      XCTAssertTrue(
        try FileManager.default.contentsOfDirectory(
          at: directory.appendingPathComponent("ImportIntents"),
          includingPropertiesForKeys: nil
        ).isEmpty)
      XCTAssertEqual(
        try FileManager.default.contentsOfDirectory(
          at: directory.appendingPathComponent("ImportReceipts"),
          includingPropertiesForKeys: nil
        ).count,
        1)
    }
  }

  func testCompletedImportSurvivesCrashBeforeJournalRemovalWithoutLosingLineage() throws {
    struct SimulatedPowerLoss: Error {}

    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try EvidenceSyncBundle.encode(
      records: [makePortableRecord(sequence: 1), makePortableRecord(sequence: 2)],
      creator: EvidenceBundleCreator(
        platform: "IOS", applicationID: "vhos.test", applicationVersion: "1.0.0",
        deviceModel: "iPhone"),
      createdAt: "2026-08-22T12:00:00Z")
    let interrupted = PortableFrameStore(
      fileManager: .default,
      root: directory,
      importLifecycleHook: { phase in
        if case .receiptDurableBeforeJournalRemoval = phase { throw SimulatedPowerLoss() }
      })
    XCTAssertThrowsError(try interrupted.importBundle(archive)) { error in
      XCTAssertTrue(error is SimulatedPowerLoss)
    }

    let restarted = PortableFrameStore(fileManager: .default, root: directory)
    XCTAssertEqual(try restarted.count(), 2)
    let export = try restarted.export(
      applicationID: "vhos.test", applicationVersion: "1.0.0", deviceModel: "iPhone")
    XCTAssertEqual(export.lineageArtifactCount, 2)
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(
        at: directory.appendingPathComponent("ImportIntents"),
        includingPropertiesForKeys: nil
      ).isEmpty)
    let original = try XCTUnwrap(
      export.lineageArtifacts.first {
        $0.contentType == "application/vnd.vhos.evidence-sync+zip"
      })
    XCTAssertEqual(try Data(contentsOf: original.url), archive)
  }

  func testOrphanArchiveIsPreservedAndDoesNotBlockDifferentDigestForSameBundleID() throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let initialized = PortableFrameStore(fileManager: .default, root: directory)
    XCTAssertEqual(try initialized.count(), 0)
    let bundleID = try XCTUnwrap(
      UUID(uuidString: "BBBBBBBB-CCCC-5DDD-8EEE-FFFFFFFFFFFF"))
    let orphan = try EvidenceSyncBundle.encode(
      records: [makePortableRecord(sequence: 1)],
      creator: EvidenceBundleCreator(
        platform: "IOS", applicationID: "vhos.test", applicationVersion: "1.0.0",
        deviceModel: "iPhone"),
      bundleID: bundleID,
      createdAt: "2026-08-22T12:00:00Z")
    let replacement = try EvidenceSyncBundle.encode(
      records: [makePortableRecord(sequence: 2)],
      creator: EvidenceBundleCreator(
        platform: "IOS", applicationID: "vhos.test", applicationVersion: "1.0.1",
        deviceModel: "iPhone"),
      bundleID: bundleID,
      createdAt: "2026-08-22T12:00:01Z")
    let importedDirectory = directory.appendingPathComponent("ImportedBundles")
    try FileManager.default.createDirectory(
      at: importedDirectory, withIntermediateDirectories: true)
    let orphanURL = importedDirectory.appendingPathComponent(
      "bundle-\(bundleID.uuidString.lowercased())-\(sha256(orphan)).vhossync")
    try orphan.write(to: orphanURL, options: .atomic)

    let restarted = PortableFrameStore(fileManager: .default, root: directory)
    XCTAssertEqual(try restarted.count(), 0)
    let quarantine = directory.appendingPathComponent("ImportOrphans")
    let quarantined = try FileManager.default.contentsOfDirectory(
      at: quarantine, includingPropertiesForKeys: nil)
    XCTAssertEqual(quarantined.count, 1)
    XCTAssertEqual(try Data(contentsOf: quarantined[0]), orphan)
    XCTAssertEqual(try restarted.importBundle(replacement).appendedRecords, 1)
    XCTAssertEqual(try restarted.records().map(\.sourceSequence), ["2"])
  }

  func testLegacyV1ImportReceiptMigratesAtStartupWithoutManualArchiveSelection() throws {
    struct LegacyReceipt: Codable {
      let contract: String
      let contractVersion: String
      let bundleID: UUID
      let manifestSHA256: String
      let archiveSHA256: String
      let creator: EvidenceBundleCreator
      let recovery: EvidenceRecoveryMetadata?
      let recordCount: Int
      let recordLinkChainSHA256: String

      private enum CodingKeys: String, CodingKey {
        case contract, contractVersion, creator, recovery, recordCount
        case bundleID = "bundleId"
        case manifestSHA256 = "manifestSha256"
        case archiveSHA256 = "archiveSha256"
        case recordLinkChainSHA256 = "recordLinkChainSha256"
      }
    }

    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let creator = EvidenceBundleCreator(
      platform: "ANDROID", applicationID: "dev.vhos.headunit",
      applicationVersion: "0.1.0", deviceModel: "Q91-A4-CPL")
    let importedRecords = [makePortableRecord(sequence: 1), makePortableRecord(sequence: 2)]
    let recovery = EvidenceRecoveryMetadata(
      sourceLedgerSHA256: sha256(try ndjson(importedRecords)))
    let bundleID = try XCTUnwrap(
      UUID(uuidString: "CCCCCCCC-DDDD-5EEE-8FFF-AAAAAAAAAAAA"))
    let archive = try EvidenceSyncBundle.encode(
      records: importedRecords,
      creator: creator,
      recovery: recovery,
      bundleID: bundleID,
      createdAt: "2026-08-22T12:00:00Z")
    let store = PortableFrameStore(fileManager: .default, root: directory)
    _ = try store.importBundle(archive)
    let receiptURL = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(
        at: directory.appendingPathComponent("ImportReceipts"),
        includingPropertiesForKeys: nil
      ).first)
    let current = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
    let legacy = LegacyReceipt(
      contract: "vhos.portable-evidence-import-receipt",
      contractVersion: "1.0.0",
      bundleID: bundleID,
      manifestSHA256: try XCTUnwrap(current["manifest_sha256"] as? String),
      archiveSHA256: sha256(archive),
      creator: creator,
      recovery: recovery,
      recordCount: 2,
      recordLinkChainSHA256: try XCTUnwrap(
        current["record_link_chain_sha256"] as? String))
    try VHOSJSON.encoder().encode(legacy).write(to: receiptURL, options: .atomic)

    let restarted = PortableFrameStore(fileManager: .default, root: directory)
    XCTAssertEqual(try restarted.count(), 2)
    let migrated = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
    XCTAssertEqual(migrated["contract_version"] as? String, "2.0.0")
    XCTAssertEqual((migrated["record_links"] as? [[String: Any]])?.count, 2)
    XCTAssertEqual(
      try restarted.export(
        applicationID: "vhos.test", applicationVersion: "1.0.0", deviceModel: "iPhone"
      ).lineageArtifactCount,
      2)
  }

  func testMissingInventoryAnchorBlocksImportRecoveryBeforeAnyArtifactMutation() throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try EvidenceSyncBundle.encode(
      records: [makePortableRecord(sequence: 1)],
      creator: EvidenceBundleCreator(
        platform: "IOS", applicationID: "vhos.test", applicationVersion: "1.0.0",
        deviceModel: "iPhone"),
      createdAt: "2026-08-22T12:00:00Z")
    let initialized = PortableFrameStore(fileManager: .default, root: directory)
    _ = try initialized.importBundle(archive)

    let imported = directory.appendingPathComponent("ImportedBundles", isDirectory: true)
    let orphan = imported.appendingPathComponent(
      "bundle-00000000-0000-4000-8000-000000000001-"
        + String(repeating: "a", count: 64) + ".vhossync")
    try Data("orphan-exact-bytes".utf8).write(to: orphan, options: .atomic)
    try FileManager.default.removeItem(
      at: directory.appendingPathComponent("generation-inventory-v1.anchor"))
    let before = try fileTreeSnapshot(directory)

    let restarted = PortableFrameStore(fileManager: .default, root: directory)
    XCTAssertThrowsError(try restarted.count()) { error in
      guard case PortableFrameStoreError.missingGenerationInventoryReceipt = error else {
        return XCTFail("Expected anchor deletion to fail closed, got \(error)")
      }
    }
    XCTAssertEqual(try fileTreeSnapshot(directory), before)
  }

  func testQuarantineOnlyStoreCannotRebaselineAfterLegacySourceDisappears() throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let active = directory.appendingPathComponent("logical-frames.ndjson")
    let invalidCommitted = Data("{\"not\":\"a portable record\"}\n".utf8)
    try invalidCommitted.write(to: active, options: .atomic)
    let first = PortableFrameStore(fileManager: .default, root: directory)
    XCTAssertThrowsError(try first.count())
    let quarantine = directory.appendingPathComponent("LegacyActiveLedgerQuarantine")
    let quarantined = try FileManager.default.contentsOfDirectory(
      at: quarantine, includingPropertiesForKeys: nil)
    XCTAssertEqual(quarantined.count, 1)
    XCTAssertEqual(try Data(contentsOf: quarantined[0]), invalidCommitted)
    try FileManager.default.removeItem(at: active)

    let restarted = PortableFrameStore(fileManager: .default, root: directory)
    XCTAssertThrowsError(try restarted.count()) { error in
      guard case PortableFrameStoreError.missingGenerationInventoryReceipt = error else {
        return XCTFail("Expected quarantine-only initialized state to fail closed, got \(error)")
      }
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("generation-inventory-v1.anchor").path))
    XCTAssertEqual(try Data(contentsOf: quarantined[0]), invalidCommitted)
  }

  func testSingleArtifactPagesEventuallyCoverLedgerAndBothImportLineageArtifacts() async throws {
    let directory = try makePortableStorageDirectory()
    let output = directory.appendingPathComponent("Prepared", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let record = makePortableRecord(sequence: 1)
    let archive = try EvidenceSyncBundle.encode(
      records: [record],
      creator: EvidenceBundleCreator(
        platform: "ANDROID",
        applicationID: "dev.vhos.headunit",
        applicationVersion: "0.1.0",
        deviceModel: "Q91-A4-CPL"),
      createdAt: "2026-08-22T12:00:00Z")
    let store = PortableFrameStore(fileManager: .default, root: directory)
    XCTAssertEqual(try store.importBundle(archive).appendedRecords, 1)

    let worker = EvidenceWorkCoordinator()
    let creator = EvidenceBundleCreator(
      platform: "IOS",
      applicationID: "com.isaiahdupree.VehicleHealthOS.tests",
      applicationVersion: "1.0.0",
      deviceModel: "iPhone")
    var known: Set<String> = []
    var contentTypes: [String] = []
    var hasMore = true
    var pageCount = 0
    while hasMore {
      pageCount += 1
      XCTAssertLessThanOrEqual(pageCount, 3)
      let snapshot = try store.makeEvidenceWorkSnapshot(
        excludingArtifactIdentities: known,
        maximumArtifacts: 1)
      let page = try await worker.prepareEvidencePage(
        snapshot, creator: creator, outputDirectory: output)
      XCTAssertEqual(page.artifacts.count, 1)
      let artifact = try XCTUnwrap(page.artifacts.first)
      XCTAssertTrue(known.insert(artifact.artifactIdentity).inserted)
      contentTypes.append(artifact.contentType)
      hasMore = page.hasMore
    }

    XCTAssertEqual(pageCount, 3)
    XCTAssertEqual(contentTypes.filter { $0 == "application/vnd.vhos.evidence-sync+zip" }.count, 2)
    XCTAssertEqual(
      contentTypes.filter {
        $0 == "application/vnd.vhos.import-provenance-receipt+json"
      }.count,
      1)
  }

  func testDiscoveryDraftEvidenceEnqueuesAndReloadsWithNoVehicleAuthority() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "VHOSEvidenceOutboxTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let payload = Data("{\"contract\":\"vhos.discovery-draft-evidence\"}".utf8)
    let store = EvidenceOutboxStore(fileManager: .default, root: directory)

    let (insertedRecord, inserted) = try store.enqueue(
      payload: payload,
      contentType: "application/vnd.vhos.discovery-draft-evidence+json")
    let (_, duplicateInserted) = try store.enqueue(
      payload: payload,
      contentType: "application/vnd.vhos.discovery-draft-evidence+json")

    XCTAssertTrue(inserted)
    XCTAssertFalse(duplicateInserted)
    XCTAssertEqual(
      insertedRecord.envelope.contentType, "application/vnd.vhos.discovery-draft-evidence+json")
    XCTAssertTrue(insertedRecord.envelope.authority.mayInterpret)
    XCTAssertTrue(insertedRecord.envelope.authority.mayProposeExperiment)
    XCTAssertFalse(insertedRecord.envelope.authority.mayActivateExperiment)
    XCTAssertFalse(insertedRecord.envelope.authority.mayEmitVehicleFrames)

    let reloaded = EvidenceOutboxStore(fileManager: .default, root: directory)
    let record = try XCTUnwrap(reloaded.records().first)
    XCTAssertEqual(try Data(contentsOf: reloaded.payloadURL(for: record)), payload)
    XCTAssertEqual(try reloaded.records().count, 1)
  }

  func testBackgroundEvidencePageUsesExactSnapshotPrefixAndBoundedGenerationPage() async throws {
    let directory = try makePortableStorageDirectory()
    let output = directory.appendingPathComponent("Prepared", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PortableFrameStore(
      fileManager: .default,
      root: directory,
      generationByteLimit: 128 * 1_024,
      generationRecordLimit: 2)
    XCTAssertTrue(try store.append(makePortableRecord(sequence: 1)))
    XCTAssertTrue(try store.append(makePortableRecord(sequence: 2)))
    XCTAssertTrue(try store.append(makePortableRecord(sequence: 3)))

    let snapshot = try store.makeEvidenceWorkSnapshot(
      excludingArtifactIdentities: [], maximumArtifacts: 1)
    XCTAssertTrue(snapshot.hasMore)
    XCTAssertTrue(try store.append(makePortableRecord(sequence: 4)))

    let heartbeat = expectation(description: "main actor remained schedulable")
    let worker = EvidenceWorkCoordinator()
    let work = Task {
      try await worker.prepareEvidencePage(
        snapshot,
        creator: EvidenceBundleCreator(
          platform: "IOS",
          applicationID: "com.isaiahdupree.VehicleHealthOS.tests",
          applicationVersion: "1.0.0",
          deviceModel: "iPhone"),
        outputDirectory: output)
    }
    Task { @MainActor in heartbeat.fulfill() }
    await fulfillment(of: [heartbeat], timeout: 0.5)
    let page = try await work.value

    XCTAssertTrue(page.hasMore)
    XCTAssertEqual(page.artifacts.count, 1)
    let artifact = try XCTUnwrap(page.artifacts.first)
    XCTAssertEqual(artifact.byteCount, try Data(contentsOf: artifact.url).count)
    let bundle = try EvidenceSyncBundle.decode(Data(contentsOf: artifact.url))
    XCTAssertEqual(bundle.records.map(\.sourceSequence), ["1", "2"])
    XCTAssertFalse(bundle.records.contains(where: { $0.sourceSequence == "4" }))
  }

  func testLargeDiscoveryReplayRunsOffMainActorAndKeepsHeartbeatResponsive() async throws {
    let directory = try makeStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try ndjson([try makeBinding()]).write(
      to: directory.appendingPathComponent("capture-bindings.ndjson"), options: .atomic)
    try ndjson([try makeDraft()]).write(
      to: directory.appendingPathComponent("test-run-drafts.ndjson"), options: .atomic)
    var markers: [StoredDiscoveryMarker] = []
    markers.reserveCapacity(5_000)
    for index in 0..<5_000 {
      let marker = try EventMarker(
        id: "marker_" + String(format: "%026d", index + 1),
        captureID: captureID,
        gatewaySessionID: gatewaySessionID,
        gatewayMonotonicMicroseconds: UInt64(2_000 + index),
        recordedAt: "2026-08-22T16:00:01Z",
        kind: .custom,
        label: "LOAD MARKER \(index)",
        source: .iPhone,
        nearestCANSequence: UInt64(20 + index),
        note: "background replay fixture")
      markers.append(
        try StoredDiscoveryMarker(
          templateID: templateID,
          testRunID: runID,
          gatewayID: gatewayID,
          gatewaySessionID: gatewaySessionID,
          marker: marker))
    }
    try ndjson(markers).write(
      to: directory.appendingPathComponent("event-markers.ndjson"), options: .atomic)
    let worker = DiscoveryEvidencePersistenceWorker(storageDirectory: directory)
    let heartbeat = expectation(description: "main actor heartbeat")
    let completed = expectation(description: "background replay completed")

    Task { @MainActor in
      do {
        let snapshot = try await worker.snapshot()
        XCTAssertEqual(snapshot.markers.count, 5_000)
      } catch {
        XCTFail("Background Discovery replay failed: \(error)")
      }
      completed.fulfill()
    }
    Task { @MainActor in heartbeat.fulfill() }

    await fulfillment(of: [heartbeat], timeout: 0.5)
    await fulfillment(of: [completed], timeout: 10)
  }

  func testLegacyPortableRecoveryAndIndexRebuildRunOffMainActor() async throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let records = (1...5_000).map { makePortableRecord(sequence: UInt64($0)) }
    try ndjson(records).write(
      to: directory.appendingPathComponent("logical-frames.ndjson"), options: .atomic)
    let worker = GatewayEvidencePersistenceWorker(
      portableFrameStore: PortableFrameStore(fileManager: .default, root: directory),
      captureStore: CaptureLogStore(
        root: directory.appendingPathComponent("PassiveCAN", isDirectory: true)))
    let heartbeat = expectation(description: "main actor heartbeat")
    let completed = expectation(description: "background store preparation completed")

    Task { @MainActor in
      do {
        let preparation = try await worker.prepare()
        XCTAssertEqual(preparation.portableFrameCount, 5_000)
      } catch {
        XCTFail("Background recovery/index rebuild failed: \(error)")
      }
      completed.fulfill()
    }
    Task { @MainActor in heartbeat.fulfill() }

    await fulfillment(of: [heartbeat], timeout: 0.5)
    await fulfillment(of: [completed], timeout: 15)
  }

  func testMaximumArchiveReadAndDecodeRunOffMainActor() async throws {
    let directory = try makePortableStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let archiveURL = directory.appendingPathComponent("large-selected-archive.vhossync")
    XCTAssertTrue(FileManager.default.createFile(atPath: archiveURL.path, contents: Data([0x50])))
    let handle = try FileHandle(forWritingTo: archiveURL)
    try handle.truncate(atOffset: UInt64(17 * 1_024 * 1_024))
    try handle.close()
    let worker = GatewayEvidencePersistenceWorker(
      portableFrameStore: PortableFrameStore(
        fileManager: .default,
        root: directory.appendingPathComponent("Portable", isDirectory: true)),
      captureStore: CaptureLogStore(
        root: directory.appendingPathComponent("PassiveCAN", isDirectory: true)))
    let heartbeat = expectation(description: "main actor heartbeat")
    let completed = expectation(description: "background archive read completed")

    Task { @MainActor in
      do {
        _ = try await worker.importBundle(from: archiveURL)
        XCTFail("Expected invalid bounded archive to fail decode")
      } catch {
        // Expected after the bounded background read.
      }
      completed.fulfill()
    }
    Task { @MainActor in heartbeat.fulfill() }

    await fulfillment(of: [heartbeat], timeout: 0.5)
    await fulfillment(of: [completed], timeout: 10)
  }

  func testConcurrentBootstrapMarkerSubmissionsCommitExactlyOneFirstMarker() async throws {
    let directory = try makeStorageDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let worker = DiscoveryEvidencePersistenceWorker(storageDirectory: directory)
    let template = try DiscoveryMutationPolicy.parkSelectorBootstrapTemplate()
    let observation = PassiveCANObservation(
      gatewayID: gatewayID,
      sessionID: gatewaySessionID,
      sourceSequence: 10,
      monotonicMicroseconds: 1_000,
      bitrateBps: 500_000,
      identifier: 0x224,
      extended: false,
      remoteRequest: false,
      listenOnly: true,
      dataLength: 8,
      data: [0, 0, 0, 0, 0, 0, 0, 0],
      evidenceSource: "VHOS_GATEWAY",
      ingestedAt: startedAt)
    let run = try await worker.beginTestRun(
      template: template, observation: observation, recordedAt: startedAt)
    let tasks = (0..<2).map { _ in
      Task {
        try await worker.append(
          template: template,
          testRun: run,
          kind: .custom,
          label: "SAFETY SETUP CONFIRMED",
          observation: observation,
          recordedAt: "2026-08-22T16:00:01Z")
      }
    }
    var successCount = 0
    var failureCount = 0
    for task in tasks {
      do {
        _ = try await task.value
        successCount += 1
      } catch DiscoveryEvidenceStoreError.markerSequenceRequired {
        failureCount += 1
      }
    }
    XCTAssertEqual(successCount, 1)
    XCTAssertEqual(failureCount, 1)
    let committedMarkers = try await worker.markers()
    XCTAssertEqual(committedMarkers.count, 1)
  }

  private var pinnedActiveDraftLine: String {
    "{\"capture_id\":\"capture_01ARZ3NDEKTSV4RRFFQ69G5FAW\",\"contract\":\"vhos.ios.discovery-test-run-draft\",\"contract_version\":\"1.0.0\",\"first_source_sequence\":10,\"gateway_id\":\"esp32-9454c5b08d14\",\"gateway_session_id\":42,\"id\":\"run_01ARZ3NDEKTSV4RRFFQ69G5FAV\",\"start_monotonic_microseconds\":1000,\"started_at\":\"2026-08-22T16:00:00Z\",\"state\":\"ACTIVE\",\"template_id\":\"discovery.transmission.selector-bootstrap\",\"template_version\":\"1.0.0\"}"
  }

  private func makeBinding() throws -> DiscoveryCaptureBinding {
    try DiscoveryCaptureBinding(
      id: captureID,
      gatewayID: gatewayID,
      gatewaySessionID: gatewaySessionID,
      createdAt: startedAt)
  }

  private func makeDraft(
    state: DiscoveryTestRunDraftState = .active,
    endedAt: String? = nil,
    endMonotonicMicroseconds: UInt64? = nil,
    lastSourceSequence: UInt64? = nil
  ) throws -> DiscoveryTestRunDraft {
    try DiscoveryTestRunDraft(
      id: runID,
      templateID: templateID,
      templateVersion: "1.0.0",
      captureID: captureID,
      gatewayID: gatewayID,
      gatewaySessionID: gatewaySessionID,
      startedAt: startedAt,
      startMonotonicMicroseconds: 1_000,
      firstSourceSequence: 10,
      state: state,
      endedAt: endedAt,
      endMonotonicMicroseconds: endMonotonicMicroseconds,
      lastSourceSequence: lastSourceSequence)
  }

  private func makeMarker() throws -> StoredDiscoveryMarker {
    let marker = try EventMarker(
      id: markerID,
      captureID: captureID,
      gatewaySessionID: gatewaySessionID,
      gatewayMonotonicMicroseconds: 1_001,
      recordedAt: "2026-08-22T16:00:01Z",
      kind: .custom,
      label: "SAFETY SETUP CONFIRMED",
      source: .iPhone,
      nearestCANSequence: 10,
      note: "fixture")
    return try StoredDiscoveryMarker(
      templateID: templateID,
      testRunID: runID,
      gatewayID: gatewayID,
      gatewaySessionID: gatewaySessionID,
      marker: marker)
  }

  private func makeStorageDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "VHOSDiscoveryEvidenceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makePortableStorageDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "VHOSPortableFrameTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makePortableRecord(
    sequence: UInt64,
    sourceRole: EvidenceSourceRole = .obdCAN,
    ingestedAt: String = "2026-08-22T12:00:00Z"
  ) -> PortableLogicalFrame {
    PortableLogicalFrame(
      frame: GatewayFrame(
        messageType: .gatewayHealth,
        sequence: sequence,
        monotonicMicroseconds: sequence * 1_000,
        payload: Data("{\"contract\":\"gateway.health\"}".utf8)),
      sourceRole: sourceRole,
      sourceID: "esp32-test",
      ingestedAt: ingestedAt)
  }

  private func writeBinding(to directory: URL) throws {
    try ndjson([try makeBinding()]).write(
      to: directory.appendingPathComponent("capture-bindings.ndjson"), options: [.atomic])
  }

  private func ndjson<Record: Encodable>(_ records: [Record]) throws -> Data {
    var result = Data()
    for record in records {
      result.append(try VHOSJSON.encoder().encode(record))
      result.append(0x0A)
    }
    return result
  }

  private func sha256(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  private func fileTreeSnapshot(_ root: URL) throws -> [String: Data] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [],
        errorHandler: nil)
    else { return [:] }
    var result: [String: Data] = [:]
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey])
      guard values.isRegularFile == true else { continue }
      let prefix = root.standardizedFileURL.path + "/"
      guard url.standardizedFileURL.path.hasPrefix(prefix) else { continue }
      result[String(url.standardizedFileURL.path.dropFirst(prefix.count))] =
        try Data(contentsOf: url)
    }
    return result
  }
}
