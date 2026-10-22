import CryptoKit
import Foundation
import SQLite3
import VHOSCore

struct StoredEvidenceOutboxRecord: Codable, Equatable, Identifiable, Sendable {
  let envelope: EvidenceOutboxEnvelope
  let payloadFilename: String
  /// Stable identity of the immutable source artifact, when the producer has one.
  ///
  /// This remains optional so packages written before artifact identities were introduced decode
  /// without migration. It is metadata only; the envelope digest remains the payload authority.
  let artifactIdentity: String?
  var attemptCount: Int
  var lastAttemptAt: String?
  var lastError: String?
  var uploadedAt: String?

  var id: UUID { envelope.packageID }
}

struct EvidenceOutboxKnownArtifact: Equatable, Sendable {
  let identity: String
  let contentType: String
  let byteCount: Int
  let sha256: String
  let packageID: UUID
}

final class EvidenceOutboxStore {
  private static let maximumMetadataBytes = 64 * 1024
  private static let maximumQuarantinedPackages = 8
  private let fileManager: FileManager
  private let root: URL
  private let maximumPackages = 512

  init(fileManager: FileManager = .default, root explicitRoot: URL? = nil) {
    self.fileManager = fileManager
    let support =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    root =
      explicitRoot
      ?? support.appendingPathComponent("VHOSEvidenceOutbox/v1", isDirectory: true)
    try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try? scavengeInterruptedStagingDirectories()
    try? scavengeAcknowledgedPackages()
  }

  func enqueue(
    payload: Data,
    contentType: String,
    artifactIdentity: String? = nil
  ) throws -> (StoredEvidenceOutboxRecord, Bool) {
    try Self.validateArtifactIdentity(artifactIdentity)
    guard payload.count <= EvidenceOutboxPayloadFileValidator.maximumBytes(for: contentType) else {
      throw EvidenceOutboxStoreError.artifactTooLarge
    }
    let candidate = try EvidenceOutboxEnvelope(contentType: contentType, payload: payload)
    let acknowledgements = try acknowledgementCatalog()
    if let acknowledged = try acknowledgements.acknowledgement(
      artifactIdentity: artifactIdentity,
      contentType: candidate.contentType,
      sha256: candidate.sha256
    ) {
      guard acknowledged.byteCount == candidate.byteCount else {
        throw EvidenceOutboxStoreError.artifactIdentityConflict(
          artifactIdentity ?? acknowledged.dedupeKey)
      }
      return (try acknowledged.storedRecord(), false)
    }
    if let artifactIdentity,
      try acknowledgements.hasConflictingAcknowledgement(
        artifactIdentity: artifactIdentity,
        contentType: candidate.contentType,
        byteCount: candidate.byteCount,
        sha256: candidate.sha256)
    {
      throw EvidenceOutboxStoreError.artifactIdentityConflict(artifactIdentity)
    }
    _ = try verifiedLiveArtifactMetadata(quarantiningInvalidPackages: true)
    let currentRecords = try records()

    if let artifactIdentity {
      let identityMatches = currentRecords.filter { $0.artifactIdentity == artifactIdentity }
      guard identityMatches.count <= 1 else {
        throw EvidenceOutboxStoreError.artifactIdentityConflict(artifactIdentity)
      }
      if let existing = identityMatches.first {
        guard
          existing.envelope.sha256 == candidate.sha256,
          existing.envelope.byteCount == candidate.byteCount,
          existing.envelope.contentType == candidate.contentType
        else {
          throw EvidenceOutboxStoreError.artifactIdentityConflict(artifactIdentity)
        }
        // A damaged on-disk package must never suppress a valid requeue solely because its
        // unverified metadata repeats the candidate identity and digest.
        _ = try validatedPayloadURL(for: existing)
        return (existing, false)
      }
    }

    if artifactIdentity == nil,
      let existing = currentRecords.first(where: {
        $0.artifactIdentity == nil
          && $0.envelope.sha256 == candidate.sha256
          && $0.envelope.contentType == candidate.contentType
      })
    {
      _ = try validatedPayloadURL(for: existing)
      return (existing, false)
    }

    guard currentRecords.count < maximumPackages else {
      throw EvidenceOutboxStoreError.capacityReached
    }
    let directory = packageDirectory(candidate.packageID)
    let staging = root.appendingPathComponent(
      ".\(candidate.packageID.uuidString).staging", isDirectory: true)
    if fileManager.fileExists(atPath: staging.path) { try fileManager.removeItem(at: staging) }
    var published = false
    defer {
      if !published, fileManager.fileExists(atPath: staging.path) {
        try? fileManager.removeItem(at: staging)
      }
    }

    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    let payloadFilename = try Self.payloadFilename(for: contentType)
    try payload.write(to: staging.appendingPathComponent(payloadFilename), options: .atomic)
    let record = StoredEvidenceOutboxRecord(
      envelope: candidate,
      payloadFilename: payloadFilename,
      artifactIdentity: artifactIdentity,
      attemptCount: 0,
      lastAttemptAt: nil,
      lastError: nil,
      uploadedAt: nil
    )
    try write(record, directory: staging)
    try candidate.validate(payload: payload)
    try fileManager.moveItem(at: staging, to: directory)
    published = true
    return (record, true)
  }

