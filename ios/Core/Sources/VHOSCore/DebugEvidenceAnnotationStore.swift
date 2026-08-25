import CryptoKit
import Foundation

public enum DebugEvidenceAnnotationKind: String, Codable, CaseIterable, Sendable {
  case label = "LABEL"
  case eventMarker = "EVENT_MARKER"
}

public struct DebugEvidenceAnnotationRecord: Codable, Equatable, Sendable, Identifiable {
  public let contract: String
  public let contractVersion: String
  public let id: String
  public let appendedAt: String
  public let annotationKind: DebugEvidenceAnnotationKind
  public let markerKind: DiscoveryMarkerKind?
  public let label: String
  public let note: String
  public let source: DiscoveryEvidenceSource
  public let annotatorID: String?
  public let acquisitionAuthority: DiscoveryMutationAuthority
  public let sourceObservationID: String
  public let sourceObservationSHA256: String
  public let sourceObservation: PassiveCANObservation
  public let promotionAllowed: Bool

  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion, id, appendedAt, annotationKind, markerKind, label, note
    case source, acquisitionAuthority, sourceObservation, promotionAllowed
    case annotatorID = "annotatorId"
    case sourceObservationID = "sourceObservationId"
    case sourceObservationSHA256 = "sourceObservationSha256"
  }

  public static func label(
    id: String,
    appendedAt: String,
    label: String,
    note: String = "",
    source: DiscoveryEvidenceSource = .iPhone,
    annotatorID: String? = nil,
    observation: PassiveCANObservation
  ) throws -> Self {
    try Self(
      id: id, appendedAt: appendedAt, annotationKind: .label, markerKind: nil,
      label: label, note: note, source: source, annotatorID: annotatorID,
      observation: observation)
  }

  public static func eventMarker(
    id: String,
    appendedAt: String,
    markerKind: DiscoveryMarkerKind,
    label: String,
    note: String = "",
    source: DiscoveryEvidenceSource = .iPhone,
    annotatorID: String? = nil,
    observation: PassiveCANObservation
  ) throws -> Self {
    try Self(
      id: id, appendedAt: appendedAt, annotationKind: .eventMarker,
      markerKind: markerKind, label: label, note: note, source: source,
      annotatorID: annotatorID, observation: observation)
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let storedContract = try values.decode(String.self, forKey: .contract)
    let storedVersion = try values.decode(String.self, forKey: .contractVersion)
    let storedAuthority = try values.decode(
      DiscoveryMutationAuthority.self,
      forKey: .acquisitionAuthority)
    let storedObservationID = try values.decode(String.self, forKey: .sourceObservationID)
    let storedObservationSHA256 = try values.decode(
      String.self,
      forKey: .sourceObservationSHA256)
    let storedPromotionAllowed = try values.decode(Bool.self, forKey: .promotionAllowed)
    let annotationKind = try values.decode(
      DebugEvidenceAnnotationKind.self,
      forKey: .annotationKind)
    let markerKind = try values.decodeIfPresent(DiscoveryMarkerKind.self, forKey: .markerKind)
    let observation = try values.decode(PassiveCANObservation.self, forKey: .sourceObservation)

    guard storedContract == "vhos.discovery.debug-evidence-annotation",
      storedVersion == "1.0.0",
      storedAuthority == .debugUnverified,
      !storedPromotionAllowed
    else { throw DebugEvidenceAnnotationStoreError.invalidRecord }

    let rebuilt = try Self(
      id: values.decode(String.self, forKey: .id),
      appendedAt: values.decode(String.self, forKey: .appendedAt),
      annotationKind: annotationKind,
      markerKind: markerKind,
      label: values.decode(String.self, forKey: .label),
      note: values.decode(String.self, forKey: .note),
      source: values.decode(DiscoveryEvidenceSource.self, forKey: .source),
      annotatorID: values.decodeIfPresent(String.self, forKey: .annotatorID),
      observation: observation)
    guard rebuilt.sourceObservationID == storedObservationID,
      rebuilt.sourceObservationSHA256 == storedObservationSHA256
    else { throw DebugEvidenceAnnotationStoreError.invalidRecord }
    self = rebuilt
  }

  public func validateContract() throws {
    guard contract == "vhos.discovery.debug-evidence-annotation",
      contractVersion == "1.0.0",
      acquisitionAuthority == .debugUnverified,
      !promotionAllowed,
      sourceObservationID == sourceObservation.id,
      DiscoveryContractValidation.isSHA256(sourceObservationSHA256),
      sourceObservationSHA256 == Self.observationDigest(sourceObservation),
      (annotationKind == .label && markerKind == nil)
        || (annotationKind == .eventMarker && markerKind != nil)
    else { throw DebugEvidenceAnnotationStoreError.invalidRecord }
    try Self.validateObservation(sourceObservation)
  }

  private init(
    id: String,
    appendedAt: String,
    annotationKind: DebugEvidenceAnnotationKind,
    markerKind: DiscoveryMarkerKind?,
    label: String,
    note: String,
    source: DiscoveryEvidenceSource,
    annotatorID: String?,
    observation: PassiveCANObservation
  ) throws {
    guard DiscoveryContractValidation.isDomainID(id, prefix: "debugannotation"),
      DiscoveryContractValidation.isWallTime(appendedAt),
      DiscoveryContractValidation.isBoundedText(label, maximum: 160),
      note.count <= 1_000,
      annotatorID.map({ DiscoveryContractValidation.isBoundedText($0, maximum: 160) }) ?? true,
      (annotationKind == .label && markerKind == nil)
        || (annotationKind == .eventMarker && markerKind != nil)
    else { throw DebugEvidenceAnnotationStoreError.invalidRecord }
    try Self.validateObservation(observation)

    contract = "vhos.discovery.debug-evidence-annotation"
    contractVersion = "1.0.0"
    self.id = id
    self.appendedAt = appendedAt
    self.annotationKind = annotationKind
    self.markerKind = markerKind
    self.label = label
    self.note = note
    self.source = source
    self.annotatorID = annotatorID
    acquisitionAuthority = .debugUnverified
    sourceObservationID = observation.id
    sourceObservationSHA256 = Self.observationDigest(observation)
    sourceObservation = observation
    promotionAllowed = false
  }

  private static func validateObservation(_ observation: PassiveCANObservation) throws {
    do {
      try PassiveCANEvidenceArchive.validateResearchProvenance(observation)
    } catch {
      throw DebugEvidenceAnnotationStoreError.invalidObservation
    }
  }

  private static func observationDigest(_ observation: PassiveCANObservation) -> String {
    let encoded = try! VHOSJSON.encoder().encode(observation)
    return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
  }
}

