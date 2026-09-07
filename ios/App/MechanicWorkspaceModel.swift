import Foundation
import Observation
import VHOSCore

enum MechanicWorkspaceLoadState: Equatable {
  case ready
  case recoveredInterruptedWrite(String)
  case unavailable(String)

  var allowsMutation: Bool {
    switch self {
    case .ready, .recoveredInterruptedWrite: true
    case .unavailable: false
    }
  }
}

struct MechanicCaseIntakeDraft: Equatable {
  var organizationName = ""
  var technicianName = ""
  var customerName = ""
  var customerPhone = ""
  var customerEmail = ""
  var vehicleDisplayName = ""
  var vin = ""
  var modelYear = ""
  var make = ""
  var model = ""
  var trim = ""
  var licensePlate = ""
  var odometer = ""
  var odometerUnit: MechanicDiagnosticDistanceUnit = .miles
  var concern = ""
  var reporter: MechanicDiagnosticComplaintReporter = .customer
  var operatingConditions = ""
  var priorWork = ""
}

struct MechanicEvidenceDraft: Equatable {
  var type: MechanicDiagnosticEvidenceType = .observation
  var source: MechanicDiagnosticEvidenceSource = .technicianObserved
  var quality: MechanicDiagnosticEvidenceQuality = .verified
  var description = ""
  var value = ""
  var unit = ""
  var dtcCode = ""
  var method = ""
  var testPoint = ""
  var expectedResult = ""
  var expectedResultSource = ""
}

struct MechanicHypothesisDraft: Equatable {
  var statement = ""
  var relationships: [String: MechanicDiagnosticEvidenceRelationship] = [:]
}

struct MechanicFindingDraft: Equatable {
  var conclusion = ""
  var limitations = ""
  var nextAction = ""
}

struct MechanicVerificationDraft: Equatable {
  var outcome: MechanicDiagnosticVerificationOutcome = .resolved
  var method = ""
  var reason = ""
  var evidenceIDs: Set<String> = []
}

@MainActor
@Observable
final class MechanicWorkspaceModel {
  private(set) var cases: [MechanicDiagnosticCaseRevision] = []
  private(set) var loadState: MechanicWorkspaceLoadState
  private(set) var preparedReports: [String: MechanicReportArtifactBundle] = [:]
  var operationMessage: String?
  var operationError: String?

  private var ledger: MechanicDiagnosticCaseLedger?
  private var attachmentStore: MechanicCaseAttachmentStore?
  private let reportGenerator = MechanicCaseReportArtifactGenerator()
  private let now: @MainActor () -> Date

  init(
    storageDirectory: URL? = nil,
    now: @escaping @MainActor () -> Date = Date.init
  ) {
    self.now = now
    do {
      let ledger = try MechanicDiagnosticCaseLedger(storageDirectory: storageDirectory)
      let attachmentStore = try MechanicCaseAttachmentStore(storageRoot: storageDirectory)
      let latestCases = ledger.latestCases()
      try Self.validateStoredAttachments(in: ledger, attachmentStore: attachmentStore)
      self.ledger = ledger
      self.attachmentStore = attachmentStore
      self.cases = latestCases
      if let recovery = ledger.lastTailRecovery {
        self.loadState = .recoveredInterruptedWrite(
          "Recovered an interrupted final write. The exact tail was quarantined at \(recovery.quarantineURL.lastPathComponent)."
        )
      } else {
        self.loadState = .ready
      }
    } catch {
      self.ledger = nil
      self.attachmentStore = nil
      self.loadState = .unavailable(error.localizedDescription)
    }
  }