  func records() throws -> [StoredEvidenceOutboxRecord] {
    guard fileManager.fileExists(atPath: root.path) else { return [] }
    let directories = try fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    var result: [StoredEvidenceOutboxRecord] = []
    for directory in directories {
      let metadata = directory.appendingPathComponent("record.json")
      do {
        guard fileManager.fileExists(atPath: metadata.path) else {
          throw EvidenceOutboxStoreError.invalidStoredMetadata
        }
        let record = try VHOSJSON.decoder().decode(
          StoredEvidenceOutboxRecord.self,
          from: try Self.readBoundedMetadata(metadata, fileManager: fileManager))
        guard directory.lastPathComponent == record.id.uuidString.lowercased() else {
          throw EvidenceOutboxStoreError.invalidStoredMetadata
        }
        result.append(record)
      } catch {
        // Source generations remain authoritative. Preserve a bounded sample of malformed package
        // bytes, remove the broken live entry from capacity, and let planning regenerate it.
        try quarantineDirectory(directory)
      }
    }
    return result.sorted { $0.envelope.createdAt < $1.envelope.createdAt }
  }

  func payloadURL(for record: StoredEvidenceOutboxRecord) throws -> URL {
    guard Self.isSafeStoredPayloadFilename(record.payloadFilename, for: record.envelope.contentType)
    else { throw EvidenceOutboxStoreError.invalidStoredMetadata }
    let url = packageDirectory(record.id).appendingPathComponent(record.payloadFilename)
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, values.fileSize == record.envelope.byteCount else {
      throw EvidenceOutboxStoreError.invalidStoredMetadata
    }
    return url
  }

  /// Synchronous validation is reserved for store-internal deduplication and actor-isolated work.
  /// UI upload code must use `EvidenceOutboxPayloadFileValidator.validate` instead.
  func validatedPayloadURL(for record: StoredEvidenceOutboxRecord) throws -> URL {
    let url = try payloadURL(for: record)
    _ = try EvidenceOutboxPayloadFileValidator.validateSynchronously(record: record, url: url)
    return url
  }

  /// Returns stable artifact identities only after validating live payload bytes or a checksummed
  /// durable upload acknowledgement.
  ///
  /// Invalid live packages are moved into a bounded quarantine and omitted so the producer can
  /// regenerate the immutable source artifact during the same automatic planning cycle.
  func knownArtifactMetadata() throws -> [String: EvidenceOutboxKnownArtifact] {
    var result = try acknowledgementCatalog().knownArtifactMetadata()
    for (identity, metadata) in try verifiedLiveArtifactMetadata(
      quarantiningInvalidPackages: true)
    {
      if let existing = result[identity], existing != metadata {
        throw EvidenceOutboxStoreError.artifactIdentityConflict(identity)
      }
      result[identity] = metadata
    }
    return result
  }

  func knownArtifactIdentities() throws -> Set<String> {
    Set(try knownArtifactMetadata().keys)
  }

  func acknowledgedUploadCount() throws -> Int {
    try acknowledgementCatalog().count()
  }

  func markAttempt(_ record: StoredEvidenceOutboxRecord, error: String?) throws {
    var updated = record
    updated.attemptCount += 1
    updated.lastAttemptAt = Self.timestamp()
    updated.lastError = error
    try write(updated, directory: packageDirectory(record.id))
  }

  func markUploaded(_ record: StoredEvidenceOutboxRecord) throws {
    _ = try validatedPayloadURL(for: record)
    var updated = record
    updated.attemptCount += 1
    updated.lastAttemptAt = Self.timestamp()
    updated.lastError = nil
    updated.uploadedAt = Self.timestamp()
    // The checksummed acknowledgement is the durable commit point. Publishing `uploadedAt` to
    // the live record first could hide the package forever if power failed before the catalogue
    // commit.
    try acknowledgementCatalog().record(uploaded: updated)
    try fileManager.removeItem(at: packageDirectory(record.id))
  }

  private func verifiedLiveArtifactMetadata(
    quarantiningInvalidPackages: Bool
  ) throws -> [String: EvidenceOutboxKnownArtifact] {
    var result: [String: EvidenceOutboxKnownArtifact] = [:]
    for record in try records() {
      do {
        _ = try validatedPayloadURL(for: record)
      } catch {
        guard quarantiningInvalidPackages else { throw error }
        try quarantinePackage(record.id)
        continue
      }
      guard let identity = record.artifactIdentity else { continue }
      let metadata = EvidenceOutboxKnownArtifact(
        identity: identity,
        contentType: record.envelope.contentType,
        byteCount: record.envelope.byteCount,
        sha256: record.envelope.sha256,
        packageID: record.envelope.packageID)
      if let existing = result[identity], existing != metadata {
        throw EvidenceOutboxStoreError.artifactIdentityConflict(identity)
      }
      result[identity] = metadata
    }
    return result
  }

  private func acknowledgementCatalog() throws -> EvidenceOutboxAcknowledgementCatalog {
    try EvidenceOutboxAcknowledgementCatalog(
      url: root.appendingPathComponent("upload-acknowledgements.sqlite3"))
  }

