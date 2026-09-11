import CryptoKit
import Foundation

private enum MechanicDiagnosticCaseLedgerEntryError: Error {
  case unsupportedEnvelope
  case revisionDigestMismatch
  case predecessorDigestMismatch
}

/// The private persistence boundary for one case revision.
///
/// The revision digest binds the exact canonical encoding of `revision`. The predecessor digest
/// binds this entry to the prior committed revision for the same case, even when cases are
/// interleaved in the NDJSON ledger.
private struct MechanicDiagnosticCaseLedgerEntry: Codable, Sendable {
  static let currentContract = "vhos.mechanic-diagnostic-case-ledger-entry"
  static let currentContractVersion = "1.0.0"

  let contract: String
  let contractVersion: String
  let revisionSHA256: String
  let predecessorRevisionSHA256: String?
  let revision: MechanicDiagnosticCaseRevision

  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion
    case revisionSHA256 = "revisionSha256"
    case predecessorRevisionSHA256 = "predecessorRevisionSha256"
    case revision
  }

  init(
    revision: MechanicDiagnosticCaseRevision,
    predecessorRevisionSHA256: String?
  ) throws {
    contract = Self.currentContract
    contractVersion = Self.currentContractVersion
    revisionSHA256 = try Self.digest(revision)
    self.predecessorRevisionSHA256 = predecessorRevisionSHA256
    self.revision = revision
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard container.contains(.contract), container.contains(.contractVersion),
      container.contains(.revisionSHA256), container.contains(.predecessorRevisionSHA256),
      container.contains(.revision)
    else {
      throw MechanicDiagnosticCaseLedgerEntryError.unsupportedEnvelope
    }
    contract = try container.decode(String.self, forKey: .contract)
    contractVersion = try container.decode(String.self, forKey: .contractVersion)
    revisionSHA256 = try container.decode(String.self, forKey: .revisionSHA256)
    predecessorRevisionSHA256 = try container.decodeIfPresent(
      String.self, forKey: .predecessorRevisionSHA256)
    revision = try container.decode(MechanicDiagnosticCaseRevision.self, forKey: .revision)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(contract, forKey: .contract)
    try container.encode(contractVersion, forKey: .contractVersion)
    try container.encode(revisionSHA256, forKey: .revisionSHA256)
    if let predecessorRevisionSHA256 {
      try container.encode(predecessorRevisionSHA256, forKey: .predecessorRevisionSHA256)
    } else {
      try container.encodeNil(forKey: .predecessorRevisionSHA256)
    }
    try container.encode(revision, forKey: .revision)
  }

  func validate(expectedPredecessorRevisionSHA256: String?) throws {
    guard contract == Self.currentContract, contractVersion == Self.currentContractVersion else {
      throw MechanicDiagnosticCaseLedgerEntryError.unsupportedEnvelope
    }
    guard revisionSHA256 == (try Self.digest(revision)) else {
      throw MechanicDiagnosticCaseLedgerEntryError.revisionDigestMismatch
    }
    guard predecessorRevisionSHA256 == expectedPredecessorRevisionSHA256 else {
      throw MechanicDiagnosticCaseLedgerEntryError.predecessorDigestMismatch
    }
  }

  static func digest(_ revision: MechanicDiagnosticCaseRevision) throws -> String {
    SHA256.hash(data: try revision.encoded()).map { String(format: "%02x", $0) }.joined()
  }

  func encoded() throws -> Data {
    try VHOSJSON.encoder().encode(self)
  }
}

public struct MechanicDiagnosticCaseLedgerLoadResult: Equatable, Sendable {
  public let revisionCount: Int
  public let latestCases: [MechanicDiagnosticCaseRevision]
  public let tailRecovery: AppendOnlyNDJSONTailRecovery?

  public init(
    revisionCount: Int,
    latestCases: [MechanicDiagnosticCaseRevision],
    tailRecovery: AppendOnlyNDJSONTailRecovery?
  ) {
    self.revisionCount = revisionCount
    self.latestCases = latestCases
    self.tailRecovery = tailRecovery
  }
}

public enum MechanicDiagnosticCaseLedgerError: Error, Equatable, LocalizedError {
  case revisionIdentityCollision(String)
  case caseIdentityCollision(String)
  case missingInitialRevision(String)
  case staleRevision(caseID: String, expectedRevisionID: String)
  case invalidRevisionNumber(caseID: String, expected: Int, actual: Int)
  case snapshotIdentityChanged(String)
  case caseResurrection(String)
  case createdAtMovedBackward(String)

  public var errorDescription: String? {
    switch self {
    case .revisionIdentityCollision(let revisionID):
      "Revision ID \(revisionID) is already bound to different evidence."
    case .caseIdentityCollision(let caseID):
      "Case ID \(caseID) already has an initial revision."
    case .missingInitialRevision(let caseID):
      "Case \(caseID) must begin with revision 1."
    case .staleRevision(let caseID, let expectedRevisionID):
      "Case \(caseID) must supersede latest revision \(expectedRevisionID)."
    case .invalidRevisionNumber(let caseID, let expected, let actual):
      "Case \(caseID) expected revision \(expected), not \(actual)."
    case .snapshotIdentityChanged(let caseID):
      "Case \(caseID) cannot change organization, customer, or vehicle identity."
    case .caseResurrection(let caseID):
      "Voided case \(caseID) cannot be revised."
    case .createdAtMovedBackward(let caseID):
      "Case \(caseID) revision time cannot move backward."
    }
  }
}