  @discardableResult
  func createCase(from draft: MechanicCaseIntakeDraft) throws -> String {
    let ledger = try writableLedger()
    let timestamp = now()
    let recordedAt = Self.instant(timestamp)
    let actor = try technicianActor(named: draft.technicianName, at: timestamp)
    let organization = MechanicDiagnosticOrganizationSnapshot(
      organizationID: try MechanicDiagnosticCaseIDGenerator.make(.organization, at: timestamp),
      displayName: try Self.required(draft.organizationName, field: "business name")
    )
    let customer = MechanicDiagnosticCustomerSnapshot(
      customerID: try MechanicDiagnosticCaseIDGenerator.make(.customer, at: timestamp),
      displayName: try Self.required(draft.customerName, field: "customer name"),
      phone: Self.optional(draft.customerPhone),
      email: Self.optional(draft.customerEmail)
    )
    let vehicle = MechanicDiagnosticVehicleSnapshot(
      vehicleID: try MechanicDiagnosticCaseIDGenerator.make(.vehicle, at: timestamp),
      displayName: try Self.required(draft.vehicleDisplayName, field: "vehicle label"),
      vin: Self.optional(draft.vin.uppercased()),
      modelYear: try Self.optionalInteger(draft.modelYear, field: "model year"),
      make: Self.optional(draft.make),
      model: Self.optional(draft.model),
      trim: Self.optional(draft.trim),
      licensePlate: Self.optional(draft.licensePlate.uppercased()),
      odometer: try Self.odometer(draft)
    )
    let complaint = MechanicDiagnosticComplaint(
      description: try Self.required(draft.concern, field: "customer concern"),
      reportedBy: draft.reporter,
      reportedAt: recordedAt,
      operatingConditions: Self.optional(draft.operatingConditions),
      priorWork: Self.optional(draft.priorWork)
    )
    let revision = try MechanicDiagnosticCaseRevision.create(
      organization: organization,
      customer: customer,
      vehicle: vehicle,
      actor: actor,
      complaint: complaint,
      createdAt: recordedAt
    )
    try ledger.append(revision)
    refreshFromLedger(ledger)
    operationMessage = "Case saved locally as a technician draft."
    operationError = nil
    return revision.caseID
  }

  func startInspection(caseID: String) throws {
    try transition(
      caseID: caseID,
      status: .inspection,
      action: .inspectionStarted,
      reason: "Technician began inspection."
    )
  }

  func addEvidence(_ draft: MechanicEvidenceDraft, caseID: String) throws {
    let current = try currentCase(caseID)
    guard current.status != .closed, current.status != .voided else {
      throw MechanicWorkspaceError.caseIsTerminal
    }
    guard let attachmentStore else { throw MechanicWorkspaceError.storeUnavailable }
    _ = try attachmentStore.validate(attachment)
    let timestamp = now()
    let evidence = MechanicDiagnosticEvidence(
      evidenceID: try MechanicDiagnosticCaseIDGenerator.make(.evidence, at: timestamp),
      type: draft.type,
      source: draft.source,
      quality: draft.quality,
      description: try Self.required(draft.description, field: "evidence description"),
      recordedAt: Self.instant(timestamp),
      value: Self.optional(draft.value),
      unit: Self.optional(draft.unit),
      dtcCode: Self.optional(draft.dtcCode.uppercased()),
      method: Self.optional(draft.method),
      testPoint: Self.optional(draft.testPoint),
      expectedResult: Self.optional(draft.expectedResult),
      expectedResultSource: Self.optional(draft.expectedResultSource)
    )
    try amend(
      current,
      reason: "Added \(draft.type.displayName.lowercased()) evidence.",
      evidence: current.evidence + [evidence]
    )
  }

  func addAttachmentEvidence(
    attachment: MechanicDiagnosticAttachment,
    type: MechanicDiagnosticEvidenceType,
    description: String,
    caseID: String
  ) throws {
    guard [.photo, .video, .audio, .document, .scanReport].contains(type) else {
      throw MechanicWorkspaceError.invalidAttachmentType
    }
    let current = try currentCase(caseID)
    guard current.status != .closed, current.status != .voided else {
      throw MechanicWorkspaceError.caseIsTerminal
    }
    let timestamp = now()
    let evidence = MechanicDiagnosticEvidence(
      evidenceID: try MechanicDiagnosticCaseIDGenerator.make(.evidence, at: timestamp),
      type: type,
      source: .imported,
      quality: .verified,
      description: try Self.required(description, field: "attachment description"),
      recordedAt: Self.instant(timestamp),
      attachment: attachment
    )
    try amend(
      current,
      reason: "Imported hash-verified \(type.displayName.lowercased()) evidence.",
      evidence: current.evidence + [evidence]
    )
  }

