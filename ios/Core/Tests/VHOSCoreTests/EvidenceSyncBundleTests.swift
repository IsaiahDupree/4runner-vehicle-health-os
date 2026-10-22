import CryptoKit
import Foundation
import Testing

@testable import VHOSCore

@Test func evidenceSyncBundleRoundTripsChecksummedLogicalFrames() throws {
  let frame = GatewayFrame(
    messageType: .gatewayHealth,
    sequence: 42,
    monotonicMicroseconds: 9_001,
    payload: Data("{\"contract\":\"gateway.health\"}".utf8)
  )
  let record = PortableLogicalFrame(
    frame: frame,
    sourceRole: .obdCAN,
    sourceID: "esp32-test",
    ingestedAt: "2026-08-17T12:00:00Z"
  )
  let archive = try EvidenceSyncBundle.encode(
    records: [record],
    creator: EvidenceBundleCreator(
      platform: "IOS",
      applicationID: "com.isaiahdupree.VehicleHealthOS",
      applicationVersion: "0.3.1",
      deviceModel: "iPhone"
    ),
    bundleID: UUID(uuidString: "7EFEC738-4535-4C66-9EC5-64BDA8ED57FB")!,
    createdAt: "2026-08-17T12:00:00Z"
  )
  let imported = try EvidenceSyncBundle.decode(archive)

  #expect(imported.manifest.bundleID.uuidString == "7EFEC738-4535-4C66-9EC5-64BDA8ED57FB")
  #expect(imported.manifest.contractVersion == "1.0.0")
  #expect(imported.manifest.recovery == nil)
  #expect(imported.authorizesLiveVehicleClaims == false)
  #expect(imported.records == [record])
  #expect(try imported.records[0].validatedFrame() == frame)
}

@Test func recoveryBundleV2BindsCompleteLedgerAndDeniesVehicleAuthority() throws {
  let frame = GatewayFrame(
    messageType: .gatewayHealth,
    sequence: 43,
    monotonicMicroseconds: 9_002,
    payload: Data("{\"contract\":\"gateway.health\"}".utf8)
  )
  let record = PortableLogicalFrame(
    frame: frame,
    sourceRole: .obdCAN,
    sourceID: "esp32-recovery",
    ingestedAt: "2026-08-22T12:00:00Z"
  )
  var ledger = try VHOSJSON.encoder().encode(record)
  ledger.append(0x0A)
  let ledgerSHA256 = SHA256.hash(data: ledger).map { String(format: "%02x", $0) }.joined()
  let archive = try EvidenceSyncBundle.encode(
    records: [record],
    creator: EvidenceBundleCreator(
      platform: "IOS",
      applicationID: "com.isaiahdupree.VehicleHealthOS",
      applicationVersion: "0.3.23",
      deviceModel: "iPhone"
    ),
    recovery: EvidenceRecoveryMetadata(sourceLedgerSHA256: ledgerSHA256),
    bundleID: UUID(uuidString: "85B3FC4A-7359-44E9-8B2C-06BA61F3C39E")!,
    createdAt: "2026-08-22T12:00:00Z"
  )

  let imported = try EvidenceSyncBundle.decode(archive)
  #expect(imported.manifest.contractVersion == "2.0.0")
  #expect(imported.manifest.recovery?.classification == "RECOVERED_PORTABLE_EVIDENCE")
  #expect(imported.manifest.recovery?.vehicleClaimsAuthorized == false)
  #expect(imported.manifest.recovery?.sourceLedgerSHA256 == ledgerSHA256)
  #expect(imported.manifest.segments.first?.sha256 == ledgerSHA256)
  #expect(imported.authorizesLiveVehicleClaims == false)
  #expect(imported.records == [record])
}

