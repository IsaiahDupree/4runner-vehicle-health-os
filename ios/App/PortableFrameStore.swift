import CryptoKit
import Darwin
import Foundation
import SQLite3
import VHOSCore

struct EvidenceSyncImportSummary: Sendable {
  let bundleID: UUID
  let verifiedRecords: Int
  let appendedRecords: Int
}

struct PortableEvidenceExportArtifact: Sendable {
  let url: URL
  let generation: Int
  let recordCount: Int
  let sourceLedgerSHA256: String
}

struct PortableEvidenceLineageArtifact: Sendable {
  let url: URL
  let contentType: String
  let sha256: String
  let bundleID: UUID
}

struct PortableEvidenceExportSet: Sendable {
  let artifacts: [PortableEvidenceExportArtifact]
  let lineageArtifacts: [PortableEvidenceLineageArtifact]

  var urls: [URL] { artifacts.map(\.url) + lineageArtifacts.map(\.url) }
  var recordCount: Int { artifacts.reduce(0) { $0 + $1.recordCount } }
  var generationCount: Int { artifacts.count }
  var lineageArtifactCount: Int { lineageArtifacts.count }
}

struct PortableLedgerSnapshot: @unchecked Sendable {
  let handle: FileHandle
  let exactByteCount: Int
  let ordinal: Int
  let sourceLedgerSHA256: String
  let artifactIdentity: String
}

struct PortableImportLineageSnapshot: @unchecked Sendable {
  let receiptHandle: FileHandle
  let receiptByteCount: Int
  let archiveHandle: FileHandle
  let archiveByteCount: Int
  let bundleID: UUID
  let archiveSHA256: String
  let requestedArtifactIdentities: Set<String>
}

struct PortableEvidenceWorkSnapshot: @unchecked Sendable {
  let ledgers: [PortableLedgerSnapshot]
  let importedLineage: [PortableImportLineageSnapshot]
  let hasMore: Bool

  func close() {
    for ledger in ledgers { try? ledger.handle.close() }
    for lineage in importedLineage {
      try? lineage.receiptHandle.close()
      try? lineage.archiveHandle.close()
    }
  }
}

enum PortableImportLifecyclePhase {
  case intentDurableBeforeArchive
  case archiveDurableBeforeRecords
  case recordsDurableBeforeReceipt
  case receiptDurableBeforeJournalRemoval
}

/// Append-only portable frame storage with content-bound immutable generations.
///
/// A single ever-growing ledger eventually cannot fit the bounded `.vhossync` contract. The
/// active ledger is therefore sealed before it reaches its byte or record ceiling. Sealed files
/// are never reopened for append, carry their exact SHA-256 in their filename, and are all
/// included as independent recovery-v2 artifacts in every export set. No rollover deletes or
/// checkpoints away evidence.
final class PortableFrameStore {
  static let productionGenerationByteLimit = 16 * 1_024 * 1_024
  static let productionGenerationRecordLimit = 20_000
  /// A v2 import receipt can bind every record in a maximum-size generation. Keep the durable
  /// receipt, background snapshot, and private-outbox reader on one explicit ceiling so a valid
  /// import can always complete its provenance handoff.
  static let productionImportReceiptByteLimit = 16 * 1_024 * 1_024
  private static let maximumGenerationOrdinal = 999_999_999_999

  private static let activeFileName = "logical-frames.ndjson"
  private static let sealedPrefix = "logical-frames-generation-"
  private static let sealedPattern =
    #"^logical-frames-generation-([0-9]{12})-([0-9a-f]{64})\.ndjson$"#
  private static let inventoryAnchorFileName = "generation-inventory-v1.anchor"
  private static let highWaterFileName = "generation-high-water.txt"
  private static let integrityManifestFileName = "generation-integrity-v1.manifest"
  private static let inventoryAnchorV1 = "vhos.portable-generation-inventory/1\n"
  private static let inventoryAnchorV2 = "vhos.portable-generation-inventory/2\n"
  private static let integrityManifestHeader = "vhos.portable-generation-integrity/1\n"
  private static let indexFileName = "record-index.sqlite3"
  private static let recoveryDirectoryName = "InterruptedActiveLedger"
  private static let legacyMigrationDirectoryName = "LegacyActiveLedgerMigration"
  private static let legacyMigrationStateFileName = "migration-state.json"
  private static let legacyMigrationStagingName = "Staging"
  private static let legacyQuarantineDirectoryName = "LegacyActiveLedgerQuarantine"
  private static let anchoredV1MigrationDirectoryName = "AnchoredV1ActiveLedgerMigration"
  private static let anchoredV1MigrationStateFileName = "migration-state.json"
  private static let anchoredV1MigrationStagingName = "Staging"
  private static let importReceiptDirectoryName = "ImportReceipts"
  private static let importIntentDirectoryName = "ImportIntents"
  private static let importedBundleDirectoryName = "ImportedBundles"
  private static let importOrphanDirectoryName = "ImportOrphans"

  private let fileManager: FileManager
  private let root: URL
  private let framesURL: URL
  private let inventoryAnchorURL: URL
  private let highWaterURL: URL
  private let integrityManifestURL: URL
  private let indexURL: URL
  private let recoveryDirectoryURL: URL
  private let legacyMigrationDirectoryURL: URL
  private let legacyMigrationStateURL: URL
  private let legacyMigrationStagingURL: URL
  private let legacyQuarantineDirectoryURL: URL
  private let anchoredV1MigrationDirectoryURL: URL
  private let anchoredV1MigrationStateURL: URL
  private let anchoredV1MigrationStagingURL: URL
  private let importReceiptDirectoryURL: URL
  private let importIntentDirectoryURL: URL
  private let importedBundleDirectoryURL: URL
  private let importOrphanDirectoryURL: URL
  private let generationByteLimit: Int
  private let generationRecordLimit: Int
  private let importLifecycleHook: ((PortableImportLifecyclePhase) throws -> Void)?
  private var recordIndex: PortableRecordIndex?
  private var cachedActiveStatistics: LedgerStatistics?
  private var importTransactionActive = false

  convenience init(fileManager: FileManager = .default) {
    let support =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    self.init(
      fileManager: fileManager,
      root: support.appendingPathComponent("VHOSPortableFrames/v1", isDirectory: true)
    )
  }

