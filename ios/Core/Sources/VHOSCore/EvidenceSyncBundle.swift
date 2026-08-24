import CryptoKit
import Foundation

public enum EvidenceSourceRole: String, Codable, Sendable {
  case obdCAN = "OBD_CAN"
  case acSensor = "AC_SENSOR"
}

public struct EvidenceBundleCreator: Codable, Equatable, Sendable {
  public let platform: String
  public let applicationID: String
  public let applicationVersion: String
  public let deviceModel: String

  private enum CodingKeys: String, CodingKey {
    case platform
    case applicationID = "applicationId"
    case applicationVersion
    case deviceModel
  }

  public init(
    platform: String,
    applicationID: String,
    applicationVersion: String,
    deviceModel: String
  ) {
    self.platform = platform
    self.applicationID = applicationID
    self.applicationVersion = applicationVersion
    self.deviceModel = deviceModel
  }
}

public struct EvidenceBundleSegment: Codable, Equatable, Sendable {
  public let path: String
  public let mediaType: String
  public let sha256: String
  public let byteCount: Int
  public let recordCount: Int
}

/// Recovery-only provenance carried inside the checksummed bundle manifest.
///
/// The classification and authority denial are constants by construction. The source-ledger
/// digest binds the exported segment back to the exact append-only iPhone ledger from which it
/// was produced, even if a share provider renames the artifact.
public struct EvidenceRecoveryMetadata: Codable, Equatable, Sendable {
  public let classification: String
  public let vehicleClaimsAuthorized: Bool
  public let sourceLedgerSHA256: String

  private enum CodingKeys: String, CodingKey {
    case classification
    case vehicleClaimsAuthorized
    case sourceLedgerSHA256 = "sourceLedgerSha256"
  }

  public init(sourceLedgerSHA256: String) {
    classification = "RECOVERED_PORTABLE_EVIDENCE"
    vehicleClaimsAuthorized = false
    self.sourceLedgerSHA256 = sourceLedgerSHA256.lowercased()
  }
}

public struct EvidenceBundleManifest: Codable, Equatable, Sendable {
  public let contract: String
  public let contractVersion: String
  public let bundleID: UUID
  public let createdAt: String
  public let creator: EvidenceBundleCreator
  public let segments: [EvidenceBundleSegment]
  public let recovery: EvidenceRecoveryMetadata?

  private enum CodingKeys: String, CodingKey {
    case contract
    case contractVersion
    case bundleID = "bundleId"
    case createdAt
    case creator
    case segments
    case recovery
  }

  public init(
    bundleID: UUID,
    createdAt: String,
    creator: EvidenceBundleCreator,
    segments: [EvidenceBundleSegment],
    recovery: EvidenceRecoveryMetadata? = nil
  ) {
    contract = "vhos.evidence-sync-bundle"
    contractVersion = recovery == nil ? "1.0.0" : "2.0.0"
    self.bundleID = bundleID
    self.createdAt = createdAt
    self.creator = creator
    self.segments = segments
    self.recovery = recovery
  }
}

public struct PortableLogicalFrame: Codable, Equatable, Sendable, Identifiable {
  public let contract: String
  public let contractVersion: String
  public let sourceRole: EvidenceSourceRole
  public let sourceID: String
  public let sourceSequence: String
  public let sourceMonotonicMicroseconds: String
  public let protocolMajor: UInt8
  public let protocolMinor: UInt8
  public let messageType: UInt8
  public let flags: UInt8
  public let ingestedAt: String
  public let envelopeSHA256: String
  public let envelopeBase64: String

  private enum CodingKeys: String, CodingKey {
    case contract
    case contractVersion
    case sourceRole
    case sourceID = "sourceId"
    case sourceSequence
    case sourceMonotonicMicroseconds
    case protocolMajor
    case protocolMinor
    case messageType
    case flags
    case ingestedAt
    case envelopeSHA256 = "envelopeSha256"
    case envelopeBase64
  }

  public var id: String { "\(sourceID):\(sourceSequence):\(envelopeSHA256)" }

  public init(
    frame: GatewayFrame,
    sourceRole: EvidenceSourceRole,
    sourceID: String,
    ingestedAt: String
  ) {
    let envelope = frame.encoded()
    contract = "vhos.portable-logical-frame"
    contractVersion = "1.0.0"
    self.sourceRole = sourceRole
    self.sourceID = sourceID
    sourceSequence = String(frame.sequence)
    sourceMonotonicMicroseconds = String(frame.monotonicMicroseconds)
    protocolMajor = frame.protocolMajor
    protocolMinor = frame.protocolMinor
    messageType = frame.messageType.rawValue
    flags = frame.flags
    self.ingestedAt = ingestedAt
    envelopeSHA256 = Self.sha256(envelope)
    envelopeBase64 = envelope.base64EncodedString()
  }

