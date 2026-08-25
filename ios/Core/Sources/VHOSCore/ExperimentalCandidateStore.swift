import CryptoKit
import Foundation

/// Immutable capture provenance retained beside an experimental signal candidate.
///
/// This is deliberately a snapshot rather than a reference to "the latest" capture metadata.
/// Re-analysis or a corrected hypothesis creates a new `CandidateSignal` identity and a new ledger
/// entry; neither the candidate nor its evidence provenance is rewritten in place.
public struct ExperimentalCandidateCaptureProvenance: Codable, Equatable, Sendable, Identifiable {
  public let contract: String
  public let contractVersion: String
  public let captureID: String
  public let vehicleID: String
  public let vehicleProfileSHA256: String
  public let archiveSHA256: String
  public let manifestSHA256: String
  public let startedAt: String
  public let endedAt: String
  public let wallClockBasis: CaptureWallClockBasis
  public let startMonotonicMicroseconds: UInt64
  public let endMonotonicMicroseconds: UInt64
  public let gatewayID: String
  public let gatewayHardwareRevision: String?
  public let gatewayFirmwareVersion: String?
  public let gatewayFirmwareBuildID: String?
  public let gatewayProtocolVersion: String?
  public let gatewayActiveConfigID: String?
  public let gatewayActiveConfigVersion: String?
  public let gatewaySessionIDs: [UInt32]
  public let busBitratesBps: [UInt32]
  public let listenOnly: Bool
  public let retainedRecordCount: Int
  public let firstSourceSequence: UInt64
  public let lastSourceSequence: UInt64
  /// Acquisition scope resolved from the exact finalized manifest. Development-lab evidence stays
  /// visibly DEBUG/UNVERIFIED throughout candidate review instead of being hidden behind a hash.
  public let acquisitionAuthority: DiscoveryMutationAuthority
  public let testTemplateID: String?
  public let testTemplateVersion: String?
  public let eventMarkerIDs: [String]
  public let physicalMeasurementIDs: [String]

