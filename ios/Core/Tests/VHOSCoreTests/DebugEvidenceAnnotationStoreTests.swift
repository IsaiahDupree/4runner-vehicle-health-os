import Foundation
import Testing

@testable import VHOSCore

private let debugAnnotationID1 = "debugannotation_01K3H000000000000000000001"
private let debugAnnotationID2 = "debugannotation_01K3H000000000000000000002"

#if DEBUG
  @Test func debugEvidenceStoreAppendsExactRealLabelAndMarkerWithoutLiveState() throws {
    let root = debugAnnotationTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DebugEvidenceAnnotationStore(storageDirectory: root)
    let samples = try debugAnnotationRealSamples()

    let label = try store.appendLabel(
      id: debugAnnotationID1,
      appendedAt: "2026-08-24T23:40:00Z",
      label: "Selector at PARK",
      note: "Developer ground-truth label",
      source: .user,
      annotatorID: "owner-local",
      observation: samples[0])
    let marker = try store.appendEventMarker(
      id: debugAnnotationID2,
      appendedAt: "2026-08-24T23:40:01Z",
      markerKind: .selectorPark,
      label: "SELECTOR: PARK",
      observation: samples[1])

    #expect(label.acquisitionAuthority == .debugUnverified)
    #expect(label.sourceObservation == samples[0])
    #expect(label.sourceObservationID == samples[0].id)
    #expect(label.sourceObservationSHA256.count == 64)
    #expect(label.annotationKind == .label)
    #expect(label.markerKind == nil)
    #expect(!label.promotionAllowed)
    #expect(marker.acquisitionAuthority == .debugUnverified)
    #expect(marker.annotationKind == .eventMarker)
    #expect(marker.markerKind == .selectorPark)
    #expect(marker.sourceObservation == samples[1])
    #expect(!marker.promotionAllowed)

    let committed = try Data(contentsOf: store.fileURL)
    #expect(committed.last == 0x0A)
    let loaded = try DebugEvidenceAnnotationStore(storageDirectory: root).load()
    #expect(loaded.recovery == nil)
    #expect(loaded.records == [label, marker])
    #expect(try Data(contentsOf: store.fileURL) == committed)
  }

  @Test func debugEvidenceStoreRejectsDuplicateAnnotationIDWithoutMutation() throws {
    let root = debugAnnotationTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DebugEvidenceAnnotationStore(storageDirectory: root)
    let samples = try debugAnnotationRealSamples()
    _ = try store.appendLabel(
      id: debugAnnotationID1,
      appendedAt: "2026-08-24T23:40:00Z",
      label: "First label",
      observation: samples[0])
    let committed = try Data(contentsOf: store.fileURL)

    #expect(
      throws: DebugEvidenceAnnotationStoreError.annotationIdentityCollision(debugAnnotationID1)
    ) {
      try store.appendEventMarker(
        id: debugAnnotationID1,
        appendedAt: "2026-08-24T23:40:01Z",
        markerKind: .brakePressed,
        label: "BRAKE PRESSED",
        observation: samples[1])
    }
    #expect(try Data(contentsOf: store.fileURL) == committed)
  }

  @Test func debugEvidenceStoreRejectsConflictingBytesForOneObservationIdentity() throws {
    let root = debugAnnotationTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DebugEvidenceAnnotationStore(storageDirectory: root)
    let source = try debugAnnotationRealSamples()[0]
    _ = try store.appendLabel(
      id: debugAnnotationID1,
      appendedAt: "2026-08-24T23:40:00Z",
      label: "Original bytes",
      observation: source)
    let committed = try Data(contentsOf: store.fileURL)
    var changedData = source.data
    changedData[0] ^= 0x01
    let conflicting = PassiveCANObservation(
      gatewayID: source.gatewayID,
      sessionID: source.sessionID,
      sourceSequence: source.sourceSequence,
      monotonicMicroseconds: source.monotonicMicroseconds,
      bitrateBps: source.bitrateBps,
      identifier: source.identifier,
      extended: source.extended,
      remoteRequest: source.remoteRequest,
      listenOnly: source.listenOnly,
      dataLength: source.dataLength,
      data: changedData,
      evidenceSource: source.evidenceSource,
      ingestedAt: source.ingestedAt)

    #expect(
      throws: DebugEvidenceAnnotationStoreError.observationIdentityCollision(source.id)
    ) {
      try store.appendLabel(
        id: debugAnnotationID2,
        appendedAt: "2026-08-24T23:40:01Z",
        label: "Conflicting bytes",
        observation: conflicting)
    }
    #expect(try Data(contentsOf: store.fileURL) == committed)
  }

  @Test func debugEvidenceStoreRejectsAnyAuthorityOtherThanDebugWithoutRewriting() throws {
    let root = debugAnnotationTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DebugEvidenceAnnotationStore(storageDirectory: root)
    _ = try store.appendLabel(
      id: debugAnnotationID1,
      appendedAt: "2026-08-24T23:40:00Z",
      label: "Ground truth",
      observation: try debugAnnotationRealSamples()[0])

    let original = try Data(contentsOf: store.fileURL)
    let originalText = try #require(String(data: original, encoding: .utf8))
    let changedText = originalText.replacingOccurrences(
      of: "DEBUG_UNVERIFIED",
      with: "PARKED")
    #expect(changedText != originalText)
    let changed = try #require(changedText.data(using: .utf8))
    try changed.write(to: store.fileURL)

    #expect(throws: DebugEvidenceAnnotationStoreError.invalidCommittedRecord(1)) {
      try store.load()
    }
    #expect(try Data(contentsOf: store.fileURL) == changed)
    #expect(!FileManager.default.fileExists(atPath: store.quarantineDirectory.path))
  }

  @Test func debugEvidenceStoreRecoversOnlyAnUnfinishedFinalAppend() throws {
    let root = debugAnnotationTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DebugEvidenceAnnotationStore(storageDirectory: root)
    let saved = try store.appendLabel(
      id: debugAnnotationID1,
      appendedAt: "2026-08-24T23:40:00Z",
      label: "Ground truth",
      observation: try debugAnnotationRealSamples()[0])
    let committed = try Data(contentsOf: store.fileURL)
    let unfinished = Data("{\"label\":".utf8)
    let handle = try FileHandle(forWritingTo: store.fileURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: unfinished)
    try handle.close()

    let result = try store.load()
    #expect(result.records == [saved])
    #expect(result.recovery?.quarantinedByteCount == unfinished.count)
    #expect(result.recovery?.retainedRecordCount == 1)
    #expect(try Data(contentsOf: store.fileURL) == committed)
    let quarantineURL = try #require(result.recovery?.quarantineURL)
    #expect(try Data(contentsOf: quarantineURL) == unfinished)
  }

  @Test func debugEvidenceStoreSerializesConcurrentAppendsAcrossInstances() async throws {
    let root = debugAnnotationTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = DebugEvidenceAnnotationStore(storageDirectory: root)
    let second = DebugEvidenceAnnotationStore(storageDirectory: root)
    let sample = try debugAnnotationRealSamples()[0]

    let outcomes = await withTaskGroup(of: String.self, returning: [String].self) { group in
      for store in [first, second] {
        group.addTask {
          do {
            _ = try store.appendLabel(
              id: debugAnnotationID1,
              appendedAt: "2026-08-24T23:40:00Z",
              label: "One immutable identity",
              observation: sample)
            return "SAVED"
          } catch DebugEvidenceAnnotationStoreError.annotationIdentityCollision {
            return "COLLISION"
          } catch {
            return "UNEXPECTED"
          }
        }
      }
      var values: [String] = []
      for await value in group { values.append(value) }
      return values
    }

    #expect(outcomes.filter { $0 == "SAVED" }.count == 1)
    #expect(outcomes.filter { $0 == "COLLISION" }.count == 1)
    #expect(try DebugEvidenceAnnotationStore(storageDirectory: root).list().count == 1)
  }