  public func validatedFrame() throws -> GatewayFrame {
    guard contract == "vhos.portable-logical-frame", contractVersion == "1.0.0" else {
      throw EvidenceSyncError.unsupportedRecordContract
    }
    guard EvidenceContractScalarValidation.isBoundedString(sourceID, maximum: 160),
      let expectedSequence = EvidenceContractScalarValidation.canonicalUInt64(sourceSequence),
      let expectedMonotonic = EvidenceContractScalarValidation.canonicalUInt64(
        sourceMonotonicMicroseconds),
      messageType > 0,
      EvidenceContractScalarValidation.isWallTime(ingestedAt),
      EvidenceContractScalarValidation.isLowercaseSHA256(envelopeSHA256),
      envelopeBase64.unicodeScalars.count <= 2_097_152,
      let envelope = Data(base64Encoded: envelopeBase64)
    else { throw EvidenceSyncError.invalidRecord }
    guard Self.sha256(envelope) == envelopeSHA256 else {
      throw EvidenceSyncError.envelopeHashMismatch
    }
    let frame = try GatewayFrame.decode(envelope)
    guard frame.sequence == expectedSequence,
      frame.monotonicMicroseconds == expectedMonotonic,
      frame.protocolMajor == protocolMajor,
      frame.protocolMinor == protocolMinor,
      frame.messageType.rawValue == messageType,
      frame.flags == flags
    else { throw EvidenceSyncError.recordMetadataMismatch }
    return frame
  }

  fileprivate static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public struct ImportedEvidenceBundle: Equatable, Sendable {
  public let manifest: EvidenceBundleManifest
  public let manifestSHA256: String
  public let records: [PortableLogicalFrame]

  /// A portable bundle is evidence transport, never live vehicle authority.
  public var authorizesLiveVehicleClaims: Bool { false }
}

public enum EvidenceSyncBundle {
  public static let fileExtension = "vhossync"
  public static let maximumArchiveByteCount = 18 * 1024 * 1024
  private static let manifestPath = "manifest.json"
  private static let segmentPath = "segments/logical-frames.ndjson"
  // Imported records are currently materialized for replay. Keep that allocation bounded to the
  // same immutable generation contract used by the iPhone ledger; larger evidence must arrive as
  // multiple independently verified bundles rather than one memory-amplifying archive.
  private static let maximumEntryBytes = 16 * 1024 * 1024
  private static let maximumManifestBytes = 1 * 1024 * 1024
  private static let maximumArchiveBytes = maximumArchiveByteCount
  private static let maximumArchiveEntries = 33
  private static let maximumAggregateEntryBytes = 17 * 1024 * 1024
  private static let maximumRecords = 20_000

  public static func encode(
    records: [PortableLogicalFrame],
    creator: EvidenceBundleCreator,
    recovery: EvidenceRecoveryMetadata? = nil,
    bundleID: UUID = UUID(),
    createdAt: String = ISO8601DateFormatter().string(from: Date())
  ) throws -> Data {
    guard records.count <= maximumRecords else { throw EvidenceSyncError.tooManyRecords }
    var ndjson = Data()
    for record in records {
      _ = try record.validatedFrame()
      ndjson.append(try VHOSJSON.encoder().encode(record))
      ndjson.append(0x0A)
    }
    guard ndjson.count <= maximumEntryBytes else { throw EvidenceSyncError.entryTooLarge }
    let manifest = EvidenceBundleManifest(
      bundleID: bundleID,
      createdAt: createdAt,
      creator: creator,
      segments: [
        EvidenceBundleSegment(
          path: segmentPath,
          mediaType: "application/x-ndjson",
          sha256: PortableLogicalFrame.sha256(ndjson),
          byteCount: ndjson.count,
          recordCount: records.count
        )
      ],
      recovery: recovery
    )
    try validateManifest(manifest)
    let manifestData = try VHOSJSON.encoder().encode(manifest)
    guard manifestData.count <= maximumManifestBytes else {
      throw EvidenceSyncError.entryTooLarge
    }
    return try StoredZipArchive.encode(
      [
        manifestPath: manifestData,
        segmentPath: ndjson,
      ],
      maximumEntryCount: maximumArchiveEntries,
      maximumAggregateBytes: maximumAggregateEntryBytes,
      maximumArchiveBytes: maximumArchiveBytes
    )
  }