  init(
    fileManager: FileManager,
    root: URL,
    generationByteLimit: Int = PortableFrameStore.productionGenerationByteLimit,
    generationRecordLimit: Int = PortableFrameStore.productionGenerationRecordLimit,
    importLifecycleHook: ((PortableImportLifecyclePhase) throws -> Void)? = nil
  ) {
    precondition(generationByteLimit > 0)
    precondition(generationRecordLimit > 0)
    self.fileManager = fileManager
    self.root = root
    framesURL = root.appendingPathComponent(Self.activeFileName)
    inventoryAnchorURL = root.appendingPathComponent(Self.inventoryAnchorFileName)
    highWaterURL = root.appendingPathComponent(Self.highWaterFileName)
    integrityManifestURL = root.appendingPathComponent(Self.integrityManifestFileName)
    indexURL = root.appendingPathComponent(Self.indexFileName)
    recoveryDirectoryURL = root.appendingPathComponent(
      Self.recoveryDirectoryName, isDirectory: true)
    legacyMigrationDirectoryURL = root.appendingPathComponent(
      Self.legacyMigrationDirectoryName, isDirectory: true)
    legacyMigrationStateURL = legacyMigrationDirectoryURL.appendingPathComponent(
      Self.legacyMigrationStateFileName)
    legacyMigrationStagingURL = legacyMigrationDirectoryURL.appendingPathComponent(
      Self.legacyMigrationStagingName, isDirectory: true)
    legacyQuarantineDirectoryURL = root.appendingPathComponent(
      Self.legacyQuarantineDirectoryName, isDirectory: true)
    anchoredV1MigrationDirectoryURL = root.appendingPathComponent(
      Self.anchoredV1MigrationDirectoryName, isDirectory: true)
    anchoredV1MigrationStateURL = anchoredV1MigrationDirectoryURL.appendingPathComponent(
      Self.anchoredV1MigrationStateFileName)
    anchoredV1MigrationStagingURL = anchoredV1MigrationDirectoryURL.appendingPathComponent(
      Self.anchoredV1MigrationStagingName, isDirectory: true)
    importReceiptDirectoryURL = root.appendingPathComponent(
      Self.importReceiptDirectoryName, isDirectory: true)
    importIntentDirectoryURL = root.appendingPathComponent(
      Self.importIntentDirectoryName, isDirectory: true)
    importedBundleDirectoryURL = root.appendingPathComponent(
      Self.importedBundleDirectoryName, isDirectory: true)
    importOrphanDirectoryURL = root.appendingPathComponent(
      Self.importOrphanDirectoryName, isDirectory: true)
    self.generationByteLimit = generationByteLimit
    self.generationRecordLimit = generationRecordLimit
    self.importLifecycleHook = importLifecycleHook
    try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func append(
    frame: GatewayFrame,
    sourceRole: EvidenceSourceRole,
    sourceID: String,
    ingestedAt: String
  ) throws -> Bool {
    let record = PortableLogicalFrame(
      frame: frame,
      sourceRole: sourceRole,
      sourceID: sourceID,
      ingestedAt: ingestedAt
    )
    return try append(record)
  }

  func append(_ record: PortableLogicalFrame) throws -> Bool {
    if !importTransactionActive { try recoverPendingImportIntentsIfNeeded() }
    _ = try record.validatedFrame()
    var line = try VHOSJSON.encoder().encode(record)
    line.append(0x0A)
    guard line.count <= generationByteLimit else {
      throw PortableFrameStoreError.recordExceedsGenerationLimit
    }

    let index = try ensuredRecordIndex()
    let recordDigest = try Self.canonicalRecordDigest(record, encoded: Data(line.dropLast()))
    if let existing = try index.entry(record.id) {
      guard existing.recordSHA256 == recordDigest,
        existing.sourceRole == record.sourceRole.rawValue
      else { throw PortableFrameStoreError.recordIdentityCollision(record.id) }
      return false
    }

    var statistics = try activeStatistics()
    if statistics.records > 0,
      statistics.records >= generationRecordLimit
        || statistics.bytes > generationByteLimit - line.count
    {
      do {
        try sealActiveGeneration()
      } catch {
        // A rollover can durably move the active ledger before a later receipt/index operation
        // reports failure. Never keep trusting the pre-move derived index in this process.
        recordIndex = nil
        cachedActiveStatistics = nil
        throw error
      }
      statistics = .empty
    }

    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    if !fileManager.fileExists(atPath: framesURL.path) {
      guard fileManager.createFile(atPath: framesURL.path, contents: nil) else {
        throw PortableFrameStoreError.createFailed
      }
      try synchronizeFile(framesURL)
      try synchronizeDirectory(root)
    }
    let handle = try FileHandle(forWritingTo: framesURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    do {
      try handle.write(contentsOf: line)
      try handle.synchronize()
      try synchronizeFile(framesURL)
      let updated = statistics.appending(line)
      cachedActiveStatistics = updated
      let ordinal = try nextActiveOrdinal()
      try index.insert(
        record.id,
        recordSHA256: recordDigest,
        sourceRole: record.sourceRole.rawValue,
        generationOrdinal: ordinal)
      try index.commitInventory(
        fingerprint: try inventoryFingerprint(active: updated),
        recordCount: try index.count()
      )
    } catch {
      // The ledger is authoritative. If a filesystem or SQLite operation failed after a partial
      // append, discard only the derived connection and reconcile from disk on the next access.
      // The interrupted-tail recovery path preserves the original bytes before restoring the
      // committed newline-delimited prefix.
      recordIndex = nil
      cachedActiveStatistics = nil
      throw error
    }
    return true
  }

  func records(limit: Int = 100_000) throws -> [PortableLogicalFrame] {
    guard (1...100_000).contains(limit) else { throw PortableFrameStoreError.invalidLimit }
    if !importTransactionActive { try recoverPendingImportIntentsIfNeeded() }
    _ = try ensuredRecordIndex()
    var newestFirst: [PortableLogicalFrame] = []
    var remaining = limit
    for source in try generationSources().reversed() where remaining > 0 {
      let records = try decodeLedger(source)
      for record in records.suffix(remaining).reversed() {
        newestFirst.append(record)
      }
      remaining = limit - newestFirst.count
    }
    return newestFirst.reversed()
  }

  /// Returns the exact disk-indexed identity count or surfaces an integrity failure.
  ///
  /// It deliberately does not translate an unreadable ledger/index into zero evidence.
  func count() throws -> Int {
    if !importTransactionActive { try recoverPendingImportIntentsIfNeeded() }
    return try ensuredRecordIndex().count()
  }

  /// Creates one independently checksummed recovery-v2 bundle per immutable ledger generation.
  ///
  /// The returned set is complete at the instant of export. Callers must share or queue every
  /// URL in the set; presenting only the newest artifact would omit older evidence.
  func export(
    applicationID: String,
    applicationVersion: String,
    deviceModel: String
  ) throws -> PortableEvidenceExportSet {
    if !importTransactionActive { try recoverPendingImportIntentsIfNeeded() }
    _ = try ensuredRecordIndex()
    let sources = try generationSources().filter { $0.byteCount > 0 }
    guard !sources.isEmpty else { throw PortableFrameStoreError.noEvidence }
    let outputDirectory = fileManager.temporaryDirectory.appendingPathComponent(
      "VehicleHealthOS-Evidence", isDirectory: true)
    try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    var artifacts: [PortableEvidenceExportArtifact] = []
    for source in sources {
      let records = try decodeLedger(source)
      let digest = source.digest
      let bundleID = try Self.deterministicBundleID(sourceLedgerSHA256: digest)
      guard let createdAt = records.last?.ingestedAt else {
        throw PortableFrameStoreError.noEvidence
      }
      let bytes = try EvidenceSyncBundle.encode(
        records: records,
        creator: EvidenceBundleCreator(
          platform: "IOS",
          applicationID: applicationID,
          applicationVersion: applicationVersion,
          deviceModel: deviceModel
        ),
        recovery: EvidenceRecoveryMetadata(sourceLedgerSHA256: digest),
        bundleID: bundleID,
        createdAt: createdAt
      )
      let output = outputDirectory.appendingPathComponent(
        "vhos-recovered-evidence-not-live-generation-"
          + String(format: "%012d", source.ordinal)
          + "-ledger-\(digest).vhossync")
      try bytes.write(to: output, options: .atomic)
      artifacts.append(
        PortableEvidenceExportArtifact(
          url: output,
          generation: source.ordinal,
          recordCount: records.count,
          sourceLedgerSHA256: digest
        ))
    }
    return PortableEvidenceExportSet(
      artifacts: artifacts,
      lineageArtifacts: try importLineageArtifacts())
  }

  /// Captures a bounded exact-byte evidence page without decoding payloads on the BLE/UI actor.
  /// Open descriptors plus exact lengths preserve the selected active-ledger prefix across later
  /// appends or rollover. The worker that consumes this value must close every descriptor.
  func makeEvidenceWorkSnapshot(
    excludingArtifactIdentities: Set<String>,
    maximumArtifacts: Int
  ) throws -> PortableEvidenceWorkSnapshot {
    guard (1...8).contains(maximumArtifacts) else {
      throw PortableFrameStoreError.invalidLimit
    }
    if !importTransactionActive { try recoverPendingImportIntentsIfNeeded() }
    _ = try ensuredRecordIndex()
    var ledgerSnapshots: [PortableLedgerSnapshot] = []
    var lineageSnapshots: [PortableImportLineageSnapshot] = []
    var remaining = maximumArtifacts
    var missingArtifacts = 0

    do {
      // Inventory receipts already bind every sealed filename to its digest. Do not re-hash an
      // unbounded historical inventory on the CoreBluetooth main actor: the background worker
      // verifies the exact bytes of each selected descriptor before it exports anything.
      for source in try generationSources(verifySealedFileHashes: false)
        .filter({ $0.byteCount > 0 })
      {
        let identity = Self.ledgerArtifactIdentity(
          ordinal: source.ordinal, digest: source.digest)
        guard !excludingArtifactIdentities.contains(identity) else { continue }
        missingArtifacts += 1
        guard remaining > 0 else { break }
        ledgerSnapshots.append(
          PortableLedgerSnapshot(
            handle: try FileHandle(forReadingFrom: source.url),
            exactByteCount: source.byteCount,
            ordinal: source.ordinal,
            sourceLedgerSHA256: source.digest,
            artifactIdentity: identity))
        remaining -= 1
      }

      for lineage in try importLineageSourceMetadata() {
        let originalIdentity = Self.importedArchiveArtifactIdentity(
          bundleID: lineage.bundleID, archiveSHA256: lineage.archiveSHA256)
        let receiptIdentity = Self.importReceiptArtifactIdentity(bundleID: lineage.bundleID)
        let requested = Set([originalIdentity, receiptIdentity]).subtracting(
          excludingArtifactIdentities)
        guard !requested.isEmpty else { continue }
        missingArtifacts += requested.count
        let selectedRequested = Set(requested.sorted().prefix(remaining))
        guard !selectedRequested.isEmpty else { break }
        lineageSnapshots.append(
          PortableImportLineageSnapshot(
            receiptHandle: try FileHandle(forReadingFrom: lineage.receiptURL),
            receiptByteCount: lineage.receiptByteCount,
            archiveHandle: try FileHandle(forReadingFrom: lineage.archiveURL),
            archiveByteCount: lineage.archiveByteCount,
            bundleID: lineage.bundleID,
            archiveSHA256: lineage.archiveSHA256,
            requestedArtifactIdentities: selectedRequested))
        remaining -= selectedRequested.count
      }
    } catch {
      PortableEvidenceWorkSnapshot(
        ledgers: ledgerSnapshots, importedLineage: lineageSnapshots, hasMore: true
      ).close()
      throw error
    }

    let selectedCount =
      ledgerSnapshots.count
      + lineageSnapshots.reduce(0) { $0 + $1.requestedArtifactIdentities.count }
    return PortableEvidenceWorkSnapshot(
      ledgers: ledgerSnapshots,
      importedLineage: lineageSnapshots,
      hasMore: missingArtifacts > selectedCount)
  }

  func makeResearchLedgerSnapshots(maximumSources: Int = 3) throws
    -> [PortableLedgerSnapshot]
  {
    guard (1...3).contains(maximumSources) else { throw PortableFrameStoreError.invalidLimit }
    if !importTransactionActive { try recoverPendingImportIntentsIfNeeded() }
    _ = try ensuredRecordIndex()
    let sources = Array(
      try generationSources(verifySealedFileHashes: false)
        .filter { $0.byteCount > 0 }.suffix(maximumSources))
    var snapshots: [PortableLedgerSnapshot] = []
    do {
      for source in sources {
        snapshots.append(
          PortableLedgerSnapshot(
            handle: try FileHandle(forReadingFrom: source.url),
            exactByteCount: source.byteCount,
            ordinal: source.ordinal,
            sourceLedgerSHA256: source.digest,
            artifactIdentity: Self.ledgerArtifactIdentity(
              ordinal: source.ordinal, digest: source.digest)))
      }
      return snapshots
    } catch {
      for snapshot in snapshots { try? snapshot.handle.close() }
      throw error
    }
  }

  static func ledgerArtifactIdentity(ordinal: Int, digest: String) -> String {
    "portable-ledger:\(ordinal):\(digest)"
  }

  static func importedArchiveArtifactIdentity(bundleID: UUID, archiveSHA256: String) -> String {
    "imported-bundle:\(bundleID.uuidString.lowercased()):\(archiveSHA256)"
  }

  static func importReceiptArtifactIdentity(bundleID: UUID) -> String {
    "import-receipt:\(bundleID.uuidString.lowercased())"
  }

  func importBundle(_ bytes: Data) throws -> EvidenceSyncImportSummary {
    if !importTransactionActive { try recoverPendingImportIntentsIfNeeded() }
    let bundle = try EvidenceSyncBundle.decode(bytes)
    let receipt = try Self.makeImportReceipt(bundle: bundle, archive: bytes)
    try preflightImportReceipt(receipt)
    try preflightImport(bundle.records)
    try persistImportIntent(receipt)
    try importLifecycleHook?(.intentDurableBeforeArchive)
    try persistImportedBundle(bytes, receipt: receipt)
    try persistImportArchiveReady(receipt)
    try importLifecycleHook?(.archiveDurableBeforeRecords)
    importTransactionActive = true
    defer { importTransactionActive = false }
    var appended = 0
    for record in bundle.records where try append(record) { appended += 1 }
    try importLifecycleHook?(.recordsDurableBeforeReceipt)
    try persistImportReceipt(receipt)
    try importLifecycleHook?(.receiptDurableBeforeJournalRemoval)
    try removeImportIntent(receipt.bundleID)
    return EvidenceSyncImportSummary(
      bundleID: bundle.manifest.bundleID,
      verifiedRecords: bundle.records.count,
      appendedRecords: appended
    )
  }

  /// Validates every deterministic append condition before the first imported byte is committed.
  ///
  /// A bundle may contain records that are individually valid while a later record reuses an
  /// existing physical-envelope identity with different immutable provenance. Discovering that
  /// conflict after earlier records were appended would leave a semantically partial import. This
  /// pass checks the complete bundle against both the disk index and its own earlier records first.
  /// Filesystem failures remain safely retryable because exact records are idempotent.
  private func preflightImport(_ records: [PortableLogicalFrame]) throws {
    let index = try ensuredRecordIndex()
    var candidates: [String: PortableRecordIndex.Entry] = [:]
    candidates.reserveCapacity(min(records.count, generationRecordLimit))

    for record in records {
      _ = try record.validatedFrame()
      let encoded = try VHOSJSON.encoder().encode(record)
      guard encoded.count < generationByteLimit else {
        throw PortableFrameStoreError.recordExceedsGenerationLimit
      }
      let candidate = PortableRecordIndex.Entry(
        recordSHA256: try Self.canonicalRecordDigest(record, encoded: encoded),
        sourceRole: record.sourceRole.rawValue)
      if let existing = try index.entry(record.id), existing != candidate {
        throw PortableFrameStoreError.recordIdentityCollision(record.id)
      }
      if let earlier = candidates[record.id], earlier != candidate {
        throw PortableFrameStoreError.recordIdentityCollision(record.id)
      }
      candidates[record.id] = candidate
    }
  }

  private struct ImportRecordLink: Codable, Equatable {
    let recordID: String
    let recordSHA256: String

    private enum CodingKeys: String, CodingKey {
      case recordID = "recordId"
      case recordSHA256 = "recordSha256"
    }
  }

  private struct ImportProvenanceReceipt: Codable, Equatable {
    let contract: String
    let contractVersion: String
    let bundleID: UUID
    let manifestSHA256: String
    let archiveSHA256: String
    let creator: EvidenceBundleCreator
    let recovery: EvidenceRecoveryMetadata?
    let recordCount: Int
    let recordLinkChainSHA256: String
    let recordLinks: [ImportRecordLink]

    private enum CodingKeys: String, CodingKey {
      case contract
      case contractVersion
      case bundleID = "bundleId"
      case manifestSHA256 = "manifestSha256"
      case archiveSHA256 = "archiveSha256"
      case creator
      case recovery
      case recordCount
      case recordLinkChainSHA256 = "recordLinkChainSha256"
      case recordLinks
    }
  }

  private struct LegacyImportProvenanceReceiptV1: Codable, Equatable {
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
      case contract
      case contractVersion
      case bundleID = "bundleId"
      case manifestSHA256 = "manifestSha256"
      case archiveSHA256 = "archiveSha256"
      case creator
      case recovery
      case recordCount
      case recordLinkChainSHA256 = "recordLinkChainSha256"
    }
  }

  private struct ImportProvenanceIntent: Codable, Equatable {
    let contract: String
    let contractVersion: String
    let bundleID: UUID
    let archiveFilename: String
    let archiveSHA256: String
    let receiptSHA256: String

    private enum CodingKeys: String, CodingKey {
      case contract
      case contractVersion
      case bundleID = "bundleId"
      case archiveFilename
      case archiveSHA256 = "archiveSha256"
      case receiptSHA256 = "receiptSha256"
    }
  }

  private static func makeImportReceipt(
    bundle: ImportedEvidenceBundle,
    archive: Data
  ) throws -> ImportProvenanceReceipt {
    var linkHasher = SHA256()
    var links: [ImportRecordLink] = []
    links.reserveCapacity(bundle.records.count)
    for record in bundle.records {
      let link = ImportRecordLink(
        recordID: record.id,
        recordSHA256: try Self.canonicalRecordDigest(record))
      links.append(link)
      let encoded = try VHOSJSON.encoder().encode(link)
      var length = UInt64(encoded.count).bigEndian
      withUnsafeBytes(of: &length) { linkHasher.update(bufferPointer: $0) }
      linkHasher.update(data: encoded)
    }
    return ImportProvenanceReceipt(
      contract: "vhos.portable-evidence-import-receipt",
      contractVersion: "2.0.0",
      bundleID: bundle.manifest.bundleID,
      manifestSHA256: bundle.manifestSHA256,
      archiveSHA256: Self.sha256(archive),
      creator: bundle.manifest.creator,
      recovery: bundle.manifest.recovery,
      recordCount: bundle.records.count,
      recordLinkChainSHA256: Data(linkHasher.finalize()).hexadecimalString,
      recordLinks: links)
  }

  private func importReceiptURL(_ bundleID: UUID) -> URL {
    importReceiptDirectoryURL.appendingPathComponent(
      "bundle-\(bundleID.uuidString.lowercased()).json")
  }

  private func importIntentURL(_ bundleID: UUID) -> URL {
    importIntentDirectoryURL.appendingPathComponent(
      "bundle-\(bundleID.uuidString.lowercased()).intent.json")
  }

  private func importArchiveReadyURL(_ bundleID: UUID) -> URL {
    importIntentDirectoryURL.appendingPathComponent(
      "bundle-\(bundleID.uuidString.lowercased()).archive-ready")
  }

  private func importedBundleURL(_ receipt: ImportProvenanceReceipt) -> URL {
    importedBundleDirectoryURL.appendingPathComponent(
      "bundle-\(receipt.bundleID.uuidString.lowercased())-\(receipt.archiveSHA256).vhossync")
  }

  private func preflightImportReceipt(_ receipt: ImportProvenanceReceipt) throws {
    let url = importReceiptURL(receipt.bundleID)
    guard fileManager.fileExists(atPath: url.path) else { return }
    let existing = try Data(contentsOf: url, options: [.mappedIfSafe])
    let expected = try VHOSJSON.encoder().encode(receipt)
    guard existing == expected || legacyReceipt(existing, matches: receipt) else {
      throw PortableFrameStoreError.importReceiptConflict(receipt.bundleID.uuidString.lowercased())
    }
  }

  private func persistImportReceipt(_ receipt: ImportProvenanceReceipt) throws {
    try fileManager.createDirectory(
      at: importReceiptDirectoryURL, withIntermediateDirectories: true)
    let url = importReceiptURL(receipt.bundleID)
    let expected = try VHOSJSON.encoder().encode(receipt)
    if fileManager.fileExists(atPath: url.path) {
      let existing = try Data(contentsOf: url, options: [.mappedIfSafe])
      guard existing == expected || legacyReceipt(existing, matches: receipt) else {
        throw PortableFrameStoreError.importReceiptConflict(
          receipt.bundleID.uuidString.lowercased())
      }
      guard existing != expected else { return }
      try replacePreserved(expected, at: url)
      return
    }
    try writePreserved(expected, to: url)
  }

  private func legacyReceipt(_ bytes: Data, matches receipt: ImportProvenanceReceipt) -> Bool {
    guard
      let legacy = try? VHOSJSON.decoder().decode(
        LegacyImportProvenanceReceiptV1.self, from: bytes),
      (try? VHOSJSON.encoder().encode(legacy)) == bytes
    else { return false }
    return legacy.contract == receipt.contract
      && legacy.contractVersion == "1.0.0"
      && legacy.bundleID == receipt.bundleID
      && legacy.manifestSHA256 == receipt.manifestSHA256
      && legacy.archiveSHA256 == receipt.archiveSHA256
      && legacy.creator == receipt.creator
      && legacy.recovery == receipt.recovery
      && legacy.recordCount == receipt.recordCount
      && legacy.recordLinkChainSHA256 == receipt.recordLinkChainSHA256
  }

  private func persistImportedBundle(
    _ archive: Data,
    receipt: ImportProvenanceReceipt
  ) throws {
    guard archive.count <= EvidenceSyncBundle.maximumArchiveByteCount,
      Self.sha256(archive) == receipt.archiveSHA256
    else { throw PortableFrameStoreError.invalidImportIntent }
    try fileManager.createDirectory(
      at: importedBundleDirectoryURL, withIntermediateDirectories: true)
    try writePreserved(archive, to: importedBundleURL(receipt))
  }

  private func persistImportIntent(_ receipt: ImportProvenanceReceipt) throws {
    try fileManager.createDirectory(
      at: importIntentDirectoryURL, withIntermediateDirectories: true)
    let receiptBytes = try VHOSJSON.encoder().encode(receipt)
    let intent = ImportProvenanceIntent(
      contract: "vhos.portable-evidence-import-intent",
      contractVersion: "2.0.0",
      bundleID: receipt.bundleID,
      archiveFilename: importedBundleURL(receipt).lastPathComponent,
      archiveSHA256: receipt.archiveSHA256,
      receiptSHA256: Self.sha256(receiptBytes))
    try writePreserved(
      try VHOSJSON.encoder().encode(intent),
      to: importIntentURL(receipt.bundleID))
  }

  private func persistImportArchiveReady(_ receipt: ImportProvenanceReceipt) throws {
    let receiptSHA256 = Self.sha256(try VHOSJSON.encoder().encode(receipt))
    let bytes = Data(
      "vhos.portable-evidence-import-archive-ready/1\n\(receipt.archiveSHA256)\n\(receiptSHA256)\n"
        .utf8)
    try writePreserved(bytes, to: importArchiveReadyURL(receipt.bundleID))
  }

  private func removeImportIntent(_ bundleID: UUID) throws {
    // Delete the intent first. Once the completion receipt is durable, a surviving ready marker
    // is harmless and can be scavenged; the inverse (intent without ready) is a pre-append journal
    // and would make recovery quarantine the archive that the receipt still references.
    for url in [importIntentURL(bundleID), importArchiveReadyURL(bundleID)]
    where fileManager.fileExists(atPath: url.path) {
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      try fileManager.removeItem(at: url)
      try synchronizeDirectory(url.deletingLastPathComponent())
    }
  }

  /// Completes any import whose original archive and intent were made durable before appends.
  ///
  /// Exact records are idempotent, so a restart after any append can replay the preserved archive.
  /// The intent is removed only after the immutable completion receipt exists. Any mismatch leaves
  /// all source evidence and the intent untouched and fails closed.
  private func recoverPendingImportIntentsIfNeeded() throws {
    guard !importTransactionActive else { return }
    try requireAuthorizedRecoveryState()
    try reconcileOrphanImportedBundles()
    try migrateLegacyImportReceiptsIfNeeded()
    guard fileManager.fileExists(atPath: importIntentDirectoryURL.path) else { return }
    let urls = try fileManager.contentsOfDirectory(
      at: importIntentDirectoryURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
    .filter { $0.lastPathComponent.hasSuffix(".intent.json") }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !urls.isEmpty else { return }

    importTransactionActive = true
    defer { importTransactionActive = false }
    for intentURL in urls {
      let intentBytes = try Data(contentsOf: intentURL, options: [.mappedIfSafe])
      let intent = try VHOSJSON.decoder().decode(
        ImportProvenanceIntent.self, from: intentBytes)
      guard try VHOSJSON.encoder().encode(intent) == intentBytes,
        intent.contract == "vhos.portable-evidence-import-intent",
        ["1.0.0", "2.0.0"].contains(intent.contractVersion),
        intent.archiveFilename.unicodeScalars.count <= 256,
        intent.archiveFilename.range(
          of: #"^bundle-[0-9a-f-]{36}-[0-9a-f]{64}\.vhossync$"#,
          options: .regularExpression) != nil,
        intent.archiveSHA256.range(
          of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
        intent.receiptSHA256.range(
          of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
      else { throw PortableFrameStoreError.invalidImportIntent }
      let archiveURL = importedBundleDirectoryURL.appendingPathComponent(intent.archiveFilename)
      if intent.contractVersion == "2.0.0",
        !fileManager.fileExists(atPath: importArchiveReadyURL(intent.bundleID).path)
      {
        let receiptURL = importReceiptURL(intent.bundleID)
        if fileManager.fileExists(atPath: receiptURL.path) {
          // A receipt is published only after every exact record append is durable. This is the
          // cleanup crash window: retain archive lineage and remove the stale intent rather than
          // misclassifying a completed import as pre-append.
          let receiptBytes = try Data(contentsOf: receiptURL, options: [.mappedIfSafe])
          let receipt = try VHOSJSON.decoder().decode(
            ImportProvenanceReceipt.self, from: receiptBytes)
          guard try VHOSJSON.encoder().encode(receipt) == receiptBytes,
            receipt.bundleID == intent.bundleID,
            receipt.archiveSHA256 == intent.archiveSHA256,
            Self.sha256(receiptBytes) == intent.receiptSHA256,
            fileManager.fileExists(atPath: archiveURL.path),
            try Self.sha256(file: archiveURL) == intent.archiveSHA256
          else { throw PortableFrameStoreError.invalidImportIntent }
          try removeImportIntent(intent.bundleID)
          continue
        }
        // v2 publishes the ready marker durably before the first record append. With no marker,
        // this is an interrupted pre-append transaction, so preserve its exact intent/archive in
        // the orphan journal and continue without touching the ledger.
        if fileManager.fileExists(atPath: archiveURL.path) {
          try quarantineImportArtifact(archiveURL)
        }
        try quarantineImportArtifact(intentURL)
        continue
      }
      if intent.contractVersion == "2.0.0" {
        let ready = try Data(
          contentsOf: importArchiveReadyURL(intent.bundleID), options: [.mappedIfSafe])
        let expected = Data(
          "vhos.portable-evidence-import-archive-ready/1\n\(intent.archiveSHA256)\n\(intent.receiptSHA256)\n"
            .utf8)
        guard ready == expected else { throw PortableFrameStoreError.invalidImportIntent }
      }
      guard
        archiveURL.deletingLastPathComponent().standardizedFileURL
          == importedBundleDirectoryURL.standardizedFileURL,
        fileManager.fileExists(atPath: archiveURL.path),
        try fileByteCount(archiveURL) <= EvidenceSyncBundle.maximumArchiveByteCount
      else { throw PortableFrameStoreError.invalidImportIntent }
      let archive = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
      guard Self.sha256(archive) == intent.archiveSHA256 else {
        throw PortableFrameStoreError.invalidImportIntent
      }
      let bundle = try EvidenceSyncBundle.decode(archive)
      let receipt = try Self.makeImportReceipt(bundle: bundle, archive: archive)
      guard receipt.bundleID == intent.bundleID,
        importedBundleURL(receipt).lastPathComponent == intent.archiveFilename,
        Self.sha256(try VHOSJSON.encoder().encode(receipt)) == intent.receiptSHA256
      else { throw PortableFrameStoreError.invalidImportIntent }
      try preflightImportReceipt(receipt)
      try preflightImport(bundle.records)
      for record in bundle.records { _ = try append(record) }
      try persistImportReceipt(receipt)
      try removeImportIntent(receipt.bundleID)
    }
  }

  /// Recovery and legacy migration may move or rewrite preserved artifacts. Missing the inventory
  /// anchor in an already initialized store is therefore checked before any such mutation.
  private func requireAuthorizedRecoveryState() throws {
    guard !fileManager.fileExists(atPath: inventoryAnchorURL.path) else { return }
    let resumableMigration = fileManager.fileExists(atPath: legacyMigrationStateURL.path)
    guard !durableInitializedStateExists() || resumableMigration else {
      throw PortableFrameStoreError.missingGenerationInventoryReceipt
    }
  }

  private func durableInitializedStateExists() -> Bool {
    [
      indexURL,
      URL(fileURLWithPath: indexURL.path + "-wal"),
      URL(fileURLWithPath: indexURL.path + "-shm"),
      recoveryDirectoryURL,
      legacyMigrationDirectoryURL,
      legacyQuarantineDirectoryURL,
      anchoredV1MigrationDirectoryURL,
      importReceiptDirectoryURL,
      importIntentDirectoryURL,
      importedBundleDirectoryURL,
      importOrphanDirectoryURL,
    ].contains { fileManager.fileExists(atPath: $0.path) }
  }

  private func migrateLegacyImportReceiptsIfNeeded() throws {
    guard fileManager.fileExists(atPath: importReceiptDirectoryURL.path) else { return }
    let receiptURLs = try fileManager.contentsOfDirectory(
      at: importReceiptDirectoryURL,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension == "json" }
    for receiptURL in receiptURLs {
      let bytes = try Data(contentsOf: receiptURL, options: [.mappedIfSafe])
      if let current = try? VHOSJSON.decoder().decode(
        ImportProvenanceReceipt.self, from: bytes),
        current.contractVersion == "2.0.0",
        (try? VHOSJSON.encoder().encode(current)) == bytes
      {
        continue
      }
      let legacy = try VHOSJSON.decoder().decode(
        LegacyImportProvenanceReceiptV1.self, from: bytes)
      guard try VHOSJSON.encoder().encode(legacy) == bytes,
        legacy.contract == "vhos.portable-evidence-import-receipt",
        legacy.contractVersion == "1.0.0",
        legacy.archiveSHA256.range(
          of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
      else { throw PortableFrameStoreError.invalidImportReceipt }
      let archiveURL = importedBundleDirectoryURL.appendingPathComponent(
        "bundle-\(legacy.bundleID.uuidString.lowercased())-\(legacy.archiveSHA256).vhossync")
      guard fileManager.fileExists(atPath: archiveURL.path) else {
        throw PortableFrameStoreError.legacyImportReceiptMissingArchive(
          legacy.bundleID.uuidString.lowercased())
      }
      guard try fileByteCount(archiveURL) <= EvidenceSyncBundle.maximumArchiveByteCount else {
        throw PortableFrameStoreError.invalidImportReceipt
      }
      let archive = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
      let migrated = try Self.makeImportReceipt(
        bundle: EvidenceSyncBundle.decode(archive), archive: archive)
      guard legacyReceipt(bytes, matches: migrated) else {
        throw PortableFrameStoreError.invalidImportReceipt
      }
      try replacePreserved(try VHOSJSON.encoder().encode(migrated), at: receiptURL)
    }
  }

  private func reconcileOrphanImportedBundles() throws {
    guard fileManager.fileExists(atPath: importedBundleDirectoryURL.path) else { return }
    var referenced: Set<String> = []
    if fileManager.fileExists(atPath: importIntentDirectoryURL.path) {
      for url in try fileManager.contentsOfDirectory(
        at: importIntentDirectoryURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      ) where url.lastPathComponent.hasSuffix(".intent.json") {
        let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
        let intent = try VHOSJSON.decoder().decode(ImportProvenanceIntent.self, from: bytes)
        guard try VHOSJSON.encoder().encode(intent) == bytes else {
          throw PortableFrameStoreError.invalidImportIntent
        }
        referenced.insert(intent.archiveFilename)
      }
    }
    if fileManager.fileExists(atPath: importReceiptDirectoryURL.path) {
      for url in try fileManager.contentsOfDirectory(
        at: importReceiptDirectoryURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      ) where url.pathExtension == "json" {
        let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
        if let receipt = try? VHOSJSON.decoder().decode(
          ImportProvenanceReceipt.self, from: bytes),
          (try? VHOSJSON.encoder().encode(receipt)) == bytes
        {
          referenced.insert(importedBundleURL(receipt).lastPathComponent)
          continue
        }
        let legacy = try VHOSJSON.decoder().decode(
          LegacyImportProvenanceReceiptV1.self, from: bytes)
        guard try VHOSJSON.encoder().encode(legacy) == bytes else {
          throw PortableFrameStoreError.invalidImportReceipt
        }
        referenced.insert(
          "bundle-\(legacy.bundleID.uuidString.lowercased())-\(legacy.archiveSHA256).vhossync")
      }
    }
    for url in try fileManager.contentsOfDirectory(
      at: importedBundleDirectoryURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) where url.pathExtension == "vhossync" && !referenced.contains(url.lastPathComponent) {
      try quarantineImportArtifact(url)
    }
  }

  private func quarantineImportArtifact(_ url: URL) throws {
    try fileManager.createDirectory(
      at: importOrphanDirectoryURL, withIntermediateDirectories: true)
    let digest = try Self.sha256(file: url)
    let destination = importOrphanDirectoryURL.appendingPathComponent(
      "\(url.lastPathComponent)-\(digest).preserved")
    if fileManager.fileExists(atPath: destination.path) {
      guard try Self.sha256(file: destination) == digest else {
        throw PortableFrameStoreError.recoveryArtifactConflict(destination.lastPathComponent)
      }
      try fileManager.removeItem(at: url)
    } else {
      try fileManager.moveItem(at: url, to: destination)
    }
    try synchronizeDirectory(url.deletingLastPathComponent())
    try synchronizeDirectory(importOrphanDirectoryURL)
  }

  private func importLineageArtifacts() throws -> [PortableEvidenceLineageArtifact] {
    guard fileManager.fileExists(atPath: importReceiptDirectoryURL.path) else { return [] }
    let receiptURLs = try fileManager.contentsOfDirectory(
      at: importReceiptDirectoryURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var artifacts: [PortableEvidenceLineageArtifact] = []
    for receiptURL in receiptURLs {
      let receiptBytes = try Data(contentsOf: receiptURL, options: [.mappedIfSafe])
      let receipt = try VHOSJSON.decoder().decode(
        ImportProvenanceReceipt.self, from: receiptBytes)
      let expectedRecordLinkChain = try Self.recordLinkChainSHA256(receipt.recordLinks)
      guard try VHOSJSON.encoder().encode(receipt) == receiptBytes,
        receipt.contract == "vhos.portable-evidence-import-receipt",
        receipt.contractVersion == "2.0.0",
        receipt.recordCount == receipt.recordLinks.count,
        receipt.recordLinkChainSHA256 == expectedRecordLinkChain
      else { throw PortableFrameStoreError.invalidImportReceipt }
      let archiveURL = importedBundleURL(receipt)
      guard try fileByteCount(archiveURL) <= EvidenceSyncBundle.maximumArchiveByteCount else {
        throw PortableFrameStoreError.invalidImportReceipt
      }
      let archive = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
      let bundle = try EvidenceSyncBundle.decode(archive)
      guard try Self.makeImportReceipt(bundle: bundle, archive: archive) == receipt else {
        throw PortableFrameStoreError.invalidImportReceipt
      }
      artifacts.append(
        PortableEvidenceLineageArtifact(
          url: archiveURL,
          contentType: "application/vnd.vhos.evidence-sync+zip",
          sha256: receipt.archiveSHA256,
          bundleID: receipt.bundleID))
      artifacts.append(
        PortableEvidenceLineageArtifact(
          url: receiptURL,
          contentType: "application/vnd.vhos.import-provenance-receipt+json",
          sha256: Self.sha256(receiptBytes),
          bundleID: receipt.bundleID))
    }
    return artifacts
  }

  private static func recordLinkChainSHA256(_ links: [ImportRecordLink]) throws -> String {
    var hasher = SHA256()
    for link in links {
      guard
        link.recordSHA256.range(
          of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
        !link.recordID.isEmpty, link.recordID.unicodeScalars.count <= 512
      else { throw PortableFrameStoreError.invalidImportReceipt }
      let encoded = try VHOSJSON.encoder().encode(link)
      var length = UInt64(encoded.count).bigEndian
      withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
      hasher.update(data: encoded)
    }
    return Data(hasher.finalize()).hexadecimalString
  }

  static func validateImportedLineage(receiptBytes: Data, archive: Data) throws -> UUID {
    let receipt = try VHOSJSON.decoder().decode(
      ImportProvenanceReceipt.self, from: receiptBytes)
    let expectedRecordLinkChainSHA256 = try recordLinkChainSHA256(receipt.recordLinks)
    guard try VHOSJSON.encoder().encode(receipt) == receiptBytes,
      receipt.contract == "vhos.portable-evidence-import-receipt",
      receipt.contractVersion == "2.0.0",
      receipt.recordCount == receipt.recordLinks.count,
      receipt.recordLinkChainSHA256 == expectedRecordLinkChainSHA256,
      receipt.archiveSHA256 == sha256(archive)
    else { throw PortableFrameStoreError.invalidImportReceipt }
    let bundle = try EvidenceSyncBundle.decode(archive)
    guard try makeImportReceipt(bundle: bundle, archive: archive) == receipt else {
      throw PortableFrameStoreError.invalidImportReceipt
    }
    return receipt.bundleID
  }

  private struct ImportLineageSourceMetadata {
    let bundleID: UUID
    let archiveSHA256: String
    let receiptURL: URL
    let receiptByteCount: Int
    let archiveURL: URL
    let archiveByteCount: Int
  }

  private func importLineageSourceMetadata() throws -> [ImportLineageSourceMetadata] {
    guard fileManager.fileExists(atPath: importReceiptDirectoryURL.path) else { return [] }
    let receiptURLs = try fileManager.contentsOfDirectory(
      at: importReceiptDirectoryURL,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
      options: [.skipsHiddenFiles]
    )
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var result: [ImportLineageSourceMetadata] = []
    for receiptURL in receiptURLs {
      let name = receiptURL.lastPathComponent
      guard name.hasPrefix("bundle-"), name.hasSuffix(".json"),
        let bundleID = UUID(
          uuidString: String(name.dropFirst("bundle-".count).dropLast(".json".count)))
      else { throw PortableFrameStoreError.invalidImportReceipt }
      let prefix = "bundle-\(bundleID.uuidString.lowercased())-"
      let candidates = try fileManager.contentsOfDirectory(
        at: importedBundleDirectoryURL,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
      )
      .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "vhossync" }
      guard candidates.count == 1 else { throw PortableFrameStoreError.invalidImportReceipt }
      let archiveURL = candidates[0]
      let archiveName = archiveURL.deletingPathExtension().lastPathComponent
      let archiveSHA256 = String(archiveName.dropFirst(prefix.count))
      guard
        archiveSHA256.range(
          of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
      else {
        throw PortableFrameStoreError.invalidImportReceipt
      }
      let receiptByteCount = try fileByteCount(receiptURL)
      let archiveByteCount = try fileByteCount(archiveURL)
      guard receiptByteCount > 0,
        receiptByteCount <= Self.productionImportReceiptByteLimit,
        archiveByteCount > 0,
        archiveByteCount <= EvidenceSyncBundle.maximumArchiveByteCount
      else { throw PortableFrameStoreError.invalidImportReceipt }
      result.append(
        ImportLineageSourceMetadata(
          bundleID: bundleID,
          archiveSHA256: archiveSHA256,
          receiptURL: receiptURL,
          receiptByteCount: receiptByteCount,
          archiveURL: archiveURL,
          archiveByteCount: archiveByteCount))
    }
    return result
  }

  private struct GenerationSource {
    let ordinal: Int
    let url: URL
    let digest: String
    let byteCount: Int
    let sealed: Bool
  }

  private struct SealedGeneration {
    let ordinal: Int
    let digest: String
    let url: URL
  }

  private struct GenerationIntegrityReceipt: Equatable {
    let ordinal: Int
    let digest: String
  }

  private struct LedgerStatistics {
    let bytes: Int
    let records: Int
    let chain: Data

    static let empty = LedgerStatistics(bytes: 0, records: 0, chain: Data())

    func appending(_ committedLine: Data) -> LedgerStatistics {
      var hasher = SHA256()
      hasher.update(data: chain)
      hasher.update(data: committedLine)
      return LedgerStatistics(
        bytes: bytes + committedLine.count,
        records: records + 1,
        chain: Data(hasher.finalize())
      )
    }
  }

  private struct InterruptedTailReceipt: Codable {
    let contract: String
    let contractVersion: String
    let originalLedgerSHA256: String
    let committedPrefixByteCount: Int
    let interruptedTailByteCount: Int
    let interruptedTailSHA256: String
  }

  private struct LegacyMigrationState: Codable, Equatable {
    let contract: String
    let contractVersion: String
    let sourceFileName: String
    let sourceLedgerSHA256: String
    let sourceByteCount: Int

    private enum CodingKeys: String, CodingKey {
      case contract
      case contractVersion
      case sourceFileName
      case sourceLedgerSHA256 = "sourceLedgerSha256"
      case sourceByteCount
    }
  }

  private struct AnchoredV1MigrationState: Codable, Equatable {
    let contract: String
    let contractVersion: String
    let sourceFileName: String
    let sourceLedgerSHA256: String
    let sourceByteCount: Int
    let baseGenerationCount: Int
    let baseGenerationInventorySHA256: String

    private enum CodingKeys: String, CodingKey {
      case contract
      case contractVersion
      case sourceFileName
      case sourceLedgerSHA256 = "sourceLedgerSha256"
      case sourceByteCount
      case baseGenerationCount
      case baseGenerationInventorySHA256 = "baseGenerationInventorySha256"
    }
  }

  private func generationSources(
    verifySealedFileHashes: Bool = true
  ) throws -> [GenerationSource] {
    var sources: [GenerationSource] = []
    let sealed = try sealedGenerations()
    for generation in sealed {
      let digest: String
      if verifySealedFileHashes {
        digest = try Self.sha256(file: generation.url)
        guard digest == generation.digest else {
          throw PortableFrameStoreError.sealedGenerationHashMismatch(
            generation.url.lastPathComponent)
        }
      } else {
        digest = generation.digest
      }
      let byteCount = try fileByteCount(generation.url)
      sources.append(
        GenerationSource(
          ordinal: generation.ordinal,
          url: generation.url,
          digest: digest,
          byteCount: byteCount,
          sealed: true
        ))
    }
    if fileManager.fileExists(atPath: framesURL.path) {
      let byteCount = try fileByteCount(framesURL)
      if byteCount > 0 {
        guard (sealed.last?.ordinal ?? 0) < Self.maximumGenerationOrdinal else {
          throw PortableFrameStoreError.generationOrdinalOverflow
        }
        sources.append(
          GenerationSource(
            ordinal: (sealed.last?.ordinal ?? 0) + 1,
            url: framesURL,
            digest: try Self.sha256(file: framesURL),
            byteCount: byteCount,
            sealed: false
          ))
      }
    }
    return sources
  }

  private func sealedGenerations() throws -> [SealedGeneration] {
    guard fileManager.fileExists(atPath: root.path) else { return [] }
    let urls = try fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
    let regex = try NSRegularExpression(pattern: Self.sealedPattern)
    var generations: [SealedGeneration] = []
    for url in urls where url.lastPathComponent.hasPrefix(Self.sealedPrefix) {
      let name = url.lastPathComponent
      let range = NSRange(name.startIndex..<name.endIndex, in: name)
      guard let match = regex.firstMatch(in: name, range: range), match.range == range,
        let ordinalRange = Range(match.range(at: 1), in: name),
        let digestRange = Range(match.range(at: 2), in: name),
        let ordinal = Int(name[ordinalRange]),
        ordinal > 0
      else { throw PortableFrameStoreError.invalidGenerationFileName(name) }
      generations.append(
        SealedGeneration(
          ordinal: ordinal,
          digest: String(name[digestRange]),
          url: url
        ))
    }
    generations.sort { $0.ordinal < $1.ordinal }
    for (offset, generation) in generations.enumerated() {
      let expected = offset + 1
      guard generation.ordinal == expected else {
        throw PortableFrameStoreError.missingGenerationOrdinal(
          expected: expected, found: generation.ordinal)
      }
    }
    return try validateGenerationInventory(generations)
  }

  private func sealActiveGeneration() throws {
    guard fileManager.fileExists(atPath: framesURL.path) else { return }
    let statistics = try activeStatistics()
    guard statistics.bytes > 0 else { return }
    let sealed = try sealedGenerations()
    let previousOrdinal = sealed.last?.ordinal ?? 0
    guard previousOrdinal < Self.maximumGenerationOrdinal else {
      throw PortableFrameStoreError.generationOrdinalOverflow
    }
    let ordinal = previousOrdinal + 1
    let digest = try Self.sha256(file: framesURL)
    let destination = root.appendingPathComponent(
      Self.sealedPrefix + String(format: "%012d", ordinal) + "-\(digest).ndjson")
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw PortableFrameStoreError.generationDestinationExists(destination.lastPathComponent)
    }
    try fileManager.moveItem(at: framesURL, to: destination)
    try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
    try synchronizeFile(destination)
    try synchronizeDirectory(root)
    try writeGenerationIntegrityManifest(
      sealed
        + [SealedGeneration(ordinal: ordinal, digest: digest, url: destination)])
    try writeGenerationHighWater(ordinal)
    cachedActiveStatistics = .empty
    if let recordIndex {
      try recordIndex.commitInventory(
        fingerprint: try inventoryFingerprint(active: .empty),
        recordCount: try recordIndex.count()
      )
    }
  }

  private func activeStatistics() throws -> LedgerStatistics {
    if let cachedActiveStatistics { return cachedActiveStatistics }
    guard fileManager.fileExists(atPath: framesURL.path) else {
      cachedActiveStatistics = .empty
      return .empty
    }
    try recoverInterruptedActiveTailIfNeeded()
    let statistics = try scanLedger(at: framesURL, expectedDigest: nil) { _ in }
    cachedActiveStatistics = statistics
    return statistics
  }

  private func decodeLedger(_ source: GenerationSource) throws -> [PortableLogicalFrame] {
    var records: [PortableLogicalFrame] = []
    _ = try scanLedger(
      at: source.url,
      expectedDigest: source.sealed ? source.digest : nil
    ) { record in
      records.append(record)
    }
    return records
  }

  @discardableResult
  private func scanLedger(
    at url: URL,
    expectedDigest: String?,
    onRecord: (PortableLogicalFrame) throws -> Void
  ) throws -> LedgerStatistics {
    try scanLedgerLines(at: url, expectedDigest: expectedDigest) { record, _ in
      if let record { try onRecord(record) }
    }
  }

  @discardableResult
  private func scanLedgerLines(
    at url: URL,
    expectedDigest: String?,
    onCommittedLine: (PortableLogicalFrame?, Data) throws -> Void
  ) throws -> LedgerStatistics {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var fileHasher = SHA256()
    var pending = Data()
    var statistics = LedgerStatistics.empty
    while true {
      let chunk = try handle.read(upToCount: 64 * 1_024) ?? Data()
      if chunk.isEmpty { break }
      fileHasher.update(data: chunk)
      pending.append(chunk)
      while let newline = pending.firstIndex(of: 0x0A) {
        let line = Data(pending[..<newline])
        let committedLine = Data(pending[...newline])
        pending.removeSubrange(...newline)
        guard committedLine.count <= generationByteLimit else {
          throw PortableFrameStoreError.recordExceedsGenerationLimit
        }
        guard !line.isEmpty else {
          throw PortableFrameStoreError.nonCanonicalCommittedRecord(url.lastPathComponent)
        }
        let record = try EvidenceSyncBundle.decodeRecord(line)
        guard try VHOSJSON.encoder().encode(record) == line else {
          throw PortableFrameStoreError.nonCanonicalCommittedRecord(url.lastPathComponent)
        }
        try onCommittedLine(record, committedLine)
        statistics = statistics.appending(committedLine)
      }
      guard pending.count <= generationByteLimit else {
        throw PortableFrameStoreError.recordExceedsGenerationLimit
      }
    }
    guard pending.isEmpty else { throw PortableFrameStoreError.uncommittedLedgerTail }
    let digest = Data(fileHasher.finalize()).hexadecimalString
    if let expectedDigest, digest != expectedDigest {
      throw PortableFrameStoreError.sealedGenerationHashMismatch(url.lastPathComponent)
    }
    return statistics
  }

  private func ensuredRecordIndex() throws -> PortableRecordIndex {
    if let recordIndex { return recordIndex }
    let sealed = try sealedGenerations()
    for generation in sealed {
      guard try Self.sha256(file: generation.url) == generation.digest else {
        throw PortableFrameStoreError.sealedGenerationHashMismatch(generation.url.lastPathComponent)
      }
    }
    let active = try activeStatistics()
    let fingerprint = try inventoryFingerprint(active: active)
    let index = try PortableRecordIndex(url: indexURL)
    if try index.isUsable(fingerprint: fingerprint) {
      recordIndex = index
      return index
    }

    try index.beginRebuild()
    do {
      for generation in sealed {
        _ = try scanLedger(at: generation.url, expectedDigest: generation.digest) { record in
          try index.insert(
            record.id,
            recordSHA256: try Self.canonicalRecordDigest(record),
            sourceRole: record.sourceRole.rawValue,
            generationOrdinal: generation.ordinal)
        }
      }
      if active.bytes > 0 {
        let ordinal = (sealed.last?.ordinal ?? 0) + 1
        _ = try scanLedger(at: framesURL, expectedDigest: nil) { record in
          try index.insert(
            record.id,
            recordSHA256: try Self.canonicalRecordDigest(record),
            sourceRole: record.sourceRole.rawValue,
            generationOrdinal: ordinal)
        }
      }
      try index.finishRebuild(
        fingerprint: fingerprint,
        recordCount: try index.count()
      )
    } catch {
      index.cancelRebuild()
      throw error
    }
    recordIndex = index
    return index
  }

  private func inventoryFingerprint(active: LedgerStatistics) throws -> String {
    let sealed = try sealedGenerations()
    var bytes = Data("vhos.portable-record-index/1\n".utf8)
    for generation in sealed {
      bytes.append(
        Data(
          "sealed:\(generation.ordinal):\(generation.digest)\n".utf8
        ))
    }
    bytes.append(
      Data(
        "active:\((sealed.last?.ordinal ?? 0) + 1):\(active.bytes):\(active.records):\(active.chain.hexadecimalString)\n"
          .utf8
      ))
    return Self.sha256(bytes)
  }

  private func nextActiveOrdinal() throws -> Int {
    let previous = try sealedGenerations().last?.ordinal ?? 0
    guard previous < Self.maximumGenerationOrdinal else {
      throw PortableFrameStoreError.generationOrdinalOverflow
    }
    return previous + 1
  }

  private func validateGenerationInventory(_ diskGenerations: [SealedGeneration]) throws
    -> [SealedGeneration]
  {
    var observed = diskGenerations
    let anchorExists = fileManager.fileExists(atPath: inventoryAnchorURL.path)
    let highWaterExists = fileManager.fileExists(atPath: highWaterURL.path)
    let manifestExists = fileManager.fileExists(atPath: integrityManifestURL.path)
    if !anchorExists {
      let migrationStateExists = fileManager.fileExists(atPath: legacyMigrationStateURL.path)
      let initializedStateExists = durableInitializedStateExists()
      // Check every durable sign of an initialized store before tail recovery, file moves, or
      // legacy splitting. Missing an anchor in such a store is evidence deletion, not permission
      // to mutate the active ledger. Only an already content-bound migration state may resume.
      guard !initializedStateExists || migrationStateExists else {
        throw PortableFrameStoreError.missingGenerationInventoryReceipt
      }
      if highWaterExists || manifestExists, !migrationStateExists {
        let activeHasBytes: Bool
        if fileManager.fileExists(atPath: framesURL.path) {
          activeHasBytes = try fileByteCount(framesURL) > 0
        } else {
          activeHasBytes = false
        }
        guard observed.isEmpty, !activeHasBytes else {
          throw PortableFrameStoreError.missingGenerationInventoryReceipt
        }
        if highWaterExists, try readGenerationHighWater() != 0 {
          throw PortableFrameStoreError.invalidGenerationInventoryReceipt
        }
        if manifestExists {
          try verifyIntegrityReceipts(
            try readGenerationIntegrityManifest(), against: [], requireEqualCount: true)
        }
      }
      observed = try migrateLegacyActiveLedgerIfNeeded(observed)
      // A fresh store writes both empty receipts before publishing the v2 anchor. Existing
      // generations cannot be rebaselined without a content-bound migration receipt.
      if highWaterExists {
        guard try readGenerationHighWater() == observed.count else {
          throw PortableFrameStoreError.invalidGenerationInventoryReceipt
        }
      } else {
        try writeGenerationHighWater(observed.count)
      }
      if manifestExists {
        try verifyIntegrityReceipts(
          try readGenerationIntegrityManifest(), against: observed, requireEqualCount: true)
      } else {
        try writeGenerationIntegrityManifest(observed)
      }
      try writeInventoryAnchor(Self.inventoryAnchorV2)
      return observed
    }

    guard highWaterExists else {
      throw PortableFrameStoreError.missingGenerationInventoryReceipt
    }
    let anchor = try readInventoryAnchor()
    switch anchor {
    case Self.inventoryAnchorV1:
      observed = try migrateLegacyGenerationInventory(observed, manifestExists: manifestExists)
    case Self.inventoryAnchorV2:
      try validateContentBoundGenerationInventory(observed, manifestExists: manifestExists)
    default:
      throw PortableFrameStoreError.invalidGenerationInventoryReceipt
    }
    return observed
  }

  private func migrateLegacyGenerationInventory(
    _ observed: [SealedGeneration], manifestExists: Bool
  ) throws -> [SealedGeneration] {
    let highWater = try readGenerationHighWater()
    let migrationInProgress = fileManager.fileExists(atPath: anchoredV1MigrationStateURL.path)
    if !migrationInProgress {
      guard observed.count == highWater || observed.count == highWater + 1 else {
        if observed.count < highWater {
          throw PortableFrameStoreError.missingTrailingGeneration(
            expectedHighWater: highWater, observedHighWater: observed.count)
        }
        throw PortableFrameStoreError.unboundGenerationSuffix
      }
    } else if observed.count < highWater {
      throw PortableFrameStoreError.missingTrailingGeneration(
        expectedHighWater: highWater, observedHighWater: observed.count)
    }
    // Bind only content that still agrees with its content-addressed filename. This migration can
    // happen exactly once from the ordinal-only release; every subsequent restart uses v2.
    for generation in observed {
      try validateBoundedLegacyGeneration(generation)
    }
    let migrated = try migrateOversizedAnchoredV1ActiveLedgerIfNeeded(observed)
    if manifestExists {
      try verifyIntegrityReceipts(
        try readGenerationIntegrityManifest(), against: migrated, requireEqualCount: true)
    } else {
      try writeGenerationIntegrityManifest(migrated)
    }
    if migrated.count > highWater { try writeGenerationHighWater(migrated.count) }
    try writeInventoryAnchor(Self.inventoryAnchorV2)
    return migrated
  }

  private func validateBoundedLegacyGeneration(_ generation: SealedGeneration) throws {
    guard try fileByteCount(generation.url) <= generationByteLimit else {
      throw PortableFrameStoreError.legacyGenerationExceedsBound(
        generation.url.lastPathComponent)
    }
    let statistics = try scanLedger(at: generation.url, expectedDigest: generation.digest) { _ in }
    guard statistics.records <= generationRecordLimit else {
      throw PortableFrameStoreError.legacyGenerationExceedsBound(
        generation.url.lastPathComponent)
    }
  }

  private func validateContentBoundGenerationInventory(
    _ observed: [SealedGeneration], manifestExists: Bool
  ) throws {
    guard manifestExists else {
      throw PortableFrameStoreError.missingGenerationIntegrityManifest
    }
    var receipts = try readGenerationIntegrityManifest()
    let highWater = try readGenerationHighWater()
    guard receipts.count == highWater || receipts.count == highWater + 1 else {
      throw PortableFrameStoreError.invalidGenerationIntegrityManifest
    }
    guard observed.count >= receipts.count else {
      throw PortableFrameStoreError.missingTrailingGeneration(
        expectedHighWater: receipts.count, observedHighWater: observed.count)
    }
    try verifyIntegrityReceipts(receipts, against: observed, requireEqualCount: false)

    if observed.count > receipts.count {
      // The only unreceipted suffix a power loss can produce is the single active-ledger move
      // immediately following the bound prefix. Verify its bytes before completing the receipt.
      guard observed.count == receipts.count + 1, highWater == receipts.count,
        let generation = observed.last
      else { throw PortableFrameStoreError.unboundGenerationSuffix }
      guard try Self.sha256(file: generation.url) == generation.digest else {
        throw PortableFrameStoreError.sealedGenerationHashMismatch(
          generation.url.lastPathComponent)
      }
      try writeGenerationIntegrityManifest(observed)
      receipts.append(
        GenerationIntegrityReceipt(ordinal: generation.ordinal, digest: generation.digest))
    }
    if highWater < receipts.count { try writeGenerationHighWater(receipts.count) }
  }

  private func verifyIntegrityReceipts(
    _ receipts: [GenerationIntegrityReceipt],
    against observed: [SealedGeneration],
    requireEqualCount: Bool
  ) throws {
    if requireEqualCount, receipts.count != observed.count {
      throw PortableFrameStoreError.invalidGenerationIntegrityManifest
    }
    for receipt in receipts {
      guard observed.indices.contains(receipt.ordinal - 1) else {
        throw PortableFrameStoreError.missingTrailingGeneration(
          expectedHighWater: receipt.ordinal, observedHighWater: observed.count)
      }
      let generation = observed[receipt.ordinal - 1]
      guard generation.digest == receipt.digest else {
        throw PortableFrameStoreError.generationIntegrityDigestMismatch(
          ordinal: receipt.ordinal,
          expected: receipt.digest,
          observed: generation.digest)
      }
    }
  }

  private func readInventoryAnchor() throws -> String {
    let bytes = try Data(contentsOf: inventoryAnchorURL, options: [.mappedIfSafe])
    guard let value = String(data: bytes, encoding: .utf8) else {
      throw PortableFrameStoreError.invalidGenerationInventoryReceipt
    }
    return value
  }

  private func writeInventoryAnchor(_ value: String) throws {
    let bytes = Data(value.utf8)
    if fileManager.fileExists(atPath: inventoryAnchorURL.path) {
      try replacePreserved(bytes, at: inventoryAnchorURL)
    } else {
      try writePreserved(bytes, to: inventoryAnchorURL)
    }
    try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: inventoryAnchorURL.path)
  }

  private func readGenerationIntegrityManifest() throws -> [GenerationIntegrityReceipt] {
    let bytes = try Data(contentsOf: integrityManifestURL, options: [.mappedIfSafe])
    guard let value = String(data: bytes, encoding: .utf8), value.last == "\n" else {
      throw PortableFrameStoreError.invalidGenerationIntegrityManifest
    }
    var lines = value.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.popLast() == "", lines.first == "vhos.portable-generation-integrity/1" else {
      throw PortableFrameStoreError.invalidGenerationIntegrityManifest
    }
    lines.removeFirst()
    var receipts: [GenerationIntegrityReceipt] = []
    for (offset, line) in lines.enumerated() {
      let fields = line.split(separator: " ", omittingEmptySubsequences: false)
      let expectedOrdinal = offset + 1
      guard fields.count == 2,
        fields[0] == Substring(String(format: "%012d", expectedOrdinal)),
        fields[1].range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
      else { throw PortableFrameStoreError.invalidGenerationIntegrityManifest }
      receipts.append(
        GenerationIntegrityReceipt(ordinal: expectedOrdinal, digest: String(fields[1])))
    }
    return receipts
  }

  private func writeGenerationIntegrityManifest(_ generations: [SealedGeneration]) throws {
    var value = Self.integrityManifestHeader
    for (offset, generation) in generations.enumerated() {
      guard generation.ordinal == offset + 1,
        generation.digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
      else { throw PortableFrameStoreError.invalidGenerationIntegrityManifest }
      value += String(format: "%012d", generation.ordinal) + " " + generation.digest + "\n"
    }
    let bytes = Data(value.utf8)
    if fileManager.fileExists(atPath: integrityManifestURL.path) {
      try replacePreserved(bytes, at: integrityManifestURL)
    } else {
      try writePreserved(bytes, to: integrityManifestURL)
    }
    try fileManager.setAttributes(
      [.posixPermissions: 0o400], ofItemAtPath: integrityManifestURL.path)
  }

  private func migrateLegacyActiveLedgerIfNeeded(_ observed: [SealedGeneration]) throws
    -> [SealedGeneration]
  {
    if fileManager.fileExists(atPath: legacyMigrationStateURL.path) {
      let state = try readLegacyMigrationState()
      return try publishLegacyMigration(state: state, existing: observed)
    }
    guard observed.isEmpty else {
      throw PortableFrameStoreError.missingGenerationInventoryReceipt
    }
    guard fileManager.fileExists(atPath: framesURL.path) else { return observed }

    do {
      try recoverInterruptedActiveTailIfNeeded()
    } catch {
      _ = try? preserveLegacyFile(
        at: framesURL,
        in: legacyQuarantineDirectoryURL,
        prefix: "invalid-legacy-active-ledger")
      throw error
    }

    let statistics: LedgerStatistics
    do {
      statistics = try scanLedger(at: framesURL, expectedDigest: nil) { _ in }
    } catch {
      _ = try? preserveLegacyFile(
        at: framesURL,
        in: legacyQuarantineDirectoryURL,
        prefix: "invalid-legacy-active-ledger")
      throw error
    }
    guard
      statistics.bytes > generationByteLimit
        || statistics.records > generationRecordLimit
    else { return observed }

    let source = try preserveLegacyFile(
      at: framesURL,
      in: legacyMigrationDirectoryURL,
      prefix: "legacy-active-ledger")
    let state = LegacyMigrationState(
      contract: "vhos.portable-legacy-ledger-migration",
      contractVersion: "1.0.0",
      sourceFileName: source.url.lastPathComponent,
      sourceLedgerSHA256: source.digest,
      sourceByteCount: source.byteCount)
    try writePreserved(try VHOSJSON.encoder().encode(state), to: legacyMigrationStateURL)
    return try publishLegacyMigration(state: state, existing: observed)
  }

  private func readLegacyMigrationState() throws -> LegacyMigrationState {
    let bytes = try Data(contentsOf: legacyMigrationStateURL, options: [.mappedIfSafe])
    let state = try VHOSJSON.decoder().decode(LegacyMigrationState.self, from: bytes)
    guard state.contract == "vhos.portable-legacy-ledger-migration",
      state.contractVersion == "1.0.0",
      state.sourceLedgerSHA256.range(
        of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
      state.sourceByteCount > 0,
      state.sourceFileName
        == "legacy-active-ledger-\(state.sourceLedgerSHA256).ndjson"
    else { throw PortableFrameStoreError.invalidLegacyMigrationState }
    let source = legacyMigrationDirectoryURL.appendingPathComponent(state.sourceFileName)
    guard fileManager.fileExists(atPath: source.path),
      try fileByteCount(source) == state.sourceByteCount,
      try Self.sha256(file: source) == state.sourceLedgerSHA256
    else { throw PortableFrameStoreError.invalidLegacyMigrationState }
    return state
  }

  private func publishLegacyMigration(
    state: LegacyMigrationState,
    existing: [SealedGeneration]
  ) throws -> [SealedGeneration] {
    let source = legacyMigrationDirectoryURL.appendingPathComponent(state.sourceFileName)
    guard try fileByteCount(source) == state.sourceByteCount,
      try Self.sha256(file: source) == state.sourceLedgerSHA256
    else { throw PortableFrameStoreError.invalidLegacyMigrationState }

    if fileManager.fileExists(atPath: legacyMigrationStagingURL.path) {
      // Staging is derived and replayable from the immutable preserved source. It is never the
      // sole evidence copy, so an interrupted attempt can be safely reconstructed.
      try fileManager.removeItem(at: legacyMigrationStagingURL)
    }
    try fileManager.createDirectory(
      at: legacyMigrationStagingURL, withIntermediateDirectories: true)
    let segments = try splitLegacyLedger(at: source, stagingAt: legacyMigrationStagingURL)
    guard segments.count >= 2 else {
      throw PortableFrameStoreError.invalidLegacyMigrationState
    }
    let sealedCount = segments.count - 1
    guard existing.count <= sealedCount else {
      throw PortableFrameStoreError.unboundGenerationSuffix
    }

    var published: [SealedGeneration] = []
    for (offset, segment) in segments.dropLast().enumerated() {
      let ordinal = offset + 1
      let digest = try Self.sha256(file: segment)
      let destination = root.appendingPathComponent(
        Self.sealedPrefix + String(format: "%012d", ordinal) + "-\(digest).ndjson")
      if existing.indices.contains(offset) {
        let generation = existing[offset]
        guard generation.ordinal == ordinal, generation.digest == digest,
          generation.url == destination,
          try Self.sha256(file: generation.url) == digest
        else {
          throw PortableFrameStoreError.generationIntegrityDigestMismatch(
            ordinal: ordinal,
            expected: digest,
            observed: generation.digest)
        }
      } else if fileManager.fileExists(atPath: destination.path) {
        guard try Self.sha256(file: destination) == digest else {
          throw PortableFrameStoreError.sealedGenerationHashMismatch(
            destination.lastPathComponent)
        }
      } else {
        try fileManager.moveItem(at: segment, to: destination)
      }
      try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
      published.append(
        SealedGeneration(ordinal: ordinal, digest: digest, url: destination))
    }

    guard let activeSegment = segments.last else {
      throw PortableFrameStoreError.invalidLegacyMigrationState
    }
    if fileManager.fileExists(atPath: framesURL.path) { try fileManager.removeItem(at: framesURL) }
    try fileManager.moveItem(at: activeSegment, to: framesURL)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: framesURL.path)
    cachedActiveStatistics = nil
    try? fileManager.removeItem(at: legacyMigrationStagingURL)
    return published
  }

  private func migrateOversizedAnchoredV1ActiveLedgerIfNeeded(
    _ observed: [SealedGeneration]
  ) throws -> [SealedGeneration] {
    if fileManager.fileExists(atPath: anchoredV1MigrationStateURL.path) {
      return try publishAnchoredV1ActiveMigration(
        state: try readAnchoredV1MigrationState(), existing: observed)
    }
    guard fileManager.fileExists(atPath: framesURL.path) else { return observed }

    do {
      try recoverInterruptedActiveTailIfNeeded()
    } catch {
      _ = try? preserveLegacyFile(
        at: framesURL,
        in: legacyQuarantineDirectoryURL,
        prefix: "invalid-v1-active-ledger")
      throw error
    }
    let statistics: LedgerStatistics
    do {
      statistics = try scanLedger(at: framesURL, expectedDigest: nil) { _ in }
    } catch {
      _ = try? preserveLegacyFile(
        at: framesURL,
        in: legacyQuarantineDirectoryURL,
        prefix: "invalid-v1-active-ledger")
      throw error
    }
    guard
      statistics.bytes > generationByteLimit
        || statistics.records > generationRecordLimit
    else { return observed }

    let source = try preserveLegacyFile(
      at: framesURL,
      in: anchoredV1MigrationDirectoryURL,
      prefix: "v1-active-ledger")
    let state = AnchoredV1MigrationState(
      contract: "vhos.portable-v1-active-ledger-migration",
      contractVersion: "1.0.0",
      sourceFileName: source.url.lastPathComponent,
      sourceLedgerSHA256: source.digest,
      sourceByteCount: source.byteCount,
      baseGenerationCount: observed.count,
      baseGenerationInventorySHA256: generationInventoryDigest(observed)
    )
    try writePreserved(try VHOSJSON.encoder().encode(state), to: anchoredV1MigrationStateURL)
    return try publishAnchoredV1ActiveMigration(state: state, existing: observed)
  }

  private func readAnchoredV1MigrationState() throws -> AnchoredV1MigrationState {
    let bytes = try Data(contentsOf: anchoredV1MigrationStateURL, options: [.mappedIfSafe])
    let state = try VHOSJSON.decoder().decode(AnchoredV1MigrationState.self, from: bytes)
    guard state.contract == "vhos.portable-v1-active-ledger-migration",
      state.contractVersion == "1.0.0",
      state.sourceLedgerSHA256.range(
        of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
      state.baseGenerationInventorySHA256.range(
        of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
      state.sourceByteCount > 0,
      (0...Self.maximumGenerationOrdinal).contains(state.baseGenerationCount),
      state.sourceFileName == "v1-active-ledger-\(state.sourceLedgerSHA256).ndjson"
    else { throw PortableFrameStoreError.invalidAnchoredV1MigrationState }
    let source = anchoredV1MigrationDirectoryURL.appendingPathComponent(state.sourceFileName)
    guard fileManager.fileExists(atPath: source.path),
      try fileByteCount(source) == state.sourceByteCount,
      try Self.sha256(file: source) == state.sourceLedgerSHA256
    else { throw PortableFrameStoreError.invalidAnchoredV1MigrationState }
    return state
  }

  private func publishAnchoredV1ActiveMigration(
    state: AnchoredV1MigrationState,
    existing: [SealedGeneration]
  ) throws -> [SealedGeneration] {
    guard existing.count >= state.baseGenerationCount else {
      throw PortableFrameStoreError.invalidAnchoredV1MigrationState
    }
    let base = Array(existing.prefix(state.baseGenerationCount))
    guard generationInventoryDigest(base) == state.baseGenerationInventorySHA256 else {
      throw PortableFrameStoreError.invalidAnchoredV1MigrationState
    }
    for generation in base {
      try validateBoundedLegacyGeneration(generation)
    }

    let source = anchoredV1MigrationDirectoryURL.appendingPathComponent(state.sourceFileName)
    guard try fileByteCount(source) == state.sourceByteCount,
      try Self.sha256(file: source) == state.sourceLedgerSHA256
    else { throw PortableFrameStoreError.invalidAnchoredV1MigrationState }
    if fileManager.fileExists(atPath: anchoredV1MigrationStagingURL.path) {
      try fileManager.removeItem(at: anchoredV1MigrationStagingURL)
    }
    try fileManager.createDirectory(
      at: anchoredV1MigrationStagingURL, withIntermediateDirectories: true)
    let segments = try splitLegacyLedger(
      at: source, stagingAt: anchoredV1MigrationStagingURL)
    guard segments.count >= 2 else {
      throw PortableFrameStoreError.invalidAnchoredV1MigrationState
    }
    let suffixCount = segments.count - 1
    let finalSealedCount = state.baseGenerationCount + suffixCount
    guard existing.count <= finalSealedCount,
      finalSealedCount <= Self.maximumGenerationOrdinal
    else { throw PortableFrameStoreError.unboundGenerationSuffix }

    var published = base
    for (offset, segment) in segments.dropLast().enumerated() {
      let ordinal = state.baseGenerationCount + offset + 1
      let digest = try Self.sha256(file: segment)
      let destination = root.appendingPathComponent(
        Self.sealedPrefix + String(format: "%012d", ordinal) + "-\(digest).ndjson")
      if existing.indices.contains(ordinal - 1) {
        let generation = existing[ordinal - 1]
        guard generation.ordinal == ordinal, generation.digest == digest,
          generation.url == destination,
          try Self.sha256(file: generation.url) == digest
        else {
          throw PortableFrameStoreError.generationIntegrityDigestMismatch(
            ordinal: ordinal,
            expected: digest,
            observed: generation.digest)
        }
      } else if fileManager.fileExists(atPath: destination.path) {
        guard try Self.sha256(file: destination) == digest else {
          throw PortableFrameStoreError.sealedGenerationHashMismatch(
            destination.lastPathComponent)
        }
      } else {
        try fileManager.moveItem(at: segment, to: destination)
      }
      try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
      published.append(
        SealedGeneration(ordinal: ordinal, digest: digest, url: destination))
    }

    guard let activeSegment = segments.last else {
      throw PortableFrameStoreError.invalidAnchoredV1MigrationState
    }
    if fileManager.fileExists(atPath: framesURL.path) { try fileManager.removeItem(at: framesURL) }
    try fileManager.moveItem(at: activeSegment, to: framesURL)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: framesURL.path)
    cachedActiveStatistics = nil
    try? fileManager.removeItem(at: anchoredV1MigrationStagingURL)
    return published
  }

  private func generationInventoryDigest(_ generations: [SealedGeneration]) -> String {
    var bytes = Data("vhos.portable-v1-migration-base/1\n".utf8)
    for generation in generations {
      bytes.append(Data("\(generation.ordinal):\(generation.digest)\n".utf8))
    }
    return Self.sha256(bytes)
  }

  private func splitLegacyLedger(at source: URL, stagingAt stagingURL: URL) throws -> [URL] {
    var segments: [URL] = []
    var handle: FileHandle?
    var bytes = 0
    var records = 0

    func openSegment() throws {
      let url = stagingURL.appendingPathComponent(
        String(format: "segment-%012d.ndjson", segments.count + 1))
      guard fileManager.createFile(atPath: url.path, contents: nil) else {
        throw PortableFrameStoreError.createFailed
      }
      handle = try FileHandle(forWritingTo: url)
      segments.append(url)
      bytes = 0
      records = 0
    }

    func closeSegment() throws {
      guard let current = handle else { return }
      try current.synchronize()
      try current.close()
      handle = nil
    }

    do {
      _ = try scanLedgerLines(at: source, expectedDigest: stateDigest(of: source)) {
        record, line in
        let recordIncrement = record == nil ? 0 : 1
        let exceedsCurrent =
          bytes > 0
          && (bytes > generationByteLimit - line.count
            || (recordIncrement == 1 && records >= generationRecordLimit))
        if exceedsCurrent { try closeSegment() }
        if handle == nil { try openSegment() }
        try handle?.write(contentsOf: line)
        bytes += line.count
        records += recordIncrement
      }
      try closeSegment()
    } catch {
      try? closeSegment()
      throw error
    }
    return segments
  }

  private func stateDigest(of source: URL) throws -> String { try Self.sha256(file: source) }

  private func preserveLegacyFile(at source: URL, in directory: URL, prefix: String) throws -> (
    url: URL, digest: String, byteCount: Int
  ) {
    let digest = try Self.sha256(file: source)
    let byteCount = try fileByteCount(source)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent("\(prefix)-\(digest).ndjson")
    if fileManager.fileExists(atPath: destination.path) {
      guard try fileByteCount(destination) == byteCount,
        try Self.sha256(file: destination) == digest
      else { throw PortableFrameStoreError.recoveryArtifactConflict(destination.lastPathComponent) }
    } else {
      try copyFilePreserved(
        from: source,
        offset: 0,
        count: byteCount,
        expectedDigest: digest,
        to: destination)
    }
    return (destination, digest, byteCount)
  }

  private func readGenerationHighWater() throws -> Int {
    let bytes = try Data(contentsOf: highWaterURL, options: [.mappedIfSafe])
    guard let value = String(data: bytes, encoding: .utf8), value.last == "\n",
      let ordinal = Int(value.dropLast()),
      (0...Self.maximumGenerationOrdinal).contains(ordinal),
      String(ordinal) == value.dropLast()
    else { throw PortableFrameStoreError.invalidGenerationInventoryReceipt }
    return ordinal
  }

  private func writeGenerationHighWater(_ ordinal: Int) throws {
    guard (0...Self.maximumGenerationOrdinal).contains(ordinal) else {
      throw PortableFrameStoreError.generationOrdinalOverflow
    }
    let bytes = Data("\(ordinal)\n".utf8)
    if fileManager.fileExists(atPath: highWaterURL.path) {
      try replacePreserved(bytes, at: highWaterURL)
    } else {
      try writePreserved(bytes, to: highWaterURL)
    }
  }

  private func recoverInterruptedActiveTailIfNeeded() throws {
    let originalByteCount = try fileByteCount(framesURL)
    guard originalByteCount > 0 else { return }
    let readHandle = try FileHandle(forReadingFrom: framesURL)
    defer { try? readHandle.close() }
    try readHandle.seek(toOffset: UInt64(originalByteCount - 1))
    guard try readHandle.read(upToCount: 1)?.first != 0x0A else { return }

    let prefixByteCount = try committedPrefixByteCount(
      in: readHandle, totalByteCount: originalByteCount)
    let temporary = root.appendingPathComponent(
      ".active-prefix-validation-\(UUID().uuidString).ndjson")
    try copyFileRange(
      from: framesURL, offset: 0, count: prefixByteCount, to: temporary)
    defer { try? fileManager.removeItem(at: temporary) }
    // A complete invalid line is never repaired. Validate every newline-committed prefix record
    // before preserving the exact source and publishing the recovered prefix.
    _ = try scanLedger(at: temporary, expectedDigest: nil) { _ in }

    try fileManager.createDirectory(at: recoveryDirectoryURL, withIntermediateDirectories: true)
    let originalDigest = try Self.sha256(file: framesURL)
    let stem = "interrupted-active-ledger-\(originalDigest)"
    let originalURL = recoveryDirectoryURL.appendingPathComponent("\(stem).ndjson")
    let tailURL = recoveryDirectoryURL.appendingPathComponent("\(stem)-tail.bin")
    let receiptURL = recoveryDirectoryURL.appendingPathComponent("\(stem)-receipt.json")
    try copyFilePreserved(
      from: framesURL,
      offset: 0,
      count: originalByteCount,
      expectedDigest: originalDigest,
      to: originalURL)
    let tailByteCount = originalByteCount - prefixByteCount
    let tailDigest = try sha256FileRange(
      framesURL, offset: prefixByteCount, count: tailByteCount)
    try copyFilePreserved(
      from: framesURL,
      offset: prefixByteCount,
      count: tailByteCount,
      expectedDigest: tailDigest,
      to: tailURL)
    let receipt = InterruptedTailReceipt(
      contract: "vhos.portable-active-tail-recovery",
      contractVersion: "1.0.0",
      originalLedgerSHA256: originalDigest,
      committedPrefixByteCount: prefixByteCount,
      interruptedTailByteCount: tailByteCount,
      interruptedTailSHA256: tailDigest
    )
    try writePreserved(try VHOSJSON.encoder().encode(receipt), to: receiptURL)
    _ = try fileManager.replaceItemAt(framesURL, withItemAt: temporary)
    try synchronizeFile(framesURL)
    try synchronizeDirectory(root)
  }

  private func committedPrefixByteCount(in handle: FileHandle, totalByteCount: Int) throws -> Int {
    var searchEnd = totalByteCount
    while searchEnd > 0 {
      let chunkCount = min(64 * 1_024, searchEnd)
      let chunkOffset = searchEnd - chunkCount
      try handle.seek(toOffset: UInt64(chunkOffset))
      let chunk = try handle.read(upToCount: chunkCount) ?? Data()
      if let newline = chunk.lastIndex(of: 0x0A) {
        return chunkOffset + newline + 1
      }
      searchEnd = chunkOffset
    }
    return 0
  }

  private func copyFilePreserved(
    from source: URL,
    offset: Int,
    count: Int,
    expectedDigest: String,
    to destination: URL
  ) throws {
    if fileManager.fileExists(atPath: destination.path) {
      guard try fileByteCount(destination) == count,
        try Self.sha256(file: destination) == expectedDigest
      else { throw PortableFrameStoreError.recoveryArtifactConflict(destination.lastPathComponent) }
      return
    }
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(
      ".\(destination.lastPathComponent)-\(UUID().uuidString).pending")
    defer { try? fileManager.removeItem(at: temporary) }
    try copyFileRange(from: source, offset: offset, count: count, to: temporary)
    guard try Self.sha256(file: temporary) == expectedDigest else {
      throw PortableFrameStoreError.recoveryArtifactConflict(destination.lastPathComponent)
    }
    try fileManager.moveItem(at: temporary, to: destination)
    try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
    try synchronizeFile(destination)
    try synchronizeDirectory(destination.deletingLastPathComponent())
  }

  private func copyFileRange(
    from source: URL, offset: Int, count: Int, to destination: URL
  ) throws {
    guard offset >= 0, count >= 0 else { throw CocoaError(.fileReadCorruptFile) }
    guard fileManager.createFile(atPath: destination.path, contents: nil) else {
      throw PortableFrameStoreError.createFailed
    }
    let reader = try FileHandle(forReadingFrom: source)
    let writer = try FileHandle(forWritingTo: destination)
    defer {
      try? reader.close()
      try? writer.close()
    }
    try reader.seek(toOffset: UInt64(offset))
    var remaining = count
    while remaining > 0 {
      let requested = min(64 * 1_024, remaining)
      let chunk = try reader.read(upToCount: requested) ?? Data()
      guard !chunk.isEmpty else {
        throw PortableFrameStoreError.unexpectedFileEOF(
          source.lastPathComponent, offset: offset + count - remaining, remaining: remaining)
      }
      try writer.write(contentsOf: chunk)
      remaining -= chunk.count
    }
    try writer.synchronize()
  }

  private func sha256FileRange(_ source: URL, offset: Int, count: Int) throws -> String {
    let handle = try FileHandle(forReadingFrom: source)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(offset))
    var remaining = count
    var hasher = SHA256()
    while remaining > 0 {
      let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)) ?? Data()
      guard !chunk.isEmpty else {
        throw PortableFrameStoreError.unexpectedFileEOF(
          source.lastPathComponent, offset: offset + count - remaining, remaining: remaining)
      }
      hasher.update(data: chunk)
      remaining -= chunk.count
    }
    return Data(hasher.finalize()).hexadecimalString
  }

  private func writePreserved(_ bytes: Data, to url: URL) throws {
    if fileManager.fileExists(atPath: url.path) {
      guard try Data(contentsOf: url, options: [.mappedIfSafe]) == bytes else {
        throw PortableFrameStoreError.recoveryArtifactConflict(url.lastPathComponent)
      }
      try synchronizeFile(url)
      try synchronizeDirectory(url.deletingLastPathComponent())
      return
    }
    try publishDurably(bytes, to: url, replacingExisting: false)
  }

  private func replacePreserved(_ bytes: Data, at url: URL) throws {
    guard fileManager.fileExists(atPath: url.path) else {
      return try writePreserved(bytes, to: url)
    }
    try publishDurably(bytes, to: url, replacingExisting: true)
  }

  private func publishDurably(
    _ bytes: Data,
    to url: URL,
    replacingExisting: Bool
  ) throws {
    let directory = url.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporary = directory.appendingPathComponent(
      ".\(url.lastPathComponent).\(UUID().uuidString.lowercased()).durable-write")
    guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
      throw PortableFrameStoreError.createFailed
    }
    var published = false
    defer {
      if !published { try? fileManager.removeItem(at: temporary) }
    }
    let handle = try FileHandle(forWritingTo: temporary)
    do {
      try handle.write(contentsOf: bytes)
      try handle.synchronize()
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }
    try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: temporary.path)
    try synchronizeFile(temporary)
    if !replacingExisting, fileManager.fileExists(atPath: url.path) {
      throw PortableFrameStoreError.recoveryArtifactConflict(url.lastPathComponent)
    }
    guard rename(temporary.path, url.path) == 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
    published = true
    try synchronizeDirectory(directory)
    let parent = directory.deletingLastPathComponent()
    if parent.path != directory.path { try synchronizeDirectory(parent) }
  }

  private func synchronizeFile(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
    defer { close(descriptor) }
    if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  private func synchronizeDirectory(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
  }

  private func fileByteCount(_ url: URL) throws -> Int {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    guard let size = attributes[.size] as? NSNumber else {
      throw CocoaError(.fileReadUnknown)
    }
    return size.intValue
  }

  static func deterministicBundleID(sourceLedgerSHA256 digest: String) throws -> UUID {
    guard digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
      throw PortableFrameStoreError.invalidSourceLedgerDigest
    }
    var hexadecimal = Array(digest.prefix(32))
    hexadecimal[12] = "5"
    let variant = Int(String(hexadecimal[16]), radix: 16) ?? 0
    hexadecimal[16] = Character(String(format: "%x", (variant & 0x3) | 0x8))
    let value = String(hexadecimal)
    let formatted =
      "\(value.prefix(8))-\(value.dropFirst(8).prefix(4))-"
      + "\(value.dropFirst(12).prefix(4))-\(value.dropFirst(16).prefix(4))-"
      + "\(value.dropFirst(20).prefix(12))"
    guard let uuid = UUID(uuidString: formatted) else {
      throw PortableFrameStoreError.invalidSourceLedgerDigest
    }
    return uuid
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func canonicalRecordDigest(
    _ record: PortableLogicalFrame,
    encoded: Data? = nil
  ) throws -> String {
    try sha256(encoded ?? VHOSJSON.encoder().encode(record))
  }

  private static func sha256(file url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let chunk = try handle.read(upToCount: 64 * 1_024) ?? Data()
      if chunk.isEmpty { break }
      hasher.update(data: chunk)
    }
    return Data(hasher.finalize()).hexadecimalString
  }
}

private final class PortableRecordIndex {
  struct Entry: Equatable {
    let recordSHA256: String
    let sourceRole: String
  }