  func importAttachmentEvidence(
    from sourceURL: URL,
    mediaType: String,
    type: MechanicDiagnosticEvidenceType,
    description: String,
    caseID: String
  ) throws {
    _ = try writableLedger()
    guard let attachmentStore else { throw MechanicWorkspaceError.storeUnavailable }
    let timestamp = now()
    let attachment = try attachmentStore.importFile(
      at: sourceURL,
      attachmentID: try MechanicDiagnosticCaseIDGenerator.make(.attachment, at: timestamp),
      displayName: sourceURL.lastPathComponent,
      mediaType: mediaType,
      capturedAt: Self.instant(timestamp)
    )
    try addAttachmentEvidence(
      attachment: attachment,
      type: type,
      description: description,
      caseID: caseID
    )
  }

  func addHypothesis(_ draft: MechanicHypothesisDraft, caseID: String) throws {
    let current = try currentCase(caseID)
    guard current.status == .inspection else { throw MechanicWorkspaceError.inspectionRequired }
    let links = draft.relationships
      .map { MechanicDiagnosticEvidenceLink(evidenceID: $0.key, relationship: $0.value) }
      .sorted { $0.evidenceID < $1.evidenceID }
    guard !links.isEmpty else { throw MechanicWorkspaceError.evidenceLinkRequired }
    let timestamp = now()
    let hypothesis = MechanicDiagnosticHypothesis(
      hypothesisID: try MechanicDiagnosticCaseIDGenerator.make(.hypothesis, at: timestamp),
      statement: try Self.required(draft.statement, field: "hypothesis"),
      evidenceLinks: links
    )
    try amend(
      current,
      reason: "Recorded a technician hypothesis with explicit evidence links.",
      hypotheses: current.hypotheses + [hypothesis]
    )
  }

  func recordFinding(_ draft: MechanicFindingDraft, caseID: String) throws {
    let current = try currentCase(caseID)
    guard current.status == .inspection || current.status == .findings else {
      throw MechanicWorkspaceError.inspectionRequired
    }
    let timestamp = now()
    let finding = MechanicDiagnosticFinding(
      conclusion: try Self.required(draft.conclusion, field: "technician conclusion"),
      limitations: Self.lines(draft.limitations),
      nextAction: try Self.required(draft.nextAction, field: "next action"),
      actor: current.actor,
      recordedAt: Self.instant(timestamp)
    )
    let action: MechanicDiagnosticCaseTransitionAction =
      current.status == .inspection ? .findingsRecorded : .amended
    let reason =
      current.status == .inspection
      ? "Technician recorded findings." : "Technician amended findings."
    try commit(
      try current.revising(
        status: .findings,
        action: action,
        reason: reason,
        actor: current.actor,
        evidence: current.evidence,
        hypotheses: current.hypotheses,
        finding: finding,
        verification: nil,
        createdAt: Self.instant(timestamp)
      )
    )
  }

  func startVerification(caseID: String) throws {
    try transition(
      caseID: caseID,
      status: .verify,
      action: .verificationStarted,
      reason: "Technician began post-work verification."
    )
  }

  func closeCase(_ draft: MechanicVerificationDraft, caseID: String) throws {
    let current = try currentCase(caseID)
    guard current.status == .verify else { throw MechanicWorkspaceError.verificationRequired }
    let timestamp = now()
    let verification = MechanicDiagnosticVerification(
      outcome: draft.outcome,
      method: Self.optional(draft.method),
      reason: Self.optional(draft.reason),
      evidenceIDs: draft.evidenceIDs.sorted(),
      recordedAt: Self.instant(timestamp)
    )
    try commit(
      try current.revising(
        status: .closed,
        action: .closed,
        reason: "Technician recorded the verification outcome.",
        actor: current.actor,
        evidence: current.evidence,
        hypotheses: current.hypotheses,
        finding: current.finding,
        verification: verification,
        createdAt: Self.instant(timestamp)
      )
    )
  }