  private func scavengeInterruptedStagingDirectories() throws {
    guard fileManager.fileExists(atPath: root.path) else { return }
    for url in try fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: []
    ) where url.lastPathComponent.hasSuffix(".staging") {
      guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
        continue
      }
      try fileManager.removeItem(at: url)
    }
  }

  /// Completes pruning after a crash between the durable acknowledgement commit and package
  /// removal. Only an exact acknowledgement for the same package and immutable payload permits
  /// deletion.
  private func scavengeAcknowledgedPackages() throws {
    let catalog = try acknowledgementCatalog()
    for record in try records() where try catalog.isAcknowledged(record) {
      _ = try validatedPayloadURL(for: record)
      try fileManager.removeItem(at: packageDirectory(record.id))
    }
  }

  private func quarantinePackage(_ packageID: UUID) throws {
    let source = packageDirectory(packageID)
    guard fileManager.fileExists(atPath: source.path) else { return }
    try quarantineDirectory(source)
  }

  private func quarantineDirectory(_ source: URL) throws {
    guard fileManager.fileExists(atPath: source.path) else { return }
    let quarantine = root.appendingPathComponent(".quarantine", isDirectory: true)
    try fileManager.createDirectory(at: quarantine, withIntermediateDirectories: true)
    let destination = quarantine.appendingPathComponent(
      "\(source.lastPathComponent)-\(UUID().uuidString.lowercased())",
      isDirectory: true)
    try fileManager.moveItem(at: source, to: destination)
    let entries = try fileManager.contentsOfDirectory(
      at: quarantine,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ).sorted {
      let lhs = try? $0.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
      let rhs = try? $1.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
      return (lhs ?? .distantPast) < (rhs ?? .distantPast)
    }
    for stale in entries.dropLast(Self.maximumQuarantinedPackages) {
      try fileManager.removeItem(at: stale)
    }
  }

  private func write(_ record: StoredEvidenceOutboxRecord, directory: URL) throws {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try VHOSJSON.encoder().encode(record).write(
      to: directory.appendingPathComponent("record.json"), options: .atomic)
  }

  private func packageDirectory(_ id: UUID) -> URL {
    root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
  }

  private static func timestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
  }

  fileprivate static func validateArtifactIdentity(_ identity: String?) throws {
    guard let identity else { return }
    let trimmed = identity.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identity.isEmpty, identity == trimmed, identity.utf8.count <= 512,
      identity.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else { throw EvidenceOutboxStoreError.invalidArtifactIdentity }
  }

  private static func payloadFilename(for contentType: String) throws -> String {
    switch contentType {
    case "application/vnd.vhos.evidence-sync+zip":
      return "evidence.vhossync"
    case "application/vnd.vhos.agent-evidence+json":
      return "agent-evidence.json"
    case "application/vnd.vhos.discovery-draft-evidence+json":
      return "discovery-draft-evidence.json"
    case "application/vnd.vhos.import-provenance-receipt+json":
      return "import-provenance-receipt.json"
    default:
      throw EvidenceOutboxStoreError.unsupportedContentType
    }
  }

  private static func isSafeStoredPayloadFilename(
    _ filename: String,
    for contentType: String
  ) -> Bool {
    guard filename == URL(fileURLWithPath: filename).lastPathComponent,
      !filename.contains("/") && !filename.contains("\\")
    else { return false }
    // v1 used evidence.vhossync for every supported media type. Continue reading those packages;
    // all new packages use the content-specific filename above.
    guard let expectedFilename = try? payloadFilename(for: contentType) else { return false }
    return filename == "evidence.vhossync" || filename == expectedFilename
  }

  private static func readBoundedMetadata(_ url: URL, fileManager: FileManager) throws -> Data {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      let fileSize = attributes[.size] as? NSNumber,
      fileSize.intValue > 0,
      fileSize.intValue <= maximumMetadataBytes
    else { throw EvidenceOutboxStoreError.invalidStoredMetadata }
    return try Data(contentsOf: url, options: [.mappedIfSafe])
  }
}

private struct EvidenceOutboxUploadAcknowledgement: Equatable, Sendable {
  let dedupeKey: String
  let artifactIdentity: String?
  let contentType: String
  let byteCount: Int
  let sha256: String
  let packageID: UUID
  let uploadedAt: String
  let integritySHA256: String

  func storedRecord() throws -> StoredEvidenceOutboxRecord {
    struct EnvelopeWire: Codable {
      let authority: EvidenceOutboxAuthority
      let byteCount: Int
      let contentType: String
      let contract: String
      let contractVersion: String
      let createdAt: String
      let packageID: UUID
      let redactionPolicy: String
      let sha256: String
    }
    let envelope = try VHOSJSON.decoder().decode(
      EvidenceOutboxEnvelope.self,
      from: VHOSJSON.encoder().encode(
        EnvelopeWire(
          authority: EvidenceOutboxAuthority(),
          byteCount: byteCount,
          contentType: contentType,
          contract: "evidence.outbox-envelope",
          contractVersion: "1.0.0",
          createdAt: uploadedAt,
          packageID: packageID,
          redactionPolicy: "OWNER_PRIVATE_V1",
          sha256: sha256)))
    return StoredEvidenceOutboxRecord(
      envelope: envelope,
      payloadFilename: "acknowledged",
      artifactIdentity: artifactIdentity,
      attemptCount: 1,
      lastAttemptAt: uploadedAt,
      lastError: nil,
      uploadedAt: uploadedAt)
  }

