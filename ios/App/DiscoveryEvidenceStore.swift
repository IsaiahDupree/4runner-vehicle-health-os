import CryptoKit
import Foundation
import VHOSCore

/// Append-only binding between the gateway's numeric recorder session and the durable Discovery
/// capture identifier used by the shared domain contracts.
struct DiscoveryCaptureBinding: Codable, Equatable, Identifiable, Sendable {
  let contract: String
  let contractVersion: String
  let id: String
  let gatewayID: String
  let gatewaySessionID: UInt32
  let createdAt: String

  // VHOSJSON converts wire keys from snake_case to lower camel case before CodingKeys lookup.
  // Spell acronym-bearing names with `Id` so records emitted as `gateway_id` and
  // `gateway_session_id` decode back into the Swift `ID` properties without changing bytes.
  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion, id, createdAt
    case gatewayID = "gatewayId"
    case gatewaySessionID = "gatewaySessionId"
  }

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
struct StoredDiscoveryMarker: Codable, Equatable, Identifiable, Sendable {
  let contract: String
  let contractVersion: String
  let templateID: String
  let testRunID: String?
  let gatewayID: String
  let gatewaySessionID: UInt32
  /// The record's original session value when it does not fit the current
  /// 32-bit gateway session contract (records written by builds predating
  /// the type, including the wrapped 2^64-range value from the 2026-08-24
  /// incident). Preserved verbatim for canonical-byte fidelity and shown
  /// as quarantined; `gatewaySessionID` is 0 for these records, which the
  /// binding policy treats as implausible — they can never win selection,
  /// bind a new marker, or feed correlation. The append-only ledger keeps
  /// them; the app just stops believing them.
  let legacyOutOfRangeSessionValue: UInt64?
  let marker: EventMarker

  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion, marker
    case templateID = "templateId"
    case testRunID = "testRunId"
    case gatewayID = "gatewayId"
    case gatewaySessionID = "gatewaySessionId"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    contract = try container.decode(String.self, forKey: .contract)
    contractVersion = try container.decode(String.self, forKey: .contractVersion)
    templateID = try container.decode(String.self, forKey: .templateID)
    testRunID = try container.decodeIfPresent(String.self, forKey: .testRunID)
    gatewayID = try container.decode(String.self, forKey: .gatewayID)
    marker = try container.decode(EventMarker.self, forKey: .marker)
    let rawSession = try container.decode(UInt64.self, forKey: .gatewaySessionID)
    if let session = UInt32(exactly: rawSession),
      DiscoveryBindingPolicy.sessionValueIsPlausible(session)
    {
      gatewaySessionID = session
      legacyOutOfRangeSessionValue = nil
    } else {
      gatewaySessionID = 0
      legacyOutOfRangeSessionValue = rawSession
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(contract, forKey: .contract)
    try container.encode(contractVersion, forKey: .contractVersion)
    try container.encode(templateID, forKey: .templateID)
    try container.encodeIfPresent(testRunID, forKey: .testRunID)
    try container.encode(gatewayID, forKey: .gatewayID)
    // Round-trip the original bytes: a quarantined record re-encodes its
    // raw historical value, never a repaired one.
    if let legacyOutOfRangeSessionValue {
      try container.encode(legacyOutOfRangeSessionValue, forKey: .gatewaySessionID)
    } else {
      try container.encode(gatewaySessionID, forKey: .gatewaySessionID)
    }
    try container.encode(marker, forKey: .marker)
  }