  private static let schemaVersion = "2"
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  private let database: OpaquePointer
  private var rebuildActive = false

  init(url: URL) throws {
    var connection: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &connection, flags, nil) == SQLITE_OK,
      let connection
    else {
      if let connection { sqlite3_close(connection) }
      throw PortableFrameStoreError.indexUnavailable
    }
    database = connection
    do {
      try execute("PRAGMA journal_mode=WAL")
      try execute("PRAGMA synchronous=FULL")
      try execute("PRAGMA foreign_keys=ON")
      try execute(
        "CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)"
      )
      try execute(
        "CREATE TABLE IF NOT EXISTS record_ids (record_id TEXT PRIMARY KEY NOT NULL COLLATE BINARY, generation_ordinal INTEGER NOT NULL CHECK(generation_ordinal > 0))"
      )
      try execute(
        "CREATE TABLE IF NOT EXISTS record_entries_v2 (record_id TEXT PRIMARY KEY NOT NULL COLLATE BINARY, record_sha256 TEXT NOT NULL COLLATE BINARY CHECK(length(record_sha256) = 64), source_role TEXT NOT NULL COLLATE BINARY, generation_ordinal INTEGER NOT NULL CHECK(generation_ordinal > 0))"
      )
    } catch {
      sqlite3_close(connection)
      throw error
    }
  }