/// A durable, local-only append ledger for technician-authored diagnostic case revisions.
///
/// Newline is the commit boundary. Loading validates the complete committed revision chain before
/// recovering an interrupted tail, so committed corruption never becomes an apparently empty UI.
public final class MechanicDiagnosticCaseLedger: @unchecked Sendable {
  public let storageDirectory: URL
  public let ledgerURL: URL
  public let quarantineDirectory: URL

  private let fileManager: FileManager
  /// Serializes the load/check/append transaction across every in-process ledger instance that
  /// resolves to this canonical path.
  private let pathLock: NSLock
  private var revisions: [MechanicDiagnosticCaseRevision]
  private var recovery: AppendOnlyNDJSONTailRecovery?

  public init(
    storageDirectory: URL? = nil,
    fileManager: FileManager = .default
  ) throws {
    self.fileManager = fileManager
    let resolvedDirectory: URL
    if let storageDirectory {
      resolvedDirectory = storageDirectory
    } else if let applicationSupport = fileManager.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first {
      resolvedDirectory =
        applicationSupport
        .appendingPathComponent("VehicleHealthOS", isDirectory: true)
        .appendingPathComponent("MechanicDiagnosticCases", isDirectory: true)
    } else {
      throw CocoaError(.fileNoSuchFile)
    }
    self.storageDirectory = resolvedDirectory
    self.ledgerURL = resolvedDirectory.appendingPathComponent("diagnostic-case-revisions.ndjson")
    self.quarantineDirectory = resolvedDirectory.appendingPathComponent(
      "quarantine", isDirectory: true)
    self.pathLock = MechanicDiagnosticCasePathLockRegistry.shared.lock(
      for: self.ledgerURL.standardizedFileURL.path)
    self.revisions = []
    self.recovery = nil

    try DurableEvidenceFile.ensureDirectory(resolvedDirectory, fileManager: fileManager)
    try DurableEvidenceFile.ensureDirectory(quarantineDirectory, fileManager: fileManager)
    try Self.applyCompleteFileProtection(
      to: [resolvedDirectory, quarantineDirectory], fileManager: fileManager)
    _ = try reload()
  }

  public var lastTailRecovery: AppendOnlyNDJSONTailRecovery? {
    pathLock.lock()
    defer { pathLock.unlock() }
    return recovery
  }

  @discardableResult
  public func reload() throws -> MechanicDiagnosticCaseLedgerLoadResult {
    pathLock.lock()
    defer { pathLock.unlock() }
    return try loadLocked()
  }

  /// Returns false only when the exact canonical revision is already committed.
  @discardableResult
  public func append(_ revision: MechanicDiagnosticCaseRevision) throws -> Bool {
    pathLock.lock()
    defer { pathLock.unlock() }

    // Reload under the same lock so multiple ledger instances cannot overwrite chain knowledge.
    _ = try loadLocked()
    try revision.validateContract()
    let encoded = try revision.encoded()
    if let existing = revisions.first(where: { $0.revisionID == revision.revisionID }) {
      if try existing.encoded() == encoded { return false }
      throw MechanicDiagnosticCaseLedgerError.revisionIdentityCollision(revision.revisionID)
    }
    try Self.validateAppend(revision, against: revisions)
    let predecessorRevisionSHA256: String?
    if let predecessor = revisions.last(where: { $0.caseID == revision.caseID }) {
      predecessorRevisionSHA256 = try MechanicDiagnosticCaseLedgerEntry.digest(predecessor)
    } else {
      predecessorRevisionSHA256 = nil
    }
    let entry = try MechanicDiagnosticCaseLedgerEntry(
      revision: revision,
      predecessorRevisionSHA256: predecessorRevisionSHA256)
    try DurableEvidenceFile.appendCommittedLine(
      try entry.encoded(), to: ledgerURL, fileManager: fileManager)
    try Self.applyCompleteFileProtection(to: [ledgerURL], fileManager: fileManager)
    revisions.append(revision)
    return true
  }

  public func latestCases() -> [MechanicDiagnosticCaseRevision] {
    pathLock.lock()
    defer { pathLock.unlock() }
    return Self.latestCases(from: revisions)
  }

  public func latest(caseID: String) -> MechanicDiagnosticCaseRevision? {
    pathLock.lock()
    defer { pathLock.unlock() }
    return revisions.last(where: { $0.caseID == caseID })
  }

  public func revisions(caseID: String) -> [MechanicDiagnosticCaseRevision] {
    pathLock.lock()
    defer { pathLock.unlock() }
    return revisions.filter { $0.caseID == caseID }
  }

