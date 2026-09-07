import Foundation

public enum MechanicDiagnosticCaseAuthority: String, Codable, Sendable {
  case technicianLocalDraft = "TECHNICIAN_LOCAL_DRAFT"
}

public enum MechanicDiagnosticCaseStatus: String, Codable, CaseIterable, Sendable {
  case intake = "INTAKE"
  case inspection = "INSPECTION"
  case findings = "FINDINGS"
  case verify = "VERIFY"
  case closed = "CLOSED"
  case voided = "VOIDED"
}

public enum MechanicDiagnosticCaseTransitionAction: String, Codable, CaseIterable, Sendable {
  case created = "CREATED"
  case amended = "AMENDED"
  case inspectionStarted = "INSPECTION_STARTED"
  case findingsRecorded = "FINDINGS_RECORDED"
  case verificationStarted = "VERIFICATION_STARTED"
  case closed = "CLOSED"
  case voided = "VOIDED"
}

public struct MechanicDiagnosticCaseTransition: Codable, Equatable, Sendable {
  public let action: MechanicDiagnosticCaseTransitionAction
  public let fromStatus: MechanicDiagnosticCaseStatus?
  public let toStatus: MechanicDiagnosticCaseStatus
  public let reason: String?

  public init(
    action: MechanicDiagnosticCaseTransitionAction,
    fromStatus: MechanicDiagnosticCaseStatus?,
    toStatus: MechanicDiagnosticCaseStatus,
    reason: String?
  ) {
    self.action = action
    self.fromStatus = fromStatus
    self.toStatus = toStatus
    self.reason = reason
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(action, forKey: .action)
    try container.encodeRequiredNullable(fromStatus, forKey: .fromStatus)
    try container.encode(toStatus, forKey: .toStatus)
    try container.encodeRequiredNullable(reason, forKey: .reason)
  }

  private enum CodingKeys: String, CodingKey {
    case action, fromStatus, toStatus, reason
  }
}

public struct MechanicDiagnosticOrganizationSnapshot: Codable, Equatable, Sendable {
  public let organizationID: String
  public let displayName: String

  private enum CodingKeys: String, CodingKey {
    case organizationID = "organizationId"
    case displayName
  }

  public init(organizationID: String, displayName: String) {
    self.organizationID = organizationID
    self.displayName = displayName
  }
}

public struct MechanicDiagnosticCustomerSnapshot: Codable, Equatable, Sendable {
  public let customerID: String
  public let displayName: String
  public let phone: String?
  public let email: String?

  private enum CodingKeys: String, CodingKey {
    case customerID = "customerId"
    case displayName, phone, email
  }

  public init(
    customerID: String,
    displayName: String,
    phone: String? = nil,
    email: String? = nil
  ) {
    self.customerID = customerID
    self.displayName = displayName
    self.phone = phone
    self.email = email
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(customerID, forKey: .customerID)
    try container.encode(displayName, forKey: .displayName)
    try container.encodeRequiredNullable(phone, forKey: .phone)
    try container.encodeRequiredNullable(email, forKey: .email)
  }
}

public enum MechanicDiagnosticDistanceUnit: String, Codable, Sendable {
  case miles = "MILES"
  case kilometers = "KILOMETERS"
}

public struct MechanicDiagnosticOdometer: Codable, Equatable, Sendable {
  public let value: Int
  public let unit: MechanicDiagnosticDistanceUnit

  public init(value: Int, unit: MechanicDiagnosticDistanceUnit) {
    self.value = value
    self.unit = unit
  }
}

public struct MechanicDiagnosticVehicleSnapshot: Codable, Equatable, Sendable {
  public let vehicleID: String
  public let displayName: String
  public let vin: String?
  public let modelYear: Int?
  public let make: String?
  public let model: String?
  public let trim: String?
  public let licensePlate: String?
  public let odometer: MechanicDiagnosticOdometer?

  private enum CodingKeys: String, CodingKey {
    case vehicleID = "vehicleId"
    case displayName, vin, modelYear, make, model, trim, licensePlate, odometer
  }

  public init(
    vehicleID: String,
    displayName: String,
    vin: String? = nil,
    modelYear: Int? = nil,
    make: String? = nil,
    model: String? = nil,
    trim: String? = nil,
    licensePlate: String? = nil,
    odometer: MechanicDiagnosticOdometer? = nil
  ) {
    self.vehicleID = vehicleID
    self.displayName = displayName
    self.vin = vin
    self.modelYear = modelYear
    self.make = make
    self.model = model
    self.trim = trim
    self.licensePlate = licensePlate
    self.odometer = odometer
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(vehicleID, forKey: .vehicleID)
    try container.encode(displayName, forKey: .displayName)
    try container.encodeRequiredNullable(vin, forKey: .vin)
    try container.encodeRequiredNullable(modelYear, forKey: .modelYear)
    try container.encodeRequiredNullable(make, forKey: .make)
    try container.encodeRequiredNullable(model, forKey: .model)
    try container.encodeRequiredNullable(trim, forKey: .trim)
    try container.encodeRequiredNullable(licensePlate, forKey: .licensePlate)
    try container.encodeRequiredNullable(odometer, forKey: .odometer)
  }
}

public enum MechanicDiagnosticActorSource: String, Codable, Sendable {
  case owner = "OWNER"
  case technician = "TECHNICIAN"
  case imported = "IMPORT"
  case system = "SYSTEM"
}

public struct MechanicDiagnosticActorSnapshot: Codable, Equatable, Sendable {
  public let source: MechanicDiagnosticActorSource
  public let actorID: String
  public let displayName: String

  private enum CodingKeys: String, CodingKey {
    case source
    case actorID = "actorId"
    case displayName
  }

  public init(source: MechanicDiagnosticActorSource, actorID: String, displayName: String) {
    self.source = source
    self.actorID = actorID
    self.displayName = displayName
  }
}