  var id: String { marker.id }
  var label: String { marker.label }
  var captureSessionID: UInt32 { gatewaySessionID }
  var sourceSequence: UInt64 { marker.nearestCANSequence ?? 0 }
  var hasPlausibleSession: Bool {
    legacyOutOfRangeSessionValue == nil
      && DiscoveryBindingPolicy.sessionValueIsPlausible(gatewaySessionID)
  }

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
    self.legacyOutOfRangeSessionValue = nil
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
struct DiscoveryTestRunDraft: Codable, Equatable, Identifiable, Sendable {
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
  /// Immutable acquisition scope selected when this run began. `nil` is reserved for legacy
  /// records written before scope binding existed and always fails closed for gateway commands.
  let acquisitionAuthority: DiscoveryMutationAuthority?
  /// Required only for app-local evidence acquisition; copied into every later snapshot.
  let ownerSafetyAcknowledgedAt: String?
  let state: DiscoveryTestRunDraftState
  let endedAt: String?
  let endMonotonicMicroseconds: UInt64?
  let lastSourceSequence: UInt64?

  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion, id, templateVersion, startedAt
    case startMonotonicMicroseconds, firstSourceSequence, acquisitionAuthority
    case ownerSafetyAcknowledgedAt, state, endedAt
    case endMonotonicMicroseconds, lastSourceSequence
    case templateID = "templateId"
    case captureID = "captureId"
    case gatewayID = "gatewayId"
    case gatewaySessionID = "gatewaySessionId"
  }

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
    acquisitionAuthority: DiscoveryMutationAuthority? = nil,
    ownerSafetyAcknowledgedAt: String? = nil,
    state: DiscoveryTestRunDraftState,
    endedAt: String? = nil,
    endMonotonicMicroseconds: UInt64? = nil,
    lastSourceSequence: UInt64? = nil
  ) throws {
    let hasGatewayEnd = endMonotonicMicroseconds != nil && lastSourceSequence != nil
    let hasPartialGatewayEnd = (endMonotonicMicroseconds == nil) != (lastSourceSequence == nil)
    let requiresOwnerSafetyAcknowledgement =
      acquisitionAuthority?.requiresOwnerSafetyAcknowledgement == true
    let localEvidenceAcknowledgementIsValid =
      DiscoveryMutationPolicy.ownerSafetyAcknowledgementIsValid(
        ownerSafetyAcknowledgedAt,
        runStartedAt: startedAt,
        required: requiresOwnerSafetyAcknowledgement)
      && (!requiresOwnerSafetyAcknowledgement
        || templateID == DiscoveryMutationPolicy.parkSelectorBootstrapTemplateID)
    guard DiscoveryEvidenceStoreValidation.isDomainID(id, prefix: "run"),
      DiscoveryEvidenceStoreValidation.isDomainID(captureID, prefix: "capture"),
      !templateID.isEmpty, templateID.count <= 160,
      !templateVersion.isEmpty, templateVersion.count <= 80,
      !gatewayID.isEmpty, gatewayID.count <= 160,
      localEvidenceAcknowledgementIsValid,
      AppendOnlyEvidenceReplay.hasValidWallClockInterval(
        startedAt: startedAt, endedAt: endedAt),
      !hasPartialGatewayEnd,
      (state == .active && endedAt == nil && !hasGatewayEnd)
        || (state == .ended && endedAt != nil && hasGatewayEnd)
        || (state == .aborted && endedAt != nil),
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
    self.acquisitionAuthority = acquisitionAuthority
    self.ownerSafetyAcknowledgedAt = ownerSafetyAcknowledgedAt
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
      firstSourceSequence: firstSourceSequence,
      acquisitionAuthority: acquisitionAuthority,
      ownerSafetyAcknowledgedAt: ownerSafetyAcknowledgedAt,
      state: state, endedAt: endedAt,
      endMonotonicMicroseconds: endMonotonicMicroseconds,
      lastSourceSequence: lastSourceSequence)
  }
}

private enum DiscoveryEvidenceSegmentKind: String, Codable {
  case captureBindings = "CAPTURE_BINDINGS"
  case testRunSnapshots = "TEST_RUN_SNAPSHOTS"
  case markers = "MARKERS"
}

private struct DiscoveryEvidenceSegment: Codable {
  let kind: DiscoveryEvidenceSegmentKind
  let ordinal: Int
  let totalSegments: Int
  let recordOffset: Int
  let recordCount: Int
  let totalRecordCount: Int
  let sourceSHA256: String
}

