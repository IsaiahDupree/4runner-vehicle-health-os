import CryptoKit
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

@Test func mechanicDiagnosticCaseLedgerRejectsCanonicalRevisionRewriteWithStaleDigest() throws {
  let directory = mechanicLedgerDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let ledger = try MechanicDiagnosticCaseLedger(storageDirectory: directory)
  try ledger.append(makeLedgerCase())
  let original = try Data(contentsOf: ledger.ledgerURL)
  var entries = try mechanicLedgerJSONEntries(original)
  #expect(entries.count == 1)

  var entry = entries[0]
  let storedDigest = try #require(entry["revision_sha256"] as? String)
  var revision = try #require(entry["revision"] as? [String: Any])
  var complaint = try #require(revision["complaint"] as? [String: Any])
  complaint["description"] = "Persistent no-start after an overnight cold soak."
  revision["complaint"] = complaint
  let rewrittenRevisionBytes = try mechanicCanonicalJSON(revision)
  let rewrittenRevision = try VHOSJSON.decoder().decode(
    MechanicDiagnosticCaseRevision.self, from: rewrittenRevisionBytes)
  try rewrittenRevision.validateContract()
  #expect(mechanicSHA256(rewrittenRevisionBytes) != storedDigest)

  entry["revision"] = revision
  entries[0] = entry
  let corrupted = try mechanicCommittedLedgerBytes(entries)
  try corrupted.write(to: ledger.ledgerURL, options: [.atomic])

  #expect(
    throws: AppendOnlyNDJSONLedgerError.invalidCommittedRecord(
      fileName: ledger.ledgerURL.lastPathComponent, line: 1)
  ) {
    try MechanicDiagnosticCaseLedger(storageDirectory: directory)
  }
  #expect(try Data(contentsOf: ledger.ledgerURL) == corrupted)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: ledger.quarantineDirectory.path).isEmpty)
}

@Test func mechanicDiagnosticCaseLedgerBindsEachCaseToItsPredecessorDigest() throws {
  let directory = mechanicLedgerDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let ledger = try MechanicDiagnosticCaseLedger(storageDirectory: directory)
  let firstCase = try makeLedgerCase()
  let otherCase = try makeLedgerCase(
    caseSuffix: "B",
    revisionSuffix: "B",
    createdAt: "2026-09-07T13:00:30Z")
  let inspection = try firstCase.revising(
    status: .inspection,
    action: .inspectionStarted,
    evidence: [],
    hypotheses: [],
    finding: nil,
    verification: nil,
    createdAt: "2026-09-07T13:01:00Z",
    revisionID: ledgerID("caserev", "2"))
  try ledger.append(firstCase)
  try ledger.append(otherCase)
  try ledger.append(inspection)

  var entries = try mechanicLedgerJSONEntries(Data(contentsOf: ledger.ledgerURL))
  #expect(entries.count == 3)
  #expect(entries[0]["contract"] as? String == "vhos.mechanic-diagnostic-case-ledger-entry")
  #expect(entries[0]["contract_version"] as? String == "1.0.0")
  #expect(entries[0]["predecessor_revision_sha256"] is NSNull)
  let firstDigest = try #require(entries[0]["revision_sha256"] as? String)
  let otherDigest = try #require(entries[1]["revision_sha256"] as? String)
  let firstRevision = try #require(entries[0]["revision"] as? [String: Any])
  #expect(mechanicSHA256(try mechanicCanonicalJSON(firstRevision)) == firstDigest)
  #expect(entries[2]["predecessor_revision_sha256"] as? String == firstDigest)
  #expect(otherDigest != firstDigest)

  entries[2]["predecessor_revision_sha256"] = otherDigest
  let corrupted = try mechanicCommittedLedgerBytes(entries)
  try corrupted.write(to: ledger.ledgerURL, options: [.atomic])

  #expect(
    throws: AppendOnlyNDJSONLedgerError.invalidCommittedRecord(
      fileName: ledger.ledgerURL.lastPathComponent, line: 3)
  ) {
    try MechanicDiagnosticCaseLedger(storageDirectory: directory)
  }
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

private func mechanicLedgerJSONEntries(_ data: Data) throws -> [[String: Any]] {
  try data.split(separator: 0x0A).map { line in
    let object = try JSONSerialization.jsonObject(with: Data(line))
    let entry = try #require(object as? [String: Any])
    #expect(try mechanicCanonicalJSON(entry) == Data(line))
    return entry
  }
}

private func mechanicCommittedLedgerBytes(_ entries: [[String: Any]]) throws -> Data {
  try entries.reduce(into: Data()) { bytes, entry in
    bytes.append(try mechanicCanonicalJSON(entry))
    bytes.append(0x0A)
  }
}

private func mechanicCanonicalJSON(_ object: Any) throws -> Data {
  try JSONSerialization.data(
    withJSONObject: object,
    options: [.sortedKeys, .withoutEscapingSlashes])
}

private func mechanicSHA256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func ledgerID(_ prefix: String, _ suffix: String) -> String {
  "\(prefix)_\(String(repeating: "0", count: 25))\(suffix)"
}