@Test func recoveryBundleV2RejectsLedgerDigestThatDoesNotMatchSegment() throws {
  let frame = GatewayFrame(
    messageType: .gatewayHealth, sequence: 1, monotonicMicroseconds: 2,
    payload: Data([1, 2, 3]))
  let record = PortableLogicalFrame(
    frame: frame, sourceRole: .obdCAN, sourceID: "esp32-test",
    ingestedAt: "2026-08-22T12:00:00Z")

  #expect(throws: EvidenceSyncError.invalidManifest) {
    try EvidenceSyncBundle.encode(
      records: [record],
      creator: EvidenceBundleCreator(
        platform: "IOS", applicationID: "test", applicationVersion: "1", deviceModel: "test"),
      recovery: EvidenceRecoveryMetadata(sourceLedgerSHA256: String(repeating: "0", count: 64))
    )
  }
}

@Test func recoveryBundleV2RejectsUndeclaredManifestAndRecoveryFields() throws {
  let base: [String: Any] = [
    "contract": "vhos.evidence-sync-bundle",
    "contract_version": "2.0.0",
    "bundle_id": "85B3FC4A-7359-44E9-8B2C-06BA61F3C39E",
    "created_at": "2026-08-22T12:00:00Z",
    "creator": [
      "platform": "IOS", "application_id": "test", "application_version": "1",
      "device_model": "iPhone",
    ],
    "segments": [
      [
        "path": "segments/logical-frames.ndjson", "media_type": "application/x-ndjson",
        "sha256": String(repeating: "a", count: 64), "byte_count": 1, "record_count": 1,
      ]
    ],
    "recovery": [
      "classification": "RECOVERED_PORTABLE_EVIDENCE", "vehicle_claims_authorized": false,
      "source_ledger_sha256": String(repeating: "a", count: 64),
      "alternate_authority": "LIVE",
    ],
  ]
  let bytes = try JSONSerialization.data(withJSONObject: base, options: [.sortedKeys])

  #expect(throws: EvidenceSyncError.invalidManifest) {
    try EvidenceSyncBundle.validateManifestJSONShape(bytes)
  }
}

@Test func evidenceSyncManifestRejectsDuplicateJSONKeysBeforeCodable() throws {
  let manifest = EvidenceBundleManifest(
    bundleID: UUID(uuidString: "85B3FC4A-7359-44E9-8B2C-06BA61F3C39E")!,
    createdAt: "2026-08-22T12:00:00Z",
    creator: EvidenceBundleCreator(
      platform: "IOS", applicationID: "test", applicationVersion: "1",
      deviceModel: "iPhone"),
    segments: [
      EvidenceBundleSegment(
        path: "segments/logical-frames.ndjson", mediaType: "application/x-ndjson",
        sha256: String(repeating: "a", count: 64), byteCount: 1, recordCount: 1)
    ]
  )
  let encoded = try VHOSJSON.encoder().encode(manifest)
  var duplicate = try #require(String(data: encoded, encoding: .utf8))
  duplicate.removeLast()
  duplicate += ",\"contr\\u0061ct\":\"vhos.evidence-sync-bundle\"}"

  #expect(throws: EvidenceSyncError.invalidManifest) {
    try EvidenceSyncBundle.validateManifestJSONShape(Data(duplicate.utf8))
  }
}

@Test func evidenceSyncPortableRecordRejectsUnknownAndDuplicateJSONKeys() throws {
  let frame = GatewayFrame(
    messageType: .gatewayHealth, sequence: 1, monotonicMicroseconds: 2,
    payload: Data([1, 2, 3]))
  let record = PortableLogicalFrame(
    frame: frame, sourceRole: .obdCAN, sourceID: "esp32-test",
    ingestedAt: "2026-08-22T12:00:00Z")
  let encoded = try VHOSJSON.encoder().encode(record)
  let object = try #require(
    JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  var withUnknown = object
  withUnknown["vehicle_claims_authorized"] = true

  #expect(throws: EvidenceSyncError.invalidRecord) {
    try EvidenceSyncBundle.validateRecordJSONShape(
      JSONSerialization.data(withJSONObject: withUnknown, options: [.sortedKeys]))
  }

  var duplicate = try #require(String(data: encoded, encoding: .utf8))
  duplicate.removeLast()
  duplicate += ",\"contr\\u0061ct\":\"vhos.portable-logical-frame\"}"
  #expect(throws: EvidenceSyncError.invalidRecord) {
    try EvidenceSyncBundle.validateRecordJSONShape(Data(duplicate.utf8))
  }
}