#endif

@Test func debugEvidenceStoreReadsProvenanceInEveryBuildAndMutatesOnlyInDebug() throws {
  let root = debugAnnotationTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = DebugEvidenceAnnotationStore(storageDirectory: root)
  let sample = try debugAnnotationRealSamples()[0]
  let saved = try DebugEvidenceAnnotationRecord.label(
    id: debugAnnotationID1,
    appendedAt: "2026-08-24T23:40:00Z",
    label: "Read-compatible provenance",
    observation: sample)
  let encoded = try VHOSJSON.encoder().encode(saved)
  try DurableEvidenceFile.ensureDirectory(root)
  try DurableEvidenceFile.appendCommittedLine(encoded, to: store.fileURL)

  let loaded = try #require(store.list().first)
  #expect(loaded == saved)
  #expect(loaded.acquisitionAuthority == .debugUnverified)
  #expect(loaded.sourceObservation == sample)

  #if DEBUG
    #expect(DebugEvidenceAnnotationStore.appendAvailable)
  #else
    #expect(!DebugEvidenceAnnotationStore.appendAvailable)
    let before = try Data(contentsOf: store.fileURL)
    #expect(throws: DebugEvidenceAnnotationStoreError.appendUnavailableInRelease) {
      try store.appendEventMarker(
        id: debugAnnotationID2,
        appendedAt: "2026-08-24T23:40:01Z",
        markerKind: .custom,
        label: "Release append must fail",
        observation: sample)
    }
    #expect(try Data(contentsOf: store.fileURL) == before)
  #endif
}

