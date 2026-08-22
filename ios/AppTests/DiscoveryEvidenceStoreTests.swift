import Foundation
import XCTest

@testable import Vehicle_Health_OS
import VHOSCore

final class DiscoveryEvidenceStoreTests: XCTestCase {
  private let captureID = "capture_01ARZ3NDEKTSV4RRFFQ69G5FAW"
  private let runID = "run_01ARZ3NDEKTSV4RRFFQ69G5FAV"
  private let markerID = "marker_01ARZ3NDEKTSV4RRFFQ69G5FAX"
  private let templateID = "discovery.transmission.selector-bootstrap"
  private let startedAt = "2026-08-22T16:00:00Z"
  private let gatewayID = "esp32-9454c5b08d14"
  private let gatewaySessionID: UInt32 = 42

  func testAllOnDiskRecordsRoundTripExactSnakeCaseEncoderOutput() throws {
    let binding = try makeBinding()
    let draft = try makeDraft()
    let marker = try makeMarker()

    let bindingBytes = try VHOSJSON.encoder().encode(binding)
    XCTAssertEqual(
      String(decoding: bindingBytes, as: UTF8.self),
      "{\"contract\":\"vhos.ios.discovery-capture-binding\",\"contract_version\":\"1.0.0\",\"created_at\":\"2026-08-22T16:00:00Z\",\"gateway_id\":\"esp32-9454c5b08d14\",\"gateway_session_id\":42,\"id\":\"capture_01ARZ3NDEKTSV4RRFFQ69G5FAW\"}")
    XCTAssertEqual(try VHOSJSON.decoder().decode(DiscoveryCaptureBinding.self, from: bindingBytes), binding)

    let draftBytes = try VHOSJSON.encoder().encode(draft)
    XCTAssertEqual(String(decoding: draftBytes, as: UTF8.self), pinnedActiveDraftLine)
    XCTAssertEqual(try VHOSJSON.decoder().decode(DiscoveryTestRunDraft.self, from: draftBytes), draft)

    let markerBytes = try VHOSJSON.encoder().encode(marker)
    XCTAssertEqual(
      String(decoding: markerBytes, as: UTF8.self),
      "{\"contract\":\"vhos.ios.discovery-marker-ledger-record\",\"contract_version\":\"1.0.0\",\"gateway_id\":\"esp32-9454c5b08d14\",\"gateway_session_id\":42,\"marker\":{\"authority\":\"OBSERVED\",\"capture_id\":\"capture_01ARZ3NDEKTSV4RRFFQ69G5FAW\",\"contract\":\"vhos.discovery.event-marker\",\"contract_version\":\"1.0.0\",\"gateway_monotonic_microseconds\":1001,\"gateway_session_id\":42,\"id\":\"marker_01ARZ3NDEKTSV4RRFFQ69G5FAX\",\"kind\":\"CUSTOM\",\"label\":\"SAFETY SETUP CONFIRMED\",\"nearest_can_sequence\":10,\"note\":\"fixture\",\"recorded_at\":\"2026-08-22T16:00:01Z\",\"source\":\"IPHONE\"},\"template_id\":\"discovery.transmission.selector-bootstrap\",\"test_run_id\":\"run_01ARZ3NDEKTSV4RRFFQ69G5FAV\"}")
    XCTAssertEqual(try VHOSJSON.decoder().decode(StoredDiscoveryMarker.self, from: markerBytes), marker)
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
}
