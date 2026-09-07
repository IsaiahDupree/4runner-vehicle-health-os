import Foundation
import Testing

@testable import VHOSCore

@Test func mechanicDiagnosticCaseLedgerIsIdempotentAndSurvivesRestart() throws {
  let directory = mechanicLedgerDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let ledger = try MechanicDiagnosticCaseLedger(storageDirectory: directory)
  let root = try makeLedgerCase()
  #expect(try ledger.append(root))
  #expect(try !ledger.append(root))

  let inspection = try root.revising(
    status: .inspection,
    action: .inspectionStarted,
    evidence: [],
    hypotheses: [],
    finding: nil,
    verification: nil,
    createdAt: "2026-09-07T13:01:00Z",
    revisionID: ledgerID("caserev", "2"))
  #expect(try ledger.append(inspection))

  let restarted = try MechanicDiagnosticCaseLedger(storageDirectory: directory)
  #expect(restarted.latest(caseID: root.caseID) == inspection)
  #expect(restarted.revisions(caseID: root.caseID) == [root, inspection])
  #expect(restarted.lastTailRecovery == nil)
}

@Test func mechanicDiagnosticCaseLedgerRejectsStaleAndCollidingRevisions() throws {
  let directory = mechanicLedgerDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let ledger = try MechanicDiagnosticCaseLedger(storageDirectory: directory)
  let root = try makeLedgerCase()
  try ledger.append(root)
  let inspection = try root.revising(
    status: .inspection,
    action: .inspectionStarted,
    evidence: [],
    hypotheses: [],
    finding: nil,
    verification: nil,
    createdAt: "2026-09-07T13:01:00Z",
    revisionID: ledgerID("caserev", "2"))
  try ledger.append(inspection)

  let stale = try root.revising(
    status: .intake,
    action: .amended,
    reason: "Record customer clarification.",
    evidence: [],
    hypotheses: [],
    finding: nil,
    verification: nil,
    createdAt: "2026-09-07T13:02:00Z",
    revisionID: ledgerID("caserev", "3"))
  #expect(
    throws: MechanicDiagnosticCaseLedgerError.staleRevision(
      caseID: root.caseID, expectedRevisionID: inspection.revisionID)
  ) {
    try ledger.append(stale)
  }

  let collidingRevision = try makeLedgerCase(
    caseSuffix: "B",
    revisionSuffix: "1",
    createdAt: "2026-09-07T14:00:00Z")
  #expect(
    throws: MechanicDiagnosticCaseLedgerError.revisionIdentityCollision(root.revisionID)
  ) {
    try ledger.append(collidingRevision)
  }

  let collidingCase = try makeLedgerCase(
    caseSuffix: "1",
    revisionSuffix: "C",
    createdAt: "2026-09-07T14:00:00Z")
  #expect(throws: MechanicDiagnosticCaseLedgerError.caseIdentityCollision(root.caseID)) {
    try ledger.append(collidingCase)
  }
}

@Test func mechanicDiagnosticCaseLedgerRecoversOnlyAnUncommittedTailAndSurfacesIt() throws {
  let directory = mechanicLedgerDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let ledger = try MechanicDiagnosticCaseLedger(storageDirectory: directory)
  let root = try makeLedgerCase()
  try ledger.append(root)
  let interrupted = Data(#"{"revision_id":"interrupted""#.utf8)
  let handle = try FileHandle(forWritingTo: ledger.ledgerURL)
  try handle.seekToEnd()
  try handle.write(contentsOf: interrupted)
  try handle.close()

  let restarted = try MechanicDiagnosticCaseLedger(storageDirectory: directory)
  #expect(restarted.latest(caseID: root.caseID) == root)
  let recovery = try #require(restarted.lastTailRecovery)
  #expect(recovery.quarantinedByteCount == interrupted.count)
  #expect(recovery.retainedRecordCount == 1)
  #expect(try Data(contentsOf: recovery.quarantineURL) == interrupted)

  let cleanReload = try restarted.reload()
  #expect(cleanReload.tailRecovery == nil)
  #expect(cleanReload.revisionCount == 1)
}

@Test func mechanicDiagnosticCaseLedgerFailsClosedForCommittedCorruption() throws {
  let directory = mechanicLedgerDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let ledger = try MechanicDiagnosticCaseLedger(storageDirectory: directory)
  try ledger.append(makeLedgerCase())
  let original = try Data(contentsOf: ledger.ledgerURL)
  let handle = try FileHandle(forWritingTo: ledger.ledgerURL)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data("{}\n".utf8))
  try handle.close()
  let corrupted = try Data(contentsOf: ledger.ledgerURL)

  #expect(throws: AppendOnlyNDJSONLedgerError.self) {
    try MechanicDiagnosticCaseLedger(storageDirectory: directory)
  }
  #expect(corrupted.count > original.count)
  #expect(try Data(contentsOf: ledger.ledgerURL) == corrupted)
}

