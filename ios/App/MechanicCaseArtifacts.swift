import CryptoKit
import Foundation
import VHOSCore

enum MechanicCaseArtifactError: Error, Equatable, LocalizedError {
  case invalidAttachmentMetadata(String)
  case sourceUnavailable(String)
  case sourceIsNotRegularFile(String)
  case attachmentTooLarge(actual: Int64, maximum: Int64)
  case storedAttachmentMissing(String)
  case storedAttachmentIntegrityFailure(String)
  case invalidGeneratedAt(String)
  case invalidOutputDirectory(String)
  case outputAlreadyExists(String)
  case unsupportedPDFText(String)

  var errorDescription: String? {
    switch self {
    case .invalidAttachmentMetadata(let reason):
      "Invalid attachment metadata: \(reason)"
    case .sourceUnavailable(let path):
      "Attachment source is unavailable: \(path)"
    case .sourceIsNotRegularFile(let path):
      "Attachment source is not a regular file: \(path)"
    case .attachmentTooLarge(let actual, let maximum):
      "Attachment is \(actual) bytes; the maximum is \(maximum) bytes."
    case .storedAttachmentMissing(let storageKey):
      "Stored attachment is missing: \(storageKey)"
    case .storedAttachmentIntegrityFailure(let storageKey):
      "Stored attachment failed its byte-count or SHA-256 check: \(storageKey)"
    case .invalidGeneratedAt(let value):
      "generatedAt must be an RFC 3339 timestamp: \(value)"
    case .invalidOutputDirectory(let path):
      "Report output directory is invalid: \(path)"
    case .outputAlreadyExists(let path):
      "Report output already exists: \(path)"
    case .unsupportedPDFText(let value):
      "Report text cannot be represented safely in the deterministic PDF: \(value)"
    }
  }
}

/// Imports attachment bytes into app-private, content-addressed storage.
///
/// The returned record is metadata for the bytes that were actually read and persisted. Existing
/// content-addressed files are reused only after their length and digest have been verified.
final class MechanicCaseAttachmentStore {
  static let maximumByteCount: Int64 = 25 * 1_024 * 1_024

  let storageRoot: URL
  let attachmentsDirectory: URL

  private let fileManager: FileManager
  private let mutationLock = NSLock()

  init(storageRoot: URL? = nil, fileManager: FileManager = .default) throws {
    self.fileManager = fileManager

    if let storageRoot {
      self.storageRoot = storageRoot.standardizedFileURL
    } else {
      let applicationSupport = try fileManager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      self.storageRoot =
        applicationSupport
        .appendingPathComponent("VehicleHealthOS", isDirectory: true)
        .appendingPathComponent("MechanicDiagnosticCases", isDirectory: true)
    }

    attachmentsDirectory =
      self.storageRoot
      .appendingPathComponent("Attachments", isDirectory: true)
      .standardizedFileURL

    try fileManager.createDirectory(
      at: attachmentsDirectory,
      withIntermediateDirectories: true
    )
    try Self.applyCompleteFileProtection(to: attachmentsDirectory, fileManager: fileManager)
  }

  func importData(
    _ data: Data,
    attachmentID: String,
    displayName: String,
    mediaType: String,
    capturedAt: String? = nil
  ) throws -> MechanicDiagnosticAttachment {
    guard Int64(data.count) <= Self.maximumByteCount else {
      throw MechanicCaseArtifactError.attachmentTooLarge(
        actual: Int64(data.count),
        maximum: Self.maximumByteCount
      )
    }
    try Self.validateMetadata(
      attachmentID: attachmentID,
      displayName: displayName,
      mediaType: mediaType,
      capturedAt: capturedAt
    )

    mutationLock.lock()
    defer { mutationLock.unlock() }

    let stagingURL =
      attachmentsDirectory
      .appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: false)
    var stagingExists = false
    defer {
      if stagingExists {
        try? fileManager.removeItem(at: stagingURL)
      }
    }

    try data.write(to: stagingURL, options: [.atomic])
    stagingExists = true
    try Self.applyCompleteFileProtection(to: stagingURL, fileManager: fileManager)

    let digest = Self.sha256Hex(data)
    let storedURL = try commitStagedFile(
      stagingURL,
      digest: digest,
      byteCount: Int64(data.count)
    )
    stagingExists = fileManager.fileExists(atPath: stagingURL.path)

