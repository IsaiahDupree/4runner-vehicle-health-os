import Foundation
import Testing

@testable import VHOSCore

@Test func mechanicDiagnosticCaseSupportsTheCompleteImmutableWorkflow() throws {
  let root = try makeDiagnosticCase()
  #expect(root.status == .intake)
  #expect(root.revisionNumber == 1)
  #expect(root.authority == .technicianLocalDraft)
  #expect(!root.vehicleClaimsAuthorized)
  #expect(!root.maintenanceHistoryAuthorized)

  let evidence = diagnosticEvidence()
  let hypothesis = MechanicDiagnosticHypothesis(
    hypothesisID: diagnosticID("hypothesis", "A"),
    statement: "Low battery voltage may contribute to the intermittent no-start.",
    evidenceLinks: [
      MechanicDiagnosticEvidenceLink(
        evidenceID: evidence[1].evidenceID, relationship: .supports),
      MechanicDiagnosticEvidenceLink(
        evidenceID: evidence[2].evidenceID, relationship: .unknown),
    ])
  let inspection = try root.revising(
    status: .inspection,
    action: .inspectionStarted,
    evidence: evidence,
    hypotheses: [hypothesis],
    finding: nil,
    verification: nil,
    createdAt: "2026-09-07T12:01:00Z",
    revisionID: diagnosticID("caserev", "2"))
  let findings = try inspection.revising(
    status: .findings,
    action: .findingsRecorded,
    evidence: evidence,
    hypotheses: [hypothesis],
    finding: nil,
    verification: nil,
    createdAt: "2026-09-07T12:02:00Z",
    revisionID: diagnosticID("caserev", "3"))
  let finding = MechanicDiagnosticFinding(
    conclusion: "Battery state of charge is below the expected rest value.",
    limitations: ["The intermittent symptom was not reproduced."],
    nextAction: "Inspect the battery and starting circuit.",
    actor: diagnosticTechnician(),
    recordedAt: "2026-09-07T12:02:30Z")
  let verifying = try findings.revising(
    status: .verify,
    action: .verificationStarted,
    evidence: evidence,
    hypotheses: [hypothesis],
    finding: finding,
    verification: nil,
    createdAt: "2026-09-07T12:03:00Z",
    revisionID: diagnosticID("caserev", "4"))
  let verification = MechanicDiagnosticVerification(
    outcome: .notReproduced,
    method: "Repeat the customer-reported overnight start procedure.",
    reason: nil,
    evidenceIDs: [evidence[0].evidenceID],
    recordedAt: "2026-09-07T12:04:00Z")
  let closed = try verifying.revising(
    status: .closed,
    action: .closed,
    evidence: evidence,
    hypotheses: [hypothesis],
    finding: finding,
    verification: verification,
    createdAt: "2026-09-07T12:04:01Z",
    revisionID: diagnosticID("caserev", "5"))

  #expect(closed.status == .closed)
  #expect(closed.revisionNumber == 5)
  #expect(closed.supersedesRevisionID == verifying.revisionID)
  #expect(closed.evidence.map(\.type) == [.observation, .measurement, .dtc, .document])
  #expect(closed.hypotheses.first?.evidenceLinks.count == 2)
  #expect(closed.finding == finding)
  #expect(closed.verification == verification)
}