private struct DiscoveryDraftEvidenceExport: Codable {
  let contract: String
  let contractVersion: String
  let generatedAt: String
  let segment: DiscoveryEvidenceSegment
  let captureBindings: [DiscoveryCaptureBinding]
  let testRunSnapshots: [DiscoveryTestRunDraft]
  let markers: [StoredDiscoveryMarker]
  let authority: DiscoveryAuthorityStatus
}

private struct DiscoveryGatewaySessionIdentity: Hashable {
  let gatewayID: String
  let gatewaySessionID: UInt32

  var evidenceDescription: String { "\(gatewayID):\(gatewaySessionID)" }
}

final class DiscoveryEvidenceStore {
  private let fileManager: FileManager
  private let bindingsURL: URL
  private let markersURL: URL
  private let testRunsURL: URL
  private let quarantineDirectoryURL: URL
  private let maximumBindings = 10_000
  private let maximumMarkers = 100_000
  private let maximumTestRunSnapshots = 20_000
  private let exportSegmentRecordCount = 500
  private(set) var recoveryReports: [AppendOnlyNDJSONTailRecovery] = []

  init(fileManager: FileManager = .default, storageDirectory: URL? = nil) {
    self.fileManager = fileManager
    let support =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    let directory =
      storageDirectory
      ?? support.appendingPathComponent("VHOSDiscoveryEvidence/v1", isDirectory: true)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    bindingsURL = directory.appendingPathComponent("capture-bindings.ndjson")
    markersURL = directory.appendingPathComponent("event-markers.ndjson")
    testRunsURL = directory.appendingPathComponent("test-run-drafts.ndjson")
    quarantineDirectoryURL = directory.appendingPathComponent("Quarantine", isDirectory: true)
  }

  func markers() throws -> [StoredDiscoveryMarker] {
    let records = try decodeLedger(at: markersURL, as: StoredDiscoveryMarker.self) {
      try $0.validate()
    }
    guard records.count <= maximumMarkers else {
      throw DiscoveryEvidenceStoreError.ledgerCapacityExceeded(markersURL.lastPathComponent)
    }
    try AppendOnlyEvidenceReplay.requireUniqueIdentity(
      in: records,
      recordKind: "Discovery marker",
      identity: \.id,
      describeIdentity: { $0 })

    let bindings = try captureBindings()
    let runs = try testRuns()
    for record in records {
      let sessionIdentity = DiscoveryGatewaySessionIdentity(
        gatewayID: record.gatewayID,
        gatewaySessionID: record.gatewaySessionID)
      guard
        bindings.contains(where: {
          $0.id == record.marker.captureID
            && DiscoveryGatewaySessionIdentity(
              gatewayID: $0.gatewayID,
              gatewaySessionID: $0.gatewaySessionID) == sessionIdentity
        }),
        record.marker.gatewaySessionID.map({ $0 == record.gatewaySessionID }) ?? true
      else {
        throw DiscoveryEvidenceStoreError.markerLineageMismatch(record.id)
      }

      if let testRunID = record.testRunID {
        guard let run = runs.first(where: { $0.id == testRunID }),
          run.templateID == record.templateID,
          run.captureID == record.marker.captureID,
          run.gatewayID == record.gatewayID,
          run.gatewaySessionID == record.gatewaySessionID
        else {
          throw DiscoveryEvidenceStoreError.markerLineageMismatch(record.id)
        }
        _ = try AppendOnlyEvidenceReplay.requireEvidenceWithinLifecycleBounds(
          recordKind: "Discovery marker",
          identity: record.id,
          evidenceRecordedAt: record.marker.recordedAt,
          evidenceMonotonicMicroseconds: record.marker.gatewayMonotonicMicroseconds,
          evidenceSourceSequence: record.marker.nearestCANSequence,
          startedAt: run.startedAt,
          startMonotonicMicroseconds: run.startMonotonicMicroseconds,
          firstSourceSequence: run.firstSourceSequence,
          endedAt: run.endedAt,
          endMonotonicMicroseconds: run.endMonotonicMicroseconds,
          lastSourceSequence: run.lastSourceSequence)
      }
    }
    return records
  }