@Test func mechanicDiagnosticCaseLedgerNeverResurrectsAVoidedCase() throws {
  let directory = mechanicLedgerDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let ledger = try MechanicDiagnosticCaseLedger(storageDirectory: directory)
  let root = try makeLedgerCase()
  try ledger.append(root)
  let voided = try root.revising(
    status: .voided,
    action: .voided,
    reason: "Duplicate work order.",
    evidence: [],
    hypotheses: [],
    finding: nil,
    verification: nil,
    createdAt: "2026-09-07T13:01:00Z",
    revisionID: ledgerID("caserev", "2"))
  try ledger.append(voided)
  let alternateBranch = try root.revising(
    status: .inspection,
    action: .inspectionStarted,
    evidence: [],
    hypotheses: [],
    finding: nil,
    verification: nil,
    createdAt: "2026-09-07T13:02:00Z",
    revisionID: ledgerID("caserev", "3"))

  #expect(throws: MechanicDiagnosticCaseLedgerError.caseResurrection(root.caseID)) {
    try ledger.append(alternateBranch)
  }
  #expect(ledger.latest(caseID: root.caseID) == voided)
}

@Test func mechanicDiagnosticCaseLedgerReturnsNewestCasesFirst() throws {
  let directory = mechanicLedgerDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let ledger = try MechanicDiagnosticCaseLedger(storageDirectory: directory)
  let older = try makeLedgerCase()
  let newer = try makeLedgerCase(
    caseSuffix: "B",
    revisionSuffix: "B",
    createdAt: "2026-09-07T14:00:00Z")
  try ledger.append(older)
  try ledger.append(newer)
  #expect(ledger.latestCases().map(\.caseID) == [newer.caseID, older.caseID])
}

private func makeLedgerCase(
  caseSuffix: String = "1",
  revisionSuffix: String = "1",
  createdAt: String = "2026-09-07T13:00:00Z"
) throws -> MechanicDiagnosticCaseRevision {
  try MechanicDiagnosticCaseRevision.create(
    organization: MechanicDiagnosticOrganizationSnapshot(
      organizationID: ledgerID("org", "2"), displayName: "Diagnostic shop"),
    customer: MechanicDiagnosticCustomerSnapshot(
      customerID: ledgerID("customer", "3"), displayName: "Customer"),
    vehicle: MechanicDiagnosticVehicleSnapshot(
      vehicleID: ledgerID("veh", "4"), displayName: "Customer vehicle"),
    actor: MechanicDiagnosticActorSnapshot(
      source: .technician,
      actorID: ledgerID("actor", "5"),
      displayName: "Technician"),
    complaint: MechanicDiagnosticComplaint(
      description: "Intermittent no-start.",
      reportedBy: .customer,
      reportedAt: createdAt),
    createdAt: createdAt,
    caseID: ledgerID("case", caseSuffix),
    revisionID: ledgerID("caserev", revisionSuffix))
}

private func mechanicLedgerDirectory() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    "vhos-mechanic-case-ledger-\(UUID().uuidString)", isDirectory: true)
}

private func ledgerID(_ prefix: String, _ suffix: String) -> String {
  "\(prefix)_\(String(repeating: "0", count: 25))\(suffix)"
}