  deinit { sqlite3_close(database) }

  func isUsable(fingerprint: String) throws -> Bool {
    guard try scalarText("PRAGMA quick_check") == "ok",
      try metadata("index_schema_version") == Self.schemaVersion,
      try metadata("inventory_fingerprint") == fingerprint,
      let declared = try metadata("record_count"),
      let declaredCount = Int(declared), declaredCount >= 0
    else { return false }
    return try count() == declaredCount
  }

  func entry(_ recordID: String) throws -> Entry? {
    let statement = try prepare(
      "SELECT record_sha256, source_role FROM record_entries_v2 WHERE record_id = ? LIMIT 1"
    )
    defer { sqlite3_finalize(statement) }
    try bind(recordID, to: 1, in: statement)
    let result = sqlite3_step(statement)
    if result == SQLITE_DONE { return nil }
    guard result == SQLITE_ROW,
      let digestPointer = sqlite3_column_text(statement, 0),
      let rolePointer = sqlite3_column_text(statement, 1)
    else { throw PortableFrameStoreError.indexUnavailable }
    let digestLength = Int(sqlite3_column_bytes(statement, 0))
    let roleLength = Int(sqlite3_column_bytes(statement, 1))
    return Entry(
      recordSHA256: String(
        decoding: UnsafeBufferPointer(start: digestPointer, count: digestLength), as: UTF8.self),
      sourceRole: String(
        decoding: UnsafeBufferPointer(start: rolePointer, count: roleLength), as: UTF8.self)
    )
  }