@Test func mechanicDiagnosticCaseEncodesEveryRequiredNullableKey() throws {
  let root = try makeDiagnosticCase()
  let object = try #require(
    JSONSerialization.jsonObject(with: root.encoded()) as? [String: Any])
  #expect(object["supersedes_revision_id"] is NSNull)
  #expect(object["finding"] is NSNull)
  #expect(object["verification"] is NSNull)
  let customer = try #require(object["customer"] as? [String: Any])
  #expect(customer["phone"] is NSNull)
  #expect(customer["email"] is NSNull)
  let vehicle = try #require(object["vehicle"] as? [String: Any])
  #expect(vehicle["vin"] is NSNull)
  #expect(vehicle["license_plate"] is NSNull)
  let complaint = try #require(object["complaint"] as? [String: Any])
  #expect(complaint["prior_work"] is NSNull)
  let transition = try #require(object["transition"] as? [String: Any])
  #expect(transition["from_status"] is NSNull)
  #expect(transition["reason"] is NSNull)

  let withEvidence = try root.revising(
    status: .inspection,
    action: .inspectionStarted,
    evidence: [diagnosticEvidence()[2]],
    hypotheses: [],
    finding: nil,
    verification: nil,
    createdAt: "2026-09-07T12:01:00Z",
    revisionID: diagnosticID("caserev", "2"))
  let evidenceObject = try #require(
    (JSONSerialization.jsonObject(with: withEvidence.encoded()) as? [String: Any])?["evidence"]
      as? [[String: Any]])[0]
  for key in [
    "method", "test_point", "expected_result", "expected_result_source", "value", "unit",
    "attachment",
  ] {
    #expect(evidenceObject[key] is NSNull)
  }
}

@Test func mechanicDiagnosticCaseRejectsSemanticEscalationAndIllegalTransitions() throws {
  let root = try makeDiagnosticCase()
  #expect(throws: MechanicDiagnosticCaseError.self) {
    try root.revising(
      status: .findings,
      action: .findingsRecorded,
      evidence: [],
      hypotheses: [],
      finding: nil,
      verification: nil,
      createdAt: "2026-09-07T12:01:00Z")
  }
  let inspection = try root.revising(
    status: .inspection,
    action: .inspectionStarted,
    evidence: [],
    hypotheses: [],
    finding: nil,
    verification: nil,
    createdAt: "2026-09-07T12:01:00Z")
  let findings = try inspection.revising(
    status: .findings,
    action: .findingsRecorded,
    evidence: [],
    hypotheses: [],
    finding: nil,
    verification: nil,
    createdAt: "2026-09-07T12:02:00Z")
  #expect(throws: MechanicDiagnosticCaseError.findingRequired) {
    try findings.revising(
      status: .verify,
      action: .verificationStarted,
      evidence: [],
      hypotheses: [],
      finding: nil,
      verification: nil,
      createdAt: "2026-09-07T12:03:00Z")
  }
  #expect(throws: MechanicDiagnosticCaseError.invalidField("actor.source")) {
    try makeDiagnosticCase(
      actor: MechanicDiagnosticActorSnapshot(
        source: .system,
        actorID: diagnosticID("actor", "5"),
        displayName: "System"))
  }
}

@Test func mechanicDiagnosticCaseRejectsInvalidEvidenceSemantics() throws {
  let invalidMeasurement = MechanicDiagnosticEvidence(
    evidenceID: diagnosticID("evidence", "6"),
    type: .measurement,
    source: .technicianMeasured,
    quality: .verified,
    description: "Battery voltage.",
    recordedAt: "2026-09-07T12:01:00Z",
    value: "12.1",
    unit: "V")
  #expect(throws: MechanicDiagnosticCaseError.self) {
    try makeDiagnosticCase(evidence: [invalidMeasurement])
  }

  let invalidDTC = MechanicDiagnosticEvidence(
    evidenceID: diagnosticID("evidence", "7"),
    type: .dtc,
    source: .vehicleGateway,
    quality: .verified,
    description: "Imported DTC.",
    recordedAt: "2026-09-07T12:01:00Z",
    dtcCode: "p0300")
  #expect(throws: MechanicDiagnosticCaseError.self) {
    try makeDiagnosticCase(evidence: [invalidDTC])
  }

  let crossTypedDTC = MechanicDiagnosticEvidence(
    evidenceID: diagnosticID("evidence", "8"),
    type: .observation,
    source: .technicianObserved,
    quality: .verified,
    description: "Observed symptom.",
    recordedAt: "2026-09-07T12:01:00Z",
    dtcCode: "P0300")
  #expect(throws: MechanicDiagnosticCaseError.self) {
    try makeDiagnosticCase(evidence: [crossTypedDTC])
  }
}