  func voidCase(caseID: String, reason: String) throws {
    let current = try currentCase(caseID)
    let timestamp = now()
    try commit(
      try current.revising(
        status: .voided,
        action: .voided,
        reason: try Self.required(reason, field: "void reason"),
        actor: current.actor,
        evidence: current.evidence,
        hypotheses: current.hypotheses,
        finding: current.finding,
        verification: current.verification,
        createdAt: Self.instant(timestamp)
      )
    )
  }

  @discardableResult
  func prepareReport(
    caseID: String,
    privacy: MechanicReportPrivacySelection = MechanicReportPrivacySelection()
  ) throws -> MechanicReportArtifactBundle {
    let current = try currentCase(caseID)
    guard current.finding != nil else { throw MechanicWorkspaceError.findingRequired }
    guard let attachmentStore else { throw MechanicWorkspaceError.storeUnavailable }
    if let prepared = preparedReports[current.revisionID], prepared.manifest.privacy == privacy {
      return prepared
    }
    let generatedAt = Self.instant(now())
    let reportRoot = attachmentStore.storageRoot.appendingPathComponent(
      "Reports", isDirectory: true)
    let destination = reportRoot.appendingPathComponent(
      "\(current.caseID)-\(current.revisionID)-\(UUID().uuidString.lowercased())",
      isDirectory: true)
    let report = try reportGenerator.generate(
      committedRevision: current,
      privacy: privacy,
      generatedAt: generatedAt,
      outputDirectory: destination
    )
    preparedReports[current.revisionID] = report
    operationMessage = "Privacy-reviewed report artifacts generated locally."
    operationError = nil
    return report
  }

  func caseRevision(_ caseID: String) -> MechanicDiagnosticCaseRevision? {
    cases.first(where: { $0.caseID == caseID })
  }

  private func transition(
    caseID: String,
    status: MechanicDiagnosticCaseStatus,
    action: MechanicDiagnosticCaseTransitionAction,
    reason: String
  ) throws {
    let current = try currentCase(caseID)
    let timestamp = now()
    try commit(
      try current.revising(
        status: status,
        action: action,
        reason: reason,
        actor: current.actor,
        evidence: current.evidence,
        hypotheses: current.hypotheses,
        finding: current.finding,
        verification: current.verification,
        createdAt: Self.instant(timestamp)
      )
    )
  }

  private func amend(
    _ current: MechanicDiagnosticCaseRevision,
    reason: String,
    evidence: [MechanicDiagnosticEvidence]? = nil,
    hypotheses: [MechanicDiagnosticHypothesis]? = nil
  ) throws {
    let timestamp = now()
    try commit(
      try current.revising(
        status: current.status,
        action: .amended,
        reason: reason,
        actor: current.actor,
        evidence: evidence ?? current.evidence,
        hypotheses: hypotheses ?? current.hypotheses,
        finding: current.finding,
        verification: current.verification,
        createdAt: Self.instant(timestamp)
      )
    )
  }

  private func commit(_ revision: MechanicDiagnosticCaseRevision) throws {
    let ledger = try writableLedger()
    try ledger.append(revision)
    refreshFromLedger(ledger)
    operationMessage = "Revision \(revision.revisionNumber) committed locally."
    operationError = nil
  }

  private func refreshFromLedger(_ ledger: MechanicDiagnosticCaseLedger) {
    cases = ledger.latestCases()
  }

  private func writableLedger() throws -> MechanicDiagnosticCaseLedger {
    guard loadState.allowsMutation, let ledger else {
      throw MechanicWorkspaceError.storeUnavailable
    }
    return ledger
  }

  private func currentCase(_ caseID: String) throws -> MechanicDiagnosticCaseRevision {
    guard let current = ledger?.latest(caseID: caseID) else {
      throw MechanicWorkspaceError.caseNotFound
    }
    return current
  }

  private func technicianActor(named name: String, at date: Date) throws
    -> MechanicDiagnosticActorSnapshot
  {
    MechanicDiagnosticActorSnapshot(
      source: .technician,
      actorID: try MechanicDiagnosticCaseIDGenerator.make(.actor, at: date),
      displayName: try Self.required(name, field: "technician name")
    )
  }