@Test func debugEvidenceStoreRequiresPassiveStructuralIntegrity() throws {
  let root = debugAnnotationTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = DebugEvidenceAnnotationStore(storageDirectory: root)
  let sample = try debugAnnotationRealSamples()[0]
  let unsafe = PassiveCANObservation(
    gatewayID: sample.gatewayID,
    sessionID: sample.sessionID,
    sourceSequence: sample.sourceSequence,
    monotonicMicroseconds: sample.monotonicMicroseconds,
    bitrateBps: sample.bitrateBps,
    identifier: sample.identifier,
    extended: sample.extended,
    remoteRequest: sample.remoteRequest,
    listenOnly: false,
    dataLength: sample.dataLength,
    data: sample.data,
    evidenceSource: sample.evidenceSource,
    ingestedAt: sample.ingestedAt)

  #expect(throws: DebugEvidenceAnnotationStoreError.invalidObservation) {
    try store.appendLabel(
      id: debugAnnotationID1,
      appendedAt: "2026-08-24T23:40:00Z",
      label: "Unsafe input",
      observation: unsafe)
  }
  let importedSource = PassiveCANObservation(
    gatewayID: sample.gatewayID,
    sessionID: sample.sessionID,
    sourceSequence: sample.sourceSequence,
    monotonicMicroseconds: sample.monotonicMicroseconds,
    bitrateBps: sample.bitrateBps,
    identifier: sample.identifier,
    extended: sample.extended,
    remoteRequest: sample.remoteRequest,
    listenOnly: true,
    dataLength: sample.dataLength,
    data: sample.data,
    evidenceSource: "unverified-import",
    ingestedAt: sample.ingestedAt)
  #if DEBUG
    let importedLabel = try store.appendLabel(
      id: debugAnnotationID2,
      appendedAt: "2026-08-24T23:40:01Z",
      label: "Imported canonical evidence",
      observation: importedSource)
    #expect(try store.list() == [importedLabel])
  #else
    let importedLabel = try DebugEvidenceAnnotationRecord.label(
      id: debugAnnotationID2,
      appendedAt: "2026-08-24T23:40:01Z",
      label: "Imported canonical evidence",
      observation: importedSource)
    #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
  #endif
  #expect(importedLabel.sourceObservation.evidenceSource == "unverified-import")
}

private func debugAnnotationTemporaryDirectory() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    "vhos-debug-annotation-tests-\(UUID().uuidString)",
    isDirectory: true)
}

private func debugAnnotationRealSamples() throws -> [PassiveCANObservation] {
  let url = try #require(
    Bundle.module.url(
      forResource: "real-can-2026-08-18-627753796-256",
      withExtension: "ndjson",
      subdirectory: "Fixtures"))
  let lines = try Data(contentsOf: url).split(separator: 0x0A)
  return try lines.prefix(2).map {
    try VHOSJSON.decoder().decode(PassiveCANObservation.self, from: Data($0))
  }
}