  public static func decode(_ archive: Data) throws -> ImportedEvidenceBundle {
    try validateArchiveByteCount(archive.count)
    let entries = try StoredZipArchive.decode(
      archive,
      maximumEntryBytes: maximumEntryBytes,
      maximumEntryCount: maximumArchiveEntries,
      maximumAggregateBytes: maximumAggregateEntryBytes
    )
    guard let manifestData = entries[manifestPath] else { throw EvidenceSyncError.missingManifest }
    guard manifestData.count <= maximumManifestBytes else {
      throw EvidenceSyncError.entryTooLarge
    }
    try validateManifestJSONShape(manifestData)
    let manifest = try VHOSJSON.decoder().decode(EvidenceBundleManifest.self, from: manifestData)
    try validateManifest(manifest)
    let declaredPaths = Set(manifest.segments.map(\.path)).union([manifestPath])
    guard Set(entries.keys) == declaredPaths else { throw EvidenceSyncError.undeclaredArchiveEntry }

    var records: [PortableLogicalFrame] = []
    for segment in manifest.segments {
      guard let bytes = entries[segment.path], bytes.count == segment.byteCount else {
        throw EvidenceSyncError.segmentByteCountMismatch(segment.path)
      }
      guard PortableLogicalFrame.sha256(bytes) == segment.sha256.lowercased() else {
        throw EvidenceSyncError.segmentHashMismatch(segment.path)
      }
      let lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: true)
      guard lines.count == segment.recordCount else {
        throw EvidenceSyncError.segmentRecordCountMismatch(segment.path)
      }
      guard records.count + lines.count <= maximumRecords else {
        throw EvidenceSyncError.tooManyRecords
      }
      for line in lines {
        records.append(try decodeRecord(Data(line)))
      }
    }
    return ImportedEvidenceBundle(
      manifest: manifest,
      manifestSHA256: PortableLogicalFrame.sha256(manifestData),
      records: records
    )
  }

  /// Strictly decodes one portable-frame NDJSON record using the same schema boundary as a
  /// checksummed sync bundle. App-local immutable ledgers use this entry point so evidence does
  /// not become more permissive merely because it has not been zipped yet.
  public static func decodeRecord(_ data: Data) throws -> PortableLogicalFrame {
    try validateRecordJSONShape(data)
    let record: PortableLogicalFrame
    do {
      record = try VHOSJSON.decoder().decode(PortableLogicalFrame.self, from: data)
    } catch {
      throw EvidenceSyncError.invalidRecord
    }
    _ = try record.validatedFrame()
    return record
  }