@Test func portableRecordScalarValidationExactlyEnforcesPublishedSchemaBounds() throws {
  let frame = GatewayFrame(
    messageType: .gatewayHealth, sequence: 1, monotonicMicroseconds: 2,
    payload: Data([1, 2, 3]))
  let record = PortableLogicalFrame(
    frame: frame, sourceRole: .obdCAN, sourceID: "esp32-test",
    ingestedAt: "2026-08-22T12:00:00Z")
  let encoded = try VHOSJSON.encoder().encode(record)

  let invalidScalars: [(String, Any)] = [
    ("source_id", ""),
    ("source_id", String(repeating: "s", count: 161)),
    ("source_sequence", "01"),
    ("source_sequence", "+1"),
    ("source_sequence", String(repeating: "9", count: 21)),
    ("source_monotonic_microseconds", "00"),
    ("message_type", 0),
    ("ingested_at", "2026-02-30T12:00:00Z"),
    ("ingested_at", "2026-08-22 12:00:00Z"),
    ("envelope_sha256", record.envelopeSHA256.uppercased()),
    ("envelope_base64", String(repeating: "A", count: 2_097_153)),
  ]
  for (key, value) in invalidScalars {
    let mutated = try mutateJSON(encoded, key: key, value: value)
    #expect(throws: EvidenceSyncError.invalidRecord, "Expected \(key) to fail") {
      try EvidenceSyncBundle.decodeRecord(mutated)
    }
  }
}

@Test func portableRecordAcceptsCanonicalDecimalBoundsAndRFC3339WallTime() throws {
  let frame = GatewayFrame(
    messageType: .gatewayHealth,
    sequence: UInt64.max,
    monotonicMicroseconds: UInt64.max,
    payload: Data([1, 2, 3]))
  let record = PortableLogicalFrame(
    frame: frame,
    sourceRole: .obdCAN,
    sourceID: String(repeating: "s", count: 160),
    ingestedAt: "2026-08-22t12:00:00.123456789123-04:00")

  let decoded = try EvidenceSyncBundle.decodeRecord(VHOSJSON.encoder().encode(record))

  #expect(decoded.sourceSequence == "18446744073709551615")
  #expect(decoded.sourceMonotonicMicroseconds == "18446744073709551615")
  #expect(decoded.ingestedAt == "2026-08-22t12:00:00.123456789123-04:00")
}

@Test func evidenceContractsRejectLeapSecondWallTimesConsistently() throws {
  let frame = GatewayFrame(
    messageType: .gatewayHealth, sequence: 1, monotonicMicroseconds: 2,
    payload: Data([1, 2, 3]))
  let record = PortableLogicalFrame(
    frame: frame, sourceRole: .obdCAN, sourceID: "esp32-test",
    ingestedAt: "2026-08-22T12:34:59Z")
  let recordBytes = try VHOSJSON.encoder().encode(record)

  #expect(throws: EvidenceSyncError.invalidRecord) {
    try EvidenceSyncBundle.decodeRecord(
      mutateJSON(recordBytes, key: "ingested_at", value: "2026-08-22T12:34:60Z"))
  }

  let manifest = EvidenceBundleManifest(
    bundleID: UUID(uuidString: "85B3FC4A-7359-44E9-8B2C-06BA61F3C39E")!,
    createdAt: "2026-08-22T12:34:60Z",
    creator: EvidenceBundleCreator(
      platform: "IOS", applicationID: "test", applicationVersion: "1",
      deviceModel: "iPhone"),
    segments: [
      EvidenceBundleSegment(
        path: "segments/logical-frames.ndjson", mediaType: "application/x-ndjson",
        sha256: String(repeating: "a", count: 64), byteCount: 1, recordCount: 1)
    ])
  #expect(throws: EvidenceSyncError.invalidManifest) {
    try EvidenceSyncBundle.validateManifest(manifest)
  }
}