  static func make(uploaded record: StoredEvidenceOutboxRecord) throws -> Self {
    let dedupeKey = Self.dedupeKey(
      artifactIdentity: record.artifactIdentity,
      contentType: record.envelope.contentType,
      sha256: record.envelope.sha256)
    let uploadedAt = record.uploadedAt ?? record.envelope.createdAt
    let material = try integrityMaterial(
      dedupeKey: dedupeKey,
      artifactIdentity: record.artifactIdentity,
      contentType: record.envelope.contentType,
      byteCount: record.envelope.byteCount,
      sha256: record.envelope.sha256,
      packageID: record.envelope.packageID,
      uploadedAt: uploadedAt)
    return Self(
      dedupeKey: dedupeKey,
      artifactIdentity: record.artifactIdentity,
      contentType: record.envelope.contentType,
      byteCount: record.envelope.byteCount,
      sha256: record.envelope.sha256,
      packageID: record.envelope.packageID,
      uploadedAt: uploadedAt,
      integritySHA256: Self.sha256(material))
  }

  func validate() throws {
    try EvidenceOutboxStore.validateArtifactIdentity(artifactIdentity)
    guard byteCount > 0,
      byteCount <= EvidenceOutboxPayloadFileValidator.maximumBytes(for: contentType),
      EvidenceOutboxEnvelope.allowedContentTypes.contains(contentType),
      sha256.utf8.count == 64,
      sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      dedupeKey
        == Self.dedupeKey(
          artifactIdentity: artifactIdentity,
          contentType: contentType,
          sha256: sha256),
      integritySHA256
        == Self.sha256(
          try Self.integrityMaterial(
            dedupeKey: dedupeKey,
            artifactIdentity: artifactIdentity,
            contentType: contentType,
            byteCount: byteCount,
            sha256: sha256,
            packageID: packageID,
            uploadedAt: uploadedAt))
    else { throw EvidenceOutboxStoreError.invalidAcknowledgementCatalog }
  }

  private static func dedupeKey(
    artifactIdentity: String?,
    contentType: String,
    sha256: String
  ) -> String {
    if let artifactIdentity { return "identity:\(artifactIdentity)" }
    return "payload:\(contentType):\(sha256)"
  }

  private static func integrityMaterial(
    dedupeKey: String,
    artifactIdentity: String?,
    contentType: String,
    byteCount: Int,
    sha256: String,
    packageID: UUID,
    uploadedAt: String
  ) throws -> Data {
    struct Material: Codable {
      let artifactIdentity: String?
      let byteCount: Int
      let contentType: String
      let dedupeKey: String
      let packageID: UUID
      let sha256: String
      let uploadedAt: String
    }
    return try VHOSJSON.encoder().encode(
      Material(
        artifactIdentity: artifactIdentity,
        byteCount: byteCount,
        contentType: contentType,
        dedupeKey: dedupeKey,
        packageID: packageID,
        sha256: sha256,
        uploadedAt: uploadedAt))
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private final class EvidenceOutboxAcknowledgementCatalog {
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  private var database: OpaquePointer?

  init(url: URL) throws {
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK,
      let database
    else {
      if let database { sqlite3_close(database) }
      throw EvidenceOutboxStoreError.invalidAcknowledgementCatalog
    }
    do {
      try execute("PRAGMA trusted_schema=OFF")
      try execute("PRAGMA journal_mode=WAL")
      try execute("PRAGMA synchronous=FULL")
      try execute(
        """
        CREATE TABLE IF NOT EXISTS upload_acknowledgements (
          dedupe_key TEXT PRIMARY KEY NOT NULL,
          artifact_identity TEXT,
          content_type TEXT NOT NULL,
          byte_count INTEGER NOT NULL,
          sha256 TEXT NOT NULL,
          package_id TEXT NOT NULL,
          uploaded_at TEXT NOT NULL,
          integrity_sha256 TEXT NOT NULL
        ) WITHOUT ROWID
        """)
      try validateIntegrity()
    } catch {
      sqlite3_close(database)
      self.database = nil
      throw error
    }
  }

  deinit {
    if let database { sqlite3_close(database) }
  }

  func record(uploaded record: StoredEvidenceOutboxRecord) throws {
    let acknowledgement = try EvidenceOutboxUploadAcknowledgement.make(uploaded: record)
    try acknowledgement.validate()
    if let existing = try self.acknowledgement(dedupeKey: acknowledgement.dedupeKey) {
      guard existing == acknowledgement else {
        throw EvidenceOutboxStoreError.artifactIdentityConflict(
          acknowledgement.artifactIdentity ?? acknowledgement.dedupeKey)
      }
      return
    }
    let sql =
      "INSERT INTO upload_acknowledgements VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    try bind(acknowledgement.dedupeKey, to: 1, statement: statement)
    if let artifactIdentity = acknowledgement.artifactIdentity {
      try bind(artifactIdentity, to: 2, statement: statement)
    } else {
      guard sqlite3_bind_null(statement, 2) == SQLITE_OK else {
        throw EvidenceOutboxStoreError.invalidAcknowledgementCatalog
      }
    }
    try bind(acknowledgement.contentType, to: 3, statement: statement)
    guard
      sqlite3_bind_int64(statement, 4, sqlite3_int64(acknowledgement.byteCount))
        == SQLITE_OK
    else { throw EvidenceOutboxStoreError.invalidAcknowledgementCatalog }
    try bind(acknowledgement.sha256, to: 5, statement: statement)
    try bind(acknowledgement.packageID.uuidString.lowercased(), to: 6, statement: statement)
    try bind(acknowledgement.uploadedAt, to: 7, statement: statement)
    try bind(acknowledgement.integritySHA256, to: 8, statement: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw EvidenceOutboxStoreError.invalidAcknowledgementCatalog
    }
  }

  func acknowledgement(
    artifactIdentity: String?,
    contentType: String,
    sha256: String
  ) throws -> EvidenceOutboxUploadAcknowledgement? {
    try acknowledgement(
      dedupeKey: artifactIdentity.map { "identity:\($0)" }
        ?? "payload:\(contentType):\(sha256)")
  }

  func hasConflictingAcknowledgement(
    artifactIdentity: String,
    contentType: String,
    byteCount: Int,
    sha256: String
  ) throws -> Bool {
    guard let existing = try acknowledgement(dedupeKey: "identity:\(artifactIdentity)") else {
      return false
    }
    return existing.contentType != contentType || existing.byteCount != byteCount
      || existing.sha256 != sha256
  }

  func isAcknowledged(_ record: StoredEvidenceOutboxRecord) throws -> Bool {
    let dedupeKey =
      record.artifactIdentity.map { "identity:\($0)" }
      ?? "payload:\(record.envelope.contentType):\(record.envelope.sha256)"
    guard let existing = try acknowledgement(dedupeKey: dedupeKey) else { return false }
    return existing.artifactIdentity == record.artifactIdentity
      && existing.contentType == record.envelope.contentType
      && existing.byteCount == record.envelope.byteCount
      && existing.sha256 == record.envelope.sha256
      && existing.packageID == record.envelope.packageID
  }

  func knownArtifactMetadata() throws -> [String: EvidenceOutboxKnownArtifact] {
    let statement = try prepare(
      "SELECT dedupe_key, artifact_identity, content_type, byte_count, sha256, package_id, uploaded_at, integrity_sha256 FROM upload_acknowledgements WHERE artifact_identity IS NOT NULL ORDER BY artifact_identity"
    )
    defer { sqlite3_finalize(statement) }
    var result: [String: EvidenceOutboxKnownArtifact] = [:]
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW else {
        throw EvidenceOutboxStoreError.invalidAcknowledgementCatalog
      }
      let acknowledgement = try decode(statement)
      try acknowledgement.validate()
      guard let identity = acknowledgement.artifactIdentity else { continue }
      result[identity] = EvidenceOutboxKnownArtifact(
        identity: identity,
        contentType: acknowledgement.contentType,
        byteCount: acknowledgement.byteCount,
        sha256: acknowledgement.sha256,
        packageID: acknowledgement.packageID)
    }
    return result
  }

  func count() throws -> Int {
    let statement = try prepare("SELECT COUNT(*) FROM upload_acknowledgements")
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw EvidenceOutboxStoreError.invalidAcknowledgementCatalog
    }
    let value = sqlite3_column_int64(statement, 0)
    guard value >= 0, value <= Int64(Int.max) else {
      throw EvidenceOutboxStoreError.invalidAcknowledgementCatalog
    }
    return Int(value)
  }