  static func validateManifest(_ manifest: EvidenceBundleManifest) throws {
    guard manifest.contract == "vhos.evidence-sync-bundle" else {
      throw EvidenceSyncError.unsupportedManifestContract
    }
    switch manifest.contractVersion {
    case "1.0.0":
      guard manifest.recovery == nil else { throw EvidenceSyncError.invalidManifest }
    case "2.0.0":
      guard let recovery = manifest.recovery,
        recovery.classification == "RECOVERED_PORTABLE_EVIDENCE",
        recovery.vehicleClaimsAuthorized == false,
        recovery.sourceLedgerSHA256.range(
          of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
        manifest.segments.count == 1,
        manifest.segments[0].path == segmentPath,
        manifest.segments[0].sha256 == recovery.sourceLedgerSHA256
      else { throw EvidenceSyncError.invalidManifest }
    default:
      throw EvidenceSyncError.unsupportedManifestContract
    }
    guard ["ANDROID", "IOS"].contains(manifest.creator.platform),
      EvidenceContractScalarValidation.isBoundedString(
        manifest.creator.applicationID, maximum: 160),
      EvidenceContractScalarValidation.isBoundedString(
        manifest.creator.applicationVersion, maximum: 80),
      EvidenceContractScalarValidation.isBoundedString(
        manifest.creator.deviceModel, maximum: 160),
      EvidenceContractScalarValidation.isWallTime(manifest.createdAt),
      !manifest.segments.isEmpty,
      manifest.segments.count <= maximumArchiveEntries - 1,
      Set(manifest.segments.map(\.path)).count == manifest.segments.count
    else { throw EvidenceSyncError.invalidManifest }
    var declaredSegmentBytes = 0
    for segment in manifest.segments {
      try validatePath(segment.path)
      guard segment.mediaType == "application/x-ndjson",
        EvidenceContractScalarValidation.isLowercaseSHA256(segment.sha256),
        (0...maximumEntryBytes).contains(segment.byteCount),
        (0...maximumRecords).contains(segment.recordCount)
      else { throw EvidenceSyncError.invalidManifest }
      guard segment.byteCount <= maximumAggregateEntryBytes - declaredSegmentBytes else {
        throw EvidenceSyncError.aggregateEntryBytesTooLarge
      }
      declaredSegmentBytes += segment.byteCount
    }
  }

  static func validateArchiveByteCount(_ byteCount: Int) throws {
    guard byteCount <= maximumArchiveBytes else { throw EvidenceSyncError.archiveTooLarge }
  }

  /// Codable intentionally ignores unknown JSON keys, but a versioned evidence manifest must not.
  /// Rejecting undeclared keys prevents an alternate authority or provenance field from creating
  /// two plausible interpretations of the same checksummed artifact.
  static func validateManifestJSONShape(_ data: Data) throws {
    do {
      try StrictJSONValidator.validate(data)
    } catch {
      throw EvidenceSyncError.invalidManifest
    }
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let version = object["contract_version"] as? String
    else { throw EvidenceSyncError.invalidManifest }
    let commonKeys: Set<String> = [
      "contract", "contract_version", "bundle_id", "created_at", "creator", "segments",
    ]
    let expectedKeys = version == "2.0.0" ? commonKeys.union(["recovery"]) : commonKeys
    guard Set(object.keys) == expectedKeys,
      let creator = object["creator"] as? [String: Any],
      Set(creator.keys)
        == ["platform", "application_id", "application_version", "device_model"],
      let segments = object["segments"] as? [[String: Any]],
      segments.allSatisfy({
        Set($0.keys) == ["path", "media_type", "sha256", "byte_count", "record_count"]
      })
    else { throw EvidenceSyncError.invalidManifest }
    if version == "2.0.0" {
      guard let recovery = object["recovery"] as? [String: Any],
        Set(recovery.keys)
          == ["classification", "vehicle_claims_authorized", "source_ledger_sha256"]
      else { throw EvidenceSyncError.invalidManifest }
    }
  }

  /// Portable record decoding is deliberately stricter than Codable's forward-compatible
  /// default. A checksummed evidence record has one canonical meaning: undeclared fields and
  /// duplicate object keys are rejected before the envelope can enter replay or research.
  static func validateRecordJSONShape(_ data: Data) throws {
    do {
      try StrictJSONValidator.validate(data)
    } catch {
      throw EvidenceSyncError.invalidRecord
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys)
        == [
          "contract", "contract_version", "source_role", "source_id", "source_sequence",
          "source_monotonic_microseconds", "protocol_major", "protocol_minor", "message_type",
          "flags", "ingested_at", "envelope_sha256", "envelope_base64",
        ]
    else { throw EvidenceSyncError.invalidRecord }
  }

  fileprivate static func validatePath(_ path: String) throws {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard path.unicodeScalars.count <= 256,
      path.range(of: "^[A-Za-z0-9][A-Za-z0-9._/-]*$", options: .regularExpression) != nil,
      !path.hasPrefix("/"), !path.contains("\\"),
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw EvidenceSyncError.unsafeArchivePath(path) }
  }
}

enum EvidenceContractScalarValidation {
  private static let canonicalDecimal = try! NSRegularExpression(
    pattern: "^(0|[1-9][0-9]*)$")
  private static let wallTime = try! NSRegularExpression(
    pattern:
      "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])[Tt]([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\\.[0-9]+)?([Zz]|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"
  )

  static func isBoundedString(_ value: String, maximum: Int) -> Bool {
    (1...maximum).contains(value.unicodeScalars.count)
  }

  static func canonicalUInt64(_ value: String) -> UInt64? {
    guard value.unicodeScalars.count <= 20, matches(canonicalDecimal, value) else { return nil }
    return UInt64(value)
  }

  static func isLowercaseSHA256(_ value: String) -> Bool {
    value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
  }