  private static func odometer(_ draft: MechanicCaseIntakeDraft) throws
    -> MechanicDiagnosticOdometer?
  {
    guard let text = optional(draft.odometer) else { return nil }
    guard let value = Int(text), value >= 0 else {
      throw MechanicWorkspaceError.invalidField("odometer")
    }
    return MechanicDiagnosticOdometer(value: value, unit: draft.odometerUnit)
  }

  private static func optionalInteger(_ text: String, field: String) throws -> Int? {
    guard let text = optional(text) else { return nil }
    guard let value = Int(text) else { throw MechanicWorkspaceError.invalidField(field) }
    return value
  }

  private static func required(_ value: String, field: String) throws -> String {
    guard let value = optional(value) else { throw MechanicWorkspaceError.missingField(field) }
    return value
  }

  private static func optional(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func lines(_ value: String) -> [String] {
    value.split(whereSeparator: \Character.isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private static func validateStoredAttachments(
    in ledger: MechanicDiagnosticCaseLedger,
    attachmentStore: MechanicCaseAttachmentStore
  ) throws {
    for current in ledger.latestCases() {
      for revision in ledger.revisions(caseID: current.caseID) {
        for attachment in revision.evidence.compactMap(\.attachment)
        where attachment.availability == .available {
          _ = try attachmentStore.validate(attachment)
        }
      }
    }
  }

  private static func instant(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}

enum MechanicWorkspaceError: Error, Equatable, LocalizedError {
  case storeUnavailable
  case caseNotFound
  case caseIsTerminal
  case inspectionRequired
  case verificationRequired
  case findingRequired
  case evidenceLinkRequired
  case invalidAttachmentType
  case missingField(String)
  case invalidField(String)

  var errorDescription: String? {
    switch self {
    case .storeUnavailable:
      "The local case ledger is unavailable. No case data was changed."
    case .caseNotFound:
      "The diagnostic case could not be found."
    case .caseIsTerminal:
      "Closed or voided cases cannot accept new evidence."
    case .inspectionRequired:
      "Start the inspection before recording hypotheses or findings."
    case .verificationRequired:
      "Start verification before closing the case."
    case .findingRequired:
      "Record a technician finding before generating a report."
    case .evidenceLinkRequired:
      "Link at least one evidence item and mark how it relates to the hypothesis."
    case .invalidAttachmentType:
      "Attachments must be recorded as a photo, video, audio file, document, or scan report."
    case .missingField(let field):
      "Enter \(field)."
    case .invalidField(let field):
      "Enter a valid \(field)."
    }
  }
}

extension MechanicDiagnosticCaseStatus {
  var displayName: String {
    switch self {
    case .intake: "Intake"
    case .inspection: "Evidence"
    case .findings: "Findings"
    case .verify: "Verification"
    case .closed: "Closed"
    case .voided: "Voided"
    }
  }
}

extension MechanicDiagnosticEvidenceType {
  var displayName: String {
    switch self {
    case .observation: "Observation"
    case .measurement: "Measurement"
    case .dtc: "DTC fact"
    case .photo: "Photo"
    case .video: "Video"
    case .audio: "Audio"
    case .document: "Document"
    case .scanReport: "Scan report"
    }
  }
}

extension MechanicDiagnosticEvidenceSource {
  var displayName: String {
    switch self {
    case .customerAsserted: "Customer asserted"
    case .referringShopAsserted: "Referring shop asserted"
    case .technicianObserved: "Technician observed"
    case .technicianMeasured: "Technician measured"
    case .imported: "Imported"
    case .vehicleGateway: "Vehicle gateway"
    }
  }
}

extension MechanicDiagnosticEvidenceQuality {
  var displayName: String { rawValue.capitalized }
}

extension MechanicDiagnosticEvidenceRelationship {
  var displayName: String { rawValue.capitalized }
}

extension MechanicDiagnosticVerificationOutcome {
  var displayName: String {
    switch self {
    case .resolved: "Resolved"
    case .notResolved: "Not resolved"
    case .notReproduced: "Not reproduced"
    case .notPerformed: "Not performed"
    }
  }
}

extension MechanicDiagnosticComplaintReporter {
  var displayName: String {
    switch self {
    case .customer: "Customer"
    case .referringShop: "Referring shop"
    case .technician: "Technician"
    }
  }
}
