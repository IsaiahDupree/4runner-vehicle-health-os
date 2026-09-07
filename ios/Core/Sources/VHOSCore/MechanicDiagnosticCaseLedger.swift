import Foundation

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
    try DurableEvidenceFile.appendCommittedLine(
      encoded, to: ledgerURL, fileManager: fileManager)
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
    let loaded: AppendOnlyNDJSONLoadResult<MechanicDiagnosticCaseRevision> =
      try AppendOnlyNDJSONLedger.load(
        from: ledgerURL,
        quarantineDirectory: quarantineDirectory,
        fileManager: fileManager
      ) { record in
        try record.validateContract()
        guard !validated.contains(where: { $0.revisionID == record.revisionID }) else {
          throw MechanicDiagnosticCaseLedgerError.revisionIdentityCollision(record.revisionID)
        }
        try Self.validateAppend(record, against: validated)
        validated.append(record)
      }
    revisions = loaded.records
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