  func testRuns() throws -> [DiscoveryTestRunDraft] {
    let snapshots = try testRunSnapshots()
    return try replayTestRuns(snapshots).sorted { $0.startedAt < $1.startedAt }
  }

  /// Materializes at most one bounded page of immutable Discovery artifacts.
  ///
  /// Each append-only ledger is partitioned by a fixed record cursor. Marker and test-run pages
  /// carry the capture/run lineage they reference, while `segment.source_sha256` binds the exact
  /// canonical primary records. Artifact identity is the final payload digest, so an unchanged
  /// segment deduplicates across automation cycles and a later active-run transition becomes a new
  /// immutable revision rather than overwriting queued evidence.
  func prepareExportPage(
    excludingArtifactIdentities: Set<String>,
    maximumArtifacts: Int,
    outputDirectory: URL
  ) throws -> PreparedDiscoveryEvidencePage {
    guard (1...32).contains(maximumArtifacts) else {
      throw DiscoveryEvidenceStoreError.invalidExportPageLimit
    }
    let bindings = try captureBindings()
    let runSnapshots = try testRunSnapshots()
    let markerRecords = try markers()
    guard !bindings.isEmpty || !runSnapshots.isEmpty || !markerRecords.isEmpty else {
      throw DiscoveryEvidenceStoreError.noDiscoveryEvidence
    }
    try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    var artifacts: [PreparedDiscoveryEvidenceArtifact] = []
    var hasMore = false

    func consider(_ export: DiscoveryDraftEvidenceExport) throws {
      guard !hasMore else { return }
      let payload = try VHOSJSON.encoder().encode(export)
      let maximumBytes = EvidenceOutboxPayloadFileValidator.maximumBytes(
        for: "application/vnd.vhos.discovery-draft-evidence+json")
      guard !payload.isEmpty, payload.count <= maximumBytes else {
        throw DiscoveryEvidenceStoreError.exportSegmentTooLarge(
          export.segment.kind.rawValue,
          export.segment.ordinal)
      }
      let digest = Self.sha256(payload)
      let identity =
        "discovery-draft:\(export.segment.kind.rawValue.lowercased()):"
        + "\(export.segment.ordinal):\(digest)"
      guard !excludingArtifactIdentities.contains(identity) else { return }
      guard artifacts.count < maximumArtifacts else {
        hasMore = true
        return
      }
      let url = outputDirectory.appendingPathComponent("\(digest).discovery-evidence.json")
      if fileManager.fileExists(atPath: url.path) {
        guard try Data(contentsOf: url, options: [.mappedIfSafe]) == payload else {
          throw DiscoveryEvidenceStoreError.exportArtifactConflict(url.lastPathComponent)
        }
      } else {
        try payload.write(to: url, options: [.atomic])
      }
      artifacts.append(
        PreparedDiscoveryEvidenceArtifact(
          identity: identity,
          url: url,
          byteCount: payload.count,
          sha256: digest))
    }

    let bindingSegmentCount = Self.segmentCount(
      recordCount: bindings.count,
      pageSize: exportSegmentRecordCount)
    for offset in stride(from: 0, to: bindings.count, by: exportSegmentRecordCount) {
      let page = Array(bindings[offset..<min(bindings.count, offset + exportSegmentRecordCount)])
      try consider(
        DiscoveryDraftEvidenceExport(
          contract: "vhos.ios.discovery-draft-evidence-segment",
          contractVersion: "1.0.0",
          generatedAt: page.map(\.createdAt).max()!,
          segment: try makeSegment(
            kind: .captureBindings,
            ordinal: offset / exportSegmentRecordCount,
            totalSegments: bindingSegmentCount,
            offset: offset,
            totalRecordCount: bindings.count,
            primaryRecords: page),
          captureBindings: page,
          testRunSnapshots: [],
          markers: [],
          authority: .observed))
      if hasMore { break }
    }

    if !hasMore {
      let runSegmentCount = Self.segmentCount(
        recordCount: runSnapshots.count,
        pageSize: exportSegmentRecordCount)
      for offset in stride(from: 0, to: runSnapshots.count, by: exportSegmentRecordCount) {
        let page = Array(
          runSnapshots[offset..<min(runSnapshots.count, offset + exportSegmentRecordCount)])
        let captureIDs = Set(page.map(\.captureID))
        let lineageBindings = bindings.filter { captureIDs.contains($0.id) }
        try consider(
          DiscoveryDraftEvidenceExport(
            contract: "vhos.ios.discovery-draft-evidence-segment",
            contractVersion: "1.0.0",
            generatedAt: page.map { $0.endedAt ?? $0.startedAt }.max()!,
            segment: try makeSegment(
              kind: .testRunSnapshots,
              ordinal: offset / exportSegmentRecordCount,
              totalSegments: runSegmentCount,
              offset: offset,
              totalRecordCount: runSnapshots.count,
              primaryRecords: page),
            captureBindings: lineageBindings,
            testRunSnapshots: page,
            markers: [],
            authority: .observed))
        if hasMore { break }
      }
    }

    if !hasMore {
      let markerSegmentCount = Self.segmentCount(
        recordCount: markerRecords.count,
        pageSize: exportSegmentRecordCount)
      for offset in stride(from: 0, to: markerRecords.count, by: exportSegmentRecordCount) {
        let page = Array(
          markerRecords[offset..<min(markerRecords.count, offset + exportSegmentRecordCount)])
        let runIDs = Set(page.compactMap(\.testRunID))
        let lineageRuns = runSnapshots.filter { runIDs.contains($0.id) }
        let captureIDs = Set(page.map { $0.marker.captureID })
        let lineageBindings = bindings.filter { captureIDs.contains($0.id) }
        try consider(
          DiscoveryDraftEvidenceExport(
            contract: "vhos.ios.discovery-draft-evidence-segment",
            contractVersion: "1.0.0",
            generatedAt: page.map { $0.marker.recordedAt }.max()!,
            segment: try makeSegment(
              kind: .markers,
              ordinal: offset / exportSegmentRecordCount,
              totalSegments: markerSegmentCount,
              offset: offset,
              totalRecordCount: markerRecords.count,
              primaryRecords: page),
            captureBindings: lineageBindings,
            testRunSnapshots: lineageRuns,
            markers: page,
            authority: .observed))
        if hasMore { break }
      }
    }

    return PreparedDiscoveryEvidencePage(artifacts: artifacts, hasMore: hasMore)
  }