  public var id: String { captureID }

  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion, startedAt, endedAt, wallClockBasis
    case startMonotonicMicroseconds
    case endMonotonicMicroseconds, gatewayHardwareRevision, gatewayFirmwareVersion
    case gatewayProtocolVersion, gatewayActiveConfigVersion, busBitratesBps, listenOnly
    case retainedRecordCount, firstSourceSequence, lastSourceSequence, acquisitionAuthority
    case testTemplateVersion
    case captureID = "captureId"
    case vehicleID = "vehicleId"
    case vehicleProfileSHA256 = "vehicleProfileSha256"
    case archiveSHA256 = "archiveSha256"
    case manifestSHA256 = "manifestSha256"
    case gatewayID = "gatewayId"
    case gatewayFirmwareBuildID = "gatewayFirmwareBuildId"
    case gatewayActiveConfigID = "gatewayActiveConfigId"
    case gatewaySessionIDs = "gatewaySessionIds"
    case testTemplateID = "testTemplateId"
    case eventMarkerIDs = "eventMarkerIds"
    case physicalMeasurementIDs = "physicalMeasurementIds"
  }

  public init(finalizedCapture: FinalizedCaptureLedgerEntry) throws {
    try finalizedCapture.validateContract()
    let capture = finalizedCapture.capture
    try capture.validateContract()
    contract = "vhos.discovery.experimental-candidate-capture-provenance"
    contractVersion = "1.0.0"
    captureID = capture.id
    vehicleID = capture.vehicleID
    vehicleProfileSHA256 = capture.vehicleProfileSHA256
    archiveSHA256 = capture.archiveSHA256
    manifestSHA256 = capture.manifestSHA256
    startedAt = capture.startedAt
    endedAt = capture.endedAt
    wallClockBasis = capture.wallClockBasis
    startMonotonicMicroseconds = capture.startMonotonicMicroseconds
    endMonotonicMicroseconds = capture.endMonotonicMicroseconds
    gatewayID = capture.gateway.gatewayID
    gatewayHardwareRevision = capture.gateway.hardwareRevision
    gatewayFirmwareVersion = capture.gateway.firmwareVersion
    gatewayFirmwareBuildID = capture.gateway.firmwareBuildID
    gatewayProtocolVersion = capture.gateway.protocolVersion
    gatewayActiveConfigID = capture.gateway.activeConfigID
    gatewayActiveConfigVersion = capture.gateway.activeConfigVersion
    gatewaySessionIDs = capture.gatewaySessionIDs
    busBitratesBps = capture.busBitratesBps
    listenOnly = capture.listenOnly
    retainedRecordCount = capture.retainedRecordCount
    firstSourceSequence = capture.firstSourceSequence
    lastSourceSequence = capture.lastSourceSequence
    acquisitionAuthority = finalizedCapture.manifest.terminalRun.acquisitionAuthority
    testTemplateID = capture.testTemplateID
    testTemplateVersion = capture.testTemplateVersion
    eventMarkerIDs = capture.eventMarkers.map(\.id).sorted()
    physicalMeasurementIDs = capture.physicalMeasurements.map(\.id).sorted()
  }

  public func validateContract() throws {
    let templatePairIsComplete = (testTemplateID == nil) == (testTemplateVersion == nil)
    guard contract == "vhos.discovery.experimental-candidate-capture-provenance",
      contractVersion == "1.0.0",
      DiscoveryContractValidation.isDomainID(captureID, prefix: "capture"),
      DiscoveryContractValidation.isDomainID(vehicleID, prefix: "veh"),
      DiscoveryContractValidation.isSHA256(vehicleProfileSHA256),
      DiscoveryContractValidation.isSHA256(archiveSHA256),
      DiscoveryContractValidation.isSHA256(manifestSHA256),
      let start = DiscoveryContractValidation.wallDate(startedAt),
      let end = DiscoveryContractValidation.wallDate(endedAt), start <= end,
      startMonotonicMicroseconds <= endMonotonicMicroseconds,
      DiscoveryContractValidation.isBoundedText(gatewayID, maximum: 160),
      [
        gatewayHardwareRevision, gatewayFirmwareVersion, gatewayFirmwareBuildID,
        gatewayProtocolVersion, gatewayActiveConfigID, gatewayActiveConfigVersion,
      ].allSatisfy({ value in
        value.map({ DiscoveryContractValidation.isBoundedText($0, maximum: 160) }) ?? true
      }),
      !gatewaySessionIDs.isEmpty, Set(gatewaySessionIDs).count == gatewaySessionIDs.count,
      !busBitratesBps.isEmpty,
      busBitratesBps.allSatisfy({ $0 == 250_000 || $0 == 500_000 }),
      listenOnly, retainedRecordCount > 0, firstSourceSequence > 0,
      firstSourceSequence <= lastSourceSequence, templatePairIsComplete,
      testTemplateID.map(DiscoveryContractValidation.isSemanticID) ?? true,
      testTemplateVersion.map(DiscoveryContractValidation.isSemanticVersion) ?? true,
      Set(eventMarkerIDs).count == eventMarkerIDs.count,
      eventMarkerIDs.allSatisfy({
        DiscoveryContractValidation.isDomainID($0, prefix: "marker")
      }),
      Set(physicalMeasurementIDs).count == physicalMeasurementIDs.count,
      physicalMeasurementIDs.allSatisfy({
        DiscoveryContractValidation.isDomainID($0, prefix: "measurement")
      })
    else { throw ExperimentalCandidateStoreError.invalidCaptureProvenance }
  }
}