@Test func mechanicDiagnosticCaseAcceptsPythonCanonicalDecimalEvidenceValues() throws {
  let canonicalValues = [
    "0",
    "-0",
    "0.000000",
    "-0.0",
    "12.1",
    "1E+1",
    "1.0E+2",
    "1E-7",
    "1.20E-7",
    "0E+1",
    "-0E-7",
    "1E+999999999999999999",
    "1E-1999999999999999997",
  ]

  for value in canonicalValues {
    let revision = try makeDiagnosticCase(
      evidence: [diagnosticMeasurement(value: value)])
    #expect(revision.evidence[0].value == value)
  }
}

@Test func mechanicDiagnosticCaseRejectsNoncanonicalOrOutOfBoundsDecimalEvidenceValues() {
  let rejectedValues = [
    "1E+01",
    "1E01",
    "0E1",
    "1E-0",
    "1E+0",
    "1E-1",
    "0.0000001",
    "12E+1",
    "1E+1000000000000000000",
    "1E-1999999999999999998",
  ]

  for value in rejectedValues {
    #expect(throws: MechanicDiagnosticCaseError.invalidField("evidence.value")) {
      try makeDiagnosticCase(
        evidence: [diagnosticMeasurement(value: value)])
    }
  }
}

@Test func mechanicDiagnosticCaseTypedULIDsHaveStrictPrefixesAndMonotonicBodies() throws {
  let instant = try #require(ISO8601DateFormatter().date(from: "2026-09-07T12:00:00Z"))
  let first = try MechanicDiagnosticCaseIDGenerator.make(.diagnosticCase, at: instant)
  let second = try MechanicDiagnosticCaseIDGenerator.make(.diagnosticCase, at: instant)
  #expect(first.range(of: "^case_[0-7][0-9A-HJKMNP-TV-Z]{25}$", options: .regularExpression) != nil)
  #expect(second > first)
  #expect(throws: MechanicDiagnosticCaseError.invalidIDPrefix("unsupported")) {
    try MechanicDiagnosticCaseIDGenerator.make(prefix: "unsupported", at: instant)
  }
}

@Test func mechanicDiagnosticCaseUsesStrictSchemaWallTimes() throws {
  let lowercase = try makeDiagnosticCase(createdAt: "2026-09-07t12:00:00z")
  #expect(lowercase.createdAt == "2026-09-07t12:00:00z")
  #expect(throws: MechanicDiagnosticCaseError.invalidField("created_at")) {
    try makeDiagnosticCase(createdAt: "2026-02-30T12:00:00Z")
  }
  #expect(throws: MechanicDiagnosticCaseError.invalidField("created_at")) {
    try makeDiagnosticCase(createdAt: "2026-09-07T24:00:00Z")
  }
}