    let attachment = MechanicDiagnosticAttachment(
      attachmentID: attachmentID,
      displayName: displayName,
      mediaType: mediaType,
      byteCount: data.count,
      sha256: digest,
      storageKey: "Attachments/\(digest)",
      availability: .available,
      capturedAt: capturedAt
    )
    _ = try validate(attachment, expectedURL: storedURL)
    return attachment
  }

  func importFile(
    at sourceURL: URL,
    attachmentID: String,
    displayName: String,
    mediaType: String,
    capturedAt: String? = nil
  ) throws -> MechanicDiagnosticAttachment {
    try Self.validateMetadata(
      attachmentID: attachmentID,
      displayName: displayName,
      mediaType: mediaType,
      capturedAt: capturedAt
    )

    let source = sourceURL.standardizedFileURL
    let accessedSecurityScope = source.startAccessingSecurityScopedResource()
    defer {
      if accessedSecurityScope {
        source.stopAccessingSecurityScopedResource()
      }
    }

    let values: URLResourceValues
    do {
      values = try source.resourceValues(forKeys: [
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
      ])
    } catch {
      throw MechanicCaseArtifactError.sourceUnavailable(source.path)
    }
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw MechanicCaseArtifactError.sourceIsNotRegularFile(source.path)
    }
    if let fileSize = values.fileSize, Int64(fileSize) > Self.maximumByteCount {
      throw MechanicCaseArtifactError.attachmentTooLarge(
        actual: Int64(fileSize),
        maximum: Self.maximumByteCount
      )
    }

    mutationLock.lock()
    defer { mutationLock.unlock() }

    let stagingURL =
      attachmentsDirectory
      .appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: false)
    var stagingExists = false
    defer {
      if stagingExists {
        try? fileManager.removeItem(at: stagingURL)
      }
    }

    guard fileManager.createFile(atPath: stagingURL.path, contents: nil) else {
      throw MechanicCaseArtifactError.sourceUnavailable(stagingURL.path)
    }
    stagingExists = true

    let sourceHandle: FileHandle
    let destinationHandle: FileHandle
    do {
      sourceHandle = try FileHandle(forReadingFrom: source)
      destinationHandle = try FileHandle(forWritingTo: stagingURL)
    } catch {
      throw MechanicCaseArtifactError.sourceUnavailable(source.path)
    }
    defer {
      try? sourceHandle.close()
      try? destinationHandle.close()
    }

    var hasher = SHA256()
    var byteCount: Int64 = 0
    while let chunk = try sourceHandle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
      byteCount += Int64(chunk.count)
      guard byteCount <= Self.maximumByteCount else {
        throw MechanicCaseArtifactError.attachmentTooLarge(
          actual: byteCount,
          maximum: Self.maximumByteCount
        )
      }
      hasher.update(data: chunk)
      try destinationHandle.write(contentsOf: chunk)
    }
    try destinationHandle.synchronize()
    try Self.applyCompleteFileProtection(to: stagingURL, fileManager: fileManager)

    let digest = Self.hexDigest(hasher.finalize())
    let storedURL = try commitStagedFile(
      stagingURL,
      digest: digest,
      byteCount: byteCount
    )
    stagingExists = fileManager.fileExists(atPath: stagingURL.path)

    let attachment = MechanicDiagnosticAttachment(
      attachmentID: attachmentID,
      displayName: displayName,
      mediaType: mediaType,
      byteCount: Int(byteCount),
      sha256: digest,
      storageKey: "Attachments/\(digest)",
      availability: .available,
      capturedAt: capturedAt
    )
    _ = try validate(attachment, expectedURL: storedURL)
    return attachment
  }

  @discardableResult
  func validate(_ attachment: MechanicDiagnosticAttachment) throws -> URL {
    try validate(attachment, expectedURL: nil)
  }

  private func validate(
    _ attachment: MechanicDiagnosticAttachment,
    expectedURL: URL?
  ) throws -> URL {
    try Self.validateMetadata(
      attachmentID: attachment.attachmentID,
      displayName: attachment.displayName,
      mediaType: attachment.mediaType,
      capturedAt: attachment.capturedAt
    )
    guard attachment.availability == .available,
      attachment.byteCount >= 0,
      Int64(attachment.byteCount) <= Self.maximumByteCount,
      attachment.sha256.range(
        of: "^[0-9a-f]{64}$",
        options: .regularExpression
      ) != nil,
      attachment.storageKey == "Attachments/\(attachment.sha256)"
    else {
      throw MechanicCaseArtifactError.invalidAttachmentMetadata(attachment.storageKey)
    }

    let storedURL =
      attachmentsDirectory
      .appendingPathComponent(attachment.sha256, isDirectory: false)
      .standardizedFileURL
    guard storedURL.deletingLastPathComponent() == attachmentsDirectory,
      expectedURL == nil || expectedURL?.standardizedFileURL == storedURL
    else {
      throw MechanicCaseArtifactError.invalidAttachmentMetadata(attachment.storageKey)
    }

    let values: URLResourceValues
    do {
      values = try storedURL.resourceValues(forKeys: [
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
      ])
    } catch {
      throw MechanicCaseArtifactError.storedAttachmentMissing(attachment.storageKey)
    }
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw MechanicCaseArtifactError.storedAttachmentIntegrityFailure(attachment.storageKey)
    }
    guard values.fileSize == attachment.byteCount else {
      throw MechanicCaseArtifactError.storedAttachmentIntegrityFailure(attachment.storageKey)
    }

    let observed = try Self.digestFile(at: storedURL, maximumByteCount: Self.maximumByteCount)
    guard observed.byteCount == Int64(attachment.byteCount),
      observed.digest == attachment.sha256
    else {
      throw MechanicCaseArtifactError.storedAttachmentIntegrityFailure(attachment.storageKey)
    }
    return storedURL
  }

  private func commitStagedFile(
    _ stagingURL: URL,
    digest: String,
    byteCount: Int64
  ) throws -> URL {
    let destination = attachmentsDirectory.appendingPathComponent(digest, isDirectory: false)
    if fileManager.fileExists(atPath: destination.path) {
      let observed = try Self.digestFile(
        at: destination,
        maximumByteCount: Self.maximumByteCount
      )
      guard observed.byteCount == byteCount, observed.digest == digest else {
        throw MechanicCaseArtifactError.storedAttachmentIntegrityFailure(
          "Attachments/\(digest)"
        )
      }
      try fileManager.removeItem(at: stagingURL)
    } else {
      try fileManager.moveItem(at: stagingURL, to: destination)
    }
    try Self.applyCompleteFileProtection(to: destination, fileManager: fileManager)
    return destination
  }

  private static func validateMetadata(
    attachmentID: String,
    displayName: String,
    mediaType: String,
    capturedAt: String?
  ) throws {
    guard
      attachmentID.range(
        of: "^attachment_[0-7][0-9A-HJKMNP-TV-Z]{25}$",
        options: .regularExpression
      ) != nil
    else {
      throw MechanicCaseArtifactError.invalidAttachmentMetadata("attachment_id")
    }
    let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty, normalizedName.count <= 255 else {
      throw MechanicCaseArtifactError.invalidAttachmentMetadata("display_name")
    }
    guard
      mediaType.range(
        of: "^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,126}/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,126}$",
        options: .regularExpression
      ) != nil
    else {
      throw MechanicCaseArtifactError.invalidAttachmentMetadata("media_type")
    }
    if let capturedAt, !Self.isRFC3339(capturedAt) {
      throw MechanicCaseArtifactError.invalidAttachmentMetadata("captured_at")
    }
  }

  fileprivate static func digestFile(
    at url: URL,
    maximumByteCount: Int64? = nil
  ) throws -> (digest: String, byteCount: Int64) {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var hasher = SHA256()
    var byteCount: Int64 = 0
    while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
      byteCount += Int64(chunk.count)
      if let maximumByteCount, byteCount > maximumByteCount {
        throw MechanicCaseArtifactError.attachmentTooLarge(
          actual: byteCount,
          maximum: maximumByteCount
        )
      }
      hasher.update(data: chunk)
    }
    return (hexDigest(hasher.finalize()), byteCount)
  }

  fileprivate static func sha256Hex(_ data: Data) -> String {
    hexDigest(SHA256.hash(data: data))
  }

  private static func hexDigest<S: Sequence>(_ digest: S) -> String where S.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  fileprivate static func isRFC3339(_ value: String) -> Bool {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if fractional.date(from: value) != nil { return true }
    let wholeSeconds = ISO8601DateFormatter()
    wholeSeconds.formatOptions = [.withInternetDateTime]
    return wholeSeconds.date(from: value) != nil
  }

  fileprivate static func applyCompleteFileProtection(
    to url: URL,
    fileManager: FileManager
  ) throws {
    #if os(iOS)
      try fileManager.setAttributes(
        [.protectionKey: FileProtectionType.complete],
        ofItemAtPath: url.path
      )
    #endif
  }
}