  static func isWallTime(_ value: String) -> Bool {
    guard matches(wallTime, value) else { return false }

    // RFC 3339 admits lower-case t/z and arbitrary fractional precision. Date validity is
    // checked independently from those lexical choices so malformed dates such as February 30
    // cannot pass merely because their shape is correct. The shared contract deliberately rejects
    // leap-second spellings so every runtime applies the same fail-closed timestamp policy.
    let datePrefix = String(value.prefix(10))
    let parts = datePrefix.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3,
      let year = Int(parts[0]),
      let month = Int(parts[1]),
      let day = Int(parts[2])
    else { return false }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
      return false
    }
    let checked = calendar.dateComponents([.year, .month, .day], from: date)
    return checked.year == year && checked.month == month && checked.day == day
  }

  private static func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return regex.firstMatch(in: value, range: range)?.range == range
  }
}

public enum EvidenceSyncError: Error, Equatable, LocalizedError {
  case invalidArchive
  case unsupportedCompression
  case unsafeArchivePath(String)
  case duplicateArchiveEntry(String)
  case archiveTooLarge
  case tooManyArchiveEntries
  case aggregateEntryBytesTooLarge
  case entryTooLarge
  case zipCRC(String)
  case missingManifest
  case unsupportedManifestContract
  case invalidManifest
  case undeclaredArchiveEntry
  case segmentByteCountMismatch(String)
  case segmentHashMismatch(String)
  case segmentRecordCountMismatch(String)
  case tooManyRecords
  case unsupportedRecordContract
  case invalidRecord
  case envelopeHashMismatch
  case recordMetadataMismatch

  public var errorDescription: String? {
    switch self {
    case .invalidArchive: "The VHOS sync archive is structurally invalid."
    case .unsupportedCompression:
      "The VHOS sync archive uses an unsupported ZIP compression method."
    case .unsafeArchivePath(let path): "The VHOS sync archive contains an unsafe path: \(path)."
    case .duplicateArchiveEntry(let path): "The VHOS sync archive repeats entry \(path)."
    case .archiveTooLarge: "The VHOS sync archive exceeds the total archive safety limit."
    case .tooManyArchiveEntries: "The VHOS sync archive contains too many entries."
    case .aggregateEntryBytesTooLarge:
      "The VHOS sync archive exceeds the aggregate uncompressed data safety limit."
    case .entryTooLarge: "A VHOS sync archive entry exceeds the safety limit."
    case .zipCRC(let path): "ZIP CRC validation failed for \(path)."
    case .missingManifest: "The VHOS sync manifest is missing."
    case .unsupportedManifestContract: "The VHOS sync manifest version is unsupported."
    case .invalidManifest: "The VHOS sync manifest is incomplete or invalid."
    case .undeclaredArchiveEntry: "Archive entries do not exactly match the VHOS sync manifest."
    case .segmentByteCountMismatch(let path): "Segment byte count does not match \(path)."
    case .segmentHashMismatch(let path): "Segment SHA-256 does not match \(path)."
    case .segmentRecordCountMismatch(let path): "Segment record count does not match \(path)."
    case .tooManyRecords: "The VHOS sync bundle contains too many records."
    case .unsupportedRecordContract: "A portable frame contract is unsupported."
    case .invalidRecord: "A portable frame record is incomplete or invalid."
    case .envelopeHashMismatch: "A portable VHOS envelope failed SHA-256 validation."
    case .recordMetadataMismatch: "Portable record metadata does not match its VHOS envelope."
    }
  }
}

private enum StoredZipArchive {
  private struct CentralEntry {
    let path: String
    let crc32: UInt32
    let size: Int
    let localOffset: Int
  }