  func insert(
    _ recordID: String,
    recordSHA256: String,
    sourceRole: String,
    generationOrdinal: Int
  ) throws {
    guard recordSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
      !sourceRole.isEmpty
    else { throw PortableFrameStoreError.indexUnavailable }
    let statement = try prepare(
      "INSERT INTO record_entries_v2(record_id, record_sha256, source_role, generation_ordinal) VALUES(?, ?, ?, ?)"
    )
    defer { sqlite3_finalize(statement) }
    try bind(recordID, to: 1, in: statement)
    try bind(recordSHA256, to: 2, in: statement)
    try bind(sourceRole, to: 3, in: statement)
    guard sqlite3_bind_int64(statement, 4, sqlite3_int64(generationOrdinal)) == SQLITE_OK else {
      throw PortableFrameStoreError.indexUnavailable
    }
    let result = sqlite3_step(statement)
    if result == SQLITE_CONSTRAINT {
      throw PortableFrameStoreError.duplicateRecordIdentity(recordID)
    }
    guard result == SQLITE_DONE else { throw PortableFrameStoreError.indexUnavailable }
  }

  func count() throws -> Int {
    guard let value = try scalarInt("SELECT COUNT(*) FROM record_entries_v2"),
      value >= 0, value <= Int64(Int.max)
    else { throw PortableFrameStoreError.indexUnavailable }
    return Int(value)
  }

