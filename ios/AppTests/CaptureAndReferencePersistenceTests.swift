import CoreBluetooth
import Foundation
import VHOSCore
import XCTest

@testable import Vehicle_Health_OS

final class GatewayRestoredLinkPolicyTests: XCTestCase {
  func testRestoredLinkAlwaysWaitsForEvidenceAuthorityBeforeBluetoothWork() {
    for state in [
      CBPeripheralState.connected, .connecting, .disconnected, .disconnecting,
    ] {
      XCTAssertEqual(
        GatewayRestoredLinkPolicy.action(
          evidencePersistenceReady: false,
          peripheralState: state),
        .deferUntilEvidenceReady)
    }
  }

  func testVerifiedEvidenceAdoptsExistingLinksWithoutLaunchDisconnect() {
    XCTAssertEqual(
      GatewayRestoredLinkPolicy.action(
        evidencePersistenceReady: true,
        peripheralState: .connected),
      .adoptConnected)
    XCTAssertEqual(
      GatewayRestoredLinkPolicy.action(
        evidencePersistenceReady: true,
        peripheralState: .connecting),
      .awaitExistingConnection)
  }

  func testVerifiedEvidenceOnlyCreatesANewConnectionWhenPeripheralIsDisconnected() {
    XCTAssertEqual(
      GatewayRestoredLinkPolicy.action(
        evidencePersistenceReady: true,
        peripheralState: .disconnected),
      .connect)
    XCTAssertEqual(
      GatewayRestoredLinkPolicy.action(
        evidencePersistenceReady: true,
        peripheralState: .disconnecting),
      .awaitDisconnection)
  }
}

final class CaptureHistoryRecoveryPersistencePolicyTests: XCTestCase {
  func testCompletedDownloadResumeOnlyDoesNotAdvertiseIncompleteHistory() {
    XCTAssertFalse(
      CaptureHistoryRecoveryPersistencePolicy.restoredRecoveryAvailable(
        phase: .resuming,
        persistedIncompleteCheckpointAvailable: false))
  }

  func testInterruptedDownloadResumeOnlyKeepsItsExplicitCheckpoint() {
    XCTAssertTrue(
      CaptureHistoryRecoveryPersistencePolicy.restoredRecoveryAvailable(
        phase: .resuming,
        persistedIncompleteCheckpointAvailable: true))
  }

  func testLegacyDownloadingPhaseMigratesToIncompleteCheckpoint() {
    XCTAssertTrue(
      CaptureHistoryRecoveryPersistencePolicy.restoredRecoveryAvailable(
        phase: .downloading,
        persistedIncompleteCheckpointAvailable: false))
  }

  func testInertCheckpointRemainsAvailableAfterBulkIntentIsCleared() {
    XCTAssertTrue(
      CaptureHistoryRecoveryPersistencePolicy.restoredRecoveryAvailable(
        phase: nil,
        persistedIncompleteCheckpointAvailable: true))
  }
}

final class CaptureAndReferencePersistenceTests: XCTestCase {
  private let gatewayID = "esp32-9454c5b08d14"
  private let sessionID: UInt32 = 42