@Test func mechanicDiagnosticCaseDecodesTheSharedContractExample() throws {
  var repository = URL(fileURLWithPath: #filePath)
  for _ in 0..<5 { repository.deleteLastPathComponent() }
  let exampleURL = repository.appendingPathComponent(
    "contracts/examples/v1/diagnostic-case-draft.json")
  let revision = try VHOSJSON.decoder().decode(
    MechanicDiagnosticCaseRevision.self,
    from: Data(contentsOf: exampleURL))
  try revision.validateContract()
  #expect(revision.contract == MechanicDiagnosticCaseRevision.currentContract)
  #expect(revision.status == .closed)
  #expect(revision.evidence.count == 4)
}

private func makeDiagnosticCase(
  caseSuffix: String = "1",
  revisionSuffix: String = "1",
  createdAt: String = "2026-09-07T12:00:00Z",
  actor: MechanicDiagnosticActorSnapshot = diagnosticTechnician(),
  evidence: [MechanicDiagnosticEvidence] = []
) throws -> MechanicDiagnosticCaseRevision {
  try MechanicDiagnosticCaseRevision.create(
    organization: MechanicDiagnosticOrganizationSnapshot(
      organizationID: diagnosticID("org", "2"),
      displayName: "Independent diagnostic service"),
    customer: MechanicDiagnosticCustomerSnapshot(
      customerID: diagnosticID("customer", "3"),
      displayName: "Sample customer"),
    vehicle: MechanicDiagnosticVehicleSnapshot(
      vehicleID: diagnosticID("veh", "4"),
      displayName: "Customer vehicle",
      modelYear: 2005,
      make: "Toyota",
      model: "4Runner",
      odometer: MechanicDiagnosticOdometer(value: 154_000, unit: .miles)),
    actor: actor,
    complaint: MechanicDiagnosticComplaint(
      description: "Customer reports an intermittent no-start.",
      reportedBy: .customer,
      reportedAt: createdAt,
      operatingConditions: "After overnight parking."),
    evidence: evidence,
    createdAt: createdAt,
    caseID: diagnosticID("case", caseSuffix),
    revisionID: diagnosticID("caserev", revisionSuffix))
}

private func diagnosticTechnician() -> MechanicDiagnosticActorSnapshot {
  MechanicDiagnosticActorSnapshot(
    source: .technician,
    actorID: diagnosticID("actor", "5"),
    displayName: "Sample technician")
}

private func diagnosticEvidence() -> [MechanicDiagnosticEvidence] {
  [
    MechanicDiagnosticEvidence(
      evidenceID: diagnosticID("evidence", "6"),
      type: .observation,
      source: .technicianObserved,
      quality: .verified,
      description: "Symptom did not recur during verification.",
      recordedAt: "2026-09-07T12:01:00Z",
      method: "Repeat the customer-reported start procedure."),
    MechanicDiagnosticEvidence(
      evidenceID: diagnosticID("evidence", "7"),
      type: .measurement,
      source: .technicianMeasured,
      quality: .verified,
      description: "Battery terminal voltage before start.",
      recordedAt: "2026-09-07T12:01:01Z",
      value: "12.1",
      unit: "V",
      method: "Measure across battery terminals with a calibrated meter."),
    MechanicDiagnosticEvidence(
      evidenceID: diagnosticID("evidence", "8"),
      type: .dtc,
      source: .vehicleGateway,
      quality: .verified,
      description: "Stored diagnostic trouble code.",
      recordedAt: "2026-09-07T12:01:02Z",
      dtcCode: "P0300"),
    MechanicDiagnosticEvidence(
      evidenceID: diagnosticID("evidence", "9"),
      type: .document,
      source: .imported,
      quality: .verified,
      description: "Original scan report.",
      recordedAt: "2026-09-07T12:01:03Z",
      attachment: MechanicDiagnosticAttachment(
        attachmentID: diagnosticID("attachment", "B"),
        displayName: "scan.pdf",
        mediaType: "application/pdf",
        byteCount: 2_048,
        sha256: String(repeating: "a", count: 64),
        storageKey: "sha256/aa/report",
        availability: .available)),
  ]
}

private func diagnosticMeasurement(value: String) -> MechanicDiagnosticEvidence {
  MechanicDiagnosticEvidence(
    evidenceID: diagnosticID("evidence", "C"),
    type: .measurement,
    source: .technicianMeasured,
    quality: .verified,
    description: "Recorded measurement.",
    recordedAt: "2026-09-07T12:01:00Z",
    value: value,
    unit: "V",
    method: "Measure with a calibrated meter.")
}

private func diagnosticID(_ prefix: String, _ suffix: String) -> String {
  "\(prefix)_\(String(repeating: "0", count: 25))\(suffix)"
}