struct MechanicReportPrivacySelection: Codable, Equatable, Sendable {
  var redactCustomerContact: Bool
  var redactVIN: Bool
  var redactLicensePlate: Bool
  var redactPriorWork: Bool

  init(
    redactCustomerContact: Bool = true,
    redactVIN: Bool = true,
    redactLicensePlate: Bool = true,
    redactPriorWork: Bool = true
  ) {
    self.redactCustomerContact = redactCustomerContact
    self.redactVIN = redactVIN
    self.redactLicensePlate = redactLicensePlate
    self.redactPriorWork = redactPriorWork
  }

  private enum CodingKeys: String, CodingKey {
    case redactCustomerContact
    case redactVIN = "redactVin"
    case redactLicensePlate
    case redactPriorWork
  }
}

struct MechanicReportManifestArtifact: Codable, Equatable, Sendable {
  let path: String
  let mediaType: String
  let byteCount: Int64
  let sha256: String
}

struct MechanicReportManifest: Codable, Equatable, Sendable {
  static let currentContract = "service.mechanic-report-manifest"
  static let currentContractVersion = "1.0.0"
  static let currentRenderer = "vhos.mechanic-report.pdf"
  static let currentRendererVersion = "1.0.0"

  let contract: String
  let contractVersion: String
  let renderer: String
  let rendererVersion: String
  let generatedAt: String
  let sourceCaseContract: String
  let sourceCaseContractVersion: String
  let caseID: String
  let revisionID: String
  let sourceRevisionSHA256: String
  let authority: MechanicDiagnosticCaseAuthority
  let vehicleClaimsAuthorized: Bool
  let maintenanceHistoryAuthorized: Bool
  let privacy: MechanicReportPrivacySelection
  let artifacts: [MechanicReportManifestArtifact]

  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion, renderer, rendererVersion, generatedAt
    case sourceCaseContract, sourceCaseContractVersion
    case caseID = "caseId"
    case revisionID = "revisionId"
    case sourceRevisionSHA256 = "sourceRevisionSha256"
    case authority, vehicleClaimsAuthorized, maintenanceHistoryAuthorized, privacy, artifacts
  }
}