  func beginRebuild() throws {
    try execute("BEGIN IMMEDIATE")
    do {
      try execute("DELETE FROM record_ids")
      try execute("DELETE FROM record_entries_v2")
      try execute("DELETE FROM metadata")
      rebuildActive = true
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  func finishRebuild(fingerprint: String, recordCount: Int) throws {
    guard rebuildActive else { throw PortableFrameStoreError.indexUnavailable }
    do {
      try setMetadata("index_schema_version", value: Self.schemaVersion)
      try setMetadata("inventory_fingerprint", value: fingerprint)
      try setMetadata("record_count", value: String(recordCount))
      try execute("COMMIT")
      rebuildActive = false
    } catch {
      try? execute("ROLLBACK")
      rebuildActive = false
      throw error
    }
  }

  func cancelRebuild() {
    guard rebuildActive else { return }
    try? execute("ROLLBACK")
    rebuildActive = false
  }

  func commitInventory(fingerprint: String, recordCount: Int) throws {
    try execute("BEGIN IMMEDIATE")
    do {
      try setMetadata("index_schema_version", value: Self.schemaVersion)
      try setMetadata("inventory_fingerprint", value: fingerprint)
      try setMetadata("record_count", value: String(recordCount))
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  private func metadata(_ key: String) throws -> String? {
    let statement = try prepare("SELECT value FROM metadata WHERE key = ?")
    defer { sqlite3_finalize(statement) }
    try bind(key, to: 1, in: statement)
    let result = sqlite3_step(statement)
    if result == SQLITE_DONE { return nil }
    guard result == SQLITE_ROW, let pointer = sqlite3_column_text(statement, 0) else {
      throw PortableFrameStoreError.indexUnavailable
    }
    let length = Int(sqlite3_column_bytes(statement, 0))
    return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
  }

  private func setMetadata(_ key: String, value: String) throws {
    let statement = try prepare(
      "INSERT INTO metadata(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value"
    )
    defer { sqlite3_finalize(statement) }
    try bind(key, to: 1, in: statement)
    try bind(value, to: 2, in: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw PortableFrameStoreError.indexUnavailable
    }
  }

  private func scalarText(_ sql: String) throws -> String? {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      let pointer = sqlite3_column_text(statement, 0)
    else { return nil }
    let length = Int(sqlite3_column_bytes(statement, 0))
    return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
  }

  private func scalarInt(_ sql: String) throws -> Int64? {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return Int64(sqlite3_column_int64(statement, 0))
  }

  private func execute(_ sql: String) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw PortableFrameStoreError.indexUnavailable
    }
  }

  private func prepare(_ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw PortableFrameStoreError.indexUnavailable }
    return statement
  }

  private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) throws {
    let result = value.withCString { pointer in
      sqlite3_bind_text(
        statement, index, pointer, Int32(value.lengthOfBytes(using: .utf8)), Self.transient)
    }
    guard result == SQLITE_OK else { throw PortableFrameStoreError.indexUnavailable }
  }
}

