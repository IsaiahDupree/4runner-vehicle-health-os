import Foundation
import VHOSCore

/// Append-only binding between the gateway's numeric recorder session and the durable Discovery
/// capture identifier used by the shared domain contracts.
struct DiscoveryCaptureBinding: Codable, Equatable, Identifiable {
  let contract: String
  let contractVersion: String
  let id: String
  let gatewayID: String
  let gatewaySessionID: UInt32
  let createdAt: String

  init(
    id: String,
    gatewayID: String,
    gatewaySessionID: UInt32,
    createdAt: String
  ) throws {
    guard DiscoveryEvidenceStoreValidation.isDomainID(id, prefix: "capture"),
      !gatewayID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      gatewayID.count <= 160,
      ISO8601DateFormatter().date(from: createdAt) != nil
    else { throw DiscoveryEvidenceStoreError.invalidCaptureBinding }
    contract = "vhos.ios.discovery-capture-binding"
    contractVersion = "1.0.0"
    self.id = id
    self.gatewayID = gatewayID
    self.gatewaySessionID = gatewaySessionID
    self.createdAt = createdAt
  }

  func validate() throws {
    guard contract == "vhos.ios.discovery-capture-binding", contractVersion == "1.0.0"
    else { throw DiscoveryEvidenceStoreError.unsupportedRecord }
    _ = try DiscoveryCaptureBinding(
      id: id,
      gatewayID: gatewayID,
      gatewaySessionID: gatewaySessionID,
      createdAt: createdAt)
  }
}

/// App-local index metadata around the canonical, shared `EventMarker` evidence record.
///
/// `marker` is the authoritative serialized observation. The remaining fields make the originating
/// test and gateway recorder session queryable without changing the versioned Core contract.
struct StoredDiscoveryMarker: Codable, Equatable, Identifiable {
  let contract: String
  let contractVersion: String
  let templateID: String
  let testRunID: String?
  let gatewayID: String
  let gatewaySessionID: UInt32
  let marker: EventMarker

  var id: String { marker.id }
  var label: String { marker.label }
  var captureSessionID: UInt32 { gatewaySessionID }
  var sourceSequence: UInt64 { marker.nearestCANSequence ?? 0 }

  init(
    templateID: String,
    testRunID: String? = nil,
    gatewayID: String,
    gatewaySessionID: UInt32,
    marker: EventMarker
  ) throws {
    guard testRunID.map({ DiscoveryEvidenceStoreValidation.isDomainID($0, prefix: "run") }) ?? true,
      !templateID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      templateID.count <= 160,
      !gatewayID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      gatewayID.count <= 160
    else { throw DiscoveryEvidenceStoreError.invalidMarkerRecord }
    try marker.validateContract()
    contract = "vhos.ios.discovery-marker-ledger-record"
    contractVersion = "1.0.0"
    self.templateID = templateID
    self.testRunID = testRunID
    self.gatewayID = gatewayID
    self.gatewaySessionID = gatewaySessionID
    self.marker = marker
  }

  func validate() throws {
    guard contract == "vhos.ios.discovery-marker-ledger-record", contractVersion == "1.0.0"
    else { throw DiscoveryEvidenceStoreError.unsupportedRecord }
    _ = try StoredDiscoveryMarker(
      templateID: templateID,
      testRunID: testRunID,
      gatewayID: gatewayID,
      gatewaySessionID: gatewaySessionID,
      marker: marker)
  }
}

enum DiscoveryTestRunDraftState: String, Codable, Sendable {
  case active = "ACTIVE"
  case ended = "ENDED"
  case aborted = "ABORTED"
}

/// A local, append-only test-run draft. It deliberately is not a finalized `CaptureSession`:
/// archive and manifest hashes are only available after retained evidence synchronization.
struct DiscoveryTestRunDraft: Codable, Equatable, Identifiable {
  let contract: String
  let contractVersion: String
  let id: String
  let templateID: String
  let templateVersion: String
  let captureID: String
  let gatewayID: String
  let gatewaySessionID: UInt32
  let startedAt: String
  let startMonotonicMicroseconds: UInt64
  let firstSourceSequence: UInt64
  let state: DiscoveryTestRunDraftState
  let endedAt: String?
  let endMonotonicMicroseconds: UInt64?
  let lastSourceSequence: UInt64?

