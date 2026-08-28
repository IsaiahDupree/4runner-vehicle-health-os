import CryptoKit
import Foundation
import VHOSCore

struct PreparedEvidenceArtifact: Sendable {
  let url: URL
  let artifactIdentity: String
  let contentType: String
  let byteCount: Int
  let sha256: String
}

struct PreparedEvidencePage: Sendable {
  let artifacts: [PreparedEvidenceArtifact]
  let hasMore: Bool
}

struct CaptureEvidenceFileSnapshot: @unchecked Sendable {
  let handle: FileHandle
  let startOffset: UInt64
  let exactByteCount: Int
}

struct PassiveCANWorkSnapshot: @unchecked Sendable {
  let captureFiles: [CaptureEvidenceFileSnapshot]
  let portableLedgers: [PortableLedgerSnapshot]
  let maximumObservationCount: Int
  let hasEarlierCaptureBytes: Bool

  func close() {
    for source in captureFiles { try? source.handle.close() }
    for source in portableLedgers { try? source.handle.close() }
  }
}

struct PreparedPassiveCANExport: Sendable {
  let url: URL
  let recordCount: Int
  let excludesEarlierCaptureBytes: Bool
}

/// Serializes evidence work away from the CoreBluetooth/UI main actor.
///
/// Snapshot creation opens only a bounded number of exact-length descriptors. This actor then
/// performs every payload read, canonical decode, hash, ZIP construction, and temporary-file
/// publication. No mutable gateway or app model is captured here.
struct PassiveCANBatch: Sendable {
  let observations: [PassiveCANObservation]
}