public struct DebugEvidenceAnnotationTailRecovery: Equatable, Sendable {
  public let quarantineURL: URL
  public let quarantinedByteCount: Int
  public let retainedRecordCount: Int

  public init(
    quarantineURL: URL,
    quarantinedByteCount: Int,
    retainedRecordCount: Int
  ) {
    self.quarantineURL = quarantineURL
    self.quarantinedByteCount = quarantinedByteCount
    self.retainedRecordCount = retainedRecordCount
  }
}

public struct DebugEvidenceAnnotationLoadResult: Equatable, Sendable {
  public let records: [DebugEvidenceAnnotationRecord]
  public let recovery: DebugEvidenceAnnotationTailRecovery?

  public init(
    records: [DebugEvidenceAnnotationRecord],
    recovery: DebugEvidenceAnnotationTailRecovery?
  ) {
    self.records = records
    self.recovery = recovery
  }
}

public final class DebugEvidenceAnnotationStore: @unchecked Sendable {
  public static let fileName = "debug-evidence-annotations.ndjson"
  public static let maximumRecordCount = 50_000
  public static let maximumEncodedRecordBytes = 256 * 1_024

  public static var appendAvailable: Bool {
    #if DEBUG
      true
    #else
      false
    #endif
  }

  public let storageDirectory: URL
  public let fileURL: URL
  public let quarantineDirectory: URL

  private let fileManager: FileManager
  private let pathLock: NSLock

  public init(storageDirectory: URL, fileManager: FileManager = .default) {
    self.storageDirectory = storageDirectory
    self.fileManager = fileManager
    fileURL = storageDirectory.appendingPathComponent(Self.fileName)
    quarantineDirectory = storageDirectory.appendingPathComponent(
      "InterruptedDebugEvidenceAnnotations",
      isDirectory: true)
    pathLock = DebugEvidenceAnnotationPathLocks.shared.lock(
      for: fileURL.standardizedFileURL.path)
  }

  public func load() throws -> DebugEvidenceAnnotationLoadResult {
    try withLock { try loadUnlocked() }
  }

  public func list() throws -> [DebugEvidenceAnnotationRecord] {
    try load().records
  }