  init(
    id: String,
    templateID: String,
    templateVersion: String,
    captureID: String,
    gatewayID: String,
    gatewaySessionID: UInt32,
    startedAt: String,
    startMonotonicMicroseconds: UInt64,
    firstSourceSequence: UInt64,
    state: DiscoveryTestRunDraftState,
    endedAt: String? = nil,
    endMonotonicMicroseconds: UInt64? = nil,
    lastSourceSequence: UInt64? = nil
  ) throws {
    let hasGatewayEnd = endMonotonicMicroseconds != nil && lastSourceSequence != nil
    let hasPartialGatewayEnd = (endMonotonicMicroseconds == nil) != (lastSourceSequence == nil)
    guard DiscoveryEvidenceStoreValidation.isDomainID(id, prefix: "run"),
      DiscoveryEvidenceStoreValidation.isDomainID(captureID, prefix: "capture"),
      !templateID.isEmpty, templateID.count <= 160,
      !templateVersion.isEmpty, templateVersion.count <= 80,
      !gatewayID.isEmpty, gatewayID.count <= 160,
      ISO8601DateFormatter().date(from: startedAt) != nil,
      !hasPartialGatewayEnd,
      (state == .active && endedAt == nil && !hasGatewayEnd)
        || (state == .ended && endedAt != nil && hasGatewayEnd)
        || (state == .aborted && endedAt != nil),
      endedAt.map({ ISO8601DateFormatter().date(from: $0) != nil }) ?? true,
      endMonotonicMicroseconds.map({ $0 >= startMonotonicMicroseconds }) ?? true,
      lastSourceSequence.map({ $0 >= firstSourceSequence }) ?? true
    else { throw DiscoveryEvidenceStoreError.invalidTestRunDraft }
    contract = "vhos.ios.discovery-test-run-draft"
    contractVersion = "1.0.0"
    self.id = id
    self.templateID = templateID
    self.templateVersion = templateVersion
    self.captureID = captureID
    self.gatewayID = gatewayID
    self.gatewaySessionID = gatewaySessionID
    self.startedAt = startedAt
    self.startMonotonicMicroseconds = startMonotonicMicroseconds
    self.firstSourceSequence = firstSourceSequence
    self.state = state
    self.endedAt = endedAt
    self.endMonotonicMicroseconds = endMonotonicMicroseconds
    self.lastSourceSequence = lastSourceSequence
  }

  func validate() throws {
    guard contract == "vhos.ios.discovery-test-run-draft", contractVersion == "1.0.0"
    else { throw DiscoveryEvidenceStoreError.unsupportedRecord }
    _ = try DiscoveryTestRunDraft(
      id: id, templateID: templateID, templateVersion: templateVersion,
      captureID: captureID, gatewayID: gatewayID, gatewaySessionID: gatewaySessionID,
      startedAt: startedAt, startMonotonicMicroseconds: startMonotonicMicroseconds,
      firstSourceSequence: firstSourceSequence, state: state, endedAt: endedAt,
      endMonotonicMicroseconds: endMonotonicMicroseconds,
      lastSourceSequence: lastSourceSequence)
  }
}

private struct DiscoveryDraftEvidenceExport: Codable {
  let contract: String
  let contractVersion: String
  let generatedAt: String
  let captureBindings: [DiscoveryCaptureBinding]
  let testRunSnapshots: [DiscoveryTestRunDraft]
  let markers: [StoredDiscoveryMarker]
  let authority: DiscoveryAuthorityStatus
}