extension Data {
  fileprivate var hexadecimalString: String { map { String(format: "%02x", $0) }.joined() }
}

enum PortableFrameStoreError: Error, LocalizedError {
  case createFailed
  case invalidLimit
  case noEvidence
  case recordExceedsGenerationLimit
  case nonCanonicalCommittedRecord(String)
  case uncommittedLedgerTail
  case invalidGenerationFileName(String)
  case sealedGenerationHashMismatch(String)
  case missingGenerationOrdinal(expected: Int, found: Int)
  case missingTrailingGeneration(expectedHighWater: Int, observedHighWater: Int)
  case missingGenerationInventoryReceipt
  case invalidGenerationInventoryReceipt
  case missingGenerationIntegrityManifest
  case invalidGenerationIntegrityManifest
  case generationIntegrityDigestMismatch(ordinal: Int, expected: String, observed: String)
  case unboundGenerationSuffix
  case invalidLegacyMigrationState
  case invalidAnchoredV1MigrationState
  case legacyGenerationExceedsBound(String)
  case unexpectedFileEOF(String, offset: Int, remaining: Int)
  case generationOrdinalOverflow
  case generationDestinationExists(String)
  case duplicateRecordIdentity(String)
  case recordIdentityCollision(String)
  case indexUnavailable
  case recoveryArtifactConflict(String)
  case invalidSourceLedgerDigest
  case importReceiptConflict(String)
  case invalidImportIntent
  case invalidImportReceipt
  case legacyImportReceiptMissingArchive(String)

