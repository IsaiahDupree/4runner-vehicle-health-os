import Foundation
import VHOSCore
import XCTest

@testable import Vehicle_Health_OS

@MainActor
final class MechanicWorkspaceTests: XCTestCase {
  func testOfflineCaseFlowsFromIntakeThroughVerifiedCloseAndReload() throws {
    let root = temporaryDirectory("complete-case")
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-07T14:00:00Z"))
    let workspace = MechanicWorkspaceModel(storageDirectory: root, now: { clock })

    let caseID = try workspace.createCase(from: intake())
    var revision = try XCTUnwrap(workspace.caseRevision(caseID))
    XCTAssertEqual(revision.status, .intake)
    XCTAssertEqual(revision.authority, .technicianLocalDraft)
    XCTAssertFalse(revision.vehicleClaimsAuthorized)
    XCTAssertFalse(revision.maintenanceHistoryAuthorized)

    try workspace.startInspection(caseID: caseID)
    try workspace.addEvidence(
      MechanicEvidenceDraft(
        type: .measurement,
        source: .technicianMeasured,
        quality: .verified,
        description: "Battery voltage at the posts with ignition off",
        value: "12.47",
        unit: "V",
        method: "Digital multimeter",
        testPoint: "Battery posts"
      ),
      caseID: caseID)
    revision = try XCTUnwrap(workspace.caseRevision(caseID))
    let evidenceID = try XCTUnwrap(revision.evidence.first?.evidenceID)

    try workspace.addHypothesis(
      MechanicHypothesisDraft(
        statement: "The concern may be downstream of the battery connection.",
        relationships: [evidenceID: .unknown]
      ),
      caseID: caseID)
    try workspace.recordFinding(
      MechanicFindingDraft(
        conclusion: "The current evidence does not establish a root cause.",
        limitations: "Concern was not reproduced.\nNo loaded voltage-drop test was performed.",
        nextAction: "Reproduce the concern and record a loaded voltage-drop test."
      ),
      caseID: caseID)
    try workspace.startVerification(caseID: caseID)
    try workspace.closeCase(
      MechanicVerificationDraft(
        outcome: .notReproduced,
        method: "Three start attempts after inspection",
        reason: "Intermittent concern did not recur.",
        evidenceIDs: [evidenceID]
      ),
      caseID: caseID)

    revision = try XCTUnwrap(workspace.caseRevision(caseID))
    XCTAssertEqual(revision.status, .closed)
    XCTAssertEqual(revision.revisionNumber, 7)
    XCTAssertEqual(revision.verification?.outcome, .notReproduced)

    let reopened = MechanicWorkspaceModel(storageDirectory: root, now: { clock })
    let restored = try XCTUnwrap(reopened.caseRevision(caseID))
    XCTAssertEqual(restored, revision)
    XCTAssertEqual(reopened.loadState, .ready)
  }

  func testInvalidMeasurementAppendsNothing() throws {
    let root = temporaryDirectory("invalid-measurement")
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-07T15:00:00Z"))
    let workspace = MechanicWorkspaceModel(storageDirectory: root, now: { clock })
    let caseID = try workspace.createCase(from: intake())
    try workspace.startInspection(caseID: caseID)
    let before = try XCTUnwrap(workspace.caseRevision(caseID))

    XCTAssertThrowsError(
      try workspace.addEvidence(
        MechanicEvidenceDraft(
          type: .measurement,
          source: .technicianMeasured,
          quality: .verified,
          description: "Voltage reading",
          value: "unknown",
          unit: "V",
          method: "Digital multimeter"
        ),
        caseID: caseID))

    XCTAssertEqual(workspace.caseRevision(caseID), before)
    XCTAssertEqual(
      try MechanicDiagnosticCaseLedger(storageDirectory: root).revisions(caseID: caseID).count, 2)
  }

  func testTechnicianCanPreserveAnInsufficientEvidenceFindingWithoutInventingFacts() throws {
    let root = temporaryDirectory("insufficient-evidence")
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-07T15:30:00Z"))
    let workspace = MechanicWorkspaceModel(storageDirectory: root, now: { clock })
    let caseID = try workspace.createCase(from: intake())
    try workspace.startInspection(caseID: caseID)

    try workspace.recordFinding(
      MechanicFindingDraft(
        conclusion: "The available evidence is insufficient to identify a root cause.",
        limitations: "The reported condition could not be reproduced.",
        nextAction: "Capture the condition before authorizing parts replacement."
      ),
      caseID: caseID)

    let revision = try XCTUnwrap(workspace.caseRevision(caseID))
    XCTAssertEqual(revision.status, .findings)
    XCTAssertTrue(revision.evidence.isEmpty)
    XCTAssertTrue(revision.hypotheses.isEmpty)
    XCTAssertEqual(
      revision.finding?.conclusion,
      "The available evidence is insufficient to identify a root cause.")
  }

  func testVoidIsARevisionAndNeverDisappearsOnReload() throws {
    let root = temporaryDirectory("void")
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-07T16:00:00Z"))
    let workspace = MechanicWorkspaceModel(storageDirectory: root, now: { clock })
    let caseID = try workspace.createCase(from: intake())

    try workspace.voidCase(caseID: caseID, reason: "Duplicate intake created by technician.")

    let reopened = MechanicWorkspaceModel(storageDirectory: root, now: { clock })
    let revision = try XCTUnwrap(reopened.caseRevision(caseID))
    XCTAssertEqual(revision.status, .voided)
    XCTAssertEqual(revision.transition.reason, "Duplicate intake created by technician.")
    XCTAssertEqual(
      try MechanicDiagnosticCaseLedger(storageDirectory: root).revisions(caseID: caseID).count, 2)
  }

  private func intake() -> MechanicCaseIntakeDraft {
    MechanicCaseIntakeDraft(
      organizationName: "Independent Diagnostic Service",
      technicianName: "Technician One",
      customerName: "Authorized Test Customer",
      vehicleDisplayName: "Redacted test vehicle",
      modelYear: "2018",
      make: "Toyota",
      model: "4Runner",
      odometer: "82000",
      odometerUnit: .miles,
      concern: "Intermittent no-start reported after a hot soak.",
      reporter: .customer,
      operatingConditions: "After approximately 30 minutes of driving."
    )
  }

  private func temporaryDirectory(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "MechanicWorkspaceTests-\(name)-\(UUID().uuidString)", isDirectory: true)
  }
}