struct MechanicReportArtifactBundle: Equatable, Sendable {
  let directory: URL
  let pdfURL: URL
  let caseJSONURL: URL
  let manifestURL: URL
  let manifest: MechanicReportManifest
}

/// Creates a deterministic, redacted report projection of exactly one committed case revision.
///
/// Commitment remains the caller's ledger boundary. This generator validates and hashes the exact
/// revision supplied to it, and never revises or appends to the case ledger.
final class MechanicCaseReportArtifactGenerator {
  static let reportLabel = "TECHNICIAN LOCAL DRAFT — NOT VEHICLE SAFETY CLEARANCE"
  static let caseSnapshotContract = "service.diagnostic-case-report-snapshot"
  static let caseSnapshotContractVersion = "1.0.0"

  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func generate(
    committedRevision revision: MechanicDiagnosticCaseRevision,
    privacy: MechanicReportPrivacySelection = MechanicReportPrivacySelection(),
    generatedAt: String,
    outputDirectory: URL
  ) throws -> MechanicReportArtifactBundle {
    try revision.validateContract()
    guard MechanicCaseAttachmentStore.isRFC3339(generatedAt) else {
      throw MechanicCaseArtifactError.invalidGeneratedAt(generatedAt)
    }

    let destination = outputDirectory.standardizedFileURL
    let parent = destination.deletingLastPathComponent()
    guard destination.isFileURL,
      !destination.lastPathComponent.isEmpty,
      destination != parent
    else {
      throw MechanicCaseArtifactError.invalidOutputDirectory(destination.path)
    }
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw MechanicCaseArtifactError.outputAlreadyExists(destination.path)
    }
    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