public enum MechanicDiagnosticComplaintReporter: String, Codable, Sendable {
  case customer = "CUSTOMER"
  case referringShop = "REFERRING_SHOP"
  case technician = "TECHNICIAN"
}

public struct MechanicDiagnosticComplaint: Codable, Equatable, Sendable {
  public let description: String
  public let reportedBy: MechanicDiagnosticComplaintReporter
  public let reportedAt: String
  public let operatingConditions: String?
  public let priorWork: String?

  public init(
    description: String,
    reportedBy: MechanicDiagnosticComplaintReporter,
    reportedAt: String,
    operatingConditions: String? = nil,
    priorWork: String? = nil
  ) {
    self.description = description
    self.reportedBy = reportedBy
    self.reportedAt = reportedAt
    self.operatingConditions = operatingConditions
    self.priorWork = priorWork
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(description, forKey: .description)
    try container.encode(reportedBy, forKey: .reportedBy)
    try container.encode(reportedAt, forKey: .reportedAt)
    try container.encodeRequiredNullable(operatingConditions, forKey: .operatingConditions)
    try container.encodeRequiredNullable(priorWork, forKey: .priorWork)
  }

  private enum CodingKeys: String, CodingKey {
    case description, reportedBy, reportedAt, operatingConditions, priorWork
  }
}

public enum MechanicDiagnosticAttachmentAvailability: String, Codable, Sendable {
  case available = "AVAILABLE"
  case missing = "MISSING"
}

public struct MechanicDiagnosticAttachment: Codable, Equatable, Sendable {
  public let attachmentID: String
  public let displayName: String
  public let mediaType: String
  public let byteCount: Int
  public let sha256: String
  public let storageKey: String
  public let availability: MechanicDiagnosticAttachmentAvailability
  public let capturedAt: String?

  private enum CodingKeys: String, CodingKey {
    case attachmentID = "attachmentId"
    case displayName, mediaType, byteCount, sha256, storageKey, availability, capturedAt
  }

  public init(
    attachmentID: String,
    displayName: String,
    mediaType: String,
    byteCount: Int,
    sha256: String,
    storageKey: String,
    availability: MechanicDiagnosticAttachmentAvailability,
    capturedAt: String? = nil
  ) {
    self.attachmentID = attachmentID
    self.displayName = displayName
    self.mediaType = mediaType
    self.byteCount = byteCount
    self.sha256 = sha256
    self.storageKey = storageKey
    self.availability = availability
    self.capturedAt = capturedAt
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(attachmentID, forKey: .attachmentID)
    try container.encode(displayName, forKey: .displayName)
    try container.encode(mediaType, forKey: .mediaType)
    try container.encode(byteCount, forKey: .byteCount)
    try container.encode(sha256, forKey: .sha256)
    try container.encode(storageKey, forKey: .storageKey)
    try container.encode(availability, forKey: .availability)
    try container.encodeRequiredNullable(capturedAt, forKey: .capturedAt)
  }
}

public enum MechanicDiagnosticEvidenceType: String, Codable, CaseIterable, Sendable {
  case observation = "OBSERVATION"
  case measurement = "MEASUREMENT"
  case dtc = "DTC"
  case photo = "PHOTO"
  case video = "VIDEO"
  case audio = "AUDIO"
  case document = "DOCUMENT"
  case scanReport = "SCAN_REPORT"
}

public enum MechanicDiagnosticEvidenceSource: String, Codable, CaseIterable, Sendable {
  case customerAsserted = "CUSTOMER_ASSERTED"
  case referringShopAsserted = "REFERRING_SHOP_ASSERTED"
  case technicianObserved = "TECHNICIAN_OBSERVED"
  case technicianMeasured = "TECHNICIAN_MEASURED"
  case imported = "IMPORTED"
  case vehicleGateway = "VEHICLE_GATEWAY"
}

public enum MechanicDiagnosticEvidenceQuality: String, Codable, CaseIterable, Sendable {
  case unverified = "UNVERIFIED"
  case verified = "VERIFIED"
  case stale = "STALE"
  case invalid = "INVALID"
}

public struct MechanicDiagnosticEvidence: Codable, Equatable, Sendable, Identifiable {
  public let evidenceID: String
  public let type: MechanicDiagnosticEvidenceType
  public let source: MechanicDiagnosticEvidenceSource
  public let quality: MechanicDiagnosticEvidenceQuality
  public let description: String
  public let recordedAt: String
  public let value: String?
  public let unit: String?
  public let dtcCode: String?
  public let attachment: MechanicDiagnosticAttachment?
  public let method: String?
  public let testPoint: String?
  public let expectedResult: String?
  public let expectedResultSource: String?

  public var id: String { evidenceID }

  private enum CodingKeys: String, CodingKey {
    case evidenceID = "evidenceId"
    case type, source, quality, description, recordedAt, value, unit, dtcCode, attachment
    case method, testPoint, expectedResult, expectedResultSource
  }

