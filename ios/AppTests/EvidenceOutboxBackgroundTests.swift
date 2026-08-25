import CryptoKit
import Foundation
import VHOSCore
import XCTest

@testable import Vehicle_Health_OS

final class EvidenceOutboxBackgroundTests: XCTestCase {
  func testLegacyRecordWithoutArtifactIdentityStillDecodes() throws {
    let root = temporaryDirectory("legacy")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EvidenceOutboxStore(fileManager: .default, root: root)

    let (record, inserted) = try store.enqueue(
      payload: Data("legacy evidence".utf8),
      contentType: "application/vnd.vhos.agent-evidence+json")

    XCTAssertTrue(inserted)
    XCTAssertNil(record.artifactIdentity)
    XCTAssertNil(try XCTUnwrap(store.records().first).artifactIdentity)
  }

  func testIdentityIsExactConflictBoundaryAndMissingPayloadIsRegenerated() async throws {
    let root = temporaryDirectory("identity")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EvidenceOutboxStore(fileManager: .default, root: root)
    let payload = Data("immutable artifact".utf8)

    let (first, inserted) = try store.enqueue(
      payload: payload,
      contentType: "application/vnd.vhos.agent-evidence+json",
      artifactIdentity: "generation:000001:abc")
    let (duplicate, duplicateInserted) = try store.enqueue(
      payload: payload,
      contentType: "application/vnd.vhos.agent-evidence+json",
      artifactIdentity: "generation:000001:abc")

    XCTAssertTrue(inserted)
    XCTAssertFalse(duplicateInserted)
    XCTAssertEqual(first.id, duplicate.id)
    XCTAssertThrowsError(
      try store.enqueue(
        payload: Data("different artifact".utf8),
        contentType: "application/vnd.vhos.agent-evidence+json",
        artifactIdentity: "generation:000001:abc")
    ) { error in
      guard
        case EvidenceOutboxStoreError.artifactIdentityConflict("generation:000001:abc") =
          error
      else { return XCTFail("Expected an exact artifact identity conflict, got \(error)") }
    }

    try FileManager.default.removeItem(at: try store.payloadURL(for: first))
    XCTAssertTrue(try store.knownArtifactMetadata().isEmpty)
    XCTAssertTrue(try store.knownArtifactIdentities().isEmpty)

    let source = temporaryDirectory("identity-source")
    defer { try? FileManager.default.removeItem(at: source) }
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let sourceURL = source.appendingPathComponent("artifact.json")
    try payload.write(to: sourceURL, options: .atomic)
    let coordinator = EvidenceOutboxBackgroundCoordinator(root: root)
    let regenerated = try await coordinator.enqueuePage(
      [
        EvidenceOutboxFileArtifact(
          identity: "generation:000001:abc",
          url: sourceURL,
          contentType: "application/vnd.vhos.agent-evidence+json",
          expectedByteCount: payload.count,
          expectedSHA256: sha256(payload))
      ],
      mode: .automatic)
    XCTAssertEqual(regenerated.insertedPackages, 1)
    XCTAssertEqual(try store.records().count, 1)
    XCTAssertEqual(try store.knownArtifactIdentities(), Set(["generation:000001:abc"]))
  }

  func testMissingAndMalformedMetadataAreQuarantinedAndSourceCanRegenerate() throws {
    for corruption in ["missing", "malformed"] {
      let root = temporaryDirectory("metadata-\(corruption)")
      defer { try? FileManager.default.removeItem(at: root) }
      let payload = Data("immutable-\(corruption)".utf8)
      let identity = "metadata:\(corruption)"
      let store = EvidenceOutboxStore(root: root)
      let (record, inserted) = try store.enqueue(
        payload: payload,
        contentType: "application/vnd.vhos.agent-evidence+json",
        artifactIdentity: identity)
      XCTAssertTrue(inserted)
      let metadata = root.appendingPathComponent(
        record.id.uuidString.lowercased(), isDirectory: true
      ).appendingPathComponent("record.json")
      if corruption == "missing" {
        try FileManager.default.removeItem(at: metadata)
      } else {
        try Data("{not-json".utf8).write(to: metadata, options: .atomic)
      }

      XCTAssertTrue(try store.knownArtifactIdentities().isEmpty)
      let (_, regenerated) = try store.enqueue(
        payload: payload,
        contentType: "application/vnd.vhos.agent-evidence+json",
        artifactIdentity: identity)
      XCTAssertTrue(regenerated)
      XCTAssertEqual(try store.records().count, 1)
    }
  }