    let exactRevisionData = try revision.encoded()
    let exactRevisionDigest = MechanicCaseAttachmentStore.sha256Hex(exactRevisionData)
    let snapshot = MechanicReportCaseSnapshot(
      revision: revision,
      sourceRevisionSHA256: exactRevisionDigest,
      generatedAt: generatedAt,
      privacy: privacy
    )
    let encoder = VHOSJSON.encoder()
    let caseJSONData = try encoder.encode(snapshot)
    let reportLines = ReportText.lines(for: snapshot)
    let pdfData = try DeterministicPDF.render(lines: reportLines)

    let pdfArtifact = MechanicReportManifestArtifact(
      path: "report.pdf",
      mediaType: "application/pdf",
      byteCount: Int64(pdfData.count),
      sha256: MechanicCaseAttachmentStore.sha256Hex(pdfData)
    )
    let caseArtifact = MechanicReportManifestArtifact(
      path: "case.json",
      mediaType: "application/json",
      byteCount: Int64(caseJSONData.count),
      sha256: MechanicCaseAttachmentStore.sha256Hex(caseJSONData)
    )
    let manifest = MechanicReportManifest(
      contract: MechanicReportManifest.currentContract,
      contractVersion: MechanicReportManifest.currentContractVersion,
      renderer: MechanicReportManifest.currentRenderer,
      rendererVersion: MechanicReportManifest.currentRendererVersion,
      generatedAt: generatedAt,
      sourceCaseContract: revision.contract,
      sourceCaseContractVersion: revision.contractVersion,
      caseID: revision.caseID,
      revisionID: revision.revisionID,
      sourceRevisionSHA256: exactRevisionDigest,
      authority: revision.authority,
      vehicleClaimsAuthorized: revision.vehicleClaimsAuthorized,
      maintenanceHistoryAuthorized: revision.maintenanceHistoryAuthorized,
      privacy: privacy,
      artifacts: [pdfArtifact, caseArtifact]
    )
    let manifestData = try encoder.encode(manifest)

    let staging = parent.appendingPathComponent(
      ".\(destination.lastPathComponent).staging-\(UUID().uuidString)",
      isDirectory: true
    )
    var stagingExists = false
    defer {
      if stagingExists {
        try? fileManager.removeItem(at: staging)
      }
    }

    try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
    stagingExists = true
    try MechanicCaseAttachmentStore.applyCompleteFileProtection(
      to: staging,
      fileManager: fileManager
    )

    let stagedPDF = staging.appendingPathComponent(pdfArtifact.path)
    let stagedCaseJSON = staging.appendingPathComponent(caseArtifact.path)
    let stagedManifest = staging.appendingPathComponent("manifest.json")
    try pdfData.write(to: stagedPDF, options: [.atomic])
    try caseJSONData.write(to: stagedCaseJSON, options: [.atomic])
    try manifestData.write(to: stagedManifest, options: [.atomic])
    for file in [stagedPDF, stagedCaseJSON, stagedManifest] {
      try MechanicCaseAttachmentStore.applyCompleteFileProtection(
        to: file,
        fileManager: fileManager
      )
    }

    try fileManager.moveItem(at: staging, to: destination)
    stagingExists = false
    try MechanicCaseAttachmentStore.applyCompleteFileProtection(
      to: destination,
      fileManager: fileManager
    )

    return MechanicReportArtifactBundle(
      directory: destination,
      pdfURL: destination.appendingPathComponent(pdfArtifact.path),
      caseJSONURL: destination.appendingPathComponent(caseArtifact.path),
      manifestURL: destination.appendingPathComponent("manifest.json"),
      manifest: manifest
    )
  }
}