  func testCaptureCrashTailPreservesExactOriginalAndTailBeforeRecovery() throws {
    let root = try temporaryDirectory(named: "capture-tail")
    defer { try? FileManager.default.removeItem(at: root) }
    var store: CaptureLogStore? = CaptureLogStore(root: root)
    XCTAssertEqual(
      try store?.append(
        [captureObservation(sequence: 1), captureObservation(sequence: 2)],
        gatewayID: gatewayID,
        sessionID: sessionID),
      2)
    let ledgerURL = captureLedgerURL(root: root)
    let committedPrefix = try Data(contentsOf: ledgerURL)
    let interruptedTail = Data(#"{"source_sequence":3,"interrupted":"#.utf8)
    try appendRaw(interruptedTail, to: ledgerURL)
    let exactCrashedBytes = committedPrefix + interruptedTail
    store = nil

    let restarted = CaptureLogStore(root: root)
    XCTAssertEqual(try restarted.recordCount(gatewayID: gatewayID, sessionID: sessionID), 2)
    XCTAssertEqual(try Data(contentsOf: ledgerURL), committedPrefix)

    let recovery = root.appendingPathComponent("InterruptedCaptureTails", isDirectory: true)
    let files = try FileManager.default.contentsOfDirectory(
      at: recovery, includingPropertiesForKeys: nil)
    let tailURL = try XCTUnwrap(files.first { $0.lastPathComponent.hasSuffix("-tail.bin") })
    let originalURL = try XCTUnwrap(
      files.first { $0.lastPathComponent.hasSuffix("-original.ndjson") })
    XCTAssertEqual(try Data(contentsOf: tailURL), interruptedTail)
    XCTAssertEqual(try Data(contentsOf: originalURL), exactCrashedBytes)
    XCTAssertEqual(files.filter { $0.lastPathComponent.hasSuffix("-receipt.json") }.count, 1)
  }

  func testCaptureInvalidCommittedLineFailsClosedWithoutRewritingLedger() throws {
    let root = try temporaryDirectory(named: "capture-invalid-committed")
    defer { try? FileManager.default.removeItem(at: root) }
    var store: CaptureLogStore? = CaptureLogStore(root: root)
    XCTAssertEqual(
      try store?.append(
        [captureObservation(sequence: 1)], gatewayID: gatewayID, sessionID: sessionID),
      1)
    let ledgerURL = captureLedgerURL(root: root)
    let invalidCommitted = Data("{\"not\":\"a passive CAN observation\"}\n".utf8)
    try appendRaw(invalidCommitted, to: ledgerURL)
    let exactBytes = try Data(contentsOf: ledgerURL)
    store = nil

    let restarted = CaptureLogStore(root: root)
    XCTAssertThrowsError(
      try restarted.recordCount(gatewayID: gatewayID, sessionID: sessionID))
    XCTAssertEqual(try Data(contentsOf: ledgerURL), exactBytes)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("InterruptedCaptureTails").path))
  }

  func testCaptureRestartReconcilesCommittedLedgerAheadOfIndexedOffset() throws {
    let root = try temporaryDirectory(named: "capture-offset")
    defer { try? FileManager.default.removeItem(at: root) }
    var store: CaptureLogStore? = CaptureLogStore(root: root)
    let indexed = (1...64).map { captureObservation(sequence: UInt64($0)) }
    XCTAssertEqual(
      try store?.append(indexed, gatewayID: gatewayID, sessionID: sessionID), 64)
    let ledgerURL = captureLedgerURL(root: root)
    store = nil

    let committedAfterIndex = (65...128).map { captureObservation(sequence: UInt64($0)) }
    try appendRaw(try PassiveCANEvidenceArchive.encodeNDJSON(committedAfterIndex), to: ledgerURL)

    let restarted = CaptureLogStore(root: root)
    XCTAssertEqual(
      try restarted.recordCount(gatewayID: gatewayID, sessionID: sessionID), 128)
    XCTAssertEqual(
      try restarted.append(
        [captureObservation(sequence: 128)], gatewayID: gatewayID, sessionID: sessionID),
      0)
    XCTAssertEqual(
      try restarted.append(
        [captureObservation(sequence: 129)], gatewayID: gatewayID, sessionID: sessionID),
      1)
    XCTAssertEqual(
      try restarted.recordCount(gatewayID: gatewayID, sessionID: sessionID), 129)
  }

  func testCaptureLargeLedgerBuildsBoundedDurableIndexWithoutWholeFileSet() throws {
    let root = try temporaryDirectory(named: "capture-large")
    defer { try? FileManager.default.removeItem(at: root) }
    let ledgerURL = captureLedgerURL(root: root)
    try FileManager.default.createDirectory(
      at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    XCTAssertTrue(FileManager.default.createFile(atPath: ledgerURL.path, contents: nil))
    let handle = try FileHandle(forWritingTo: ledgerURL)
    for start in stride(from: 1, through: 10_000, by: 250) {
      let end = min(start + 249, 10_000)
      let batch = (start...end).map { captureObservation(sequence: UInt64($0)) }
      try handle.write(contentsOf: PassiveCANEvidenceArchive.encodeNDJSON(batch))
    }
    try handle.synchronize()
    try handle.close()

    let store = CaptureLogStore(root: root)
    XCTAssertEqual(try store.recordCount(gatewayID: gatewayID, sessionID: sessionID), 10_000)
    XCTAssertEqual(try store.summaries().first?.recordCount, 10_000)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("capture-index.sqlite3").path))
    XCTAssertEqual(
      try store.append(
        [captureObservation(sequence: 9_999)], gatewayID: gatewayID, sessionID: sessionID),
      0)
  }

  func testActiveDebugRunCanReacquireItsExactStartAfterCacheEvictionAndRestart() throws {
    let root = try temporaryDirectory(named: "capture-debug-run-pin")
    defer { try? FileManager.default.removeItem(at: root) }
    var store: CaptureLogStore? = CaptureLogStore(root: root)
    let records = (1...600).map { captureObservation(sequence: UInt64($0)) }
    XCTAssertEqual(
      try store?.append(records, gatewayID: gatewayID, sessionID: sessionID),
      600)
    store = nil

    let restarted = CaptureLogStore(root: root)
    let pinned = try restarted.observation(
      gatewayID: gatewayID,
      sessionID: sessionID,
      sourceSequence: 1)
    XCTAssertEqual(pinned, records[0])
    XCTAssertNil(
      try restarted.observation(
        gatewayID: gatewayID,
        sessionID: sessionID,
        sourceSequence: 601))
  }

  func testReferenceCrashTailPreservesExactBytesAndRecoversCanonicalPrefix() async throws {
    let root = try temporaryDirectory(named: "reference-tail")
    defer { try? FileManager.default.removeItem(at: root) }
    var store: SynchronizedReferenceStore? = SynchronizedReferenceStore(root: root)
    let appended = try await store?.append([Self.referenceSample(1), Self.referenceSample(2)])
    XCTAssertEqual(appended, 2)
    let ledgerURL = root.appendingPathComponent("reference-samples.ndjson")
    let committedPrefix = try Data(contentsOf: ledgerURL)
    let interruptedTail = Data(#"{"id":"interrupted"#.utf8)
    try appendRaw(interruptedTail, to: ledgerURL)
    let exactCrashedBytes = committedPrefix + interruptedTail
    store = nil

    let restarted = SynchronizedReferenceStore(root: root)
    let recoveredCount = try await restarted.count()
    XCTAssertEqual(recoveredCount, 2)
    XCTAssertEqual(try Data(contentsOf: ledgerURL), committedPrefix)
    let recovery = root.appendingPathComponent("InterruptedReferenceTails", isDirectory: true)
    let files = try FileManager.default.contentsOfDirectory(
      at: recovery, includingPropertiesForKeys: nil)
    let tailURL = try XCTUnwrap(files.first { $0.lastPathComponent.hasSuffix("-tail.bin") })
    let originalURL = try XCTUnwrap(
      files.first { $0.lastPathComponent.hasSuffix("-original.ndjson") })
    XCTAssertEqual(try Data(contentsOf: tailURL), interruptedTail)
    XCTAssertEqual(try Data(contentsOf: originalURL), exactCrashedBytes)
  }

  func testReferenceActorSustainsBatchedLoadAndKeepsMainActorResponsive() async throws {
    let root = try temporaryDirectory(named: "reference-load")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SynchronizedReferenceStore(root: root, maximumSamples: 6_000)
    let heartbeat = expectation(description: "main actor remained schedulable")
    let completed = expectation(description: "batched reference appends completed")
    let batches = try stride(from: 1, through: 5_000, by: 250).map { start in
      try (start...min(start + 249, 5_000)).map(Self.referenceSample)
    }

    Task { @MainActor in
      do {
        for batch in batches {
          let appended = try await store.append(batch)
          XCTAssertEqual(appended, batch.count)
        }
        let count = try await store.count()
        XCTAssertEqual(count, 5_000)
        let repeated = try await store.append(batches[0])
        XCTAssertEqual(
          repeated, 0, "A repeated batch must be a zero-byte/index delta")
      } catch {
        XCTFail("Sustained reference append failed: \(error)")
      }
      completed.fulfill()
    }
    Task { @MainActor in heartbeat.fulfill() }

    await fulfillment(of: [heartbeat], timeout: 0.5)
    await fulfillment(of: [completed], timeout: 20)
    let ledgerURL = root.appendingPathComponent("reference-samples.ndjson")
    let bytes = try Data(contentsOf: ledgerURL, options: [.mappedIfSafe])
    XCTAssertEqual(bytes.filter { $0 == 0x0A }.count, 5_000)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("reference-index.sqlite3").path))
  }

  func testReferenceDedupePreservesEveryEvidenceBearingFieldAndRejectsIdentityCollision()
    async throws
  {
    let root = try temporaryDirectory(named: "reference-complete-evidence-dedupe")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SynchronizedReferenceStore(root: root)
    let baseID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000101"))

    func sample(
      id: UUID,
      gatewayMonotonicMicroseconds: UInt64 = 1_000_000,
      signalID: String = "reference.engine-rpm",
      value: Double = 742,
      unit: String = "rpm",
      source: String = "TOYOTA_TECHSTREAM",
      recordedAt: String = "2026-08-22T16:00:00Z",
      nearestCANSequence: UInt64? = 41,
      evidenceNote: String = "Techstream synchronized reference"
    ) throws -> SynchronizedReferenceSample {
      try SynchronizedReferenceSample(
        id: id,
        gatewayMonotonicMicroseconds: gatewayMonotonicMicroseconds,
        signalID: signalID,
        value: value,
        unit: unit,
        source: source,
        recordedAt: recordedAt,
        nearestCANSequence: nearestCANSequence,
        evidenceNote: evidenceNote)
    }

    let records = try [
      sample(id: baseID),
      sample(
        id: XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000102")),
        unit: "revolutions_per_minute"),
      sample(
        id: XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000103")),
        recordedAt: "2026-08-22T16:00:01Z"),
      sample(
        id: XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000104")),
        nearestCANSequence: 42),
      sample(
        id: XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000105")),
        evidenceNote: "Independent OBD synchronized reference"),
    ]
    let appendedCount = try await store.append(records)
    let storedCount = try await store.count()
    XCTAssertEqual(appendedCount, records.count)
    XCTAssertEqual(storedCount, records.count)

    // A second UUID carrying byte-for-byte equivalent evidence is a true semantic duplicate.
    let exactEvidenceDuplicate = try sample(
      id: XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000106")))
    let appendedExactDuplicate = try await store.append(exactEvidenceDuplicate)
    XCTAssertFalse(appendedExactDuplicate)

    let ledgerURL = root.appendingPathComponent("reference-samples.ndjson")
    let committedBytes = try Data(contentsOf: ledgerURL)
    let identityCollisionVariants = try [
      sample(id: baseID, gatewayMonotonicMicroseconds: 1_000_001),
      sample(id: baseID, signalID: "reference.engine-speed"),
      sample(id: baseID, value: 743),
      sample(id: baseID, unit: "revolutions_per_minute"),
      sample(id: baseID, source: "SAE_J1979"),
      sample(id: baseID, recordedAt: "2026-08-22T16:00:01Z"),
      sample(id: baseID, nearestCANSequence: 42),
      sample(
        id: baseID,
        evidenceNote: "Conflicting evidence under the same immutable identity"),
    ]
    for conflictingIdentity in identityCollisionVariants {
      do {
        _ = try await store.append(conflictingIdentity)
        XCTFail("A reused immutable identity with changed evidence must fail closed")
      } catch let error as SynchronizedReferenceStoreError {
        guard case .recordIdentityCollision(baseID) = error else {
          return XCTFail("Unexpected synchronized-reference collision error: \(error)")
        }
      }
    }
    let finalCount = try await store.count()
    XCTAssertEqual(finalCount, records.count)
    XCTAssertEqual(try Data(contentsOf: ledgerURL), committedBytes)
  }

  func testReferenceDedupePreservesSignedZeroAsExactValueEvidence() async throws {
    let root = try temporaryDirectory(named: "reference-signed-zero")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SynchronizedReferenceStore(root: root)
    let positiveID = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-4000-8000-000000000201"))
    let negativeID = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-4000-8000-000000000202"))

    func sample(id: UUID, value: Double) throws -> SynchronizedReferenceSample {
      try SynchronizedReferenceSample(
        id: id,
        gatewayMonotonicMicroseconds: 2_000_000,
        signalID: "reference.steering-offset",
        value: value,
        unit: "degree",
        source: "TOYOTA_TECHSTREAM",
        recordedAt: "2026-08-22T16:00:00Z",
        nearestCANSequence: 51,
        evidenceNote: "Signed-zero lineage regression")
    }

    let appended = try await store.append([
      sample(id: positiveID, value: 0.0),
      sample(id: negativeID, value: -0.0),
    ])
    let storedCount = try await store.count()
    XCTAssertEqual(appended, 2)
    XCTAssertEqual(storedCount, 2)
    do {
      _ = try await store.append(sample(id: positiveID, value: -0.0))
      XCTFail("A reused identity with a different IEEE-754 value must fail closed")
    } catch let error as SynchronizedReferenceStoreError {
      guard case .recordIdentityCollision(positiveID) = error else {
        return XCTFail("Unexpected signed-zero collision error: \(error)")
      }
    }
  }

  private func captureObservation(sequence: UInt64) -> PassiveCANObservation {
    PassiveCANObservation(
      gatewayID: gatewayID,
      sessionID: sessionID,
      sourceSequence: sequence,
      monotonicMicroseconds: sequence * 1_000,
      bitrateBps: 500_000,
      identifier: 0x224,
      extended: false,
      remoteRequest: false,
      listenOnly: true,
      dataLength: 8,
      data: [
        UInt8(truncatingIfNeeded: sequence), 1, 2, 3, 4, 5, 6, 7,
      ],
      evidenceSource: "gateway-flash",
      ingestedAt: "2026-08-22T16:00:00Z")
  }

  private nonisolated static func referenceSample(_ ordinal: Int) throws
    -> SynchronizedReferenceSample
  {
    let id = try XCTUnwrap(
      UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", ordinal)))
    return try SynchronizedReferenceSample(
      id: id,
      gatewayMonotonicMicroseconds: UInt64(ordinal) * 1_000,
      signalID: "reference.engine-rpm",
      value: Double(ordinal),
      unit: "rpm",
      source: "SAE_J1979",
      recordedAt: "2026-08-22T16:00:00Z",
      nearestCANSequence: UInt64(ordinal),
      evidenceNote: "Sustained real-ledger persistence test sample \(ordinal).")
  }

  private func captureLedgerURL(root: URL) -> URL {
    root.appendingPathComponent(gatewayID, isDirectory: true)
      .appendingPathComponent("\(sessionID).ndjson")
  }

  private func appendRaw(_ bytes: Data, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: bytes)
    try handle.synchronize()
    try handle.close()
  }

  private func temporaryDirectory(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "vhos-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
