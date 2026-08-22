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

public struct EvidenceBundleManifest: Codable, Equatable, Sendable {
  public let contract: String
  public let contractVersion: String
  public let bundleID: UUID
  public let createdAt: String
  public let creator: EvidenceBundleCreator
  public let segments: [EvidenceBundleSegment]

  private enum CodingKeys: String, CodingKey {
    case contract
    case contractVersion
    case bundleID = "bundleId"
    case createdAt
    case creator
    case segments
  }

  public init(
    bundleID: UUID,
    createdAt: String,
    creator: EvidenceBundleCreator,
    segments: [EvidenceBundleSegment]
  ) {
    contract = "vhos.evidence-sync-bundle"
    contractVersion = "1.0.0"
    self.bundleID = bundleID
    self.createdAt = createdAt
    self.creator = creator
    self.segments = segments
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
    guard !sourceID.isEmpty,
      let expectedSequence = UInt64(sourceSequence),
      let expectedMonotonic = UInt64(sourceMonotonicMicroseconds),
      let envelope = Data(base64Encoded: envelopeBase64)
    else { throw EvidenceSyncError.invalidRecord }
    guard Self.sha256(envelope) == envelopeSHA256.lowercased() else {
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
}

public enum EvidenceSyncBundle {
  public static let fileExtension = "vhossync"
  private static let manifestPath = "manifest.json"
  private static let segmentPath = "segments/logical-frames.ndjson"
  private static let maximumEntryBytes = 128 * 1024 * 1024
  private static let maximumRecords = 1_000_000

  public static func encode(
    records: [PortableLogicalFrame],
    creator: EvidenceBundleCreator,
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
      ]
    )
    let manifestData = try VHOSJSON.encoder().encode(manifest)
    return try StoredZipArchive.encode([
      manifestPath: manifestData,
      segmentPath: ndjson,
    ])
  }

  public static func decode(_ archive: Data) throws -> ImportedEvidenceBundle {
    let entries = try StoredZipArchive.decode(archive, maximumEntryBytes: maximumEntryBytes)
    guard let manifestData = entries[manifestPath] else { throw EvidenceSyncError.missingManifest }
    let manifest = try VHOSJSON.decoder().decode(EvidenceBundleManifest.self, from: manifestData)
    try validate(manifest)
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
        let record = try VHOSJSON.decoder().decode(PortableLogicalFrame.self, from: Data(line))
        _ = try record.validatedFrame()
        records.append(record)
      }
    }
    return ImportedEvidenceBundle(
      manifest: manifest,
      manifestSHA256: PortableLogicalFrame.sha256(manifestData),
      records: records
    )
  }

  private static func validate(_ manifest: EvidenceBundleManifest) throws {
    guard manifest.contract == "vhos.evidence-sync-bundle",
      manifest.contractVersion == "1.0.0"
    else { throw EvidenceSyncError.unsupportedManifestContract }
    guard ["ANDROID", "IOS"].contains(manifest.creator.platform),
      !manifest.creator.applicationID.isEmpty,
      !manifest.creator.applicationVersion.isEmpty,
      !manifest.creator.deviceModel.isEmpty,
      ISO8601DateFormatter().date(from: manifest.createdAt) != nil,
      !manifest.segments.isEmpty,
      Set(manifest.segments.map(\.path)).count == manifest.segments.count
    else { throw EvidenceSyncError.invalidManifest }
    for segment in manifest.segments {
      try validatePath(segment.path)
      guard segment.mediaType == "application/x-ndjson",
        segment.sha256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil,
        (0...maximumEntryBytes).contains(segment.byteCount),
        (0...maximumRecords).contains(segment.recordCount)
      else { throw EvidenceSyncError.invalidManifest }
    }
  }

  fileprivate static func validatePath(_ path: String) throws {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw EvidenceSyncError.unsafeArchivePath(path) }
  }
}

public enum EvidenceSyncError: Error, Equatable, LocalizedError {
  case invalidArchive
  case unsupportedCompression
  case unsafeArchivePath(String)
  case duplicateArchiveEntry(String)
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
    case .unsupportedCompression: "The VHOS sync archive uses an unsupported ZIP compression method."
    case .unsafeArchivePath(let path): "The VHOS sync archive contains an unsafe path: \(path)."
    case .duplicateArchiveEntry(let path): "The VHOS sync archive repeats entry \(path)."
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

  static func encode(_ entries: [String: Data]) throws -> Data {
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
    return archive
  }

  static func decode(_ archive: Data, maximumEntryBytes: Int) throws -> [String: Data] {
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
    let centralSize = Int(try archive.readU32(endOffset + 12))
    let centralOffset = Int(try archive.readU32(endOffset + 16))
    guard centralOffset >= 0, centralSize >= 0,
      centralOffset + centralSize == endOffset
    else { throw EvidenceSyncError.invalidArchive }

    var cursor = centralOffset
    var centralEntries: [CentralEntry] = []
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
      guard flags & ~UInt16(0x0800) == 0, method == 0, compressed == uncompressed,
        uncompressed <= maximumEntryBytes
      else {
        if method != 0 { throw EvidenceSyncError.unsupportedCompression }
        throw EvidenceSyncError.invalidArchive
      }
      let nameStart = cursor + 46
      let nameEnd = nameStart + nameLength
      guard nameEnd + extraLength + commentLength <= endOffset,
        let path = String(data: archive[nameStart..<nameEnd], encoding: .utf8)
      else { throw EvidenceSyncError.invalidArchive }
      try EvidenceSyncBundle.validatePath(path)
      centralEntries.append(CentralEntry(path: path, crc32: crc, size: uncompressed, localOffset: localOffset))
      cursor = nameEnd + extraLength + commentLength
    }
    guard cursor == centralOffset + centralSize else { throw EvidenceSyncError.invalidArchive }

    var result: [String: Data] = [:]
    for entry in centralEntries {
      guard result[entry.path] == nil else { throw EvidenceSyncError.duplicateArchiveEntry(entry.path) }
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