@Test func evidenceManifestCreatorAndDigestValidationMatchesPublishedSchema() throws {
  func manifest(
    applicationID: String = "app",
    applicationVersion: String = "1",
    deviceModel: String = "iPhone",
    createdAt: String = "2026-08-22T12:00:00Z",
    sha256: String = String(repeating: "a", count: 64)
  ) -> EvidenceBundleManifest {
    EvidenceBundleManifest(
      bundleID: UUID(uuidString: "85B3FC4A-7359-44E9-8B2C-06BA61F3C39E")!,
      createdAt: createdAt,
      creator: EvidenceBundleCreator(
        platform: "IOS",
        applicationID: applicationID,
        applicationVersion: applicationVersion,
        deviceModel: deviceModel),
      segments: [
        EvidenceBundleSegment(
          path: "segments/logical-frames.ndjson",
          mediaType: "application/x-ndjson",
          sha256: sha256,
          byteCount: 1,
          recordCount: 1)
      ])
  }

  try EvidenceSyncBundle.validateManifest(
    manifest(
      applicationID: String(repeating: "a", count: 160),
      applicationVersion: String(repeating: "v", count: 80),
      deviceModel: String(repeating: "d", count: 160),
      createdAt: "2026-08-22t12:00:00.123+05:30"))

  let invalidManifests = [
    manifest(applicationID: ""),
    manifest(applicationID: String(repeating: "a", count: 161)),
    manifest(applicationVersion: String(repeating: "v", count: 81)),
    manifest(deviceModel: String(repeating: "d", count: 161)),
    manifest(createdAt: "2026-02-30T12:00:00Z"),
    manifest(sha256: String(repeating: "A", count: 64)),
  ]
  for invalid in invalidManifests {
    #expect(throws: EvidenceSyncError.invalidManifest) {
      try EvidenceSyncBundle.validateManifest(invalid)
    }
  }
}

@Test func evidenceSyncResourceLimitsBoundArchiveEntriesBytesAndDeclaredSegments() throws {
  #expect(throws: EvidenceSyncError.archiveTooLarge) {
    try EvidenceSyncBundle.validateArchiveByteCount(18 * 1_024 * 1_024 + 1)
  }

  let boundaryManifest = EvidenceBundleManifest(
    bundleID: UUID(uuidString: "85B3FC4A-7359-44E9-8B2C-06BA61F3C39E")!,
    createdAt: "2026-08-22T12:00:00Z",
    creator: EvidenceBundleCreator(
      platform: "IOS", applicationID: "test", applicationVersion: "1",
      deviceModel: "iPhone"),
    segments: [
      EvidenceBundleSegment(
        path: "segments/logical-frames.ndjson", mediaType: "application/x-ndjson",
        sha256: String(repeating: "a", count: 64),
        byteCount: 16 * 1_024 * 1_024, recordCount: 20_000)
    ])
  try EvidenceSyncBundle.validateManifest(boundaryManifest)

  let oversizedManifest = EvidenceBundleManifest(
    bundleID: UUID(uuidString: "85B3FC4A-7359-44E9-8B2C-06BA61F3C39E")!,
    createdAt: "2026-08-22T12:00:00Z",
    creator: EvidenceBundleCreator(
      platform: "IOS", applicationID: "test", applicationVersion: "1",
      deviceModel: "iPhone"),
    segments: [
      EvidenceBundleSegment(
        path: "segments/a.ndjson", mediaType: "application/x-ndjson",
        sha256: String(repeating: "a", count: 64),
        byteCount: 16 * 1_024 * 1_024 + 1, recordCount: 20_000)
    ]
  )
  #expect(throws: EvidenceSyncError.invalidManifest) {
    try EvidenceSyncBundle.validateManifest(oversizedManifest)
  }

  let frame = GatewayFrame(
    messageType: .gatewayHealth, sequence: 1, monotonicMicroseconds: 2,
    payload: Data([1, 2, 3]))
  let archive = try EvidenceSyncBundle.encode(
    records: [
      PortableLogicalFrame(
        frame: frame, sourceRole: .obdCAN, sourceID: "esp32-test",
        ingestedAt: "2026-08-22T12:00:00Z")
    ],
    creator: EvidenceBundleCreator(
      platform: "IOS", applicationID: "test", applicationVersion: "1",
      deviceModel: "iPhone")
  )
  var tooManyEntries = archive
  let endOffset = tooManyEntries.count - 22
  replaceLittleEndianUInt16(34, in: &tooManyEntries, at: endOffset + 8)
  replaceLittleEndianUInt16(34, in: &tooManyEntries, at: endOffset + 10)
  #expect(throws: EvidenceSyncError.tooManyArchiveEntries) {
    try EvidenceSyncBundle.decode(tooManyEntries)
  }

  var oversizedCentralEntry = archive
  let oversizedEndOffset = oversizedCentralEntry.count - 22
  let centralOffset = littleEndianUInt32(in: oversizedCentralEntry, at: oversizedEndOffset + 16)
  replaceLittleEndianUInt32(
    UInt32(16 * 1_024 * 1_024 + 1), in: &oversizedCentralEntry,
    at: Int(centralOffset) + 20)
  replaceLittleEndianUInt32(
    UInt32(16 * 1_024 * 1_024 + 1), in: &oversizedCentralEntry,
    at: Int(centralOffset) + 24)
  #expect(throws: EvidenceSyncError.entryTooLarge) {
    try EvidenceSyncBundle.decode(oversizedCentralEntry)
  }
}