  private func loadLocked() throws -> MechanicDiagnosticCaseLedgerLoadResult {
    var validated: [MechanicDiagnosticCaseRevision] = []
    var latestRevisionSHA256ByCase: [String: String] = [:]
    let loaded: AppendOnlyNDJSONLoadResult<MechanicDiagnosticCaseLedgerEntry> =
      try AppendOnlyNDJSONLedger.load(
        from: ledgerURL,
        quarantineDirectory: quarantineDirectory,
        fileManager: fileManager
      ) { entry in
        let record = entry.revision
        try entry.validate(
          expectedPredecessorRevisionSHA256: latestRevisionSHA256ByCase[record.caseID])
        try record.validateContract()
        guard !validated.contains(where: { $0.revisionID == record.revisionID }) else {
          throw MechanicDiagnosticCaseLedgerError.revisionIdentityCollision(record.revisionID)
        }
        try Self.validateAppend(record, against: validated)
        validated.append(record)
        latestRevisionSHA256ByCase[record.caseID] = entry.revisionSHA256
      }
    revisions = loaded.records.map(\.revision)
    recovery = loaded.recovery
    var protectedURLs = [storageDirectory, quarantineDirectory]
    if fileManager.fileExists(atPath: ledgerURL.path) { protectedURLs.append(ledgerURL) }
    if let recovery = loaded.recovery { protectedURLs.append(recovery.quarantineURL) }
    try Self.applyCompleteFileProtection(to: protectedURLs, fileManager: fileManager)
    return MechanicDiagnosticCaseLedgerLoadResult(
      revisionCount: revisions.count,
      latestCases: Self.latestCases(from: revisions),
      tailRecovery: loaded.recovery)
  }

  private static func validateAppend(
    _ candidate: MechanicDiagnosticCaseRevision,
    against revisions: [MechanicDiagnosticCaseRevision]
  ) throws {
    let caseRevisions = revisions.filter { $0.caseID == candidate.caseID }
    guard let latest = caseRevisions.last else {
      guard candidate.revisionNumber == 1, candidate.supersedesRevisionID == nil,
        candidate.transition.action == .created
      else {
        throw MechanicDiagnosticCaseLedgerError.missingInitialRevision(candidate.caseID)
      }
      return
    }
    guard candidate.revisionNumber != 1 else {
      throw MechanicDiagnosticCaseLedgerError.caseIdentityCollision(candidate.caseID)
    }
    guard latest.status != .voided else {
      throw MechanicDiagnosticCaseLedgerError.caseResurrection(candidate.caseID)
    }
    guard candidate.supersedesRevisionID == latest.revisionID else {
      throw MechanicDiagnosticCaseLedgerError.staleRevision(
        caseID: candidate.caseID, expectedRevisionID: latest.revisionID)
    }
    let expectedNumber = latest.revisionNumber + 1
    guard candidate.revisionNumber == expectedNumber else {
      throw MechanicDiagnosticCaseLedgerError.invalidRevisionNumber(
        caseID: candidate.caseID, expected: expectedNumber, actual: candidate.revisionNumber)
    }
    guard candidate.organization.organizationID == latest.organization.organizationID,
      candidate.customer.customerID == latest.customer.customerID,
      candidate.vehicle.vehicleID == latest.vehicle.vehicleID
    else {
      throw MechanicDiagnosticCaseLedgerError.snapshotIdentityChanged(candidate.caseID)
    }
    guard candidate.transition.fromStatus == latest.status else {
      throw MechanicDiagnosticCaseError.invalidTransition(
        action: candidate.transition.action,
        from: candidate.transition.fromStatus,
        to: candidate.transition.toStatus)
    }
    try MechanicDiagnosticCaseTransitionPolicy.validate(
      action: candidate.transition.action,
      from: latest.status,
      to: candidate.status,
      reason: candidate.transition.reason)
    guard Self.date(candidate.createdAt) >= Self.date(latest.createdAt) else {
      throw MechanicDiagnosticCaseLedgerError.createdAtMovedBackward(candidate.caseID)
    }
  }

  private static func latestCases(
    from revisions: [MechanicDiagnosticCaseRevision]
  ) -> [MechanicDiagnosticCaseRevision] {
    var latestByCase: [String: MechanicDiagnosticCaseRevision] = [:]
    for revision in revisions { latestByCase[revision.caseID] = revision }
    return latestByCase.values.sorted {
      let lhs = date($0.createdAt)
      let rhs = date($1.createdAt)
      if lhs != rhs { return lhs > rhs }
      return $0.revisionID > $1.revisionID
    }
  }

  private static func date(_ value: String) -> Date {
    MechanicDiagnosticWallTime.date(value) ?? .distantPast
  }

  private static func applyCompleteFileProtection(
    to urls: [URL],
    fileManager: FileManager
  ) throws {
    #if os(iOS)
      for url in urls where fileManager.fileExists(atPath: url.path) {
        try fileManager.setAttributes(
          [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
      }
    #endif
  }
}

private final class MechanicDiagnosticCasePathLockRegistry: @unchecked Sendable {
  static let shared = MechanicDiagnosticCasePathLockRegistry()

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