final class DiscoveryEvidenceStore {
  private let fileManager: FileManager
  private let bindingsURL: URL
  private let markersURL: URL
  private let testRunsURL: URL
  private let maximumBindings = 10_000
  private let maximumMarkers = 100_000

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    let support =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    let directory = support.appendingPathComponent("VHOSDiscoveryEvidence/v1", isDirectory: true)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    bindingsURL = directory.appendingPathComponent("capture-bindings.ndjson")
    markersURL = directory.appendingPathComponent("event-markers.ndjson")
    testRunsURL = directory.appendingPathComponent("test-run-drafts.ndjson")
  }

  func markers() throws -> [StoredDiscoveryMarker] {
    try decodeLedger(at: markersURL, as: StoredDiscoveryMarker.self) { try $0.validate() }
  }

  func testRuns() throws -> [DiscoveryTestRunDraft] {
    let snapshots = try testRunSnapshots()
    var latest: [String: DiscoveryTestRunDraft] = [:]
    for snapshot in snapshots { latest[snapshot.id] = snapshot }
    return latest.values.sorted { $0.startedAt < $1.startedAt }
  }

  func exportURL(generatedAt: String) throws -> URL {
    let export = DiscoveryDraftEvidenceExport(
      contract: "vhos.ios.discovery-draft-evidence-export",
      contractVersion: "1.0.0",
      generatedAt: generatedAt,
      captureBindings: try captureBindings(),
      testRunSnapshots: try testRunSnapshots(),
      markers: try markers(),
      authority: .observed)
    guard !export.testRunSnapshots.isEmpty || !export.markers.isEmpty else {
      throw DiscoveryEvidenceStoreError.noDiscoveryEvidence
    }
    let directory = fileManager.temporaryDirectory.appendingPathComponent(
      "VehicleHealthOS-Discovery", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("discovery-test-run-drafts-and-markers.json")
    try VHOSJSON.encoder().encode(export).write(to: url, options: [.atomic])
    return url
  }

  func beginTestRun(
    template: TestTemplate,
    observation: PassiveCANObservation,
    recordedAt: String
  ) throws -> DiscoveryTestRunDraft {
    try template.validateContract()
    try PassiveCANEvidenceArchive.validate(observation)
    guard try !testRuns().contains(where: { $0.state == .active }) else {
      throw DiscoveryEvidenceStoreError.testRunAlreadyActive
    }
    let binding = try captureBinding(for: observation, recordedAt: recordedAt)
    let draft = try DiscoveryTestRunDraft(
      id: DiscoveryIDGenerator.make(prefix: "run"),
      templateID: template.id,
      templateVersion: template.templateVersion,
      captureID: binding.id,
      gatewayID: observation.gatewayID,
      gatewaySessionID: observation.sessionID,
      startedAt: recordedAt,
      startMonotonicMicroseconds: observation.monotonicMicroseconds,
      firstSourceSequence: observation.sourceSequence,
      state: .active)
    try appendLine(draft, to: testRunsURL)
    return draft
  }

  func transitionTestRun(
    _ run: DiscoveryTestRunDraft,
    to state: DiscoveryTestRunDraftState,
    observation: PassiveCANObservation?,
    recordedAt: String
  ) throws -> DiscoveryTestRunDraft {
    guard run.state == .active, state != .active else {
      throw DiscoveryEvidenceStoreError.invalidTestRunTransition
    }
    if state == .ended {
      guard let observation,
        observation.gatewayID == run.gatewayID,
        observation.sessionID == run.gatewaySessionID
      else { throw DiscoveryEvidenceStoreError.testRunCaptureChanged }
    }
    if let observation,
      observation.gatewayID != run.gatewayID || observation.sessionID != run.gatewaySessionID
    {
      throw DiscoveryEvidenceStoreError.testRunCaptureChanged
    }
    let updated = try DiscoveryTestRunDraft(
      id: run.id,
      templateID: run.templateID,
      templateVersion: run.templateVersion,
      captureID: run.captureID,
      gatewayID: run.gatewayID,
      gatewaySessionID: run.gatewaySessionID,
      startedAt: run.startedAt,
      startMonotonicMicroseconds: run.startMonotonicMicroseconds,
      firstSourceSequence: run.firstSourceSequence,
      state: state,
      endedAt: recordedAt,
      endMonotonicMicroseconds: observation?.monotonicMicroseconds,
      lastSourceSequence: observation?.sourceSequence)
    try appendLine(updated, to: testRunsURL)
    return updated
  }

  @discardableResult
  func append(
    template: TestTemplate,
    testRun: DiscoveryTestRunDraft,
    kind: DiscoveryMarkerKind,
    label: String,
    observation: PassiveCANObservation,
    recordedAt: String
  ) throws -> StoredDiscoveryMarker {
    try template.validateContract()
    try PassiveCANEvidenceArchive.validate(observation)
    guard testRun.state == .active, testRun.templateID == template.id,
      testRun.gatewayID == observation.gatewayID,
      testRun.gatewaySessionID == observation.sessionID
    else { throw DiscoveryEvidenceStoreError.testRunCaptureChanged }
    let binding = try captureBinding(for: observation, recordedAt: recordedAt)
    guard binding.id == testRun.captureID else {
      throw DiscoveryEvidenceStoreError.testRunCaptureChanged
    }

    let existingMarkers = try markers()
    guard existingMarkers.count < maximumMarkers else {
      throw DiscoveryEvidenceStoreError.markerCapacityReached
    }
    let marker = try EventMarker(
      id: DiscoveryIDGenerator.make(prefix: "marker"),
      captureID: binding.id,
      gatewayMonotonicMicroseconds: observation.monotonicMicroseconds,
      recordedAt: recordedAt,
      kind: kind,
      label: label,
      source: .iPhone,
      nearestCANSequence: observation.sourceSequence,
      note:
        "Test template \(template.id) v\(template.templateVersion); gateway recorder session \(observation.sessionID)."
    )
    let stored = try StoredDiscoveryMarker(
      templateID: template.id,
      testRunID: testRun.id,
      gatewayID: observation.gatewayID,
      gatewaySessionID: observation.sessionID,
      marker: marker)
    try appendLine(stored, to: markersURL)
    return stored
  }

  private func captureBindings() throws -> [DiscoveryCaptureBinding] {
    try decodeLedger(at: bindingsURL, as: DiscoveryCaptureBinding.self) { try $0.validate() }
  }

  private func testRunSnapshots() throws -> [DiscoveryTestRunDraft] {
    try decodeLedger(at: testRunsURL, as: DiscoveryTestRunDraft.self) { try $0.validate() }
  }

  private func captureBinding(
    for observation: PassiveCANObservation,
    recordedAt: String
  ) throws -> DiscoveryCaptureBinding {
    let bindings = try captureBindings()
    if let existing = bindings.first(where: {
      $0.gatewayID == observation.gatewayID && $0.gatewaySessionID == observation.sessionID
    }) {
      return existing
    }
    guard bindings.count < maximumBindings else {
      throw DiscoveryEvidenceStoreError.bindingCapacityReached
    }
    let binding = try DiscoveryCaptureBinding(
      id: DiscoveryIDGenerator.make(prefix: "capture"),
      gatewayID: observation.gatewayID,
      gatewaySessionID: observation.sessionID,
      createdAt: recordedAt)
    try appendLine(binding, to: bindingsURL)
    return binding
  }

  private func decodeLedger<Record: Decodable>(
    at url: URL,
    as type: Record.Type,
    validate: (Record) throws -> Void
  ) throws -> [Record] {
    guard fileManager.fileExists(atPath: url.path) else { return [] }
    return try Data(contentsOf: url, options: [.mappedIfSafe]).split(separator: 0x0A)
      .enumerated().map { index, line in
        do {
          let record = try VHOSJSON.decoder().decode(type, from: Data(line))
          try validate(record)
          return record
        } catch {
          throw DiscoveryEvidenceStoreError.invalidLedgerRecord(url.lastPathComponent, index + 1)
        }
      }
  }

  private func appendLine<Record: Encodable>(_ record: Record, to url: URL) throws {
    var bytes = try VHOSJSON.encoder().encode(record)
    bytes.append(0x0A)
    if !fileManager.fileExists(atPath: url.path) {
      try bytes.write(to: url, options: [.atomic])
      return
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: bytes)
    try handle.synchronize()
  }
}