private struct MechanicReportCaseSnapshot: Codable, Sendable {
  let contract: String
  let contractVersion: String
  let generatedAt: String
  let sourceCaseContract: String
  let sourceCaseContractVersion: String
  let sourceRevisionSHA256: String
  let caseID: String
  let revisionID: String
  let supersedesRevisionID: String?
  let revisionNumber: Int
  let authority: MechanicDiagnosticCaseAuthority
  let vehicleClaimsAuthorized: Bool
  let maintenanceHistoryAuthorized: Bool
  let privacy: MechanicReportPrivacySelection
  let organization: MechanicDiagnosticOrganizationSnapshot
  let customer: MechanicDiagnosticCustomerSnapshot
  let vehicle: MechanicDiagnosticVehicleSnapshot
  let actor: MechanicDiagnosticActorSnapshot
  let status: MechanicDiagnosticCaseStatus
  let transition: MechanicDiagnosticCaseTransition
  let complaint: MechanicDiagnosticComplaint
  let evidence: [MechanicDiagnosticEvidence]
  let hypotheses: [MechanicDiagnosticHypothesis]
  let finding: MechanicDiagnosticFinding?
  let verification: MechanicDiagnosticVerification?
  let sourceRevisionCreatedAt: String

  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion, generatedAt
    case sourceCaseContract, sourceCaseContractVersion
    case sourceRevisionSHA256 = "sourceRevisionSha256"
    case caseID = "caseId"
    case revisionID = "revisionId"
    case supersedesRevisionID = "supersedesRevisionId"
    case revisionNumber, authority, vehicleClaimsAuthorized, maintenanceHistoryAuthorized
    case privacy, organization, customer, vehicle, actor, status, transition, complaint
    case evidence, hypotheses, finding, verification, sourceRevisionCreatedAt
  }

  init(
    revision: MechanicDiagnosticCaseRevision,
    sourceRevisionSHA256: String,
    generatedAt: String,
    privacy: MechanicReportPrivacySelection
  ) {
    contract = MechanicCaseReportArtifactGenerator.caseSnapshotContract
    contractVersion = MechanicCaseReportArtifactGenerator.caseSnapshotContractVersion
    self.generatedAt = generatedAt
    sourceCaseContract = revision.contract
    sourceCaseContractVersion = revision.contractVersion
    self.sourceRevisionSHA256 = sourceRevisionSHA256
    caseID = revision.caseID
    revisionID = revision.revisionID
    supersedesRevisionID = revision.supersedesRevisionID
    revisionNumber = revision.revisionNumber
    authority = revision.authority
    vehicleClaimsAuthorized = revision.vehicleClaimsAuthorized
    maintenanceHistoryAuthorized = revision.maintenanceHistoryAuthorized
    self.privacy = privacy
    organization = revision.organization
    customer = MechanicDiagnosticCustomerSnapshot(
      customerID: revision.customer.customerID,
      displayName: revision.customer.displayName,
      phone: privacy.redactCustomerContact ? nil : revision.customer.phone,
      email: privacy.redactCustomerContact ? nil : revision.customer.email
    )
    vehicle = MechanicDiagnosticVehicleSnapshot(
      vehicleID: revision.vehicle.vehicleID,
      displayName: revision.vehicle.displayName,
      vin: privacy.redactVIN ? nil : revision.vehicle.vin,
      modelYear: revision.vehicle.modelYear,
      make: revision.vehicle.make,
      model: revision.vehicle.model,
      trim: revision.vehicle.trim,
      licensePlate: privacy.redactLicensePlate ? nil : revision.vehicle.licensePlate,
      odometer: revision.vehicle.odometer
    )
    actor = revision.actor
    status = revision.status
    transition = revision.transition
    complaint = MechanicDiagnosticComplaint(
      description: revision.complaint.description,
      reportedBy: revision.complaint.reportedBy,
      reportedAt: revision.complaint.reportedAt,
      operatingConditions: revision.complaint.operatingConditions,
      priorWork: privacy.redactPriorWork ? nil : revision.complaint.priorWork
    )
    evidence = revision.evidence
    hypotheses = revision.hypotheses
    finding = revision.finding
    verification = revision.verification
    sourceRevisionCreatedAt = revision.createdAt
  }
}