  private func acknowledgement(
    dedupeKey: String
  ) throws -> EvidenceOutboxUploadAcknowledgement? {
    let statement = try prepare(
      "SELECT dedupe_key, artifact_identity, content_type, byte_count, sha256, package_id, uploaded_at, integrity_sha256 FROM upload_acknowledgements WHERE dedupe_key = ?"
    )
    defer { sqlite3_finalize(statement) }
    try bind(dedupeKey, to: 1, statement: statement)
    let step = sqlite3_step(statement)
    if step == SQLITE_DONE { return nil }
    guard step == SQLITE_ROW else {
      throw EvidenceOutboxStoreError.invalidAcknowledgementCatalog
    }
    let acknowledgement = try decode(statement)
    try acknowledgement.validate()
    return acknowledgement
  }

  private func validateIntegrity() throws {
    let statement = try prepare("PRAGMA quick_check")
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      let pointer = sqlite3_column_text(statement, 0)
    else { throw EvidenceOutboxStoreError.invalidAcknowledgementCatalog }
    let result = String(
      decoding: UnsafeBufferPointer(
        start: pointer,
        count: Int(sqlite3_column_bytes(statement, 0))),
      as: UTF8.self)
    guard result == "ok", sqlite3_step(statement) == SQLITE_DONE else {
      throw EvidenceOutboxStoreError.invalidAcknowledgementCatalog
    }
  }

  private func decode(_ statement: OpaquePointer) throws -> EvidenceOutboxUploadAcknowledgement {
    func string(_ column: Int32) throws -> String {
      guard let pointer = sqlite3_column_text(statement, column) else {
        throw EvidenceOutboxStoreError.invalidAcknowledgementCatalog
      }
      return String(
        decoding: UnsafeBufferPointer(
          start: pointer,
          count: Int(sqlite3_column_bytes(statement, column))),
        as: UTF8.self)
    }
    let identity = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : try string(1)
    guard let byteCount = Int(exactly: sqlite3_column_int64(statement, 3)),
      let packageID = UUID(uuidString: try string(5))
    else { throw EvidenceOutboxStoreError.invalidAcknowledgementCatalog }
    return EvidenceOutboxUploadAcknowledgement(
      dedupeKey: try string(0),
      artifactIdentity: identity,
      contentType: try string(2),
      byteCount: byteCount,
      sha256: try string(4),
      packageID: packageID,
      uploadedAt: try string(6),
      integritySHA256: try string(7))
  }