actor EvidenceWorkCoordinator {
  func prepareEvidencePage(
    _ snapshot: PortableEvidenceWorkSnapshot,
    creator: EvidenceBundleCreator,
    outputDirectory: URL
  ) throws -> PreparedEvidencePage {
    defer { snapshot.close() }
    try Task.checkCancellation()
    try FileManager.default.createDirectory(
      at: outputDirectory, withIntermediateDirectories: true)
    var prepared: [PreparedEvidenceArtifact] = []

    for ledger in snapshot.ledgers {
      try Task.checkCancellation()
      let bytes = try Self.readExactly(
        ledger.handle,
        byteCount: ledger.exactByteCount,
        maximumByteCount: 16 * 1_024 * 1_024)
      guard Self.sha256(bytes) == ledger.sourceLedgerSHA256 else {
        throw PortableFrameStoreError.sealedGenerationHashMismatch(
          "snapshot-generation-\(ledger.ordinal)")
      }
      let records = try Self.decodeCanonicalLedger(bytes)
      guard let createdAt = records.last?.ingestedAt else {
        throw PortableFrameStoreError.noEvidence
      }
      let bundle = try EvidenceSyncBundle.encode(
        records: records,
        creator: creator,
        recovery: EvidenceRecoveryMetadata(
          sourceLedgerSHA256: ledger.sourceLedgerSHA256),
        bundleID: try PortableFrameStore.deterministicBundleID(
          sourceLedgerSHA256: ledger.sourceLedgerSHA256),
        createdAt: createdAt)
      let url = outputDirectory.appendingPathComponent(
        "vhos-recovered-evidence-not-live-generation-"
          + String(format: "%012d", ledger.ordinal)
          + "-ledger-\(ledger.sourceLedgerSHA256).vhossync")
      try bundle.write(to: url, options: [.atomic])
      prepared.append(
        PreparedEvidenceArtifact(
          url: url,
          artifactIdentity: ledger.artifactIdentity,
          contentType: "application/vnd.vhos.evidence-sync+zip",
          byteCount: bundle.count,
          sha256: Self.sha256(bundle)))
    }

    for lineage in snapshot.importedLineage {
      try Task.checkCancellation()
      let receipt = try Self.readExactly(
        lineage.receiptHandle,
        byteCount: lineage.receiptByteCount,
        maximumByteCount: PortableFrameStore.productionImportReceiptByteLimit)
      let archive = try Self.readExactly(
        lineage.archiveHandle,
        byteCount: lineage.archiveByteCount,
        maximumByteCount: EvidenceSyncBundle.maximumArchiveByteCount)
      guard Self.sha256(archive) == lineage.archiveSHA256,
        try PortableFrameStore.validateImportedLineage(
          receiptBytes: receipt, archive: archive) == lineage.bundleID
      else { throw PortableFrameStoreError.invalidImportReceipt }

      let archiveIdentity = PortableFrameStore.importedArchiveArtifactIdentity(
        bundleID: lineage.bundleID, archiveSHA256: lineage.archiveSHA256)
      if lineage.requestedArtifactIdentities.contains(archiveIdentity) {
        let archiveURL = outputDirectory.appendingPathComponent(
          "imported-bundle-\(lineage.bundleID.uuidString.lowercased())-"
            + "\(lineage.archiveSHA256).vhossync")
        try archive.write(to: archiveURL, options: [.atomic])
        prepared.append(
          PreparedEvidenceArtifact(
            url: archiveURL,
            artifactIdentity: archiveIdentity,
            contentType: "application/vnd.vhos.evidence-sync+zip",
            byteCount: archive.count,
            sha256: lineage.archiveSHA256))
      }

      let receiptIdentity = PortableFrameStore.importReceiptArtifactIdentity(
        bundleID: lineage.bundleID)
      if lineage.requestedArtifactIdentities.contains(receiptIdentity) {
        let receiptDigest = Self.sha256(receipt)
        let receiptURL = outputDirectory.appendingPathComponent(
          "import-receipt-\(lineage.bundleID.uuidString.lowercased())-"
            + "\(receiptDigest).json")
        try receipt.write(to: receiptURL, options: [.atomic])
        prepared.append(
          PreparedEvidenceArtifact(
            url: receiptURL,
            artifactIdentity: receiptIdentity,
            contentType: "application/vnd.vhos.import-provenance-receipt+json",
            byteCount: receipt.count,
            sha256: receiptDigest))
      }
    }

    return PreparedEvidencePage(artifacts: prepared, hasMore: snapshot.hasMore)
  }

  func analyzePassiveCAN(_ snapshot: PassiveCANWorkSnapshot) async throws
    -> PassiveCANResearchReport?
  {
    defer { snapshot.close() }
    let observations = try await Self.decodePassiveCAN(snapshot)
    guard !observations.isEmpty else { return nil }
    return try PassiveCANResearchAnalyzer.analyze(observations)
  }

  func preparePassiveCANExport(
    _ snapshot: PassiveCANWorkSnapshot,
    outputDirectory: URL
  ) async throws -> PreparedPassiveCANExport {
    defer { snapshot.close() }
    let observations = try await Self.decodePassiveCAN(snapshot)
    guard !observations.isEmpty else { throw CaptureSyncError.noStoredLogs }
    try FileManager.default.createDirectory(
      at: outputDirectory, withIntermediateDirectories: true)
    let output = outputDirectory.appendingPathComponent("passive-can-recent-logs.ndjson")
    try PassiveCANEvidenceArchive.encodeNDJSON(observations).write(
      to: output, options: [.atomic])
    return PreparedPassiveCANExport(
      url: output,
      recordCount: observations.count,
      excludesEarlierCaptureBytes: snapshot.hasEarlierCaptureBytes)
  }

  func analyzeCANUnits(
    _ snapshot: PassiveCANWorkSnapshot,
    standardSamples: [J1979StandardSample]
  ) async throws -> CANUnitsReport {
    defer { snapshot.close() }
    let observations = try await Self.decodePassiveCAN(snapshot)
    return try CANUnitsAnalyzer.analyze(
      observations: observations,
      standardSamples: standardSamples)
  }

  func recentPassiveCAN(
    _ snapshot: PassiveCANWorkSnapshot,
    limit: Int = 512
  ) async throws -> PassiveCANBatch {
    defer { snapshot.close() }
    guard (1...2_048).contains(limit) else { throw EvidenceSyncError.tooManyRecords }
    let observations = try await Self.decodePassiveCAN(snapshot)
    return PassiveCANBatch(observations: Array(observations.suffix(limit)))
  }

  private static func decodePassiveCAN(_ snapshot: PassiveCANWorkSnapshot) async throws
    -> [PassiveCANObservation]
  {
    guard snapshot.maximumObservationCount > 0,
      snapshot.maximumObservationCount <= 50_000
    else { throw EvidenceSyncError.tooManyRecords }
    var archived: [PassiveCANObservation] = []
    for source in snapshot.captureFiles {
      try Task.checkCancellation()
      let bytes = try readExactly(
        source.handle,
        startOffset: source.startOffset,
        byteCount: source.exactByteCount,
        maximumByteCount: 16 * 1_024 * 1_024)
      let committedBytes: Data
      if source.startOffset > 0 {
        guard let firstNewline = bytes.firstIndex(of: 0x0A) else { continue }
        committedBytes = Data(bytes[bytes.index(after: firstNewline)...])
      } else {
        committedBytes = bytes
      }
      guard !committedBytes.isEmpty else { continue }
      let decoded = try PassiveCANEvidenceArchive.decodeNDJSON(committedBytes)
      archived = try PassiveCANEvidenceArchive.merge(
        existing: archived,
        incoming: decoded
      ).records
      if archived.count > snapshot.maximumObservationCount {
        archived = Array(archived.suffix(snapshot.maximumObservationCount))
      }
      await Task.yield()
    }

    var portableFrames: [PortableLogicalFrame] = []
    for source in snapshot.portableLedgers {
      try Task.checkCancellation()
      let bytes = try readExactly(
        source.handle,
        byteCount: source.exactByteCount,
        maximumByteCount: PortableFrameStore.productionGenerationByteLimit)
      guard sha256(bytes) == source.sourceLedgerSHA256 else {
        throw PortableFrameStoreError.sealedGenerationHashMismatch(
          "research-generation-\(source.ordinal)")
      }
      portableFrames.append(contentsOf: try decodeCanonicalLedger(bytes))
      if portableFrames.count > snapshot.maximumObservationCount {
        portableFrames = Array(portableFrames.suffix(snapshot.maximumObservationCount))
      }
      await Task.yield()
    }
    let portable = try PortableCANEvidence.project(portableFrames)
    let reconciled = try PortableCANEvidence.reconcile(existing: archived, projected: portable)
    return reconciled.count > snapshot.maximumObservationCount
      ? Array(reconciled.suffix(snapshot.maximumObservationCount)) : reconciled
  }

  private static func readExactly(
    _ handle: FileHandle,
    startOffset: UInt64 = 0,
    byteCount: Int,
    maximumByteCount: Int
  ) throws -> Data {
    guard byteCount >= 0, byteCount <= maximumByteCount else {
      throw EvidenceSyncError.entryTooLarge
    }
    try handle.seek(toOffset: startOffset)
    var result = Data()
    result.reserveCapacity(byteCount)
    while result.count < byteCount {
      try Task.checkCancellation()
      let requested = min(64 * 1_024, byteCount - result.count)
      let chunk = try handle.read(upToCount: requested) ?? Data()
      guard !chunk.isEmpty else { throw EvidenceSyncError.invalidArchive }
      result.append(chunk)
    }
    return result
  }

  private static func decodeCanonicalLedger(_ bytes: Data) throws
    -> [PortableLogicalFrame]
  {
    guard !bytes.isEmpty, bytes.last == 0x0A else {
      throw PortableFrameStoreError.uncommittedLedgerTail
    }
    let lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
    guard lines.last?.isEmpty == true, lines.count - 1 <= 20_000 else {
      throw EvidenceSyncError.tooManyRecords
    }
    var records: [PortableLogicalFrame] = []
    records.reserveCapacity(lines.count - 1)
    for line in lines.dropLast() {
      try Task.checkCancellation()
      guard !line.isEmpty else {
        throw PortableFrameStoreError.nonCanonicalCommittedRecord("snapshot")
      }
      let raw = Data(line)
      let record = try EvidenceSyncBundle.decodeRecord(raw)
      guard try VHOSJSON.encoder().encode(record) == raw else {
        throw PortableFrameStoreError.nonCanonicalCommittedRecord("snapshot")
      }
      records.append(record)
    }
    return records
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
