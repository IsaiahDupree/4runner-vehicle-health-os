import CryptoKit
import Foundation
import PDFKit
import VHOSCore
import XCTest

@testable import Vehicle_Health_OS

final class MechanicCaseArtifactTests: XCTestCase {
  func testAttachmentStoreCopiesFileBytesAndDeduplicatesByDigest() throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }

    let source = temporary.appendingPathComponent("real-inspection-note.txt")
    let bytes = Data("Measured at the vehicle: 12.63 V\n".utf8)
    try bytes.write(to: source)
    let store = try MechanicCaseAttachmentStore(
      storageRoot: temporary.appendingPathComponent("private-store")
    )

    let importedFile = try store.importFile(
      at: source,
      attachmentID: "attachment_00000000000000000000000009",
      displayName: "inspection-note.txt",
      mediaType: "text/plain",
      capturedAt: "2026-09-07T14:15:00Z"
    )
    let importedData = try store.importData(
      bytes,
      attachmentID: "attachment_0000000000000000000000000A",
      displayName: "inspection-note-copy.txt",
      mediaType: "text/plain",
      capturedAt: "2026-09-07T14:15:00Z"
    )

    XCTAssertEqual(importedFile.sha256, sha256(bytes))
    XCTAssertEqual(importedFile.sha256, importedData.sha256)
    XCTAssertEqual(importedFile.storageKey, importedData.storageKey)
    XCTAssertEqual(importedFile.byteCount, bytes.count)
    let storedURL = try store.validate(importedFile)
    XCTAssertEqual(try Data(contentsOf: storedURL), bytes)

    let storedNames = try FileManager.default.contentsOfDirectory(
      at: store.attachmentsDirectory,
      includingPropertiesForKeys: nil
    ).map(\.lastPathComponent)
    XCTAssertEqual(storedNames, [importedFile.sha256])
  }

  func testAttachmentStoreFailsClosedWhenStoredContentIsTampered() throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let store = try MechanicCaseAttachmentStore(storageRoot: temporary)
    let original = Data("original physical evidence".utf8)
    let attachment = try store.importData(
      original,
      attachmentID: "attachment_00000000000000000000000009",
      displayName: "evidence.txt",
      mediaType: "text/plain"
    )
    let storedURL = store.attachmentsDirectory.appendingPathComponent(attachment.sha256)
    try Data("tampered physical evidence".utf8).write(to: storedURL)

    XCTAssertThrowsError(try store.validate(attachment)) { error in
      guard case MechanicCaseArtifactError.storedAttachmentIntegrityFailure = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertThrowsError(
      try store.importData(
        original,
        attachmentID: "attachment_0000000000000000000000000A",
        displayName: "second-import.txt",
        mediaType: "text/plain"
      )
    ) { error in
      guard case MechanicCaseArtifactError.storedAttachmentIntegrityFailure = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testAttachmentStoreRejectsActualFileLargerThanTwentyFiveMiB() throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }

    let source = temporary.appendingPathComponent("oversize.bin")
    XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
    let handle = try FileHandle(forWritingTo: source)
    try handle.truncate(atOffset: UInt64(MechanicCaseAttachmentStore.maximumByteCount + 1))
    try handle.close()

    let store = try MechanicCaseAttachmentStore(
      storageRoot: temporary.appendingPathComponent("private-store")
    )
    XCTAssertThrowsError(
      try store.importFile(
        at: source,
        attachmentID: "attachment_00000000000000000000000009",
        displayName: "oversize.bin",
        mediaType: "application/octet-stream"
      )
    ) { error in
      guard case MechanicCaseArtifactError.attachmentTooLarge(let actual, let maximum) = error
      else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(actual, MechanicCaseAttachmentStore.maximumByteCount + 1)
      XCTAssertEqual(maximum, MechanicCaseAttachmentStore.maximumByteCount)
    }
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        at: store.attachmentsDirectory,
        includingPropertiesForKeys: nil
      ),
      []
    )
  }

  func testReportDefaultsRedactPrivateFieldsAndManifestMatchesArtifacts() throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let revision = try committedRevision(in: temporary)
    let originalRevisionBytes = try revision.encoded()

    let bundle = try MechanicCaseReportArtifactGenerator().generate(
      committedRevision: revision,
      generatedAt: "2026-09-07T15:00:00Z",
      outputDirectory: temporary.appendingPathComponent("report-a")
    )

    XCTAssertEqual(try revision.encoded(), originalRevisionBytes)
    XCTAssertEqual(bundle.manifest.contract, MechanicReportManifest.currentContract)
    XCTAssertEqual(bundle.manifest.contractVersion, "1.0.0")
    XCTAssertEqual(bundle.manifest.renderer, MechanicReportManifest.currentRenderer)
    XCTAssertEqual(bundle.manifest.rendererVersion, "1.0.0")
    XCTAssertEqual(bundle.manifest.caseID, revision.caseID)
    XCTAssertEqual(bundle.manifest.revisionID, revision.revisionID)
    XCTAssertEqual(bundle.manifest.sourceRevisionSHA256, sha256(originalRevisionBytes))
    XCTAssertEqual(bundle.manifest.authority, .technicianLocalDraft)
    XCTAssertFalse(bundle.manifest.vehicleClaimsAuthorized)
    XCTAssertFalse(bundle.manifest.maintenanceHistoryAuthorized)
    XCTAssertEqual(bundle.manifest.privacy, MechanicReportPrivacySelection())

    let manifestOnDisk = try VHOSJSON.decoder().decode(
      MechanicReportManifest.self,
      from: Data(contentsOf: bundle.manifestURL)
    )
    XCTAssertEqual(manifestOnDisk, bundle.manifest)
    XCTAssertEqual(manifestOnDisk.artifacts.map(\.path), ["report.pdf", "case.json"])
    for artifact in manifestOnDisk.artifacts {
      let url = bundle.directory.appendingPathComponent(artifact.path)
      let data = try Data(contentsOf: url)
      XCTAssertEqual(artifact.byteCount, Int64(data.count))
      XCTAssertEqual(artifact.sha256, sha256(data))
    }
    XCTAssertEqual(manifestOnDisk.artifacts[0].mediaType, "application/pdf")
    XCTAssertEqual(manifestOnDisk.artifacts[1].mediaType, "application/json")

    let pdf = try XCTUnwrap(PDFDocument(url: bundle.pdfURL))
    let pdfText = try XCTUnwrap(pdf.string)
    XCTAssertTrue(pdfText.contains(MechanicCaseReportArtifactGenerator.reportLabel))
    XCTAssertTrue(pdfText.contains("[REDACTED]"))
    assertPrivateValuesAreAbsent(from: pdfText)

    let caseText = try String(contentsOf: bundle.caseJSONURL, encoding: .utf8)
    XCTAssertTrue(caseText.contains("service.diagnostic-case-report-snapshot"))
    XCTAssertTrue(caseText.contains(revision.caseID))
    XCTAssertTrue(caseText.contains(revision.revisionID))
    XCTAssertTrue(caseText.contains("source_revision_sha256"))
    assertPrivateValuesAreAbsent(from: caseText)
  }

  func testReportIsByteDeterministicForFixedRevisionPrivacyAndGeneratedAt() throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let revision = try committedRevision(in: temporary)
    let generator = MechanicCaseReportArtifactGenerator()
    let generatedAt = "2026-09-07T15:00:00.125Z"

    let first = try generator.generate(
      committedRevision: revision,
      generatedAt: generatedAt,
      outputDirectory: temporary.appendingPathComponent("report-a")
    )
    let second = try generator.generate(
      committedRevision: revision,
      generatedAt: generatedAt,
      outputDirectory: temporary.appendingPathComponent("report-b")
    )

    XCTAssertEqual(try Data(contentsOf: first.pdfURL), try Data(contentsOf: second.pdfURL))
    XCTAssertEqual(
      try Data(contentsOf: first.caseJSONURL),
      try Data(contentsOf: second.caseJSONURL)
    )
    XCTAssertEqual(
      try Data(contentsOf: first.manifestURL),
      try Data(contentsOf: second.manifestURL)
    )
  }

  func testReportCanIncludeFieldsOnlyWhenPrivacySelectionExplicitlyAllowsThem() throws {
    let temporary = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let revision = try committedRevision(in: temporary)
    let privacy = MechanicReportPrivacySelection(
      redactCustomerContact: false,
      redactVIN: false,
      redactLicensePlate: false,
      redactPriorWork: false
    )

    let bundle = try MechanicCaseReportArtifactGenerator().generate(
      committedRevision: revision,
      privacy: privacy,
      generatedAt: "2026-09-07T15:00:00Z",
      outputDirectory: temporary.appendingPathComponent("unredacted-report")
    )
    let caseText = try String(contentsOf: bundle.caseJSONURL, encoding: .utf8)
    XCTAssertTrue(caseText.contains("555-0100"))
    XCTAssertTrue(caseText.contains("owner@example.com"))
    XCTAssertTrue(caseText.contains("JTEBU14R750012345"))
    XCTAssertTrue(caseText.contains("PRIVATE7"))
    XCTAssertTrue(caseText.contains("Confidential prior repair"))
    XCTAssertEqual(bundle.manifest.privacy, privacy)
  }

  private func committedRevision(in temporary: URL) throws -> MechanicDiagnosticCaseRevision {
    let revision = try MechanicDiagnosticCaseRevision.create(
      organization: MechanicDiagnosticOrganizationSnapshot(
        organizationID: "org_00000000000000000000000002",
        displayName: "Independent Diagnostic Specialists"
      ),
      customer: MechanicDiagnosticCustomerSnapshot(
        customerID: "customer_00000000000000000000000003",
        displayName: "Vehicle Owner",
        phone: "555-0100",
        email: "owner@example.com"
      ),
      vehicle: MechanicDiagnosticVehicleSnapshot(
        vehicleID: "veh_00000000000000000000000004",
        displayName: "Customer 4Runner",
        vin: "JTEBU14R750012345",
        modelYear: 2005,
        make: "Toyota",
        model: "4Runner",
        trim: "SR5",
        licensePlate: "PRIVATE7",
        odometer: MechanicDiagnosticOdometer(value: 187_500, unit: .miles)
      ),
      actor: MechanicDiagnosticActorSnapshot(
        source: .technician,
        actorID: "actor_00000000000000000000000005",
        displayName: "Assigned Technician"
      ),
      complaint: MechanicDiagnosticComplaint(
        description: "Intermittent no-start after an overnight soak.",
        reportedBy: .customer,
        reportedAt: "2026-09-07T13:00:00Z",
        operatingConditions: "Cold start after sitting overnight",
        priorWork: "Confidential prior repair"
      ),
      createdAt: "2026-09-07T14:00:00Z",
      caseID: "case_00000000000000000000000001",
      revisionID: "caserev_00000000000000000000000001"
    )
    let ledger = try MechanicDiagnosticCaseLedger(
      storageDirectory: temporary.appendingPathComponent("ledger")
    )
    try ledger.append(revision)
    return try XCTUnwrap(ledger.latest(caseID: revision.caseID))
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MechanicCaseArtifactTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func assertPrivateValuesAreAbsent(
    from text: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    for privateValue in [
      "555-0100",
      "owner@example.com",
      "JTEBU14R750012345",
      "PRIVATE7",
      "Confidential prior repair",
    ] {
      XCTAssertFalse(text.contains(privateValue), "Leaked \(privateValue)", file: file, line: line)
    }
  }
}