@Test func evidenceSyncBundleRejectsTampering() throws {
  let frame = GatewayFrame(
    messageType: .gatewayHealth, sequence: 1, monotonicMicroseconds: 2,
    payload: Data([1, 2, 3]))
  let record = PortableLogicalFrame(
    frame: frame, sourceRole: .obdCAN, sourceID: "esp32-test",
    ingestedAt: "2026-08-17T12:00:00Z")
  var archive = try EvidenceSyncBundle.encode(
    records: [record],
    creator: EvidenceBundleCreator(
      platform: "IOS", applicationID: "test", applicationVersion: "1", deviceModel: "test"))
  archive[80] ^= 0x01

  #expect(throws: EvidenceSyncError.self) { try EvidenceSyncBundle.decode(archive) }
}

@Test func evidenceSyncBundleImportsAndroidGoldenArchive() throws {
  let base64 =
    "UEsDBAoAAAgAAAAAIQB6RuMh4gEAAOIBAAANAAkAbWFuaWZlc3QuanNvblVUBQABAAAAAHsiY29udHJhY3QiOiJ2aG9zLmV2aWRlbmNlLXN5bmMtYnVuZGxlIiwiY29udHJhY3RfdmVyc2lvbiI6IjEuMC4wIiwiYnVuZGxlX2lkIjoiN2VmZWM3MzgtNDUzNS00YzY2LTllYzUtNjRiZGE4ZWQ1N2ZiIiwiY3JlYXRlZF9hdCI6IjIwMjYtMDgtMTdUMTI6MDA6MDBaIiwiY3JlYXRvciI6eyJwbGF0Zm9ybSI6IkFORFJPSUQiLCJhcHBsaWNhdGlvbl9pZCI6ImRldi52aG9zLmhlYWR1bml0IiwiYXBwbGljYXRpb25fdmVyc2lvbiI6IjAuMS4wIiwiZGV2aWNlX21vZGVsIjoiaGVhZC11bml0In0sInNlZ21lbnRzIjpbeyJwYXRoIjoic2VnbWVudHMvbG9naWNhbC1mcmFtZXMubmRqc29uIiwibWVkaWFfdHlwZSI6ImFwcGxpY2F0aW9uL3gtbmRqc29uIiwic2hhMjU2IjoiYzFlMDFkNGMyYzJiNzdhYmI2NTU0MzI2MzcxMmY2YjI1ZTgzNzM3ZGRjMWMxNmY2NWM4MGU0MTY3ZTlkZmVmMiIsImJ5dGVfY291bnQiOjQ3NywicmVjb3JkX2NvdW50IjoxfV19UEsDBAoAAAgAAAAAIQBnS0qx3QEAAN0BAAAeAAkAc2VnbWVudHMvbG9naWNhbC1mcmFtZXMubmRqc29uVVQFAAEAAAAAeyJjb250cmFjdCI6InZob3MucG9ydGFibGUtbG9naWNhbC1mcmFtZSIsImNvbnRyYWN0X3ZlcnNpb24iOiIxLjAuMCIsInNvdXJjZV9yb2xlIjoiT0JEX0NBTiIsInNvdXJjZV9pZCI6ImVzcDMyLXRlc3QiLCJzb3VyY2Vfc2VxdWVuY2UiOiI0MiIsInNvdXJjZV9tb25vdG9uaWNfbWljcm9zZWNvbmRzIjoiOTAwMSIsInByb3RvY29sX21ham9yIjoxLCJwcm90b2NvbF9taW5vciI6MCwibWVzc2FnZV90eXBlIjo0LCJmbGFncyI6MCwiaW5nZXN0ZWRfYXQiOiIyMDI2LTA4LTE3VDEyOjAwOjAwWiIsImVudmVsb3BlX3NoYTI1NiI6ImFmOGEyMWIwYTgwOTFiNjM3YTU2YjZlYmUxMGYwNGFlZmFkMWZmN2E0NDRlNzEyZjc5ZmI0ZjlhZThkMzQ4ZTIiLCJlbnZlbG9wZV9iYXNlNjQiOiJWa2hQVXdFQUJBQWRBQUFBS2dBQUFBQUFBQUFwSXdBQUFBQUFBQlo4WXdmVWJ4SGZleUpqYjI1MGNtRmpkQ0k2SW1kaGRHVjNZWGt1YUdWaGJIUm9JbjA9In0KUEsBAgoACgAACAAAAAAhAHpG4yHiAQAA4gEAAA0ACQAAAAAAAAAAAAAAAAAAAG1hbmlmZXN0Lmpzb25VVAUAAQAAAABQSwECCgAKAAAIAAAAACEAZ0tKsd0BAADdAQAAHgAJAAAAAAAAAAAAAAAWAgAAc2VnbWVudHMvbG9naWNhbC1mcmFtZXMubmRqc29uVVQFAAEAAAAAUEsFBgAAAAACAAIAmQAAADgEAAAAAA=="
  let archive = try #require(Data(base64Encoded: base64))
  let imported = try EvidenceSyncBundle.decode(archive)

  #expect(imported.manifest.creator.platform == "ANDROID")
  #expect(imported.records.count == 1)
  #expect(imported.records[0].sourceID == "esp32-test")
  #expect(imported.records[0].sourceSequence == "42")
}

private func replaceLittleEndianUInt16(_ value: UInt16, in data: inout Data, at offset: Int) {
  data[offset] = UInt8(value & 0x00FF)
  data[offset + 1] = UInt8((value >> 8) & 0x00FF)
}

private func replaceLittleEndianUInt32(_ value: UInt32, in data: inout Data, at offset: Int) {
  data[offset] = UInt8(value & 0x0000_00FF)
  data[offset + 1] = UInt8((value >> 8) & 0x0000_00FF)
  data[offset + 2] = UInt8((value >> 16) & 0x0000_00FF)
  data[offset + 3] = UInt8((value >> 24) & 0x0000_00FF)
}

private func littleEndianUInt32(in data: Data, at offset: Int) -> UInt32 {
  UInt32(data[offset])
    | (UInt32(data[offset + 1]) << 8)
    | (UInt32(data[offset + 2]) << 16)
    | (UInt32(data[offset + 3]) << 24)
}

private func mutateJSON(_ data: Data, key: String, value: Any) throws -> Data {
  var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  object[key] = value
  return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