  @discardableResult
  public func appendLabel(
    id: String? = nil,
    appendedAt: String,
    label: String,
    note: String = "",
    source: DiscoveryEvidenceSource = .iPhone,
    annotatorID: String? = nil,
    observation: PassiveCANObservation
  ) throws -> DebugEvidenceAnnotationRecord {
    let record = try DebugEvidenceAnnotationRecord.label(
      id: id ?? DiscoveryIDGenerator.make(prefix: "debugannotation"),
      appendedAt: appendedAt,
      label: label,
      note: note,
      source: source,
      annotatorID: annotatorID,
      observation: observation)
    return try append(record)
  }

  @discardableResult
  public func appendEventMarker(
    id: String? = nil,
    appendedAt: String,
    markerKind: DiscoveryMarkerKind,
    label: String,
    note: String = "",
    source: DiscoveryEvidenceSource = .iPhone,
    annotatorID: String? = nil,
    observation: PassiveCANObservation
  ) throws -> DebugEvidenceAnnotationRecord {
    let record = try DebugEvidenceAnnotationRecord.eventMarker(
      id: id ?? DiscoveryIDGenerator.make(prefix: "debugannotation"),
      appendedAt: appendedAt,
      markerKind: markerKind,
      label: label,
      note: note,
      source: source,
      annotatorID: annotatorID,
      observation: observation)
    return try append(record)
  }

  @discardableResult
  public func append(
    _ record: DebugEvidenceAnnotationRecord
  ) throws -> DebugEvidenceAnnotationRecord {
    #if DEBUG
      try record.validateContract()
      guard record.acquisitionAuthority == .debugUnverified else {
        throw DebugEvidenceAnnotationStoreError.nonDebugAuthority
      }
      return try withLock {
        let current = try loadUnlocked().records
        guard current.count < Self.maximumRecordCount else {
          throw DebugEvidenceAnnotationStoreError.capacityExceeded
        }
        try Self.checkCollision(record, against: current)
        let encoded = try VHOSJSON.encoder().encode(record)
        guard encoded.count <= Self.maximumEncodedRecordBytes else {
          throw DebugEvidenceAnnotationStoreError.recordTooLarge(encoded.count)
        }
        try DurableEvidenceFile.ensureDirectory(storageDirectory, fileManager: fileManager)
        try DurableEvidenceFile.appendCommittedLine(
          encoded,
          to: fileURL,
          fileManager: fileManager)
        return record
      }
    #else
      throw DebugEvidenceAnnotationStoreError.appendUnavailableInRelease
    #endif
  }

  private func loadUnlocked() throws -> DebugEvidenceAnnotationLoadResult {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return DebugEvidenceAnnotationLoadResult(records: [], recovery: nil)
    }
    let allBytes = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    guard !allBytes.isEmpty else {
      return DebugEvidenceAnnotationLoadResult(records: [], recovery: nil)
    }

    let committedByteCount: Int
    let unfinished: Data?
    if allBytes.last == 0x0A {
      committedByteCount = allBytes.count
      unfinished = nil
    } else if let finalLineFeed = allBytes.lastIndex(of: 0x0A) {
      let committedEnd = allBytes.index(after: finalLineFeed)
      committedByteCount = allBytes.distance(from: allBytes.startIndex, to: committedEnd)
      unfinished = Data(allBytes[committedEnd...])
    } else {
      committedByteCount = 0
      unfinished = allBytes
    }

    let committedBytes = Data(allBytes.prefix(committedByteCount))
    var lines = committedBytes.split(separator: 0x0A, omittingEmptySubsequences: false)
    if committedBytes.last == 0x0A, lines.last?.isEmpty == true { lines.removeLast() }
    let records: [DebugEvidenceAnnotationRecord] = try lines.enumerated().map { index, line in
      guard !line.isEmpty else {
        throw DebugEvidenceAnnotationStoreError.invalidCommittedRecord(index + 1)
      }
      do {
        let exactBytes = Data(line)
        let record = try VHOSJSON.decoder().decode(
          DebugEvidenceAnnotationRecord.self,
          from: exactBytes)
        try record.validateContract()
        guard record.acquisitionAuthority == .debugUnverified,
          try VHOSJSON.encoder().encode(record) == exactBytes
        else { throw DebugEvidenceAnnotationStoreError.invalidRecord }
        return record
      } catch {
        throw DebugEvidenceAnnotationStoreError.invalidCommittedRecord(index + 1)
      }
    }
    guard records.count <= Self.maximumRecordCount else {
      throw DebugEvidenceAnnotationStoreError.capacityExceeded
    }
    var annotationIDs = Set<String>()
    var sourceByIdentity: [String: DebugEvidenceAnnotationRecord] = [:]
    for record in records {
      guard annotationIDs.insert(record.id).inserted else {
        throw DebugEvidenceAnnotationStoreError.annotationIdentityCollision(record.id)
      }
      if let prior = sourceByIdentity[record.sourceObservationID] {
        guard prior.sourceObservationSHA256 == record.sourceObservationSHA256,
          prior.sourceObservation == record.sourceObservation
        else {
          throw DebugEvidenceAnnotationStoreError.observationIdentityCollision(
            record.sourceObservationID)
        }
      } else {
        sourceByIdentity[record.sourceObservationID] = record
      }
    }