  private func makeSegment<Record: Encodable>(
    kind: DiscoveryEvidenceSegmentKind,
    ordinal: Int,
    totalSegments: Int,
    offset: Int,
    totalRecordCount: Int,
    primaryRecords: [Record]
  ) throws -> DiscoveryEvidenceSegment {
    var canonicalSource = Data()
    for record in primaryRecords {
      canonicalSource.append(try VHOSJSON.encoder().encode(record))
      canonicalSource.append(0x0A)
    }
    return DiscoveryEvidenceSegment(
      kind: kind,
      ordinal: ordinal,
      totalSegments: totalSegments,
      recordOffset: offset,
      recordCount: primaryRecords.count,
      totalRecordCount: totalRecordCount,
      sourceSHA256: Self.sha256(canonicalSource))
  }

  private static func segmentCount(recordCount: Int, pageSize: Int) -> Int {
    guard recordCount > 0 else { return 0 }
    return (recordCount + pageSize - 1) / pageSize
  }

  private static func sha256(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  func beginTestRun(
    template: TestTemplate,
    observation: PassiveCANObservation,
    recordedAt: String,
    acquisitionAuthority: DiscoveryMutationAuthority,
    ownerSafetyAcknowledgedAt: String? = nil
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
      acquisitionAuthority: acquisitionAuthority,
      ownerSafetyAcknowledgedAt: ownerSafetyAcknowledgedAt,
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
    guard let current = try testRuns().first(where: { $0.id == run.id }), current == run,
      current.state == .active, state != .active
    else {
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
      acquisitionAuthority: run.acquisitionAuthority,
      ownerSafetyAcknowledgedAt: run.ownerSafetyAcknowledgedAt,
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
    guard let current = try testRuns().first(where: { $0.id == testRun.id }), current == testRun,
      current.state == .active,
      DiscoveryMutationPolicy.testRunIdentityMatches(
        template: template,
        templateID: testRun.templateID,
        templateVersion: testRun.templateVersion),
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
    if testRun.templateID == DiscoveryMutationPolicy.parkSelectorBootstrapTemplateID {
      let runMarkers = existingMarkers.filter { $0.testRunID == testRun.id }
      let recorded = runMarkers.map {
        DiscoveryOrderedMarkerRequirement(kind: $0.marker.kind, label: $0.label)
      }
      guard
        DiscoveryMutationPolicy.nextParkSelectorBootstrapMarker(after: recorded)
          == DiscoveryOrderedMarkerRequirement(kind: kind, label: label)
      else { throw DiscoveryEvidenceStoreError.markerSequenceRequired }
      if let last = runMarkers.last {
        let remaining =
          DiscoveryMutationPolicy.parkSelectorBootstrapDwellRemainingMicroseconds(
            after: DiscoveryOrderedMarkerRequirement(
              kind: last.marker.kind, label: last.label),
            lastMarkerMonotonicMicroseconds: last.marker.gatewayMonotonicMicroseconds,
            currentMonotonicMicroseconds: observation.monotonicMicroseconds)
        guard remaining == 0 else {
          throw DiscoveryEvidenceStoreError.markerDwellRequired
        }
      }
    }
    let marker = try EventMarker(
      id: DiscoveryIDGenerator.make(prefix: "marker"),
      captureID: binding.id,
      gatewaySessionID: observation.sessionID,
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
    let records = try decodeLedger(at: bindingsURL, as: DiscoveryCaptureBinding.self) {
      try $0.validate()
    }
    guard records.count <= maximumBindings else {
      throw DiscoveryEvidenceStoreError.ledgerCapacityExceeded(bindingsURL.lastPathComponent)
    }
    try AppendOnlyEvidenceReplay.requireBijection(
      in: records,
      leftKind: "Discovery capture binding",
      rightKind: "Discovery gateway-session binding",
      left: \.id,
      right: {
        DiscoveryGatewaySessionIdentity(
          gatewayID: $0.gatewayID,
          gatewaySessionID: $0.gatewaySessionID)
      },
      describeLeft: { $0 },
      describeRight: \.evidenceDescription)
    return records
  }

  private func testRunSnapshots() throws -> [DiscoveryTestRunDraft] {
    let records = try decodeLedger(at: testRunsURL, as: DiscoveryTestRunDraft.self) {
      try $0.validate()
    }
    guard records.count <= maximumTestRunSnapshots else {
      throw DiscoveryEvidenceStoreError.ledgerCapacityExceeded(testRunsURL.lastPathComponent)
    }
    _ = try replayTestRuns(records)

    let bindings = try captureBindings()
    for record in records {
      guard
        bindings.contains(where: {
          $0.id == record.captureID && $0.gatewayID == record.gatewayID
            && $0.gatewaySessionID == record.gatewaySessionID
        })
      else {
        throw DiscoveryEvidenceStoreError.testRunLineageMismatch(record.id)
      }
    }
    return records
  }

  private func replayTestRuns(
    _ records: [DiscoveryTestRunDraft]
  ) throws -> [DiscoveryTestRunDraft] {
    let identity: (DiscoveryTestRunDraft) -> String = { $0.id }
    let state: (DiscoveryTestRunDraft) -> DiscoveryTestRunDraftState = { $0.state }
    let sameLineage: (DiscoveryTestRunDraft, DiscoveryTestRunDraft) -> Bool = {
      $0.id == $1.id && $0.templateID == $1.templateID
        && $0.templateVersion == $1.templateVersion && $0.captureID == $1.captureID
        && $0.gatewayID == $1.gatewayID && $0.gatewaySessionID == $1.gatewaySessionID
        && $0.startedAt == $1.startedAt
        && $0.startMonotonicMicroseconds == $1.startMonotonicMicroseconds
        && $0.firstSourceSequence == $1.firstSourceSequence
        && $0.acquisitionAuthority == $1.acquisitionAuthority
        && $0.ownerSafetyAcknowledgedAt == $1.ownerSafetyAcknowledgedAt
    }
    let transition: (DiscoveryTestRunDraftState, DiscoveryTestRunDraftState) -> Bool = {
      $0 == .active && ($1 == .ended || $1 == .aborted)
    }
    return try AppendOnlyEvidenceReplay.reduceLifecycle(
      records,
      recordKind: "Discovery test run",
      identity: identity,
      describeIdentity: { $0 },
      state: state,
      describeState: { $0.rawValue },
      isInitial: { $0 == .active },
      isTerminal: { $0 != .active },
      hasSameImmutableLineage: sameLineage,
      canTransition: transition)
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

  private func decodeLedger<Record: Codable>(
    at url: URL,
    as type: Record.Type,
    validate: (Record) throws -> Void
  ) throws -> [Record] {
    do {
      let result = try AppendOnlyNDJSONLedger.load(
        from: url,
        quarantineDirectory: quarantineDirectoryURL,
        fileManager: fileManager,
        decoder: VHOSJSON.decoder(),
        validate: validate)
      if let recovery = result.recovery {
        recoveryReports.append(recovery)
      }
      return result.records
    } catch AppendOnlyNDJSONLedgerError.invalidCommittedRecord(_, let line) {
      throw DiscoveryEvidenceStoreError.invalidLedgerRecord(url.lastPathComponent, line)
    }
  }

  private func appendLine<Record: Encodable>(_ record: Record, to url: URL) throws {
    try DurableEvidenceFile.appendCommittedLine(
      try VHOSJSON.encoder().encode(record),
      to: url,
      fileManager: fileManager)
  }
}

struct DiscoveryEvidenceSnapshot: Sendable {
  let testRuns: [DiscoveryTestRunDraft]
  let markers: [StoredDiscoveryMarker]
  let recoveryReports: [AppendOnlyNDJSONTailRecovery]
}

struct PreparedDiscoveryEvidenceArtifact: Sendable {
  let identity: String
  let url: URL
  let byteCount: Int
  let sha256: String
}

struct PreparedDiscoveryEvidencePage: Sendable {
  let artifacts: [PreparedDiscoveryEvidenceArtifact]
  let hasMore: Bool
}

/// Exclusive serial owner of the Discovery append-only ledgers.
///
/// Test-run replay can scan up to 100,000 canonical markers. Keeping that work behind this actor
/// prevents a large historical ledger or interrupted-tail recovery from starving CoreBluetooth's
/// main-queue callbacks.
actor DiscoveryEvidencePersistenceWorker {
  private let store: DiscoveryEvidenceStore

  init(
    fileManager: FileManager = .default,
    storageDirectory: URL? = nil
  ) {
    store = DiscoveryEvidenceStore(
      fileManager: fileManager,
      storageDirectory: storageDirectory)
  }

  func snapshot() throws -> DiscoveryEvidenceSnapshot {
    DiscoveryEvidenceSnapshot(
      testRuns: try store.testRuns(),
      markers: try store.markers(),
      recoveryReports: store.recoveryReports)
  }

  func testRuns() throws -> [DiscoveryTestRunDraft] { try store.testRuns() }

  func markers() throws -> [StoredDiscoveryMarker] { try store.markers() }

  func recoveryReports() -> [AppendOnlyNDJSONTailRecovery] { store.recoveryReports }

  func beginTestRun(
    template: TestTemplate,
    observation: PassiveCANObservation,
    recordedAt: String,
    acquisitionAuthority: DiscoveryMutationAuthority,
    ownerSafetyAcknowledgedAt: String? = nil
  ) throws -> DiscoveryTestRunDraft {
    try store.beginTestRun(
      template: template,
      observation: observation,
      recordedAt: recordedAt,
      acquisitionAuthority: acquisitionAuthority,
      ownerSafetyAcknowledgedAt: ownerSafetyAcknowledgedAt)
  }

  func transitionTestRun(
    _ run: DiscoveryTestRunDraft,
    to state: DiscoveryTestRunDraftState,
    observation: PassiveCANObservation?,
    recordedAt: String
  ) throws -> DiscoveryTestRunDraft {
    try store.transitionTestRun(
      run,
      to: state,
      observation: observation,
      recordedAt: recordedAt)
  }

  func append(
    template: TestTemplate,
    testRun: DiscoveryTestRunDraft,
    kind: DiscoveryMarkerKind,
    label: String,
    observation: PassiveCANObservation,
    recordedAt: String
  ) throws -> StoredDiscoveryMarker {
    try store.append(
      template: template,
      testRun: testRun,
      kind: kind,
      label: label,
      observation: observation,
      recordedAt: recordedAt)
  }

  func prepareExportPage(
    excludingArtifactIdentities: Set<String>,
    maximumArtifacts: Int,
    outputDirectory: URL
  ) throws -> PreparedDiscoveryEvidencePage {
    try store.prepareExportPage(
      excludingArtifactIdentities: excludingArtifactIdentities,
      maximumArtifacts: maximumArtifacts,
      outputDirectory: outputDirectory)
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
  case markerSequenceRequired
  case markerDwellRequired
  case testRunAlreadyActive
  case invalidTestRunTransition
  case testRunCaptureChanged
  case markerLineageMismatch(String)
  case testRunLineageMismatch(String)
  case noDiscoveryEvidence
  case invalidExportPageLimit
  case exportSegmentTooLarge(String, Int)
  case exportArtifactConflict(String)
  case ledgerCapacityExceeded(String)

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
    case .markerSequenceRequired:
      "The Park-selector bootstrap marker is out of order or duplicates committed evidence."
    case .markerDwellRequired:
      "Hold the current selector position for the full required dwell before recording the next marker."
    case .testRunAlreadyActive:
      "End or abort the active Discovery test run before starting another."
    case .invalidTestRunTransition:
      "The Discovery test-run lifecycle transition is invalid."
    case .testRunCaptureChanged:
      "The gateway capture session changed during this test run. Abort it and begin a new run."
    case .markerLineageMismatch(let id):
      "Discovery marker \(id) does not resolve to its immutable capture, gateway session, and test-run lineage."
    case .testRunLineageMismatch(let id):
      "Discovery test run \(id) does not resolve to its immutable capture and gateway-session binding."
    case .noDiscoveryEvidence:
      "Begin a Discovery test run or record a synchronized marker before exporting draft evidence."
    case .invalidExportPageLimit:
      "Discovery evidence export must request between 1 and 32 bounded artifacts."
    case .exportSegmentTooLarge(let kind, let ordinal):
      "Discovery evidence segment \(kind) #\(ordinal) exceeds the private outbox limit."
    case .exportArtifactConflict(let file):
      "Discovery evidence artifact \(file) conflicts with an existing immutable export."
    case .ledgerCapacityExceeded(let file):
      "The bounded append-only Discovery ledger \(file) exceeds its published capacity."
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