/// One immutable, append-only local snapshot of an experimental candidate and its source evidence.
///
/// `promotionAllowed` and `authority` are encoded in every line and fail closed during decoding.
/// The local store can retain and reload hypotheses while fully offline, but it cannot manufacture
/// `VEHICLE_VALIDATED` or `PROMOTED` authority.
public struct ExperimentalCandidateLedgerEntry: Codable, Equatable, Sendable, Identifiable {
  public let contract: String
  public let contractVersion: String
  public let id: String
  public let savedAt: String
  public let candidate: CandidateSignal
  public let candidateSHA256: String
  public let captureProvenance: [ExperimentalCandidateCaptureProvenance]
  public let evidenceReferences: [String]
  public let provenanceSHA256: String
  public let promotionAllowed: Bool
  public let authority: DiscoveryAuthorityStatus

  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion, id, savedAt, candidate, captureProvenance
    case evidenceReferences, promotionAllowed, authority
    case candidateSHA256 = "candidateSha256"
    case provenanceSHA256 = "provenanceSha256"
  }

  public init(
    id: String,
    savedAt: String,
    candidate: CandidateSignal,
    finalizedCaptures: [FinalizedCaptureLedgerEntry]
  ) throws {
    let provenance = try finalizedCaptures.map(
      ExperimentalCandidateCaptureProvenance.init(finalizedCapture:)
    ).sorted { $0.captureID < $1.captureID }
    try self.init(
      id: id,
      savedAt: savedAt,
      candidate: candidate,
      captureProvenance: provenance)
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let contract = try values.decode(String.self, forKey: .contract)
    let version = try values.decode(String.self, forKey: .contractVersion)
    let storedCandidateDigest = try values.decode(String.self, forKey: .candidateSHA256)
    let storedProvenance = try values.decode(
      [ExperimentalCandidateCaptureProvenance].self,
      forKey: .captureProvenance)
    let storedReferences = try values.decode([String].self, forKey: .evidenceReferences)
    let storedProvenanceDigest = try values.decode(String.self, forKey: .provenanceSHA256)
    let storedPromotionAllowed = try values.decode(Bool.self, forKey: .promotionAllowed)
    let storedAuthority = try values.decode(DiscoveryAuthorityStatus.self, forKey: .authority)
    let candidate = try values.decode(CandidateSignal.self, forKey: .candidate)

    guard contract == "vhos.discovery.experimental-candidate-ledger-entry",
      version == "1.0.0", !storedPromotionAllowed, storedAuthority == .candidate
    else { throw ExperimentalCandidateStoreError.invalidEntry }

    let reconstructed = try ExperimentalCandidateLedgerEntry(
      id: values.decode(String.self, forKey: .id),
      savedAt: values.decode(String.self, forKey: .savedAt),
      candidate: candidate,
      captureProvenance: storedProvenance)
    guard reconstructed.candidateSHA256 == storedCandidateDigest,
      reconstructed.captureProvenance == storedProvenance,
      reconstructed.evidenceReferences == storedReferences,
      reconstructed.provenanceSHA256 == storedProvenanceDigest
    else { throw ExperimentalCandidateStoreError.invalidEntry }
    self = reconstructed
  }

  private init(
    id: String,
    savedAt: String,
    candidate: CandidateSignal,
    captureProvenance provenance: [ExperimentalCandidateCaptureProvenance]
  ) throws {
    try candidate.validateContract()
    guard DiscoveryContractValidation.isDomainID(id, prefix: "candidateentry"),
      DiscoveryContractValidation.isWallTime(savedAt), !provenance.isEmpty,
      candidate.authority == .candidate
    else { throw ExperimentalCandidateStoreError.invalidEntry }
    for item in provenance { try item.validateContract() }
    let sortedProvenance = provenance.sorted { $0.captureID < $1.captureID }
    let captureIDs = sortedProvenance.map(\.captureID)
    guard captureIDs.count == Set(captureIDs).count,
      captureIDs == candidate.captureIDs,
      candidate.metrics.analyzedCaptureCount == captureIDs.count,
      Set(candidate.eventMarkerIDs).isSubset(
        of: Set(sortedProvenance.flatMap(\.eventMarkerIDs))),
      Set(candidate.testTemplateIDs).isSubset(
        of: Set(sortedProvenance.compactMap(\.testTemplateID)))
    else { throw ExperimentalCandidateStoreError.evidenceDoesNotMatchCandidate }

    let references = Self.evidenceReferences(
      candidate: candidate,
      provenance: sortedProvenance)
    guard !references.isEmpty else {
      throw ExperimentalCandidateStoreError.evidenceDoesNotMatchCandidate
    }

    contract = "vhos.discovery.experimental-candidate-ledger-entry"
    contractVersion = "1.0.0"
    self.id = id
    self.savedAt = savedAt
    self.candidate = candidate
    candidateSHA256 = Self.sha256(try VHOSJSON.encoder().encode(candidate))
    captureProvenance = sortedProvenance
    evidenceReferences = references
    provenanceSHA256 = Self.provenanceDigest(
      captureProvenance: sortedProvenance,
      evidenceReferences: references)
    promotionAllowed = false
    authority = .candidate
  }

  public func validateContract() throws {
    guard contract == "vhos.discovery.experimental-candidate-ledger-entry",
      contractVersion == "1.0.0", !promotionAllowed, authority == .candidate,
      DiscoveryContractValidation.isSHA256(candidateSHA256),
      DiscoveryContractValidation.isSHA256(provenanceSHA256)
    else { throw ExperimentalCandidateStoreError.invalidEntry }
    try candidate.validateContract()
    for provenance in captureProvenance { try provenance.validateContract() }
    guard candidateSHA256 == Self.sha256(try VHOSJSON.encoder().encode(candidate)),
      provenanceSHA256 == Self.provenanceDigest(
        captureProvenance: captureProvenance,
        evidenceReferences: evidenceReferences),
      captureProvenance.map(\.captureID) == candidate.captureIDs,
      candidate.metrics.analyzedCaptureCount == captureProvenance.count,
      evidenceReferences == Self.evidenceReferences(
        candidate: candidate,
        provenance: captureProvenance)
    else { throw ExperimentalCandidateStoreError.evidenceDoesNotMatchCandidate }
  }

  private static func evidenceReferences(
    candidate: CandidateSignal,
    provenance: [ExperimentalCandidateCaptureProvenance]
  ) -> [String] {
    Array(
      Set(
        candidate.sourceReferences + candidate.independentEvidenceReferences
          + provenance.flatMap {
            [
              "capture-archive-sha256:\($0.archiveSHA256)",
              "capture-manifest-sha256:\($0.manifestSHA256)",
              "capture-acquisition-authority:\($0.acquisitionAuthority.rawValue)",
            ]
          }
      )
    ).sorted()
  }

  private static func provenanceDigest(
    captureProvenance: [ExperimentalCandidateCaptureProvenance],
    evidenceReferences: [String]
  ) -> String {
    let envelope = ProvenanceDigestEnvelope(
      captureProvenance: captureProvenance,
      evidenceReferences: evidenceReferences)
    return sha256(try! VHOSJSON.encoder().encode(envelope))
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private struct ProvenanceDigestEnvelope: Codable {
  let captureProvenance: [ExperimentalCandidateCaptureProvenance]
  let evidenceReferences: [String]
}

public struct ExperimentalCandidateLedgerSnapshot: Equatable, Sendable {
  public let entries: [ExperimentalCandidateLedgerEntry]
  public let recovery: AppendOnlyNDJSONTailRecovery?

  public init(
    entries: [ExperimentalCandidateLedgerEntry],
    recovery: AppendOnlyNDJSONTailRecovery?
  ) {
    self.entries = entries
    self.recovery = recovery
  }
}

/// Device-local append-only candidate persistence. It intentionally has no networking dependency.
public final class ExperimentalCandidateStore: @unchecked Sendable {
  public static let ledgerFileName = "experimental-candidates.ndjson"
  public static let maximumEntryCount = 10_000
  public static let maximumEncodedEntryBytes = 4 * 1_024 * 1_024

  public let storageDirectory: URL
  public let ledgerURL: URL
  public let quarantineDirectory: URL

  private let fileManager: FileManager
  /// Shared by every store instance resolving to the same canonical ledger path. Candidate append
  /// is a load/check/write transaction, so an instance-local lock is insufficient when the app,
  /// replay lab, and background analysis each construct their own store.
  private let pathLock: NSLock

  public init(storageDirectory: URL, fileManager: FileManager = .default) {
    self.storageDirectory = storageDirectory
    self.fileManager = fileManager
    ledgerURL = storageDirectory.appendingPathComponent(Self.ledgerFileName)
    quarantineDirectory = storageDirectory.appendingPathComponent(
      "InterruptedExperimentalCandidateLedger",
      isDirectory: true)
    pathLock = ExperimentalCandidatePathLockRegistry.shared.lock(
      for: ledgerURL.standardizedFileURL.path)
  }

  /// Returns the committed ledger from disk. A missing ledger is a valid empty offline state.
  public func load() throws -> ExperimentalCandidateLedgerSnapshot {
    try withLock { try loadUnlocked() }
  }

  /// Convenience list operation that always reloads committed disk state.
  public func list() throws -> [ExperimentalCandidateLedgerEntry] {
    try load().entries
  }

  /// Appends one immutable candidate snapshot. Saving the same candidate identity twice is rejected;
  /// a corrected or re-analyzed hypothesis must receive a new `candidate_...` identity.
  ///
  /// Candidate provenance is resolved through `FinalizedCaptureStore` immediately before append.
  /// Bare in-memory `CaptureSession` values are intentionally not accepted at this boundary.
  @discardableResult
  public func save(
    candidate: CandidateSignal,
    finalizedCaptureStore: FinalizedCaptureStore,
    savedAt: String
  ) throws -> ExperimentalCandidateLedgerEntry {
    let finalizedEntries = try finalizedCaptureStore.resolvedEntries(
      captureIDs: candidate.captureIDs)
    return try withLock {
      let entry = try ExperimentalCandidateLedgerEntry(
        id: DiscoveryIDGenerator.make(prefix: "candidateentry"),
        savedAt: savedAt,
        candidate: candidate,
        finalizedCaptures: finalizedEntries)
      let current = try loadUnlocked().entries
      guard current.count < Self.maximumEntryCount else {
        throw ExperimentalCandidateStoreError.capacityExceeded
      }
      guard !current.contains(where: { $0.id == entry.id }) else {
        throw ExperimentalCandidateStoreError.duplicateEntryIdentity(entry.id)
      }
      guard !current.contains(where: { $0.candidate.id == candidate.id }) else {
        throw ExperimentalCandidateStoreError.duplicateCandidateIdentity(candidate.id)
      }
      let encoded = try VHOSJSON.encoder().encode(entry)
      guard encoded.count <= Self.maximumEncodedEntryBytes else {
        throw ExperimentalCandidateStoreError.entryTooLarge(encoded.count)
      }
      try DurableEvidenceFile.ensureDirectory(storageDirectory, fileManager: fileManager)
      try DurableEvidenceFile.appendCommittedLine(
        encoded,
        to: ledgerURL,
        fileManager: fileManager)
      return entry
    }
  }

  private func loadUnlocked() throws -> ExperimentalCandidateLedgerSnapshot {
    let result: AppendOnlyNDJSONLoadResult<ExperimentalCandidateLedgerEntry> =
      try AppendOnlyNDJSONLedger.load(
      from: ledgerURL,
      quarantineDirectory: quarantineDirectory,
      fileManager: fileManager
    ) { entry in
      try entry.validateContract()
    }
    guard result.records.count <= Self.maximumEntryCount else {
      throw ExperimentalCandidateStoreError.capacityExceeded
    }
    var entryIDs = Set<String>()
    var candidateIDs = Set<String>()
    for entry in result.records {
      guard entryIDs.insert(entry.id).inserted else {
        throw ExperimentalCandidateStoreError.duplicateEntryIdentity(entry.id)
      }
      guard candidateIDs.insert(entry.candidate.id).inserted else {
        throw ExperimentalCandidateStoreError.duplicateCandidateIdentity(entry.candidate.id)
      }
    }
    return ExperimentalCandidateLedgerSnapshot(
      entries: result.records,
      recovery: result.recovery)
  }

  private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
    pathLock.lock()
    defer { pathLock.unlock() }
    return try operation()
  }
}