private enum ReportText {
  static func lines(for snapshot: MechanicReportCaseSnapshot) -> [String] {
    var lines: [String] = [
      MechanicCaseReportArtifactGenerator.reportLabel,
      "",
      "Generated: \(snapshot.generatedAt)",
      "Case: \(snapshot.caseID)",
      "Committed revision: \(snapshot.revisionID) (#\(snapshot.revisionNumber))",
      "Revision SHA-256: \(snapshot.sourceRevisionSHA256)",
      "Authority: \(snapshot.authority.rawValue)",
      "Vehicle claims authorized: NO",
      "Maintenance history authorized: NO",
      "",
      "ORGANIZATION AND TECHNICIAN",
      "Organization: \(snapshot.organization.displayName)",
      "Technician: \(snapshot.actor.displayName)",
      "Source: \(snapshot.actor.source.rawValue)",
      "",
      "CUSTOMER",
      "Name: \(snapshot.customer.displayName)",
      "Contact: \(customerContact(snapshot))",
      "",
      "VEHICLE",
      "Vehicle: \(snapshot.vehicle.displayName)",
      "VIN: \(snapshot.privacy.redactVIN ? "[REDACTED]" : optional(snapshot.vehicle.vin))",
      "License plate: \(snapshot.privacy.redactLicensePlate ? "[REDACTED]" : optional(snapshot.vehicle.licensePlate))",
      "Model year: \(snapshot.vehicle.modelYear.map(String.init) ?? "Not recorded")",
      "Make/model/trim: \([snapshot.vehicle.make, snapshot.vehicle.model, snapshot.vehicle.trim].compactMap { $0 }.joined(separator: " ").nilIfEmpty ?? "Not recorded")",
      "Odometer: \(odometer(snapshot.vehicle.odometer))",
      "",
      "CUSTOMER COMPLAINT",
      snapshot.complaint.description,
      "Reported by: \(snapshot.complaint.reportedBy.rawValue)",
      "Reported at: \(snapshot.complaint.reportedAt)",
      "Operating conditions: \(optional(snapshot.complaint.operatingConditions))",
      "Prior work: \(snapshot.privacy.redactPriorWork ? "[REDACTED]" : optional(snapshot.complaint.priorWork))",
      "",
      "EVIDENCE",
    ]

    if snapshot.evidence.isEmpty {
      lines.append("No evidence recorded in this revision.")
    } else {
      for item in snapshot.evidence {
        lines.append("• \(item.description) [\(item.type.rawValue), \(item.quality.rawValue)]")
        lines.append("  Source: \(item.source.rawValue); recorded: \(item.recordedAt)")
        if let value = item.value {
          lines.append("  Value: \(value)\(item.unit.map { " \($0)" } ?? "")")
        }
        if let dtc = item.dtcCode { lines.append("  DTC: \(dtc)") }
        if let method = item.method { lines.append("  Method: \(method)") }
        if let testPoint = item.testPoint { lines.append("  Test point: \(testPoint)") }
        if let expectedResult = item.expectedResult {
          lines.append("  Expected result: \(expectedResult)")
        }
        if let expectedResultSource = item.expectedResultSource {
          lines.append("  Expected-result source: \(expectedResultSource)")
        }
        if let attachment = item.attachment {
          lines.append("  Attachment: \(attachment.displayName) (\(attachment.sha256))")
        }
      }
    }

    lines.append("")
    lines.append("HYPOTHESES")
    if snapshot.hypotheses.isEmpty {
      lines.append("No hypotheses recorded in this revision.")
    } else {
      for item in snapshot.hypotheses {
        lines.append("• \(item.statement)")
        if !item.evidenceLinks.isEmpty {
          let links = item.evidenceLinks.map {
            "\($0.evidenceID) [\($0.relationship.rawValue)]"
          }
          lines.append("  Evidence: \(links.joined(separator: ", "))")
        }
      }
    }

    lines.append("")
    lines.append("TECHNICIAN FINDING")
    if let finding = snapshot.finding {
      lines.append(finding.conclusion)
      if !finding.limitations.isEmpty {
        lines.append("Limitations: \(finding.limitations.joined(separator: "; "))")
      }
      lines.append("Next action: \(finding.nextAction)")
      lines.append("Recorded by: \(finding.actor.displayName) at \(finding.recordedAt)")
    } else {
      lines.append("No technician finding recorded in this revision.")
    }

    lines.append("")
    lines.append("VERIFICATION")
    if let verification = snapshot.verification {
      lines.append("Outcome: \(verification.outcome.rawValue)")
      lines.append("Method: \(optional(verification.method))")
      lines.append("Reason: \(optional(verification.reason))")
      lines.append("Recorded at: \(verification.recordedAt)")
      if !verification.evidenceIDs.isEmpty {
        lines.append("Evidence IDs: \(verification.evidenceIDs.joined(separator: ", "))")
      }
    } else {
      lines.append("No verification recorded in this revision.")
    }

    lines.append("")
    lines.append(
      "This report is technician-authored draft evidence only. It is not canonical vehicle maintenance history, an authorized vehicle finding, or vehicle safety clearance."
    )
    return lines.flatMap { wrap($0, width: 88) }
  }