  func testContentTypesUseFixedSafePayloadFilenames() throws {
    let root = temporaryDirectory("filenames")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EvidenceOutboxStore(fileManager: .default, root: root)
    let cases = [
      ("application/vnd.vhos.evidence-sync+zip", "evidence.vhossync"),
      ("application/vnd.vhos.agent-evidence+json", "agent-evidence.json"),
      (
        "application/vnd.vhos.discovery-draft-evidence+json",
        "discovery-draft-evidence.json"
      ),
      (
        "application/vnd.vhos.import-provenance-receipt+json",
        "import-provenance-receipt.json"
      ),
    ]

    for (index, item) in cases.enumerated() {
      let (record, inserted) = try store.enqueue(
        payload: Data("payload-\(index)".utf8),
        contentType: item.0,
        artifactIdentity: "filename-test:\(index)")
      XCTAssertTrue(inserted)
      XCTAssertEqual(record.payloadFilename, item.1)
      XCTAssertEqual(try store.payloadURL(for: record).lastPathComponent, item.1)
    }
  }

  func testAutomaticCoordinatorPagesTwoThenAdvancesPastKnownArtifacts() async throws {
    let root = temporaryDirectory("automatic")
    let sources = temporaryDirectory("automatic-sources")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: sources)
    }
    let artifacts = try (0..<3).map { index in
      try makeArtifact(index: index, directory: sources)
    }
    let coordinator = EvidenceOutboxBackgroundCoordinator(root: root)

    let first = try await coordinator.enqueuePage(artifacts, mode: .automatic)
    XCTAssertEqual(first.insertedPackages, 2)
    XCTAssertEqual(first.packageIDs.count, 2)
    let identitiesAfterFirstPage = try await coordinator.knownArtifactIdentities()
    XCTAssertEqual(identitiesAfterFirstPage.count, 2)

    let second = try await coordinator.enqueuePage(artifacts, mode: .automatic)
    XCTAssertEqual(second.insertedPackages, 1)
    XCTAssertEqual(second.skippedKnownArtifacts, 2)
    let identitiesAfterSecondPage = try await coordinator.knownArtifactIdentities()
    XCTAssertEqual(identitiesAfterSecondPage.count, 3)
  }

  func testManualCoordinatorRejectsPagesAboveEightBeforeReading() async throws {
    let root = temporaryDirectory("manual-limit")
    let sources = temporaryDirectory("manual-limit-sources")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: sources)
    }
    let artifact = try makeArtifact(index: 1, directory: sources)
    let coordinator = EvidenceOutboxBackgroundCoordinator(root: root)

    do {
      _ = try await coordinator.enqueuePage(
        [artifact], mode: .manual(maximumArtifacts: 9))
      XCTFail("Expected the manual page limit to fail closed")
    } catch EvidenceOutboxStoreError.invalidPageSize {
      // Expected.
    }
    XCTAssertEqual(try EvidenceOutboxStore(root: root).records().count, 0)
  }

  func testOversizeArtifactAndCancellationPublishNoPartialPackage() async throws {
    let root = temporaryDirectory("bounded")
    let sources = temporaryDirectory("bounded-sources")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: sources)
    }
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    let oversizedURL = sources.appendingPathComponent("oversized-receipt.json")
    XCTAssertTrue(FileManager.default.createFile(atPath: oversizedURL.path, contents: Data([0x7b])))
    let handle = try FileHandle(forWritingTo: oversizedURL)
    try handle.truncate(
      atOffset: UInt64(PortableFrameStore.productionImportReceiptByteLimit + 1))
    try handle.close()
    let oversized = EvidenceOutboxFileArtifact(
      identity: "receipt:oversized",
      url: oversizedURL,
      contentType: "application/vnd.vhos.import-provenance-receipt+json")
    let coordinator = EvidenceOutboxBackgroundCoordinator(root: root)

    do {
      _ = try await coordinator.enqueuePage([oversized], mode: .manual(maximumArtifacts: 1))
      XCTFail("Expected the bounded reader to reject an oversized receipt")
    } catch EvidenceOutboxStoreError.artifactTooLarge {
      // Expected.
    }
    XCTAssertEqual(try EvidenceOutboxStore(root: root).records().count, 0)
    XCTAssertFalse(
      try visiblePackageDirectories(at: root).contains { $0.pathExtension == "staging" })

    let valid = try makeArtifact(index: 7, directory: sources)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await coordinator.enqueuePage([valid], mode: .manual(maximumArtifacts: 1))
    }
    do {
      _ = try await task.value
      XCTFail("Expected cancellation before publication")
    } catch is CancellationError {
      // Expected.
    }
    XCTAssertEqual(try EvidenceOutboxStore(root: root).records().count, 0)
  }

  func testMaximumRecordImportReceiptAndArchiveBothQueueAndValidate() async throws {
    let root = temporaryDirectory("maximum-import-lineage")
    let sources = temporaryDirectory("maximum-import-lineage-sources")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: sources)
    }
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)

    let archive = Data("bounded verified sync archive".utf8)
    let archiveURL = sources.appendingPathComponent("original.vhossync")
    try archive.write(to: archiveURL, options: .atomic)

    let receiptURL = sources.appendingPathComponent("import-receipt.json")
    var receipt = Data(
      """
      {"archive_sha256":"\(sha256(archive))","bundle_id":"00000000-0000-4000-8000-000000000001","contract":"vhos.portable-evidence-import-receipt","contract_version":"2.0.0","creator":{"application_id":"com.isaiahdupree.VehicleHealthOS","application_version":"1.0.0","device_model":"iPhone","platform":"IOS"},"manifest_sha256":"\(String(repeating: "a", count: 64))","record_count":20000,"record_link_chain_sha256":"\(String(repeating: "b", count: 64))","record_links":[
      """.utf8)
    for index in 0..<20_000 {
      if index > 0 { receipt.append(0x2c) }
      let recordID =
        String(format: "%020d", index)
        + ":" + String(repeating: "r", count: 425)
      receipt.append(
        Data(
          "{\"record_id\":\"\(recordID)\",\"record_sha256\":\"\(String(repeating: "c", count: 64))\"}"
            .utf8))
    }
    receipt.append(Data("]}".utf8))
    XCTAssertGreaterThan(receipt.count, 1 * 1_024 * 1_024)
    XCTAssertLessThanOrEqual(
      receipt.count, PortableFrameStore.productionImportReceiptByteLimit)
    try receipt.write(to: receiptURL, options: .atomic)

    let artifacts = [
      EvidenceOutboxFileArtifact(
        identity: "imported-bundle:maximum:\(sha256(archive))",
        url: archiveURL,
        contentType: "application/vnd.vhos.evidence-sync+zip",
        expectedByteCount: archive.count,
        expectedSHA256: sha256(archive)),
      EvidenceOutboxFileArtifact(
        identity: "import-receipt:maximum:\(sha256(receipt))",
        url: receiptURL,
        contentType: "application/vnd.vhos.import-provenance-receipt+json",
        expectedByteCount: receipt.count,
        expectedSHA256: sha256(receipt)),
    ]
    let coordinator = EvidenceOutboxBackgroundCoordinator(root: root)
    let result = try await coordinator.enqueuePage(artifacts, mode: .automatic)
    XCTAssertEqual(result.insertedPackages, 2)

    let store = EvidenceOutboxStore(root: root)
    let records = try store.records()
    XCTAssertEqual(records.count, 2)
    for record in records {
      let validation = try await EvidenceOutboxPayloadFileValidator.validate(
        record: record,
        url: try store.payloadURL(for: record))
      XCTAssertEqual(validation.byteCount, record.envelope.byteCount)
      XCTAssertEqual(validation.sha256, record.envelope.sha256)
    }
  }

  func testUploadValidatorHashesExactFileOffMainAndRejectsMutation() async throws {
    let root = temporaryDirectory("upload-validation")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EvidenceOutboxStore(root: root)
    let payload = Data(repeating: 0x5a, count: 2 * 1024 * 1024)
    let (record, inserted) = try store.enqueue(
      payload: payload,
      contentType: "application/vnd.vhos.agent-evidence+json",
      artifactIdentity: "upload-validation:\(sha256(payload))")
    XCTAssertTrue(inserted)
    let payloadURL = try store.payloadURL(for: record)

    let validation = try await EvidenceOutboxPayloadFileValidator.validate(
      record: record, url: payloadURL)
    XCTAssertEqual(validation.byteCount, payload.count)
    XCTAssertEqual(validation.sha256, record.envelope.sha256)
    XCTAssertFalse(validation.validatorThreadWasMain)

    let handle = try FileHandle(forWritingTo: payloadURL)
    try handle.seek(toOffset: UInt64(payload.count / 2))
    try handle.write(contentsOf: Data([0x00]))
    try handle.close()
    do {
      _ = try await EvidenceOutboxPayloadFileValidator.validate(record: record, url: payloadURL)
      XCTFail("Expected exact streaming SHA validation to reject same-size mutation")
    } catch EvidenceOutboxError.invalidEnvelope {
      // Expected.
    }
  }

  func testUploadedAcknowledgementsPrunePayloadsAndSurviveMoreThanLifetimeCapacity() throws {
    let root = temporaryDirectory("acknowledgement-capacity")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EvidenceOutboxStore(root: root)

    for index in 0..<520 {
      let identity = "generation:\(String(format: "%06d", index + 1))"
      let payload = Data("artifact-\(index)".utf8)
      let (record, inserted) = try store.enqueue(
        payload: payload,
        contentType: "application/vnd.vhos.agent-evidence+json",
        artifactIdentity: identity)
      XCTAssertTrue(inserted)
      try store.markUploaded(record)
    }

    XCTAssertTrue(try store.records().isEmpty)
    XCTAssertEqual(try store.knownArtifactIdentities().count, 520)
    let reloaded = EvidenceOutboxStore(root: root)
    XCTAssertEqual(try reloaded.knownArtifactIdentities().count, 520)

    let duplicatePayload = Data("artifact-519".utf8)
    let (_, duplicateInserted) = try reloaded.enqueue(
      payload: duplicatePayload,
      contentType: "application/vnd.vhos.agent-evidence+json",
      artifactIdentity: "generation:000520")
    XCTAssertFalse(duplicateInserted)
    XCTAssertTrue(try reloaded.records().isEmpty)

    let staging = root.appendingPathComponent(".interrupted.staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try Data(repeating: 0xa5, count: 1_024).write(
      to: staging.appendingPathComponent("partial"))
    _ = EvidenceOutboxStore(root: root)
    XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
  }

  func testCorruptAcknowledgementCatalogFailsClosedInsteadOfRequeueingEvidence() throws {
    let root = temporaryDirectory("acknowledgement-corrupt")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EvidenceOutboxStore(root: root)
    let payload = Data("private-immutable-evidence".utf8)
    let (record, inserted) = try store.enqueue(
      payload: payload,
      contentType: "application/vnd.vhos.agent-evidence+json",
      artifactIdentity: "generation:000001:private")
    XCTAssertTrue(inserted)
    try store.markUploaded(record)
    XCTAssertTrue(try store.records().isEmpty)

    let catalog = root.appendingPathComponent("upload-acknowledgements.sqlite3")
    var corruptBytes = try Data(contentsOf: catalog)
    XCTAssertGreaterThan(corruptBytes.count, 100)
    corruptBytes.replaceSubrange(0..<100, with: Data(repeating: 0, count: 100))
    try corruptBytes.write(to: catalog, options: .atomic)

    let restarted = EvidenceOutboxStore(root: root)
    XCTAssertThrowsError(try restarted.knownArtifactMetadata()) { error in
      guard case EvidenceOutboxStoreError.invalidAcknowledgementCatalog = error else {
        return XCTFail("Expected fail-closed catalogue integrity error, got \(error)")
      }
    }
    XCTAssertThrowsError(
      try restarted.enqueue(
        payload: Data("new-evidence".utf8),
        contentType: "application/vnd.vhos.agent-evidence+json",
        artifactIdentity: "generation:000002:new"
      )
    ) { error in
      guard case EvidenceOutboxStoreError.invalidAcknowledgementCatalog = error else {
        return XCTFail("Expected corrupted dedupe catalogue to block enqueue, got \(error)")
      }
    }
    XCTAssertTrue(try restarted.records().isEmpty)
  }

  func testUploadCrashWindowsRetryLegacyMetadataAndPruneAcknowledgedLivePackage() async throws {
    let root = temporaryDirectory("upload-crash-windows")
    defer { try? FileManager.default.removeItem(at: root) }
    let payload = Data("crash-safe-upload".utf8)
    let store = EvidenceOutboxStore(root: root)
    let (legacy, inserted) = try store.enqueue(
      payload: payload,
      contentType: "application/vnd.vhos.agent-evidence+json",
      artifactIdentity: "upload-crash:legacy")
    XCTAssertTrue(inserted)
    let legacyDirectory = root.appendingPathComponent(
      legacy.id.uuidString.lowercased(), isDirectory: true)
    let metadataURL = legacyDirectory.appendingPathComponent("record.json")
    var metadata = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
    metadata["uploaded_at"] = "2026-08-22T12:00:00Z"
    try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(
      to: metadataURL, options: .atomic)

    let legacyCoordinator = EvidenceOutboxBackgroundCoordinator(root: root)
    let legacyPending = try await legacyCoordinator.pendingRecords(maximumCount: 8)
    XCTAssertEqual(legacyPending.count, 1)

    let liveCopy = temporaryDirectory("ack-live-copy")
    defer { try? FileManager.default.removeItem(at: liveCopy) }
    try FileManager.default.copyItem(at: legacyDirectory, to: liveCopy)
    try store.markUploaded(try XCTUnwrap(store.records().first))
    try FileManager.default.copyItem(at: liveCopy, to: legacyDirectory)

    let restarted = EvidenceOutboxStore(root: root)
    XCTAssertTrue(try restarted.records().isEmpty)
    XCTAssertEqual(try restarted.acknowledgedUploadCount(), 1)
  }

  private func makeArtifact(index: Int, directory: URL) throws -> EvidenceOutboxFileArtifact {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let payload = Data("artifact-\(index)".utf8)
    let url = directory.appendingPathComponent("artifact-\(index).json")
    try payload.write(to: url, options: .atomic)
    return EvidenceOutboxFileArtifact(
      identity: "artifact:\(index):\(sha256(payload))",
      url: url,
      contentType: "application/vnd.vhos.agent-evidence+json",
      expectedByteCount: payload.count,
      expectedSHA256: sha256(payload))
  }

  private func temporaryDirectory(_ suffix: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "VHOSEvidenceOutboxBackgroundTests-\(suffix)-\(UUID().uuidString)", isDirectory: true)
  }

  private func visiblePackageDirectories(at root: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