    guard let unfinished, !unfinished.isEmpty else {
      return DebugEvidenceAnnotationLoadResult(records: records, recovery: nil)
    }
    try DurableEvidenceFile.ensureDirectory(quarantineDirectory, fileManager: fileManager)
    let quarantineURL = quarantineDirectory.appendingPathComponent(
      "\(Self.fileName).\(UUID().uuidString.lowercased()).truncated-tail")
    try DurableEvidenceFile.replace(unfinished, at: quarantineURL, fileManager: fileManager)
    try DurableEvidenceFile.replace(committedBytes, at: fileURL, fileManager: fileManager)
    return DebugEvidenceAnnotationLoadResult(
      records: records,
      recovery: DebugEvidenceAnnotationTailRecovery(
        quarantineURL: quarantineURL,
        quarantinedByteCount: unfinished.count,
        retainedRecordCount: records.count))
  }

  private static func checkCollision(
    _ record: DebugEvidenceAnnotationRecord,
    against current: [DebugEvidenceAnnotationRecord]
  ) throws {
    guard !current.contains(where: { $0.id == record.id }) else {
      throw DebugEvidenceAnnotationStoreError.annotationIdentityCollision(record.id)
    }
    if let prior = current.first(where: {
      $0.sourceObservationID == record.sourceObservationID
    }) {
      guard prior.sourceObservationSHA256 == record.sourceObservationSHA256,
        prior.sourceObservation == record.sourceObservation
      else {
        throw DebugEvidenceAnnotationStoreError.observationIdentityCollision(
          record.sourceObservationID)
      }
    }
  }

  private func withLock<T>(_ action: () throws -> T) rethrows -> T {
    pathLock.lock()
    defer { pathLock.unlock() }
    return try action()
  }
}

private final class DebugEvidenceAnnotationPathLocks: @unchecked Sendable {
  static let shared = DebugEvidenceAnnotationPathLocks()

  private let rootLock = NSLock()
  private var values: [String: NSLock] = [:]

  func lock(for canonicalPath: String) -> NSLock {
    rootLock.lock()
    defer { rootLock.unlock() }
    if let existing = values[canonicalPath] { return existing }
    let created = NSLock()
    values[canonicalPath] = created
    return created
  }
}

public enum DebugEvidenceAnnotationStoreError: Error, Equatable, LocalizedError {
  case invalidRecord
  case invalidObservation
  case nonDebugAuthority
  case invalidCommittedRecord(Int)
  case annotationIdentityCollision(String)
  case observationIdentityCollision(String)
  case capacityExceeded
  case recordTooLarge(Int)
  case appendUnavailableInRelease

  public var errorDescription: String? {
    switch self {
    case .invalidRecord:
      "The DEBUG_UNVERIFIED evidence annotation is invalid."
    case .invalidObservation:
      "The annotation does not retain a valid passive CAN observation."
    case .nonDebugAuthority:
      "The Debug evidence annotation store accepts only DEBUG_UNVERIFIED authority."
    case .invalidCommittedRecord(let line):
      "The committed Debug evidence annotation is invalid at line \(line)."
    case .annotationIdentityCollision(let id):
      "Debug evidence annotation identity \(id) is already committed."
    case .observationIdentityCollision(let id):
      "Passive observation identity \(id) resolves to conflicting immutable evidence."
    case .capacityExceeded:
      "The local Debug evidence annotation store reached its bounded capacity."
    case .recordTooLarge(let bytes):
      "The Debug evidence annotation is too large to append safely (\(bytes) bytes)."
    case .appendUnavailableInRelease:
      "Release builds can read DEBUG_UNVERIFIED provenance but cannot append it."
    }
  }
}