  static func encode(
    _ entries: [String: Data],
    maximumEntryCount: Int,
    maximumAggregateBytes: Int,
    maximumArchiveBytes: Int
  ) throws -> Data {
    guard entries.count <= maximumEntryCount else {
      throw EvidenceSyncError.tooManyArchiveEntries
    }
    var aggregateBytes = 0
    for bytes in entries.values {
      guard bytes.count <= maximumAggregateBytes - aggregateBytes else {
        throw EvidenceSyncError.aggregateEntryBytesTooLarge
      }
      aggregateBytes += bytes.count
    }
    var archive = Data()
    var central: [(path: String, crc: UInt32, size: UInt32, offset: UInt32)] = []
    for path in entries.keys.sorted() {
      try EvidenceSyncBundle.validatePath(path)
      guard let name = path.data(using: .utf8), let bytes = entries[path],
        name.count <= Int(UInt16.max), bytes.count <= Int(UInt32.max),
        archive.count <= Int(UInt32.max)
      else { throw EvidenceSyncError.entryTooLarge }
      let crc = ZipCRC32.checksum(bytes)
      let offset = UInt32(archive.count)
      archive.appendLE(UInt32(0x0403_4B50))
      archive.appendLE(UInt16(20))
      archive.appendLE(UInt16(0))
      archive.appendLE(UInt16(0))
      archive.appendLE(UInt16(0))
      archive.appendLE(UInt16(0))
      archive.appendLE(crc)
      archive.appendLE(UInt32(bytes.count))
      archive.appendLE(UInt32(bytes.count))
      archive.appendLE(UInt16(name.count))
      archive.appendLE(UInt16(0))
      archive.append(name)
      archive.append(bytes)
      central.append((path, crc, UInt32(bytes.count), offset))
    }
    guard archive.count <= Int(UInt32.max), central.count <= Int(UInt16.max) else {
      throw EvidenceSyncError.entryTooLarge
    }
    let centralOffset = UInt32(archive.count)
    for entry in central {
      let name = Data(entry.path.utf8)
      archive.appendLE(UInt32(0x0201_4B50))
      archive.appendLE(UInt16(20))
      archive.appendLE(UInt16(20))
      archive.appendLE(UInt16(0))
      archive.appendLE(UInt16(0))
      archive.appendLE(UInt16(0))
      archive.appendLE(UInt16(0))
      archive.appendLE(entry.crc)
      archive.appendLE(entry.size)
      archive.appendLE(entry.size)
      archive.appendLE(UInt16(name.count))
      archive.appendLE(UInt16(0))
      archive.appendLE(UInt16(0))
      archive.appendLE(UInt16(0))
      archive.appendLE(UInt16(0))
      archive.appendLE(UInt32(0))
      archive.appendLE(entry.offset)
      archive.append(name)
    }
    let centralSize = UInt32(archive.count) - centralOffset
    archive.appendLE(UInt32(0x0605_4B50))
    archive.appendLE(UInt16(0))
    archive.appendLE(UInt16(0))
    archive.appendLE(UInt16(central.count))
    archive.appendLE(UInt16(central.count))
    archive.appendLE(centralSize)
    archive.appendLE(centralOffset)
    archive.appendLE(UInt16(0))
    guard archive.count <= maximumArchiveBytes else { throw EvidenceSyncError.archiveTooLarge }
    return archive
  }

  static func decode(
    _ archive: Data,
    maximumEntryBytes: Int,
    maximumEntryCount: Int,
    maximumAggregateBytes: Int
  ) throws -> [String: Data] {
    guard archive.count >= 22 else { throw EvidenceSyncError.invalidArchive }
    let endOffset = archive.count - 22
    guard try archive.readU32(endOffset) == 0x0605_4B50,
      try archive.readU16(endOffset + 4) == 0,
      try archive.readU16(endOffset + 6) == 0,
      try archive.readU16(endOffset + 20) == 0
    else { throw EvidenceSyncError.invalidArchive }
    let entryCount = Int(try archive.readU16(endOffset + 10))
    guard try archive.readU16(endOffset + 8) == UInt16(entryCount) else {
      throw EvidenceSyncError.invalidArchive
    }
    guard entryCount <= maximumEntryCount else {
      throw EvidenceSyncError.tooManyArchiveEntries
    }
    let centralSize = Int(try archive.readU32(endOffset + 12))
    let centralOffset = Int(try archive.readU32(endOffset + 16))
    guard centralOffset >= 0, centralSize >= 0,
      centralOffset + centralSize == endOffset
    else { throw EvidenceSyncError.invalidArchive }

    var cursor = centralOffset
    var centralEntries: [CentralEntry] = []
    var aggregateBytes = 0
    for _ in 0..<entryCount {
      guard try archive.readU32(cursor) == 0x0201_4B50 else {
        throw EvidenceSyncError.invalidArchive
      }
      let flags = try archive.readU16(cursor + 8)
      let method = try archive.readU16(cursor + 10)
      let crc = try archive.readU32(cursor + 16)
      let compressed = Int(try archive.readU32(cursor + 20))
      let uncompressed = Int(try archive.readU32(cursor + 24))
      let nameLength = Int(try archive.readU16(cursor + 28))
      let extraLength = Int(try archive.readU16(cursor + 30))
      let commentLength = Int(try archive.readU16(cursor + 32))
      let localOffset = Int(try archive.readU32(cursor + 42))
      guard flags & ~UInt16(0x0800) == 0, method == 0, compressed == uncompressed else {
        if method != 0 { throw EvidenceSyncError.unsupportedCompression }
        throw EvidenceSyncError.invalidArchive
      }
      guard uncompressed <= maximumEntryBytes else {
        throw EvidenceSyncError.entryTooLarge
      }
      guard uncompressed <= maximumAggregateBytes - aggregateBytes else {
        throw EvidenceSyncError.aggregateEntryBytesTooLarge
      }
      aggregateBytes += uncompressed
      let nameStart = cursor + 46
      let nameEnd = nameStart + nameLength
      guard nameEnd + extraLength + commentLength <= endOffset,
        let path = String(data: archive[nameStart..<nameEnd], encoding: .utf8)
      else { throw EvidenceSyncError.invalidArchive }
      try EvidenceSyncBundle.validatePath(path)
      centralEntries.append(
        CentralEntry(path: path, crc32: crc, size: uncompressed, localOffset: localOffset))
      cursor = nameEnd + extraLength + commentLength
    }
    guard cursor == centralOffset + centralSize else { throw EvidenceSyncError.invalidArchive }

    var result: [String: Data] = [:]
    for entry in centralEntries {
      guard result[entry.path] == nil else {
        throw EvidenceSyncError.duplicateArchiveEntry(entry.path)
      }
      let offset = entry.localOffset
      guard try archive.readU32(offset) == 0x0403_4B50,
        try archive.readU16(offset + 6) & ~UInt16(0x0800) == 0,
        try archive.readU16(offset + 8) == 0,
        try archive.readU32(offset + 14) == entry.crc32,
        Int(try archive.readU32(offset + 18)) == entry.size,
        Int(try archive.readU32(offset + 22)) == entry.size
      else { throw EvidenceSyncError.invalidArchive }
      let nameLength = Int(try archive.readU16(offset + 26))
      let extraLength = Int(try archive.readU16(offset + 28))
      let nameStart = offset + 30
      let nameEnd = nameStart + nameLength
      let dataStart = nameEnd + extraLength
      let dataEnd = dataStart + entry.size
      guard dataEnd <= centralOffset,
        let localPath = String(data: archive[nameStart..<nameEnd], encoding: .utf8),
        localPath == entry.path
      else { throw EvidenceSyncError.invalidArchive }
      let bytes = Data(archive[dataStart..<dataEnd])
      guard ZipCRC32.checksum(bytes) == entry.crc32 else {
        throw EvidenceSyncError.zipCRC(entry.path)
      }
      result[entry.path] = bytes
    }
    return result
  }
}