private final class ExperimentalCandidatePathLockRegistry: @unchecked Sendable {
  static let shared = ExperimentalCandidatePathLockRegistry()

  private let registryLock = NSLock()
  private var locksByCanonicalPath: [String: NSLock] = [:]

  func lock(for canonicalPath: String) -> NSLock {
    registryLock.lock()
    defer { registryLock.unlock() }
    if let existing = locksByCanonicalPath[canonicalPath] { return existing }
    let created = NSLock()
    locksByCanonicalPath[canonicalPath] = created
    return created
  }
}

public enum ExperimentalCandidateStoreError: Error, Equatable, LocalizedError {
  case invalidCaptureProvenance
  case invalidEntry
  case evidenceDoesNotMatchCandidate
  case duplicateEntryIdentity(String)
  case duplicateCandidateIdentity(String)
  case capacityExceeded
  case entryTooLarge(Int)

  public var errorDescription: String? {
    switch self {
    case .invalidCaptureProvenance:
      "The experimental candidate capture provenance is invalid."
    case .invalidEntry:
      "The append-only experimental candidate entry is invalid."
    case .evidenceDoesNotMatchCandidate:
      "The candidate does not match its immutable evidence provenance."
    case .duplicateEntryIdentity(let id):
      "Experimental candidate ledger entry \(id) is already committed."
    case .duplicateCandidateIdentity(let id):
      "Experimental candidate \(id) is already committed; corrections require a new identity."
    case .capacityExceeded:
      "The local experimental candidate ledger reached its bounded entry capacity."
    case .entryTooLarge(let bytes):
      "The experimental candidate entry is too large to append safely (\(bytes) bytes)."
    }
  }
}