  public init(
    evidenceID: String,
    type: MechanicDiagnosticEvidenceType,
    source: MechanicDiagnosticEvidenceSource,
    quality: MechanicDiagnosticEvidenceQuality,
    description: String,
    recordedAt: String,
    value: String? = nil,
    unit: String? = nil,
    dtcCode: String? = nil,
    attachment: MechanicDiagnosticAttachment? = nil,
    method: String? = nil,
    testPoint: String? = nil,
    expectedResult: String? = nil,
    expectedResultSource: String? = nil
  ) {
    self.evidenceID = evidenceID
    self.type = type
    self.source = source
    self.quality = quality
    self.description = description
    self.recordedAt = recordedAt
    self.value = value
    self.unit = unit
    self.dtcCode = dtcCode
    self.attachment = attachment
    self.method = method
    self.testPoint = testPoint
    self.expectedResult = expectedResult
    self.expectedResultSource = expectedResultSource
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(evidenceID, forKey: .evidenceID)
    try container.encode(type, forKey: .type)
    try container.encode(source, forKey: .source)
    try container.encode(quality, forKey: .quality)
    try container.encode(description, forKey: .description)
    try container.encode(recordedAt, forKey: .recordedAt)
    try container.encodeRequiredNullable(value, forKey: .value)
    try container.encodeRequiredNullable(unit, forKey: .unit)
    try container.encodeRequiredNullable(dtcCode, forKey: .dtcCode)
    try container.encodeRequiredNullable(attachment, forKey: .attachment)
    try container.encodeRequiredNullable(method, forKey: .method)
    try container.encodeRequiredNullable(testPoint, forKey: .testPoint)
    try container.encodeRequiredNullable(expectedResult, forKey: .expectedResult)
    try container.encodeRequiredNullable(expectedResultSource, forKey: .expectedResultSource)
  }
}

public enum MechanicDiagnosticEvidenceRelationship: String, Codable, CaseIterable, Sendable {
  case supports = "SUPPORTS"
  case contradicts = "CONTRADICTS"
  case unknown = "UNKNOWN"
}

public struct MechanicDiagnosticEvidenceLink: Codable, Equatable, Sendable {
  public let evidenceID: String
  public let relationship: MechanicDiagnosticEvidenceRelationship

  private enum CodingKeys: String, CodingKey {
    case evidenceID = "evidenceId"
    case relationship
  }

  public init(evidenceID: String, relationship: MechanicDiagnosticEvidenceRelationship) {
    self.evidenceID = evidenceID
    self.relationship = relationship
  }
}

public struct MechanicDiagnosticHypothesis: Codable, Equatable, Sendable, Identifiable {
  public let hypothesisID: String
  public let statement: String
  public let evidenceLinks: [MechanicDiagnosticEvidenceLink]

  public var id: String { hypothesisID }

  private enum CodingKeys: String, CodingKey {
    case hypothesisID = "hypothesisId"
    case statement, evidenceLinks
  }

  public init(
    hypothesisID: String,
    statement: String,
    evidenceLinks: [MechanicDiagnosticEvidenceLink]
  ) {
    self.hypothesisID = hypothesisID
    self.statement = statement
    self.evidenceLinks = evidenceLinks
  }
}

public struct MechanicDiagnosticFinding: Codable, Equatable, Sendable {
  public let conclusion: String
  public let limitations: [String]
  public let nextAction: String
  public let actor: MechanicDiagnosticActorSnapshot
  public let recordedAt: String

  public init(
    conclusion: String,
    limitations: [String],
    nextAction: String,
    actor: MechanicDiagnosticActorSnapshot,
    recordedAt: String
  ) {
    self.conclusion = conclusion
    self.limitations = limitations
    self.nextAction = nextAction
    self.actor = actor
    self.recordedAt = recordedAt
  }
}

public enum MechanicDiagnosticVerificationOutcome: String, Codable, CaseIterable, Sendable {
  case resolved = "RESOLVED"
  case notResolved = "NOT_RESOLVED"
  case notReproduced = "NOT_REPRODUCED"
  case notPerformed = "NOT_PERFORMED"
}

public struct MechanicDiagnosticVerification: Codable, Equatable, Sendable {
  public let outcome: MechanicDiagnosticVerificationOutcome
  public let method: String?
  public let reason: String?
  public let evidenceIDs: [String]
  public let recordedAt: String

  private enum CodingKeys: String, CodingKey {
    case outcome, method, reason
    case evidenceIDs = "evidenceIds"
    case recordedAt
  }

  public init(
    outcome: MechanicDiagnosticVerificationOutcome,
    method: String?,
    reason: String?,
    evidenceIDs: [String],
    recordedAt: String
  ) {
    self.outcome = outcome
    self.method = method
    self.reason = reason
    self.evidenceIDs = evidenceIDs
    self.recordedAt = recordedAt
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(outcome, forKey: .outcome)
    try container.encodeRequiredNullable(method, forKey: .method)
    try container.encodeRequiredNullable(reason, forKey: .reason)
    try container.encode(evidenceIDs, forKey: .evidenceIDs)
    try container.encode(recordedAt, forKey: .recordedAt)
  }
}

public struct MechanicDiagnosticCaseRevision: Codable, Equatable, Sendable, Identifiable {
  public static let currentContract = "service.diagnostic-case-draft"
  public static let currentContractVersion = "1.0.0"

  public let contract: String
  public let contractVersion: String
  public let caseID: String
  public let revisionID: String
  public let supersedesRevisionID: String?
  public let revisionNumber: Int
  public let authority: MechanicDiagnosticCaseAuthority
  public let vehicleClaimsAuthorized: Bool
  public let maintenanceHistoryAuthorized: Bool
  public let organization: MechanicDiagnosticOrganizationSnapshot
  public let customer: MechanicDiagnosticCustomerSnapshot
  public let vehicle: MechanicDiagnosticVehicleSnapshot
  public let actor: MechanicDiagnosticActorSnapshot
  public let status: MechanicDiagnosticCaseStatus
  public let transition: MechanicDiagnosticCaseTransition
  public let complaint: MechanicDiagnosticComplaint
  public let evidence: [MechanicDiagnosticEvidence]
  public let hypotheses: [MechanicDiagnosticHypothesis]
  public let finding: MechanicDiagnosticFinding?
  public let verification: MechanicDiagnosticVerification?
  public let createdAt: String