  private func execute(_ sql: String) throws {
    guard let database, sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw EvidenceOutboxStoreError.invalidAcknowledgementCatalog
    }
  }

  private func prepare(_ sql: String) throws -> OpaquePointer {
    guard let database else { throw EvidenceOutboxStoreError.invalidAcknowledgementCatalog }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw EvidenceOutboxStoreError.invalidAcknowledgementCatalog }
    return statement
  }

  private func bind(_ value: String, to index: Int32, statement: OpaquePointer) throws {
    guard
      sqlite3_bind_text(
        statement,
        index,
        value,
        -1,
        Self.transient) == SQLITE_OK
    else { throw EvidenceOutboxStoreError.invalidAcknowledgementCatalog }
  }
}

struct EvidenceOutboxFileArtifact: Equatable, Sendable {
  let identity: String?
  let url: URL
  let contentType: String
  let expectedByteCount: Int?
  let expectedSHA256: String?

  init(
    identity: String? = nil,
    url: URL,
    contentType: String,
    expectedByteCount: Int? = nil,
    expectedSHA256: String? = nil
  ) {
    self.identity = identity
    self.url = url
    self.contentType = contentType
    self.expectedByteCount = expectedByteCount
    self.expectedSHA256 = expectedSHA256
  }
}

enum EvidenceOutboxEnqueueMode: Equatable, Sendable {
  case automatic
  case manual(maximumArtifacts: Int)
}

struct EvidenceOutboxEnqueuePageResult: Equatable, Sendable {
  let consideredArtifacts: Int
  let insertedPackages: Int
  let deduplicatedPackages: Int
  let skippedKnownArtifacts: Int
  let packageIDs: [UUID]
}

struct EvidenceOutboxBackgroundStatus: Equatable, Sendable {
  let pendingCount: Int
  let acknowledgedUploadCount: Int
}