enum DiscoveryEvidenceStoreError: Error, LocalizedError {
  case unsupportedRecord
  case invalidCaptureBinding
  case invalidMarkerRecord
  case invalidTestRunDraft
  case invalidLedgerRecord(String, Int)
  case bindingCapacityReached
  case markerCapacityReached
  case testRunAlreadyActive
  case invalidTestRunTransition
  case testRunCaptureChanged
  case noDiscoveryEvidence

  var errorDescription: String? {
    switch self {
    case .unsupportedRecord:
      "The Discovery evidence ledger contains an unsupported contract version."
    case .invalidCaptureBinding:
      "The gateway recorder session could not be bound to a durable Discovery capture."
    case .invalidMarkerRecord:
      "The Discovery marker index metadata is invalid."
    case .invalidTestRunDraft:
      "The local Discovery test-run draft is invalid."
    case .invalidLedgerRecord(let file, let line):
      "The append-only Discovery ledger \(file) is invalid at line \(line)."
    case .bindingCapacityReached:
      "The bounded Discovery capture-binding ledger is full. Export the evidence before continuing."
    case .markerCapacityReached:
      "The bounded Discovery marker ledger is full. Export the evidence before continuing."
    case .testRunAlreadyActive:
      "End or abort the active Discovery test run before starting another."
    case .invalidTestRunTransition:
      "The Discovery test-run lifecycle transition is invalid."
    case .testRunCaptureChanged:
      "The gateway capture session changed during this test run. Abort it and begin a new run."
    case .noDiscoveryEvidence:
      "Begin a Discovery test run or record a synchronized marker before exporting draft evidence."
    }
  }
}

private enum DiscoveryEvidenceStoreValidation {
  static func isDomainID(_ value: String, prefix: String) -> Bool {
    value.range(
      of: "^\(NSRegularExpression.escapedPattern(for: prefix))_[0-9A-HJKMNP-TV-Z]{26}$",
      options: .regularExpression) != nil
  }
}