  public var id: String { revisionID }

  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion
    case caseID = "caseId"
    case revisionID = "revisionId"
    case supersedesRevisionID = "supersedesRevisionId"
    case revisionNumber, authority, vehicleClaimsAuthorized, maintenanceHistoryAuthorized
    case organization, customer, vehicle, actor, status, transition, complaint, evidence
    case hypotheses, finding, verification, createdAt
  }

  public init(
    contract: String = Self.currentContract,
    contractVersion: String = Self.currentContractVersion,
    caseID: String,
    revisionID: String,
    supersedesRevisionID: String?,
    revisionNumber: Int,
    authority: MechanicDiagnosticCaseAuthority = .technicianLocalDraft,
    vehicleClaimsAuthorized: Bool = false,
    maintenanceHistoryAuthorized: Bool = false,
    organization: MechanicDiagnosticOrganizationSnapshot,
    customer: MechanicDiagnosticCustomerSnapshot,
    vehicle: MechanicDiagnosticVehicleSnapshot,
    actor: MechanicDiagnosticActorSnapshot,
    status: MechanicDiagnosticCaseStatus,
    transition: MechanicDiagnosticCaseTransition,
    complaint: MechanicDiagnosticComplaint,
    evidence: [MechanicDiagnosticEvidence],
    hypotheses: [MechanicDiagnosticHypothesis],
    finding: MechanicDiagnosticFinding?,
    verification: MechanicDiagnosticVerification?,
    createdAt: String
  ) throws {
    self.contract = contract
    self.contractVersion = contractVersion
    self.caseID = caseID
    self.revisionID = revisionID
    self.supersedesRevisionID = supersedesRevisionID
    self.revisionNumber = revisionNumber
    self.authority = authority
    self.vehicleClaimsAuthorized = vehicleClaimsAuthorized
    self.maintenanceHistoryAuthorized = maintenanceHistoryAuthorized
    self.organization = organization
    self.customer = customer
    self.vehicle = vehicle
    self.actor = actor
    self.status = status
    self.transition = transition
    self.complaint = complaint
    self.evidence = evidence
    self.hypotheses = hypotheses
    self.finding = finding
    self.verification = verification
    self.createdAt = createdAt
    try validateContract()
  }

  public static func create(
    organization: MechanicDiagnosticOrganizationSnapshot,
    customer: MechanicDiagnosticCustomerSnapshot,
    vehicle: MechanicDiagnosticVehicleSnapshot,
    actor: MechanicDiagnosticActorSnapshot,
    complaint: MechanicDiagnosticComplaint,
    evidence: [MechanicDiagnosticEvidence] = [],
    hypotheses: [MechanicDiagnosticHypothesis] = [],
    finding: MechanicDiagnosticFinding? = nil,
    verification: MechanicDiagnosticVerification? = nil,
    createdAt: String,
    caseID: String? = nil,
    revisionID: String? = nil
  ) throws -> Self {
    let createdDate = try MechanicDiagnosticCaseValidation.requiredDate(
      createdAt, field: "created_at")
    let resolvedCaseID =
      try caseID
      ?? MechanicDiagnosticCaseIDGenerator.make(.diagnosticCase, at: createdDate)
    let resolvedRevisionID =
      try revisionID
      ?? MechanicDiagnosticCaseIDGenerator.make(.caseRevision, at: createdDate)
    return try Self(
      caseID: resolvedCaseID,
      revisionID: resolvedRevisionID,
      supersedesRevisionID: nil,
      revisionNumber: 1,
      organization: organization,
      customer: customer,
      vehicle: vehicle,
      actor: actor,
      status: .intake,
      transition: MechanicDiagnosticCaseTransition(
        action: .created, fromStatus: nil, toStatus: .intake, reason: nil),
      complaint: complaint,
      evidence: evidence,
      hypotheses: hypotheses,
      finding: finding,
      verification: verification,
      createdAt: createdAt)
  }

  public func revising(
    status: MechanicDiagnosticCaseStatus,
    action: MechanicDiagnosticCaseTransitionAction,
    reason: String? = nil,
    actor: MechanicDiagnosticActorSnapshot? = nil,
    complaint: MechanicDiagnosticComplaint? = nil,
    evidence: [MechanicDiagnosticEvidence],
    hypotheses: [MechanicDiagnosticHypothesis],
    finding: MechanicDiagnosticFinding?,
    verification: MechanicDiagnosticVerification?,
    createdAt: String,
    revisionID: String? = nil
  ) throws -> Self {
    try MechanicDiagnosticCaseTransitionPolicy.validate(
      action: action, from: self.status, to: status, reason: reason)
    let createdDate = try MechanicDiagnosticCaseValidation.requiredDate(
      createdAt, field: "created_at")
    return try Self(
      caseID: caseID,
      revisionID: try revisionID
        ?? MechanicDiagnosticCaseIDGenerator.make(.caseRevision, at: createdDate),
      supersedesRevisionID: self.revisionID,
      revisionNumber: revisionNumber + 1,
      organization: organization,
      customer: customer,
      vehicle: vehicle,
      actor: actor ?? self.actor,
      status: status,
      transition: MechanicDiagnosticCaseTransition(
        action: action, fromStatus: self.status, toStatus: status, reason: reason),
      complaint: complaint ?? self.complaint,
      evidence: evidence,
      hypotheses: hypotheses,
      finding: finding,
      verification: verification,
      createdAt: createdAt)
  }

  public func encoded() throws -> Data {
    try VHOSJSON.encoder().encode(self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(contract, forKey: .contract)
    try container.encode(contractVersion, forKey: .contractVersion)
    try container.encode(caseID, forKey: .caseID)
    try container.encode(revisionID, forKey: .revisionID)
    try container.encodeRequiredNullable(supersedesRevisionID, forKey: .supersedesRevisionID)
    try container.encode(revisionNumber, forKey: .revisionNumber)
    try container.encode(authority, forKey: .authority)
    try container.encode(vehicleClaimsAuthorized, forKey: .vehicleClaimsAuthorized)
    try container.encode(maintenanceHistoryAuthorized, forKey: .maintenanceHistoryAuthorized)
    try container.encode(organization, forKey: .organization)
    try container.encode(customer, forKey: .customer)
    try container.encode(vehicle, forKey: .vehicle)
    try container.encode(actor, forKey: .actor)
    try container.encode(status, forKey: .status)
    try container.encode(transition, forKey: .transition)
    try container.encode(complaint, forKey: .complaint)
    try container.encode(evidence, forKey: .evidence)
    try container.encode(hypotheses, forKey: .hypotheses)
    try container.encodeRequiredNullable(finding, forKey: .finding)
    try container.encodeRequiredNullable(verification, forKey: .verification)
    try container.encode(createdAt, forKey: .createdAt)
  }

  public func validateContract() throws {
    guard contract == Self.currentContract, contractVersion == Self.currentContractVersion else {
      throw MechanicDiagnosticCaseError.unsupportedContract
    }
    guard (1...Int(Int32.max)).contains(revisionNumber) else {
      throw MechanicDiagnosticCaseError.invalidRevision
    }
    guard authority == .technicianLocalDraft, !vehicleClaimsAuthorized,
      !maintenanceHistoryAuthorized
    else { throw MechanicDiagnosticCaseError.authorityEscalation }
    try MechanicDiagnosticCaseValidation.requireID(caseID, prefix: "case", field: "case_id")
    try MechanicDiagnosticCaseValidation.requireID(
      revisionID, prefix: "caserev", field: "revision_id")
    if let supersedesRevisionID {
      try MechanicDiagnosticCaseValidation.requireID(
        supersedesRevisionID, prefix: "caserev", field: "supersedes_revision_id")
      guard supersedesRevisionID != revisionID, revisionNumber > 1 else {
        throw MechanicDiagnosticCaseError.invalidRevision
      }
    } else if revisionNumber != 1 {
      throw MechanicDiagnosticCaseError.invalidRevision
    }
    try MechanicDiagnosticCaseTransitionPolicy.validate(
      action: transition.action, from: transition.fromStatus, to: transition.toStatus,
      reason: transition.reason)
    guard transition.toStatus == status else {
      throw MechanicDiagnosticCaseError.invalidTransition(
        action: transition.action, from: transition.fromStatus, to: transition.toStatus)
    }
    if revisionNumber == 1 {
      guard supersedesRevisionID == nil, transition.action == .created else {
        throw MechanicDiagnosticCaseError.invalidRevision
      }
    } else {
      guard supersedesRevisionID != nil, transition.action != .created else {
        throw MechanicDiagnosticCaseError.invalidRevision
      }
    }
    try MechanicDiagnosticCaseValidation.requireID(
      organization.organizationID, prefix: "org", field: "organization.organization_id")
    try MechanicDiagnosticCaseValidation.requireText(
      organization.displayName, maximum: 160, field: "organization.display_name")
    try MechanicDiagnosticCaseValidation.requireID(
      customer.customerID, prefix: "customer", field: "customer.customer_id")
    try MechanicDiagnosticCaseValidation.requireText(
      customer.displayName, maximum: 160, field: "customer.display_name")
    try MechanicDiagnosticCaseValidation.validateOptionalText(
      customer.phone, maximum: 80, field: "customer.phone")
    if let email = customer.email {
      try MechanicDiagnosticCaseValidation.requireText(
        email, maximum: 254, field: "customer.email")
      guard
        email.range(
          of: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", options: .regularExpression) != nil
      else { throw MechanicDiagnosticCaseError.invalidField("customer.email") }
    }
    try MechanicDiagnosticCaseValidation.requireID(
      vehicle.vehicleID, prefix: "veh", field: "vehicle.vehicle_id")
    try MechanicDiagnosticCaseValidation.requireText(
      vehicle.displayName, maximum: 200, field: "vehicle.display_name")
    if let vin = vehicle.vin,
      vin.range(of: "^[A-HJ-NPR-Z0-9]{17}$", options: .regularExpression) == nil
    {
      throw MechanicDiagnosticCaseError.invalidField("vehicle.vin")
    }
    if let year = vehicle.modelYear, !(1886...3000).contains(year) {
      throw MechanicDiagnosticCaseError.invalidField("vehicle.model_year")
    }
    for value in [vehicle.make, vehicle.model, vehicle.trim].compactMap({ $0 }) {
      try MechanicDiagnosticCaseValidation.requireText(
        value, maximum: 120, field: "vehicle identity")
    }
    try MechanicDiagnosticCaseValidation.validateOptionalText(
      vehicle.licensePlate, maximum: 32, field: "vehicle.license_plate")
    if let odometer = vehicle.odometer, !(0...20_000_000).contains(odometer.value) {
      throw MechanicDiagnosticCaseError.invalidField("vehicle.odometer")
    }
    try MechanicDiagnosticCaseValidation.validate(actor, field: "actor")
    guard actor.source == .technician else {
      throw MechanicDiagnosticCaseError.invalidField("actor.source")
    }
    try MechanicDiagnosticCaseValidation.requireText(
      complaint.description, maximum: 10_000, field: "complaint.description")
    try MechanicDiagnosticCaseValidation.validateOptionalText(
      complaint.operatingConditions, maximum: 5_000, field: "complaint.operating_conditions")
    try MechanicDiagnosticCaseValidation.validateOptionalText(
      complaint.priorWork, maximum: 5_000, field: "complaint.prior_work")
    _ = try MechanicDiagnosticCaseValidation.requiredDate(
      complaint.reportedAt, field: "complaint.reported_at")
    _ = try MechanicDiagnosticCaseValidation.requiredDate(createdAt, field: "created_at")

    guard evidence.count <= 5_000,
      Set(evidence.map(\.evidenceID)).count == evidence.count
    else {
      throw MechanicDiagnosticCaseError.duplicateIdentity("evidence_id")
    }
    var attachmentIDs = Set<String>()
    for item in evidence {
      try MechanicDiagnosticCaseValidation.validate(item)
      if let attachment = item.attachment,
        !attachmentIDs.insert(attachment.attachmentID).inserted
      {
        throw MechanicDiagnosticCaseError.duplicateIdentity("attachment_id")
      }
    }
    let evidenceIDs = Set(evidence.map(\.evidenceID))
    guard hypotheses.count <= 1_000,
      Set(hypotheses.map(\.hypothesisID)).count == hypotheses.count
    else {
      throw MechanicDiagnosticCaseError.duplicateIdentity("hypothesis_id")
    }
    for hypothesis in hypotheses {
      try MechanicDiagnosticCaseValidation.requireID(
        hypothesis.hypothesisID, prefix: "hypothesis", field: "hypothesis_id")
      try MechanicDiagnosticCaseValidation.requireText(
        hypothesis.statement, maximum: 2_000, field: "hypothesis.statement")
      guard !hypothesis.evidenceLinks.isEmpty, hypothesis.evidenceLinks.count <= 500,
        Set(hypothesis.evidenceLinks.map(\.evidenceID)).count == hypothesis.evidenceLinks.count,
        hypothesis.evidenceLinks.allSatisfy({ evidenceIDs.contains($0.evidenceID) })
      else { throw MechanicDiagnosticCaseError.unresolvedEvidenceReference }
    }
    if let finding {
      guard finding.limitations.count <= 100 else {
        throw MechanicDiagnosticCaseError.invalidField("finding.limitations")
      }
      try MechanicDiagnosticCaseValidation.requireText(
        finding.conclusion, maximum: 10_000, field: "finding.conclusion")
      try MechanicDiagnosticCaseValidation.requireText(
        finding.nextAction, maximum: 5_000, field: "finding.next_action")
      for limitation in finding.limitations {
        try MechanicDiagnosticCaseValidation.requireText(
          limitation, maximum: 2_000, field: "finding.limitations")
      }
      try MechanicDiagnosticCaseValidation.validate(finding.actor, field: "finding.actor")
      guard finding.actor.source == .technician else {
        throw MechanicDiagnosticCaseError.invalidField("finding.actor.source")
      }
      _ = try MechanicDiagnosticCaseValidation.requiredDate(
        finding.recordedAt, field: "finding.recorded_at")
    }
    if status == .verify || status == .closed {
      guard finding != nil else { throw MechanicDiagnosticCaseError.findingRequired }
    }
    if status == .closed, verification == nil {
      throw MechanicDiagnosticCaseError.verificationRequired
    }
    if let verification {
      try MechanicDiagnosticCaseValidation.validate(
        verification, availableEvidenceIDs: evidenceIDs)
    }
  }
}

extension KeyedEncodingContainer {
  fileprivate mutating func encodeRequiredNullable<Value: Encodable>(
    _ value: Value?,
    forKey key: Key
  ) throws {
    if let value {
      try encode(value, forKey: key)
    } else {
      try encodeNil(forKey: key)
    }
  }
}

public enum MechanicDiagnosticCaseTransitionPolicy {
  public static func isAllowed(
    action: MechanicDiagnosticCaseTransitionAction,
    from: MechanicDiagnosticCaseStatus?,
    to: MechanicDiagnosticCaseStatus
  ) -> Bool {
    switch action {
    case .created:
      from == nil && to == .intake
    case .amended:
      from == to && from != nil && from != .voided
    case .inspectionStarted:
      from == .intake && to == .inspection
    case .findingsRecorded:
      from == .inspection && to == .findings
    case .verificationStarted:
      from == .findings && to == .verify
    case .closed:
      from == .verify && to == .closed
    case .voided:
      from != nil && from != .voided && to == .voided
    }
  }

  public static func validate(
    action: MechanicDiagnosticCaseTransitionAction,
    from: MechanicDiagnosticCaseStatus?,
    to: MechanicDiagnosticCaseStatus,
    reason: String?
  ) throws {
    guard isAllowed(action: action, from: from, to: to) else {
      throw MechanicDiagnosticCaseError.invalidTransition(action: action, from: from, to: to)
    }
    if action == .created {
      guard reason == nil else { throw MechanicDiagnosticCaseError.invalidTransitionReason }
    } else if action == .amended || action == .voided {
      guard let reason else { throw MechanicDiagnosticCaseError.invalidTransitionReason }
      try MechanicDiagnosticCaseValidation.requireText(
        reason, maximum: 2_000, field: "transition.reason")
    } else if let reason {
      try MechanicDiagnosticCaseValidation.requireText(
        reason, maximum: 2_000, field: "transition.reason")
    }
  }
}

public enum MechanicDiagnosticCaseIDPrefix: String, Codable, CaseIterable, Sendable {
  case diagnosticCase = "case"
  case caseRevision = "caserev"
  case evidence = "evidence"
  case hypothesis = "hypothesis"
  case organization = "org"
  case customer = "customer"
  case vehicle = "veh"
  case actor = "actor"
  case attachment = "attachment"
}

public enum MechanicDiagnosticCaseIDGenerator {
  public static func make(
    _ prefix: MechanicDiagnosticCaseIDPrefix,
    at date: Date = Date()
  ) throws -> String {
    try state.make(prefix: prefix.rawValue, at: date)
  }

  public static func make(prefix: String, at date: Date = Date()) throws -> String {
    guard MechanicDiagnosticCaseIDPrefix(rawValue: prefix) != nil else {
      throw MechanicDiagnosticCaseError.invalidIDPrefix(prefix)
    }
    return try state.make(prefix: prefix, at: date)
  }

  private static let state = MechanicDiagnosticCaseULIDState()
}

public enum MechanicDiagnosticCaseError: Error, Equatable, LocalizedError {
  case unsupportedContract
  case authorityEscalation
  case invalidIDPrefix(String)
  case invalidField(String)
  case invalidRevision
  case invalidTransition(
    action: MechanicDiagnosticCaseTransitionAction,
    from: MechanicDiagnosticCaseStatus?,
    to: MechanicDiagnosticCaseStatus)
  case invalidTransitionReason
  case duplicateIdentity(String)
  case unresolvedEvidenceReference
  case findingRequired
  case verificationRequired

  public var errorDescription: String? {
    switch self {
    case .unsupportedContract:
      "The mechanic diagnostic case contract or version is unsupported."
    case .authorityEscalation:
      "A technician-local draft cannot authorize vehicle claims or maintenance history."
    case .invalidIDPrefix(let prefix):
      "The mechanic diagnostic case ID prefix \(prefix) is unsupported."
    case .invalidField(let field):
      "The mechanic diagnostic case field \(field) is invalid."
    case .invalidRevision:
      "The mechanic diagnostic case revision identity or numbering is invalid."
    case .invalidTransition(let action, let from, let to):
      "The case transition \(action.rawValue) from \(from?.rawValue ?? "none") to \(to.rawValue) is not allowed."
    case .invalidTransitionReason:
      "This case transition has an invalid or missing reason."
    case .duplicateIdentity(let field):
      "The mechanic diagnostic case contains a duplicate \(field)."
    case .unresolvedEvidenceReference:
      "A hypothesis or verification references missing or duplicate evidence."
    case .findingRequired:
      "Verification requires a technician-authored finding."
    case .verificationRequired:
      "A closed diagnostic case requires verification."
    }
  }
}

private enum MechanicDiagnosticCaseValidation {
  static func requireID(_ value: String, prefix: String, field: String) throws {
    let escaped = NSRegularExpression.escapedPattern(for: prefix)
    guard
      value.range(
        of: "^\(escaped)_[0-7][0-9A-HJKMNP-TV-Z]{25}$",
        options: .regularExpression) != nil
    else { throw MechanicDiagnosticCaseError.invalidField(field) }
  }

  static func requireText(_ value: String, maximum: Int, field: String) throws {
    guard value == value.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
      value.unicodeScalars.count <= maximum
    else { throw MechanicDiagnosticCaseError.invalidField(field) }
  }

  static func validateOptionalText(_ value: String?, maximum: Int, field: String) throws {
    if let value { try requireText(value, maximum: maximum, field: field) }
  }

  static func requiredDate(_ value: String, field: String) throws -> Date {
    guard let date = MechanicDiagnosticWallTime.date(value) else {
      throw MechanicDiagnosticCaseError.invalidField(field)
    }
    return date
  }

  static func validate(_ actor: MechanicDiagnosticActorSnapshot, field: String) throws {
    try requireID(actor.actorID, prefix: "actor", field: "\(field).actor_id")
    try requireText(actor.displayName, maximum: 160, field: "\(field).display_name")
  }

  static func validate(_ evidence: MechanicDiagnosticEvidence) throws {
    try requireID(evidence.evidenceID, prefix: "evidence", field: "evidence_id")
    try requireText(evidence.description, maximum: 10_000, field: "evidence.description")
    _ = try requiredDate(evidence.recordedAt, field: "evidence.recorded_at")
    if let unit = evidence.unit {
      try requireText(unit, maximum: 80, field: "evidence.unit")
    }
    if let value = evidence.value {
      try requireText(value, maximum: 80, field: "evidence.value")
      guard
        value.range(
          of: "^-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:E[+-]?[0-9]+)?$",
          options: .regularExpression) != nil
      else { throw MechanicDiagnosticCaseError.invalidField("evidence.value") }
    }
    try validateOptionalText(evidence.method, maximum: 5_000, field: "evidence.method")
    try validateOptionalText(evidence.testPoint, maximum: 1_000, field: "evidence.test_point")
    try validateOptionalText(
      evidence.expectedResult, maximum: 2_000, field: "evidence.expected_result")
    try validateOptionalText(
      evidence.expectedResultSource, maximum: 2_000,
      field: "evidence.expected_result_source")
    if let code = evidence.dtcCode,
      code.range(of: "^[PBCU][0-3][0-9A-F]{3}$", options: .regularExpression) == nil
    {
      throw MechanicDiagnosticCaseError.invalidField("evidence.dtc_code")
    }
    guard (evidence.value == nil) == (evidence.unit == nil) else {
      throw MechanicDiagnosticCaseError.invalidField("evidence.value_unit")
    }
    switch evidence.type {
    case .measurement:
      guard evidence.value != nil, evidence.unit != nil, evidence.method != nil
      else { throw MechanicDiagnosticCaseError.invalidField("evidence.measurement") }
    case .dtc:
      guard evidence.dtcCode != nil, evidence.value == nil, evidence.unit == nil else {
        throw MechanicDiagnosticCaseError.invalidField("evidence.dtc_code")
      }
    case .photo, .video, .audio, .document, .scanReport:
      guard evidence.attachment != nil else {
        throw MechanicDiagnosticCaseError.invalidField("evidence.attachment")
      }
    case .observation:
      break
    }
    if evidence.type != .dtc, evidence.dtcCode != nil {
      throw MechanicDiagnosticCaseError.invalidField("evidence.dtc_code")
    }
    if let attachment = evidence.attachment { try validate(attachment) }
  }

  static func validate(_ attachment: MechanicDiagnosticAttachment) throws {
    try requireID(attachment.attachmentID, prefix: "attachment", field: "attachment_id")
    try requireText(attachment.displayName, maximum: 255, field: "attachment.display_name")
    guard
      attachment.mediaType.range(
        of: "^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$",
        options: .regularExpression) != nil,
      (0...1_073_741_824).contains(attachment.byteCount),
      attachment.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    else { throw MechanicDiagnosticCaseError.invalidField("attachment") }
    try requireText(attachment.storageKey, maximum: 500, field: "attachment.storage_key")
    if let capturedAt = attachment.capturedAt {
      _ = try requiredDate(capturedAt, field: "attachment.captured_at")
    }
  }

  static func validate(
    _ verification: MechanicDiagnosticVerification,
    availableEvidenceIDs: Set<String>
  ) throws {
    _ = try requiredDate(verification.recordedAt, field: "verification.recorded_at")
    guard verification.evidenceIDs.count <= 500,
      Set(verification.evidenceIDs).count == verification.evidenceIDs.count,
      verification.evidenceIDs.allSatisfy(availableEvidenceIDs.contains)
    else { throw MechanicDiagnosticCaseError.unresolvedEvidenceReference }
    switch verification.outcome {
    case .notPerformed:
      guard verification.method == nil, verification.evidenceIDs.isEmpty,
        let reason = verification.reason
      else { throw MechanicDiagnosticCaseError.invalidField("verification") }
      try requireText(reason, maximum: 2_000, field: "verification.reason")
    case .resolved, .notResolved, .notReproduced:
      guard let method = verification.method, !verification.evidenceIDs.isEmpty else {
        throw MechanicDiagnosticCaseError.invalidField("verification")
      }
      try requireText(method, maximum: 2_000, field: "verification.method")
      if let reason = verification.reason {
        try requireText(reason, maximum: 2_000, field: "verification.reason")
      }
    }
  }
}

enum MechanicDiagnosticWallTime {
  private static let pattern =
    "^([0-9]{4})-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])[Tt]"
    + "([01][0-9]|2[0-3]):([0-5][0-9]):([0-5][0-9])(?:\\.([0-9]+))?"
    + "([Zz]|([+-])([01][0-9]|2[0-3]):([0-5][0-9]))$"

  static func date(_ value: String) -> Date? {
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(
        in: value, range: NSRange(location: 0, length: (value as NSString).length)),
      match.range.location == 0, match.range.length == (value as NSString).length
    else { return nil }
    let source = value as NSString
    func integer(_ group: Int) -> Int? {
      let range = match.range(at: group)
      guard range.location != NSNotFound else { return nil }
      return Int(source.substring(with: range))
    }
    guard let year = integer(1), (1...9_999).contains(year),
      let month = integer(2), let day = integer(3),
      let hour = integer(4), let minute = integer(5), let second = integer(6)
    else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var components = DateComponents()
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    guard let local = calendar.date(from: components),
      calendar.component(.year, from: local) == year,
      calendar.component(.month, from: local) == month,
      calendar.component(.day, from: local) == day,
      calendar.component(.hour, from: local) == hour,
      calendar.component(.minute, from: local) == minute,
      calendar.component(.second, from: local) == second
    else { return nil }

    let fractionRange = match.range(at: 7)
    let fraction: TimeInterval
    if fractionRange.location == NSNotFound {
      fraction = 0
    } else {
      fraction = Double("0." + source.substring(with: fractionRange)) ?? 0
    }
    let signRange = match.range(at: 9)
    let offset: Int
    if signRange.location == NSNotFound {
      offset = 0
    } else {
      guard let offsetHour = integer(10), let offsetMinute = integer(11) else { return nil }
      let magnitude = offsetHour * 3_600 + offsetMinute * 60
      offset = source.substring(with: signRange) == "+" ? magnitude : -magnitude
    }
    return local.addingTimeInterval(fraction - TimeInterval(offset))
  }
}

private final class MechanicDiagnosticCaseULIDState: @unchecked Sendable {
  private let lock = NSLock()
  private var lastTimestamp: UInt64 = 0
  private var lastRandom = [UInt8](repeating: 0, count: 10)

  func make(prefix: String, at date: Date) throws -> String {
    guard date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 >= 0 else {
      throw MechanicDiagnosticCaseError.invalidField("id timestamp")
    }
    let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded(.down)
    guard milliseconds.isFinite, milliseconds <= Double(0xFFFF_FFFF_FFFF) else {
      throw MechanicDiagnosticCaseError.invalidField("id timestamp")
    }
    let requested = UInt64(milliseconds)
    lock.lock()
    defer { lock.unlock() }
    var timestamp = requested
    if timestamp > lastTimestamp {
      lastRandom = secureRandomBytes(count: 10)
    } else {
      timestamp = lastTimestamp
      if !increment(&lastRandom) {
        guard timestamp < 0xFFFF_FFFF_FFFF else {
          throw MechanicDiagnosticCaseError.invalidField("id timestamp")
        }
        timestamp += 1
        lastRandom = secureRandomBytes(count: 10)
      }
    }
    lastTimestamp = timestamp
    var bytes = (0..<6).map { offset in
      UInt8((timestamp >> UInt64((5 - offset) * 8)) & 0xFF)
    }
    bytes.append(contentsOf: lastRandom)
    return "\(prefix)_\(encode(bytes))"
  }

  private func secureRandomBytes(count: Int) -> [UInt8] {
    var generator = SystemRandomNumberGenerator()
    return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
  }

  private func increment(_ bytes: inout [UInt8]) -> Bool {
    for index in bytes.indices.reversed() {
      if bytes[index] < .max {
        bytes[index] += 1
        return true
      }
      bytes[index] = 0
    }
    return false
  }

  private func encode(_ bytes: [UInt8]) -> String {
    let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    var bits = [UInt8](repeating: 0, count: 130)
    for byteIndex in bytes.indices {
      for bitIndex in 0..<8 {
        bits[2 + byteIndex * 8 + bitIndex] =
          (bytes[byteIndex] >> UInt8(7 - bitIndex)) & 1
      }
    }
    return String(
      (0..<26).map { group in
        let value = (0..<5).reduce(0) { partial, offset in
          partial * 2 + Int(bits[group * 5 + offset])
        }
        return alphabet[value]
      })
  }
}