/// Serial, non-main-actor file ingestion for immutable outbox artifacts.
///
/// Each package is published by `EvidenceOutboxStore` with staging + atomic directory rename. A
/// cancellation or read failure can therefore leave already completed packages, but never exposes
/// a half-written package. Automatic cycles ingest at most two new artifacts; an explicit manual
/// cycle may request one through eight.
actor EvidenceOutboxBackgroundCoordinator {
  static let automaticPageSize = 2
  static let maximumManualPageSize = 8

  private let store: EvidenceOutboxStore

  init(fileManager: FileManager = .default, root: URL? = nil) {
    store = EvidenceOutboxStore(fileManager: fileManager, root: root)
  }

  func knownArtifactMetadata() throws -> [String: EvidenceOutboxKnownArtifact] {
    try store.knownArtifactMetadata()
  }

  func knownArtifactIdentities() throws -> Set<String> {
    try store.knownArtifactIdentities()
  }

  func pendingRecords(maximumCount: Int) throws -> [StoredEvidenceOutboxRecord] {
    guard (1...32).contains(maximumCount) else {
      throw EvidenceOutboxStoreError.invalidPageSize
    }
    // A live package is pending regardless of legacy `uploadedAt` metadata. Only the separate,
    // checksummed acknowledgement catalogue can prove upload completion and authorize pruning.
    return Array(try store.records().prefix(maximumCount))
  }

  func payloadURL(for record: StoredEvidenceOutboxRecord) throws -> URL {
    try store.payloadURL(for: record)
  }

  func markUploaded(_ record: StoredEvidenceOutboxRecord) throws {
    try store.markUploaded(record)
  }

  func markAttempt(_ record: StoredEvidenceOutboxRecord, error: String) throws {
    try store.markAttempt(record, error: error)
  }

  func status() throws -> EvidenceOutboxBackgroundStatus {
    EvidenceOutboxBackgroundStatus(
      pendingCount: try store.records().count,
      acknowledgedUploadCount: try store.acknowledgedUploadCount())
  }

  func enqueuePage(
    _ artifacts: [EvidenceOutboxFileArtifact],
    mode: EvidenceOutboxEnqueueMode
  ) async throws -> EvidenceOutboxEnqueuePageResult {
    let pageSize = try Self.pageSize(for: mode)
    let known = try store.knownArtifactMetadata()
    var pending: [EvidenceOutboxFileArtifact] = []
    var skippedKnown = 0

    for artifact in artifacts {
      try Task.checkCancellation()
      try Self.validate(artifact)
      if let identity = artifact.identity, let existing = known[identity],
        Self.matchesExpectedArtifact(existing, artifact: artifact)
      {
        // Known live artifacts already passed bounded payload validation; uploaded artifacts are
        // backed by a checksummed durable acknowledgement. Damaged metadata cannot suppress
        // regeneration here.
        skippedKnown += 1
        continue
      } else if let identity = artifact.identity, known[identity] != nil,
        artifact.expectedSHA256 != nil
      {
        throw EvidenceOutboxStoreError.artifactIdentityConflict(identity)
      }
      pending.append(artifact)
      if pending.count == pageSize { break }
    }

    var inserted = 0
    var deduplicated = 0
    var packageIDs: [UUID] = []
    for artifact in pending {
      try Task.checkCancellation()
      let payload = try Self.readBoundedArtifact(artifact)
      try Task.checkCancellation()
      let (record, wasInserted) = try store.enqueue(
        payload: payload,
        contentType: artifact.contentType,
        artifactIdentity: artifact.identity)
      packageIDs.append(record.id)
      if wasInserted {
        inserted += 1
      } else {
        deduplicated += 1
      }
      await Task.yield()
    }

    return EvidenceOutboxEnqueuePageResult(
      consideredArtifacts: pending.count + skippedKnown,
      insertedPackages: inserted,
      deduplicatedPackages: deduplicated,
      skippedKnownArtifacts: skippedKnown,
      packageIDs: packageIDs)
  }

  private static func pageSize(for mode: EvidenceOutboxEnqueueMode) throws -> Int {
    switch mode {
    case .automatic:
      return automaticPageSize
    case .manual(let maximumArtifacts):
      guard (1...maximumManualPageSize).contains(maximumArtifacts) else {
        throw EvidenceOutboxStoreError.invalidPageSize
      }
      return maximumArtifacts
    }
  }

  private static func matchesExpectedArtifact(
    _ existing: EvidenceOutboxKnownArtifact,
    artifact: EvidenceOutboxFileArtifact
  ) -> Bool {
    guard existing.contentType == artifact.contentType,
      let expectedSHA256 = artifact.expectedSHA256,
      existing.sha256 == expectedSHA256
    else { return false }
    return artifact.expectedByteCount.map { existing.byteCount == $0 } ?? true
  }

  private static func validate(_ artifact: EvidenceOutboxFileArtifact) throws {
    try EvidenceOutboxStore.validateArtifactIdentity(artifact.identity)
    guard EvidenceOutboxEnvelope.allowedContentTypes.contains(artifact.contentType) else {
      throw EvidenceOutboxStoreError.unsupportedContentType
    }
    if let byteCount = artifact.expectedByteCount {
      guard
        byteCount > 0,
        byteCount <= EvidenceOutboxPayloadFileValidator.maximumBytes(for: artifact.contentType)
      else {
        throw EvidenceOutboxStoreError.artifactTooLarge
      }
    }
    if let digest = artifact.expectedSHA256 {
      guard digest.utf8.count == 64,
        digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else { throw EvidenceOutboxStoreError.artifactChangedDuringRead }
    }
  }

  private static func readBoundedArtifact(_ artifact: EvidenceOutboxFileArtifact) throws -> Data {
    let maximumBytes = EvidenceOutboxPayloadFileValidator.maximumBytes(for: artifact.contentType)
    let values = try artifact.url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else {
      throw EvidenceOutboxStoreError.artifactNotRegularFile
    }
    if let size = values.fileSize, size > maximumBytes {
      throw EvidenceOutboxStoreError.artifactTooLarge
    }

    let handle = try FileHandle(forReadingFrom: artifact.url)
    defer { try? handle.close() }
    var payload = Data()
    if let size = values.fileSize { payload.reserveCapacity(min(size, maximumBytes)) }
    while true {
      try Task.checkCancellation()
      let remaining = maximumBytes - payload.count
      guard remaining >= 0 else { throw EvidenceOutboxStoreError.artifactTooLarge }
      let chunk = try handle.read(upToCount: min(64 * 1024, remaining + 1)) ?? Data()
      if chunk.isEmpty { break }
      payload.append(chunk)
      guard payload.count <= maximumBytes else {
        throw EvidenceOutboxStoreError.artifactTooLarge
      }
    }
    guard !payload.isEmpty else { throw EvidenceOutboxStoreError.artifactChangedDuringRead }
    if let expectedByteCount = artifact.expectedByteCount,
      payload.count != expectedByteCount
    {
      throw EvidenceOutboxStoreError.artifactChangedDuringRead
    }
    if let expectedSHA256 = artifact.expectedSHA256,
      Self.sha256(payload) != expectedSHA256
    {
      throw EvidenceOutboxStoreError.artifactChangedDuringRead
    }
    return payload
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

struct EvidenceOutboxPayloadValidationResult: Equatable, Sendable {
  let byteCount: Int
  let sha256: String
  let validatorThreadWasMain: Bool
}

enum EvidenceOutboxPayloadFileValidator {
  static func validate(
    record: StoredEvidenceOutboxRecord,
    url: URL
  ) async throws -> EvidenceOutboxPayloadValidationResult {
    try await Task.detached(priority: .utility) {
      try validateSynchronously(record: record, url: url)
    }.value
  }

  static func validateSynchronously(
    record: StoredEvidenceOutboxRecord,
    url: URL
  ) throws -> EvidenceOutboxPayloadValidationResult {
    try Task.checkCancellation()
    let envelope = record.envelope
    let maximumBytes = maximumBytes(for: envelope.contentType)
    guard envelope.contract == "evidence.outbox-envelope",
      envelope.contractVersion == "1.0.0",
      envelope.redactionPolicy == "OWNER_PRIVATE_V1",
      envelope.byteCount > 0,
      envelope.byteCount <= maximumBytes,
      EvidenceOutboxEnvelope.allowedContentTypes.contains(envelope.contentType),
      isWallTime(envelope.createdAt),
      isLowercaseSHA256(envelope.sha256),
      envelope.authority.mayInterpret,
      envelope.authority.mayProposeExperiment,
      !envelope.authority.mayActivateExperiment,
      !envelope.authority.mayEmitVehicleFrames
    else { throw EvidenceOutboxError.invalidEnvelope }

    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, values.fileSize == envelope.byteCount else {
      throw EvidenceOutboxStoreError.invalidStoredMetadata
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    var byteCount = 0
    while true {
      try Task.checkCancellation()
      let remaining = maximumBytes - byteCount
      guard remaining >= 0 else { throw EvidenceOutboxStoreError.artifactTooLarge }
      let chunk = try handle.read(upToCount: min(64 * 1024, remaining + 1)) ?? Data()
      if chunk.isEmpty { break }
      byteCount += chunk.count
      guard byteCount <= maximumBytes else { throw EvidenceOutboxStoreError.artifactTooLarge }
      hasher.update(data: chunk)
    }
    let digest = Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    guard byteCount == envelope.byteCount, digest == envelope.sha256 else {
      throw EvidenceOutboxError.invalidEnvelope
    }
    return EvidenceOutboxPayloadValidationResult(
      byteCount: byteCount,
      sha256: digest,
      validatorThreadWasMain: Thread.isMainThread)
  }

  static func maximumBytes(for contentType: String) -> Int {
    switch contentType {
    case "application/vnd.vhos.evidence-sync+zip":
      return EvidenceSyncBundle.maximumArchiveByteCount
    case "application/vnd.vhos.import-provenance-receipt+json":
      return PortableFrameStore.productionImportReceiptByteLimit
    default:
      return 16 * 1024 * 1024
    }
  }

  private static func isLowercaseSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
  }

  private static func isWallTime(_ value: String) -> Bool {
    let pattern =
      "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])[Tt]([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\\.[0-9]+)?([Zz]|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"
    guard value.range(of: pattern, options: .regularExpression) != nil else { return false }
    let parts = value.prefix(10).split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3,
      let year = Int(parts[0]),
      let month = Int(parts[1]),
      let day = Int(parts[2])
    else { return false }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
      return false
    }
    let checked = calendar.dateComponents([.year, .month, .day], from: date)
    return checked.year == year && checked.month == month && checked.day == day
  }
}

struct EvidenceOutboxUploader {
  func upload(
    _ record: StoredEvidenceOutboxRecord,
    payloadURL: URL,
    endpoint: URL,
    bearerToken: String
  ) async throws {
    guard endpoint.scheme?.lowercased() == "https", endpoint.host != nil else {
      throw EvidenceOutboxStoreError.httpsEndpointRequired
    }
    _ = try await EvidenceOutboxPayloadFileValidator.validate(record: record, url: payloadURL)
    try Task.checkCancellation()
    let envelopeBytes = try VHOSJSON.encoder().encode(record.envelope)
    var request = URLRequest(
      url: endpoint.appendingPathComponent(record.envelope.packageID.uuidString.lowercased()))
    request.httpMethod = "POST"
    request.setValue(record.envelope.contentType, forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    request.setValue(record.envelope.packageID.uuidString, forHTTPHeaderField: "Idempotency-Key")
    request.setValue(record.envelope.sha256, forHTTPHeaderField: "X-VHOS-SHA256")
    request.setValue(
      envelopeBytes.base64EncodedString(), forHTTPHeaderField: "X-VHOS-Envelope-Base64")
    let (_, response) = try await URLSession.shared.upload(
      for: request,
      fromFile: payloadURL,
      delegate: EvidenceOutboxRedirectRejector()
    )
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw EvidenceOutboxStoreError.uploadRejected(
        (response as? HTTPURLResponse)?.statusCode ?? -1)
    }
  }
}

private final class EvidenceOutboxRedirectRejector: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

enum EvidenceOutboxStoreError: Error, LocalizedError {
  case capacityReached
  case invalidArtifactIdentity
  case invalidStoredMetadata
  case artifactIdentityConflict(String)
  case unsupportedContentType
  case invalidPageSize
  case artifactNotRegularFile
  case artifactTooLarge
  case artifactChangedDuringRead
  case invalidAcknowledgementCatalog
  case httpsEndpointRequired
  case uploadRejected(Int)

  var errorDescription: String? {
    switch self {
    case .capacityReached:
      "The private evidence outbox reached its bounded 512-pending-package capacity. Original immutable generations remain intact; retry or resolve pending uploads, or use the complete paged manual export."
    case .invalidArtifactIdentity:
      "The evidence artifact identity is empty, non-canonical, or too long."
    case .invalidStoredMetadata:
      "The evidence outbox package metadata or payload path is invalid."
    case .artifactIdentityConflict(let identity):
      "Evidence artifact identity \(identity) is already bound to different payload bytes."
    case .unsupportedContentType:
      "The evidence artifact content type is not supported by the private outbox."
    case .invalidPageSize:
      "Automatic evidence pages are fixed at two artifacts and manual pages must contain one through eight artifacts."
    case .artifactNotRegularFile:
      "The evidence artifact URL is not a regular file."
    case .artifactTooLarge:
      "The evidence artifact exceeds its bounded content-type limit."
    case .artifactChangedDuringRead:
      "The evidence artifact changed or did not match its immutable size and digest."
    case .invalidAcknowledgementCatalog:
      "The checksummed upload acknowledgement catalog is unavailable or failed validation."
    case .httpsEndpointRequired:
      "The private evidence inbox must use an HTTPS endpoint."
    case .uploadRejected(let status):
      "The private evidence inbox rejected the package with HTTP status \(status)."
    }
  }
}