/// A small, bounded-depth JSON syntax walk used before Foundation decoding.
///
/// Foundation intentionally accepts duplicate object keys and keeps one value. That behavior is
/// useful for permissive APIs but unsafe for signed/checksummed evidence, where two parsers must
/// not be able to choose different values for the same field.
private enum StrictJSONValidator {
  private enum ParseError: Error {
    case invalid
    case duplicateKey
    case nestingLimit
  }

  static func validate(_ data: Data) throws {
    var parser = Parser(data: data)
    try parser.parseDocument()
  }

  private struct Parser {
    let data: Data
    var index = 0
    let maximumDepth = 64

    mutating func parseDocument() throws {
      skipWhitespace()
      try parseValue(depth: 0)
      skipWhitespace()
      guard index == data.count else { throw ParseError.invalid }
    }

    mutating func parseValue(depth: Int) throws {
      guard depth <= maximumDepth, index < data.count else {
        throw depth > maximumDepth ? ParseError.nestingLimit : ParseError.invalid
      }
      switch data[index] {
      case 0x7B: try parseObject(depth: depth + 1)  // {
      case 0x5B: try parseArray(depth: depth + 1)  // [
      case 0x22: _ = try parseString(capturingValue: false)
      case 0x74: try consumeLiteral("true")
      case 0x66: try consumeLiteral("false")
      case 0x6E: try consumeLiteral("null")
      case 0x2D, 0x30...0x39: try parseNumber()
      default: throw ParseError.invalid
      }
    }

    mutating func parseObject(depth: Int) throws {
      guard depth <= maximumDepth, consume(0x7B) else { throw ParseError.nestingLimit }
      skipWhitespace()
      if consume(0x7D) { return }
      var keys: Set<String> = []
      while true {
        guard index < data.count, data[index] == 0x22,
          let key = try parseString(capturingValue: true)
        else { throw ParseError.invalid }
        guard keys.insert(key).inserted else { throw ParseError.duplicateKey }
        skipWhitespace()
        guard consume(0x3A) else { throw ParseError.invalid }
        skipWhitespace()
        try parseValue(depth: depth)
        skipWhitespace()
        if consume(0x7D) { return }
        guard consume(0x2C) else { throw ParseError.invalid }
        skipWhitespace()
      }
    }