  private static func customerContact(_ snapshot: MechanicReportCaseSnapshot) -> String {
    if snapshot.privacy.redactCustomerContact { return "[REDACTED]" }
    return [snapshot.customer.phone, snapshot.customer.email]
      .compactMap { $0 }
      .joined(separator: ", ")
      .nilIfEmpty ?? "Not recorded"
  }

  private static func optional(_ value: String?) -> String {
    value?.nilIfEmpty ?? "Not recorded"
  }

  private static func odometer(_ value: MechanicDiagnosticOdometer?) -> String {
    guard let value else { return "Not recorded" }
    return "\(value.value) \(value.unit.rawValue)"
  }

  private static func wrap(_ input: String, width: Int) -> [String] {
    guard input.count > width else { return [input] }
    let indentation = String(input.prefix { $0 == " " })
    var output: [String] = []
    var current = ""
    for word in input.split(separator: " ", omittingEmptySubsequences: false) {
      let candidate = current.isEmpty ? String(word) : "\(current) \(word)"
      if candidate.count > width, !current.isEmpty {
        output.append(current)
        current = indentation + String(word)
      } else {
        current = candidate
      }
    }
    if !current.isEmpty { output.append(current) }
    return output.isEmpty ? [""] : output
  }
}

private enum DeterministicPDF {
  private static let linesPerPage = 53

  static func render(lines: [String]) throws -> Data {
    let pages = stride(from: 0, to: max(lines.count, 1), by: linesPerPage).map { start in
      Array(lines[start..<min(start + linesPerPage, lines.count)])
    }
    let normalizedPages = pages.isEmpty ? [[""]] : pages
    let objectCount = 3 + normalizedPages.count * 2
    let pageObjectIDs = normalizedPages.indices.map { 4 + $0 * 2 }
    let kids = pageObjectIDs.map { "\($0) 0 R" }.joined(separator: " ")

    var objects: [Data] = []
    objects.append(ascii("<< /Type /Catalog /Pages 2 0 R >>"))
    objects.append(ascii("<< /Type /Pages /Kids [\(kids)] /Count \(normalizedPages.count) >>"))
    objects.append(
      ascii("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"))

    for (index, pageLines) in normalizedPages.enumerated() {
      let pageID = pageObjectIDs[index]
      let streamID = pageID + 1
      objects.append(
        ascii(
          "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents \(streamID) 0 R >>"
        ))
      let stream = try contentStream(pageLines)
      var streamObject = ascii("<< /Length \(stream.count) >>\nstream\n")
      streamObject.append(stream)
      streamObject.append(ascii("\nendstream"))
      objects.append(streamObject)
    }

    var output = ascii("%PDF-1.4\n")
    var offsets: [Int] = [0]
    for (index, object) in objects.enumerated() {
      offsets.append(output.count)
      output.append(ascii("\(index + 1) 0 obj\n"))
      output.append(object)
      output.append(ascii("\nendobj\n"))
    }

    let xrefOffset = output.count
    output.append(ascii("xref\n0 \(objectCount + 1)\n"))
    output.append(ascii("0000000000 65535 f \n"))
    for offset in offsets.dropFirst() {
      output.append(ascii(String(format: "%010d 00000 n \n", offset)))
    }
    output.append(ascii("trailer\n<< /Size \(objectCount + 1) /Root 1 0 R >>\n"))
    output.append(ascii("startxref\n\(xrefOffset)\n%%EOF\n"))
    return output
  }

  private static func contentStream(_ lines: [String]) throws -> Data {
    var output = ascii("BT\n/F1 9 Tf\n12 TL\n54 738 Td\n")
    for line in lines {
      output.append(ascii("("))
      output.append(try escapedPDFString(line))
      output.append(ascii(") Tj\nT*\n"))
    }
    output.append(ascii("ET"))
    return output
  }

  private static func escapedPDFString(_ value: String) throws -> Data {
    guard let bytes = value.data(using: .windowsCP1252, allowLossyConversion: false) else {
      throw MechanicCaseArtifactError.unsupportedPDFText(value)
    }
    var output = Data()
    for byte in bytes {
      switch byte {
      case 0x28, 0x29, 0x5C:
        output.append(0x5C)
        output.append(byte)
      case 0x20...0x7E:
        output.append(byte)
      default:
        output.append(contentsOf: ascii(String(format: "\\%03o", byte)))
      }
    }
    return output
  }

  private static func ascii(_ value: String) -> Data {
    Data(value.utf8)
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