  var errorDescription: String? {
    switch self {
    case .createFailed: "The iPhone could not create its append-only portable evidence store."
    case .invalidLimit: "The portable evidence query limit is invalid."
    case .noEvidence: "No validated VHOS logical frames are stored on this iPhone yet."
    case .recordExceedsGenerationLimit:
      "A portable frame exceeds the immutable ledger generation safety limit."
    case .nonCanonicalCommittedRecord(let name):
      "Portable evidence ledger \(name) contains a blank or non-canonical committed record."
    case .uncommittedLedgerTail:
      "The active portable evidence ledger has an interrupted, uncommitted final append."
    case .invalidGenerationFileName(let name):
      "Portable evidence generation \(name) has an invalid content-bound filename."
    case .sealedGenerationHashMismatch(let name):
      "Portable evidence generation \(name) no longer matches its immutable SHA-256."
    case .missingGenerationOrdinal(let expected, let found):
      "Portable evidence generation \(expected) is missing before generation \(found); the ledger is incomplete."
    case .missingTrailingGeneration(let expected, let observed):
      "Portable evidence generation inventory reached \(expected), but only \(observed) generations remain; the ledger is incomplete."
    case .missingGenerationInventoryReceipt:
      "The portable evidence generation high-water receipt is missing."
    case .invalidGenerationInventoryReceipt:
      "The portable evidence generation high-water receipt is invalid."
    case .missingGenerationIntegrityManifest:
      "The portable evidence content-bound generation integrity manifest is missing."
    case .invalidGenerationIntegrityManifest:
      "The portable evidence content-bound generation integrity manifest is invalid."
    case .generationIntegrityDigestMismatch(let ordinal, let expected, let observed):
      "Portable evidence generation \(ordinal) was rebound from immutable SHA-256 \(expected) to \(observed); the ledger is untrusted."
    case .unboundGenerationSuffix:
      "Portable evidence contains more than one unbound sealed generation; recovery stopped fail-closed."
    case .invalidLegacyMigrationState:
      "The bounded legacy portable-ledger migration state is invalid or incomplete."
    case .invalidAnchoredV1MigrationState:
      "The bounded v1 portable-ledger migration state is invalid or incomplete."
    case .legacyGenerationExceedsBound(let name):
      "Legacy portable evidence generation \(name) exceeds the bounded generation contract; v2 promotion stopped fail-closed."
    case .unexpectedFileEOF(let name, let offset, let remaining):
      "Portable evidence file \(name) ended unexpectedly at byte \(offset) with \(remaining) bytes unverified."
    case .generationOrdinalOverflow:
      "The portable evidence generation counter cannot advance safely."
    case .generationDestinationExists(let name):
      "Portable evidence generation \(name) already exists; rollover stopped without overwriting it."
    case .duplicateRecordIdentity(let id):
      "Portable evidence repeats the exact record identity \(id); indexing stopped fail-closed."
    case .recordIdentityCollision(let id):
      "Portable evidence identity \(id) conflicts with different immutable provenance; ingestion stopped fail-closed."
    case .indexUnavailable:
      "The disk-backed portable evidence identity index is unavailable or corrupt."
    case .recoveryArtifactConflict(let name):
      "Interrupted portable evidence recovery artifact \(name) conflicts with preserved bytes."
    case .invalidSourceLedgerDigest:
      "The portable evidence source-ledger digest cannot form a deterministic export identity."
    case .importReceiptConflict(let bundleID):
      "Evidence bundle \(bundleID) conflicts with its durable import provenance receipt."
    case .invalidImportIntent:
      "A durable evidence-import intent or its preserved source bundle is invalid."
    case .invalidImportReceipt:
      "A completed evidence-import provenance receipt or record cross-link is invalid."
    case .legacyImportReceiptMissingArchive(let bundleID):
      "Legacy import receipt \(bundleID) is preserved, but its original source archive is missing; lineage migration stopped without rewriting the receipt."
    }
  }
}