    mutating func parseArray(depth: Int) throws {
      guard depth <= maximumDepth, consume(0x5B) else { throw ParseError.nestingLimit }
      skipWhitespace()
      if consume(0x5D) { return }
      while true {
        try parseValue(depth: depth)
        skipWhitespace()
        if consume(0x5D) { return }
        guard consume(0x2C) else { throw ParseError.invalid }
        skipWhitespace()
      }
    }

    mutating func parseString(capturingValue: Bool) throws -> String? {
      let start = index
      guard consume(0x22) else { throw ParseError.invalid }
      var hasEscape = false
      while index < data.count {
        let byte = data[index]
        if byte == 0x22 {
          index += 1
          guard capturingValue else { return nil }
          if hasEscape {
            let token = Data(data[start..<index])
            guard
              let value = try? JSONSerialization.jsonObject(
                with: token, options: [.fragmentsAllowed]) as? String
            else { throw ParseError.invalid }
            return value
          }
          guard let value = String(data: data[(start + 1)..<(index - 1)], encoding: .utf8) else {
            throw ParseError.invalid
          }
          return value
        }
        guard byte >= 0x20 else { throw ParseError.invalid }
        if byte == 0x5C {
          hasEscape = true
          index += 1
          guard index < data.count else { throw ParseError.invalid }
          switch data[index] {
          case 0x22, 0x2F, 0x5C, 0x62, 0x66, 0x6E, 0x72, 0x74:
            index += 1
          case 0x75:
            index += 1
            guard index + 4 <= data.count,
              data[index..<(index + 4)].allSatisfy(Self.isHexDigit)
            else { throw ParseError.invalid }
            index += 4
          default: throw ParseError.invalid
          }
        } else {
          index += 1
        }
      }
      throw ParseError.invalid
    }

    mutating func parseNumber() throws {
      _ = consume(0x2D)
      guard index < data.count else { throw ParseError.invalid }
      if consume(0x30) {
        guard index == data.count || !Self.isDigit(data[index]) else {
          throw ParseError.invalid
        }
      } else {
        guard index < data.count, (0x31...0x39).contains(data[index]) else {
          throw ParseError.invalid
        }
        index += 1
        while index < data.count, Self.isDigit(data[index]) { index += 1 }
      }
      if consume(0x2E) {
        guard index < data.count, Self.isDigit(data[index]) else { throw ParseError.invalid }
        while index < data.count, Self.isDigit(data[index]) { index += 1 }
      }
      if index < data.count, data[index] == 0x65 || data[index] == 0x45 {
        index += 1
        if index < data.count, data[index] == 0x2B || data[index] == 0x2D { index += 1 }
        guard index < data.count, Self.isDigit(data[index]) else { throw ParseError.invalid }
        while index < data.count, Self.isDigit(data[index]) { index += 1 }
      }
    }

    mutating func consumeLiteral(_ literal: String) throws {
      let bytes = Array(literal.utf8)
      guard index + bytes.count <= data.count,
        data[index..<(index + bytes.count)].elementsEqual(bytes)
      else { throw ParseError.invalid }
      index += bytes.count
    }

    mutating func skipWhitespace() {
      while index < data.count, [0x20, 0x09, 0x0A, 0x0D].contains(data[index]) {
        index += 1
      }
    }

    mutating func consume(_ byte: UInt8) -> Bool {
      guard index < data.count, data[index] == byte else { return false }
      index += 1
      return true
    }

    static func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }

    static func isHexDigit(_ byte: UInt8) -> Bool {
      (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte)
        || (0x61...0x66).contains(byte)
    }
  }
}

private enum ZipCRC32 {
  static func checksum(_ data: Data) -> UInt32 {
    var crc = UInt32.max
    for byte in data {
      crc ^= UInt32(byte)
      for _ in 0..<8 {
        crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB8_8320 : 0)
      }
    }
    return ~crc
  }
}

extension Data {
  fileprivate mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
    var little = value.littleEndian
    Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
  }

  fileprivate func readU16(_ offset: Int) throws -> UInt16 {
    guard offset >= 0, offset + 2 <= count else { throw EvidenceSyncError.invalidArchive }
    return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
  }

  fileprivate func readU32(_ offset: Int) throws -> UInt32 {
    guard offset >= 0, offset + 4 <= count else { throw EvidenceSyncError.invalidArchive }
    return UInt32(self[offset]) | UInt32(self[offset + 1]) << 8
      | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
  }
}
