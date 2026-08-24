import CryptoKit
import Darwin
import Foundation
import SQLite3
import VHOSCore

/// Serial, non-main-actor owner of the synchronized-reference ledger and its derived index.
///
/// The NDJSON ledger is authoritative. SQLite contains only a bounded deduplication/count index;
/// every process restart streams and validates the committed ledger prefix before trusting it.
actor SynchronizedReferenceStore {
  static let productionMaximumSamples = 20_000
  private static let maximumRecordByteCount = 64 * 1_024
  private static let ledgerKey = "synchronized-reference-v1"

  private let fileManager: FileManager
  private let root: URL
  private let ledgerURL: URL
  private let indexURL: URL
  private let recoveryDirectoryURL: URL
  private let maximumSamples: Int
  private var recordIndex: DurableLedgerIndex?
  private var prepared = false

  init(
    fileManager: FileManager = .default,
    root explicitRoot: URL? = nil,
    maximumSamples: Int = SynchronizedReferenceStore.productionMaximumSamples
  ) {
    precondition(maximumSamples > 0)
    self.fileManager = fileManager
    let support =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    root =
      explicitRoot
      ?? support.appendingPathComponent("VHOSSynchronizedReferences/v1", isDirectory: true)
    ledgerURL = root.appendingPathComponent("reference-samples.ndjson")
    indexURL = root.appendingPathComponent("reference-index.sqlite3")
    recoveryDirectoryURL = root.appendingPathComponent(
      "InterruptedReferenceTails", isDirectory: true)
    self.maximumSamples = maximumSamples
  }

  func samples() throws -> [SynchronizedReferenceSample] {
    _ = try ensuredRecordIndex()
    guard fileManager.fileExists(atPath: ledgerURL.path) else { return [] }
    var result: [SynchronizedReferenceSample] = []
    result.reserveCapacity(try count())
    _ = try scanLedger { sample, _, _ in result.append(sample) }
    return result
  }

  func count() throws -> Int {
    try ensuredRecordIndex().count(ledgerKey: Self.ledgerKey)
  }

  @discardableResult
  func append(_ sample: SynchronizedReferenceSample) throws -> Bool {
    try append([sample]) == 1
  }

  /// Appends only the batch delta with one durable file commit and one SQLite transaction.
  @discardableResult
  func append(_ samples: [SynchronizedReferenceSample]) throws -> Int {
    guard !samples.isEmpty else { return 0 }
    guard samples.count <= maximumSamples else {
      throw SynchronizedReferenceStoreError.capacityReached
    }
    let index = try ensuredRecordIndex()
    var batchCanonicalRecords: [String: String] = [:]
    var batchDedupeKeys = Set<String>()
    var fresh:
      [(
        sample: SynchronizedReferenceSample,
        primary: String,
        dedupe: String
      )] = []
    fresh.reserveCapacity(samples.count)

    for sample in samples {
      let primary = Self.primaryKey(sample)
      let dedupe = Self.dedupeKey(sample)
      let canonicalRecord = Self.canonicalRecordKey(
        primaryKey: primary, semanticDedupeKey: dedupe)
      if let batchExistingCanonicalRecord = batchCanonicalRecords[primary] {
        guard batchExistingCanonicalRecord == canonicalRecord else {
          throw SynchronizedReferenceStoreError.recordIdentityCollision(sample.id)
        }
        continue
      }
      batchCanonicalRecords[primary] = canonicalRecord
      guard batchDedupeKeys.insert(dedupe).inserted else { continue }
      if let existingDedupe = try index.dedupeKey(
        ledgerKey: Self.ledgerKey, primaryKey: primary)
      {
        let existingCanonicalRecord = Self.canonicalRecordKey(
          primaryKey: primary, semanticDedupeKey: existingDedupe)
        guard existingCanonicalRecord == canonicalRecord else {
          throw SynchronizedReferenceStoreError.recordIdentityCollision(sample.id)
        }
        continue
      }
      if try index.containsDedupeKey(ledgerKey: Self.ledgerKey, dedupeKey: dedupe) {
        continue
      }
      fresh.append((sample, primary, dedupe))
    }
    guard !fresh.isEmpty else { return 0 }

    let currentCount = try index.count(ledgerKey: Self.ledgerKey)
    guard currentCount <= maximumSamples - fresh.count else {
      throw SynchronizedReferenceStoreError.capacityReached
    }
    var delta = Data()
    var committedLines: [Data] = []
    committedLines.reserveCapacity(fresh.count)
    for candidate in fresh {
      var line = try Self.encodeLedgerSample(candidate.sample)
      guard !line.isEmpty, line.count + 1 <= Self.maximumRecordByteCount else {
        throw SynchronizedReferenceStoreError.recordTooLarge
      }
      line.append(0x0A)
      committedLines.append(line)
      delta.append(line)
    }

    let prior = try index.metadata(ledgerKey: Self.ledgerKey) ?? .empty
    do {
      let finalOffset = try DurableNDJSONLedger.appendDurably(
        delta, to: ledgerURL, expectedOffset: prior.byteCount, fileManager: fileManager)
      var updated = prior
      for line in committedLines { updated = updated.appending(line) }
      guard updated.byteCount == finalOffset else {
        throw SynchronizedReferenceStoreError.indexUnavailable
      }
      try index.beginDelta()
      do {
        for candidate in fresh {
          try index.insert(
            ledgerKey: Self.ledgerKey,
            primaryKey: candidate.primary,
            dedupeKey: candidate.dedupe)
        }
        try index.finish(ledgerKey: Self.ledgerKey, metadata: updated)
      } catch {
        index.cancel()
        throw error
      }
      try DurableNDJSONLedger.synchronizeDirectory(root)
    } catch {
      // The ledger is authoritative. A write may have reached a complete newline before a later
      // file or SQLite durability operation failed, so force exact disk reconciliation next time.
      recordIndex = nil
      prepared = false
      throw error
    }
    return fresh.count
  }

  func exportURL() throws -> URL {
    let values = try samples()
    guard !values.isEmpty else { throw SynchronizedReferenceStoreError.noSamples }
    let directory = fileManager.temporaryDirectory.appendingPathComponent(
      "VehicleHealthOS-ReferenceCapture", isDirectory: true)
    try DurableNDJSONLedger.ensureDirectory(directory, fileManager: fileManager)
    let url = directory.appendingPathComponent("synchronized-reference-samples.csv")
    try DurableNDJSONLedger.publishDurably(
      SynchronizedReferenceCSV.encode(values), to: url, replacingExisting: true,
      fileManager: fileManager)
    return url
  }

  private func ensuredRecordIndex() throws -> DurableLedgerIndex {
    if prepared, let recordIndex { return recordIndex }
    do {
      try DurableNDJSONLedger.ensureDirectory(root, fileManager: fileManager)
      try recoverInterruptedTailIfNeeded()
      let index = try recordIndex ?? DurableLedgerIndex(url: indexURL)
      if fileManager.fileExists(atPath: ledgerURL.path) {
        try reconcile(index)
      } else if let metadata = try index.metadata(ledgerKey: Self.ledgerKey),
        metadata.recordCount > 0 || metadata.byteCount > 0
      {
        throw SynchronizedReferenceStoreError.missingLedger
      } else {
        try index.replaceLedger(ledgerKey: Self.ledgerKey) { _ in .empty }
      }
      try DurableNDJSONLedger.synchronizeDirectory(root)
      recordIndex = index
      prepared = true
      return index
    } catch {
      recordIndex = nil
      prepared = false
      throw error
    }
  }

  private func reconcile(_ index: DurableLedgerIndex) throws {
    let fileByteCount = try DurableNDJSONLedger.fileByteCount(ledgerURL)
    if let metadata = try index.metadata(ledgerKey: Self.ledgerKey),
      metadata.byteCount <= fileByteCount,
      try index.count(ledgerKey: Self.ledgerKey) == metadata.recordCount
    {
      do {
        let prefix = try scanLedger(exactByteCount: metadata.byteCount) {
          _, primary, dedupe in
          guard
            try index.dedupeKey(ledgerKey: Self.ledgerKey, primaryKey: primary) == dedupe
          else {
            throw SynchronizedReferenceStoreError.indexUnavailable
          }
        }
        guard prefix == metadata else {
          throw SynchronizedReferenceStoreError.indexUnavailable
        }
        if metadata.byteCount < fileByteCount {
          try index.beginDelta()
          do {
            let final = try scanLedger(
              startOffset: metadata.byteCount,
              initial: metadata
            ) { _, primary, dedupe in
              try index.insert(
                ledgerKey: Self.ledgerKey, primaryKey: primary, dedupeKey: dedupe)
            }
            guard final.recordCount <= maximumSamples else {
              throw SynchronizedReferenceStoreError.capacityReached
            }
            try index.finish(ledgerKey: Self.ledgerKey, metadata: final)
          } catch {
            index.cancel()
            throw error
          }
        }
        return
      } catch let error as SynchronizedReferenceStoreError {
        if case .invalidLedgerRecord = error { throw error }
        if case .duplicateCommittedRecord = error { throw error }
        // A derived-index mismatch is recoverable by rebuilding from authoritative bytes.
      }
    }

    try index.replaceLedger(ledgerKey: Self.ledgerKey) { insert in
      let final = try scanLedger { _, primary, dedupe in try insert(primary, dedupe) }
      guard final.recordCount <= maximumSamples else {
        throw SynchronizedReferenceStoreError.capacityReached
      }
      return final
    }
  }

  @discardableResult
  private func scanLedger(
    startOffset: Int64 = 0,
    exactByteCount: Int64? = nil,
    initial: DurableLedgerMetadata = .empty,
    onSample: (SynchronizedReferenceSample, String, String) throws -> Void
  ) throws -> DurableLedgerMetadata {
    do {
      return try DurableNDJSONLedger.scan(
        ledgerURL,
        startOffset: startOffset,
        exactByteCount: exactByteCount,
        initial: initial,
        maximumLineByteCount: Self.maximumRecordByteCount
      ) { line, lineNumber in
        let sample: SynchronizedReferenceSample
        do {
          sample = try Self.decodeLedgerSample(line)
        } catch {
          throw SynchronizedReferenceStoreError.invalidLedgerRecord(lineNumber)
        }
        guard try Self.encodeLedgerSample(sample) == line else {
          throw SynchronizedReferenceStoreError.invalidLedgerRecord(lineNumber)
        }
        do {
          try onSample(sample, Self.primaryKey(sample), Self.dedupeKey(sample))
        } catch DurableLedgerIndexError.duplicateEntry {
          throw SynchronizedReferenceStoreError.duplicateCommittedRecord(lineNumber)
        }
      }
    } catch DurableNDJSONLedgerError.blankCommittedLine(let line) {
      throw SynchronizedReferenceStoreError.invalidLedgerRecord(line)
    } catch DurableNDJSONLedgerError.recordTooLarge(let line) {
      throw SynchronizedReferenceStoreError.invalidLedgerRecord(line)
    }
  }

  private func recoverInterruptedTailIfNeeded() throws {
    guard fileManager.fileExists(atPath: ledgerURL.path) else { return }
    try DurableNDJSONLedger.recoverInterruptedTailIfNeeded(
      at: ledgerURL,
      quarantineDirectory: recoveryDirectoryURL,
      artifactPrefix: "interrupted-reference-ledger",
      receiptContract: "vhos.synchronized-reference-tail-recovery",
      maximumLineByteCount: Self.maximumRecordByteCount,
      fileManager: fileManager
    ) { line, lineNumber in
      let sample: SynchronizedReferenceSample
      do {
        sample = try Self.decodeLedgerSample(line)
      } catch {
        throw SynchronizedReferenceStoreError.invalidLedgerRecord(lineNumber)
      }
      guard try Self.encodeLedgerSample(sample) == line else {
        throw SynchronizedReferenceStoreError.invalidLedgerRecord(lineNumber)
      }
    }
  }

  private static func primaryKey(_ sample: SynchronizedReferenceSample) -> String {
    sample.id.uuidString.uppercased()
  }

  /// `VHOSJSON`'s snake-case decoder maps `signal_id` to `signalId`, while the domain model's
  /// Swift property intentionally uses the acronym spelling `signalID`. Keep the on-disk wire
  /// contract canonical and restart-decodable through an exact transport representation.
  private static func encodeLedgerSample(_ sample: SynchronizedReferenceSample) throws -> Data {
    let record = SynchronizedReferenceLedgerRecord(sample)
    guard try record.sample() == sample else {
      throw SynchronizedReferenceError.invalidSample
    }
    return try VHOSJSON.encoder().encode(record)
  }

  private static func decodeLedgerSample(_ bytes: Data) throws -> SynchronizedReferenceSample {
    try VHOSJSON.decoder().decode(SynchronizedReferenceLedgerRecord.self, from: bytes).sample()
  }

  /// Exact logical record identity used for immutable-primary collision checks. The primary UUID
  /// plus the complete semantic evidence key below covers every canonical ledger field.
  private static func canonicalRecordKey(
    primaryKey: String,
    semanticDedupeKey: String
  ) -> String {
    "primary:\(lengthPrefixed(primaryKey))|evidence:\(lengthPrefixed(semanticDedupeKey))"
  }

  /// Semantic deduplication intentionally excludes only the record UUID. Every evidence-bearing
  /// field is represented with unambiguous length/option/value encodings, so two different UUIDs
  /// dedupe only when they carry the same complete observation and lineage.
  private static func dedupeKey(_ sample: SynchronizedReferenceSample) -> String {
    let valueBits = sample.value.bitPattern
    let nearestSequence = sample.nearestCANSequence.map { "some:\($0)" } ?? "none"
    return [
      "monotonic:\(sample.gatewayMonotonicMicroseconds)",
      "signal:\(lengthPrefixed(sample.signalID))",
      "value-bits:\(String(valueBits, radix: 16))",
      "unit:\(lengthPrefixed(sample.unit))",
      "source:\(lengthPrefixed(sample.source))",
      "recorded-at:\(lengthPrefixed(sample.recordedAt))",
      "nearest-can-sequence:\(nearestSequence)",
      "evidence-note:\(lengthPrefixed(sample.evidenceNote))",
    ].joined(separator: "|")
  }

  private static func lengthPrefixed(_ value: String) -> String {
    "\(value.utf8.count):\(value)"
  }
}

private struct SynchronizedReferenceLedgerRecord: Codable {
  let id: UUID
  let gatewayMonotonicMicroseconds: UInt64
  let signalId: String
  let value: Double
  let unit: String
  let source: String
  let recordedAt: String
  let nearestCanSequence: UInt64?
  let evidenceNote: String

  init(_ sample: SynchronizedReferenceSample) {
    id = sample.id
    gatewayMonotonicMicroseconds = sample.gatewayMonotonicMicroseconds
    signalId = sample.signalID
    value = sample.value
    unit = sample.unit
    source = sample.source
    recordedAt = sample.recordedAt
    nearestCanSequence = sample.nearestCANSequence
    evidenceNote = sample.evidenceNote
  }

  func sample() throws -> SynchronizedReferenceSample {
    try SynchronizedReferenceSample(
      id: id,
      gatewayMonotonicMicroseconds: gatewayMonotonicMicroseconds,
      signalID: signalId,
      value: value,
      unit: unit,
      source: source,
      recordedAt: recordedAt,
      nearestCANSequence: nearestCanSequence,
      evidenceNote: evidenceNote)
  }
}

enum SynchronizedReferenceStoreError: Error, LocalizedError {
  case capacityReached
  case duplicateCommittedRecord(Int)
  case indexUnavailable
  case invalidLedgerRecord(Int)
  case missingLedger
  case noSamples
  case recordIdentityCollision(UUID)
  case recordTooLarge

  var errorDescription: String? {
    switch self {
    case .capacityReached:
      "The synchronized reference ledger reached its bounded sample capacity."
    case .duplicateCommittedRecord(let line):
      "The append-only synchronized reference ledger repeats an identity at line \(line)."
    case .indexUnavailable:
      "The disk-backed synchronized reference index is unavailable or corrupt."
    case .invalidLedgerRecord(let line):
      "The append-only synchronized reference ledger is invalid at line \(line)."
    case .missingLedger:
      "The synchronized reference index exists, but its authoritative ledger is missing."
    case .noSamples:
      "Record at least one Techstream or standard OBD reference sample before exporting."
    case .recordIdentityCollision(let id):
      "Synchronized reference identity \(id.uuidString) conflicts with different evidence."
    case .recordTooLarge:
      "A synchronized reference record exceeds the bounded ledger record size."
    }
  }
}

struct DurableLedgerMetadata: Equatable {
  let byteCount: Int64
  let recordCount: Int
  let chain: Data

  static let empty = DurableLedgerMetadata(byteCount: 0, recordCount: 0, chain: Data())

  func appending(_ committedLine: Data) -> DurableLedgerMetadata {
    var hasher = SHA256()
    hasher.update(data: chain)
    hasher.update(data: committedLine)
    return DurableLedgerMetadata(
      byteCount: byteCount + Int64(committedLine.count),
      recordCount: recordCount + 1,
      chain: Data(hasher.finalize()))
  }
}

enum DurableNDJSONLedger {
  private static let chunkByteCount = 64 * 1_024

  private struct InterruptedTailReceipt: Codable {
    let contract: String
    let contractVersion: String
    let originalLedgerSHA256: String
    let committedPrefixByteCount: Int64
    let interruptedTailByteCount: Int64
    let interruptedTailSHA256: String

    private enum CodingKeys: String, CodingKey {
      case contract
      case contractVersion
      case originalLedgerSHA256 = "originalLedgerSha256"
      case committedPrefixByteCount
      case interruptedTailByteCount
      case interruptedTailSHA256 = "interruptedTailSha256"
    }
  }

  static func scan(
    _ url: URL,
    startOffset: Int64 = 0,
    exactByteCount: Int64? = nil,
    initial: DurableLedgerMetadata = .empty,
    maximumLineByteCount: Int,
    onLine: (Data, Int) throws -> Void
  ) throws -> DurableLedgerMetadata {
    guard startOffset >= 0, maximumLineByteCount > 1,
      exactByteCount.map({ $0 >= 0 }) ?? true,
      initial.byteCount == startOffset
    else { throw DurableNDJSONLedgerError.invalidScanRange }
    let total = try fileByteCount(url)
    let requested = exactByteCount ?? (total - startOffset)
    guard requested >= 0, startOffset <= total, requested <= total - startOffset else {
      throw DurableNDJSONLedgerError.invalidScanRange
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(startOffset))
    var remaining = requested
    var pending = Data()
    var result = initial
    while remaining > 0 {
      let chunk = try handle.read(upToCount: min(chunkByteCount, Int(remaining))) ?? Data()
      guard !chunk.isEmpty else { throw DurableNDJSONLedgerError.unexpectedEndOfFile }
      remaining -= Int64(chunk.count)
      pending.append(chunk)
      while let newline = pending.firstIndex(of: 0x0A) {
        let line = Data(pending[..<newline])
        let committedLine = Data(pending[...newline])
        pending.removeSubrange(...newline)
        guard !line.isEmpty else {
          throw DurableNDJSONLedgerError.blankCommittedLine(result.recordCount + 1)
        }
        guard committedLine.count <= maximumLineByteCount else {
          throw DurableNDJSONLedgerError.recordTooLarge(result.recordCount + 1)
        }
        try onLine(line, result.recordCount + 1)
        result = result.appending(committedLine)
      }
      guard pending.count < maximumLineByteCount else {
        throw DurableNDJSONLedgerError.recordTooLarge(result.recordCount + 1)
      }
    }
    guard pending.isEmpty else { throw DurableNDJSONLedgerError.uncommittedTail }
    return result
  }

  static func recoverInterruptedTailIfNeeded(
    at ledgerURL: URL,
    quarantineDirectory: URL,
    artifactPrefix: String,
    receiptContract: String,
    maximumLineByteCount: Int,
    fileManager: FileManager,
    validateCommittedLine: (Data, Int) throws -> Void
  ) throws {
    let originalByteCount = try fileByteCount(ledgerURL)
    guard originalByteCount > 0 else { return }
    let reader = try FileHandle(forReadingFrom: ledgerURL)
    defer { try? reader.close() }
    try reader.seek(toOffset: UInt64(originalByteCount - 1))
    guard try reader.read(upToCount: 1)?.first != 0x0A else { return }

    let prefixByteCount = try committedPrefixByteCount(
      in: reader, totalByteCount: originalByteCount)
    _ = try scan(
      ledgerURL,
      exactByteCount: prefixByteCount,
      maximumLineByteCount: maximumLineByteCount,
      onLine: validateCommittedLine)

    try ensureDirectory(quarantineDirectory, fileManager: fileManager)
    let originalDigest = try sha256(ledgerURL, offset: 0, count: originalByteCount)
    let tailByteCount = originalByteCount - prefixByteCount
    let tailDigest = try sha256(
      ledgerURL, offset: prefixByteCount, count: tailByteCount)
    let stem = "\(artifactPrefix)-\(originalDigest)"
    let originalURL = quarantineDirectory.appendingPathComponent("\(stem)-original.ndjson")
    let tailURL = quarantineDirectory.appendingPathComponent("\(stem)-tail.bin")
    let receiptURL = quarantineDirectory.appendingPathComponent("\(stem)-receipt.json")
    try copyPreserved(
      from: ledgerURL, offset: 0, count: originalByteCount,
      expectedDigest: originalDigest, to: originalURL, fileManager: fileManager)
    try copyPreserved(
      from: ledgerURL, offset: prefixByteCount, count: tailByteCount,
      expectedDigest: tailDigest, to: tailURL, fileManager: fileManager)
    let receipt = InterruptedTailReceipt(
      contract: receiptContract,
      contractVersion: "1.0.0",
      originalLedgerSHA256: originalDigest,
      committedPrefixByteCount: prefixByteCount,
      interruptedTailByteCount: tailByteCount,
      interruptedTailSHA256: tailDigest)
    try writePreserved(
      try VHOSJSON.encoder().encode(receipt), to: receiptURL, fileManager: fileManager)

    let temporary = ledgerURL.deletingLastPathComponent().appendingPathComponent(
      ".\(ledgerURL.lastPathComponent).\(UUID().uuidString.lowercased()).recovered-prefix")
    var published = false
    defer { if !published { try? fileManager.removeItem(at: temporary) } }
    try copyRange(
      from: ledgerURL, offset: 0, count: prefixByteCount, to: temporary,
      fileManager: fileManager)
    try synchronizeFile(temporary)
    guard rename(temporary.path, ledgerURL.path) == 0 else {
      throw DurableNDJSONLedgerError.durableWriteFailed
    }
    published = true
    try synchronizeFile(ledgerURL)
    try synchronizeDirectory(ledgerURL.deletingLastPathComponent())
  }

  static func appendDurably(
    _ bytes: Data,
    to url: URL,
    expectedOffset: Int64,
    fileManager: FileManager
  ) throws -> Int64 {
    guard !bytes.isEmpty, expectedOffset >= 0 else {
      throw DurableNDJSONLedgerError.invalidScanRange
    }
    let directory = url.deletingLastPathComponent()
    try ensureDirectory(directory, fileManager: fileManager)
    if !fileManager.fileExists(atPath: url.path) {
      guard expectedOffset == 0,
        fileManager.createFile(atPath: url.path, contents: nil)
      else { throw DurableNDJSONLedgerError.durableWriteFailed }
      try synchronizeFile(url)
      try synchronizeDirectory(directory)
    }
    guard try fileByteCount(url) == expectedOffset else {
      throw DurableNDJSONLedgerError.appendOffsetMismatch
    }
    let handle = try FileHandle(forWritingTo: url)
    do {
      try handle.seek(toOffset: UInt64(expectedOffset))
      try handle.write(contentsOf: bytes)
      try handle.synchronize()
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }
    try synchronizeFile(url)
    try synchronizeDirectory(directory)
    let final = try fileByteCount(url)
    guard final == expectedOffset + Int64(bytes.count) else {
      throw DurableNDJSONLedgerError.durableWriteFailed
    }
    return final
  }

  static func publishDurably(
    _ bytes: Data,
    to url: URL,
    replacingExisting: Bool,
    fileManager: FileManager
  ) throws {
    let directory = url.deletingLastPathComponent()
    try ensureDirectory(directory, fileManager: fileManager)
    let temporary = directory.appendingPathComponent(
      ".\(url.lastPathComponent).\(UUID().uuidString.lowercased()).durable-write")
    guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
      throw DurableNDJSONLedgerError.durableWriteFailed
    }
    var published = false
    defer { if !published { try? fileManager.removeItem(at: temporary) } }
    let handle = try FileHandle(forWritingTo: temporary)
    do {
      try handle.write(contentsOf: bytes)
      try handle.synchronize()
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }
    try synchronizeFile(temporary)
    if !replacingExisting, fileManager.fileExists(atPath: url.path) {
      throw DurableNDJSONLedgerError.recoveryArtifactConflict(url.lastPathComponent)
    }
    guard rename(temporary.path, url.path) == 0 else {
      throw DurableNDJSONLedgerError.durableWriteFailed
    }
    published = true
    try synchronizeFile(url)
    try synchronizeDirectory(directory)
  }

  static func ensureDirectory(_ url: URL, fileManager: FileManager) throws {
    let existed = fileManager.fileExists(atPath: url.path)
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    if !existed {
      let parent = url.deletingLastPathComponent()
      if parent.path != url.path { try synchronizeDirectory(parent) }
    }
    try synchronizeDirectory(url)
  }

  static func synchronizeFile(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw DurableNDJSONLedgerError.durableWriteFailed }
    defer { close(descriptor) }
    if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
      throw DurableNDJSONLedgerError.durableWriteFailed
    }
  }

  static func synchronizeDirectory(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw DurableNDJSONLedgerError.durableWriteFailed }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else {
      throw DurableNDJSONLedgerError.durableWriteFailed
    }
  }

  static func fileByteCount(_ url: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let size = attributes[.size] as? NSNumber else {
      throw DurableNDJSONLedgerError.unexpectedEndOfFile
    }
    return size.int64Value
  }

  static func canonicalDigest(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  private static func committedPrefixByteCount(
    in handle: FileHandle, totalByteCount: Int64
  ) throws -> Int64 {
    var searchEnd = totalByteCount
    while searchEnd > 0 {
      let count = min(Int64(chunkByteCount), searchEnd)
      let offset = searchEnd - count
      try handle.seek(toOffset: UInt64(offset))
      let chunk = try handle.read(upToCount: Int(count)) ?? Data()
      guard chunk.count == Int(count) else {
        throw DurableNDJSONLedgerError.unexpectedEndOfFile
      }
      if let newline = chunk.lastIndex(of: 0x0A) {
        return offset + Int64(newline) + 1
      }
      searchEnd = offset
    }
    return 0
  }

  private static func copyPreserved(
    from source: URL,
    offset: Int64,
    count: Int64,
    expectedDigest: String,
    to destination: URL,
    fileManager: FileManager
  ) throws {
    if fileManager.fileExists(atPath: destination.path) {
      guard try fileByteCount(destination) == count,
        try sha256(destination, offset: 0, count: count) == expectedDigest
      else {
        throw DurableNDJSONLedgerError.recoveryArtifactConflict(
          destination.lastPathComponent)
      }
      return
    }
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString.lowercased()).preserved")
    defer { try? fileManager.removeItem(at: temporary) }
    try copyRange(
      from: source, offset: offset, count: count, to: temporary,
      fileManager: fileManager)
    guard try sha256(temporary, offset: 0, count: count) == expectedDigest else {
      throw DurableNDJSONLedgerError.recoveryArtifactConflict(destination.lastPathComponent)
    }
    try fileManager.moveItem(at: temporary, to: destination)
    try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
    try synchronizeFile(destination)
    try synchronizeDirectory(destination.deletingLastPathComponent())
  }

  private static func copyRange(
    from source: URL,
    offset: Int64,
    count: Int64,
    to destination: URL,
    fileManager: FileManager
  ) throws {
    guard offset >= 0, count >= 0,
      fileManager.createFile(atPath: destination.path, contents: nil)
    else { throw DurableNDJSONLedgerError.durableWriteFailed }
    let reader = try FileHandle(forReadingFrom: source)
    let writer = try FileHandle(forWritingTo: destination)
    defer {
      try? reader.close()
      try? writer.close()
    }
    try reader.seek(toOffset: UInt64(offset))
    var remaining = count
    while remaining > 0 {
      let chunk = try reader.read(upToCount: min(chunkByteCount, Int(remaining))) ?? Data()
      guard !chunk.isEmpty else { throw DurableNDJSONLedgerError.unexpectedEndOfFile }
      try writer.write(contentsOf: chunk)
      remaining -= Int64(chunk.count)
    }
    try writer.synchronize()
  }

  private static func writePreserved(
    _ bytes: Data, to url: URL, fileManager: FileManager
  ) throws {
    if fileManager.fileExists(atPath: url.path) {
      guard try Data(contentsOf: url, options: [.mappedIfSafe]) == bytes else {
        throw DurableNDJSONLedgerError.recoveryArtifactConflict(url.lastPathComponent)
      }
      return
    }
    try publishDurably(bytes, to: url, replacingExisting: false, fileManager: fileManager)
  }

  private static func sha256(_ url: URL, offset: Int64, count: Int64) throws -> String {
    guard offset >= 0, count >= 0 else { throw DurableNDJSONLedgerError.invalidScanRange }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(offset))
    var remaining = count
    var hasher = SHA256()
    while remaining > 0 {
      let chunk = try handle.read(upToCount: min(chunkByteCount, Int(remaining))) ?? Data()
      guard !chunk.isEmpty else { throw DurableNDJSONLedgerError.unexpectedEndOfFile }
      hasher.update(data: chunk)
      remaining -= Int64(chunk.count)
    }
    return Data(hasher.finalize()).hexadecimalString
  }
}

enum DurableNDJSONLedgerError: Error, LocalizedError {
  case appendOffsetMismatch
  case blankCommittedLine(Int)
  case durableWriteFailed
  case invalidScanRange
  case recordTooLarge(Int)
  case recoveryArtifactConflict(String)
  case uncommittedTail
  case unexpectedEndOfFile

  var errorDescription: String? {
    switch self {
    case .appendOffsetMismatch:
      "The append-only ledger changed outside its serialized persistence owner."
    case .blankCommittedLine(let line):
      "The append-only ledger contains a blank committed record at line \(line)."
    case .durableWriteFailed:
      "The append-only ledger could not complete a durable file-system commit."
    case .invalidScanRange:
      "The append-only ledger scan range is invalid."
    case .recordTooLarge(let line):
      "The append-only ledger record at line \(line) exceeds its bounded size."
    case .recoveryArtifactConflict(let name):
      "Interrupted ledger recovery artifact \(name) conflicts with preserved bytes."
    case .uncommittedTail:
      "The append-only ledger contains an unterminated final record."
    case .unexpectedEndOfFile:
      "The append-only ledger ended before the requested bytes were read."
    }
  }
}

final class DurableLedgerIndex {
  private static let schemaVersion = 1
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  private let database: OpaquePointer
  private var transactionActive = false

  init(url: URL) throws {
    var connection: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &connection, flags, nil) == SQLITE_OK,
      let connection
    else {
      if let connection { sqlite3_close(connection) }
      throw DurableLedgerIndexError.unavailable
    }
    database = connection
    do {
      try execute("PRAGMA journal_mode=WAL")
      try execute("PRAGMA synchronous=FULL")
      try execute("PRAGMA foreign_keys=ON")
      try execute("PRAGMA wal_autocheckpoint=1")
      try execute(
        "CREATE TABLE IF NOT EXISTS ledger_metadata (ledger_key TEXT PRIMARY KEY NOT NULL COLLATE BINARY, byte_count INTEGER NOT NULL CHECK(byte_count >= 0), record_count INTEGER NOT NULL CHECK(record_count >= 0), chain_sha256 TEXT NOT NULL COLLATE BINARY CHECK(length(chain_sha256) IN (0, 64)))"
      )
      try execute(
        "CREATE TABLE IF NOT EXISTS ledger_records (ledger_key TEXT NOT NULL COLLATE BINARY, primary_key TEXT NOT NULL COLLATE BINARY, dedupe_key TEXT NOT NULL COLLATE BINARY, PRIMARY KEY(ledger_key, primary_key), UNIQUE(ledger_key, dedupe_key), FOREIGN KEY(ledger_key) REFERENCES ledger_metadata(ledger_key) DEFERRABLE INITIALLY DEFERRED)"
      )
      let version = try scalarInt("PRAGMA user_version") ?? 0
      if version == 0 {
        try execute("PRAGMA user_version=\(Self.schemaVersion)")
      } else if version != Self.schemaVersion {
        throw DurableLedgerIndexError.unavailable
      }
      guard try scalarText("PRAGMA quick_check") == "ok" else {
        throw DurableLedgerIndexError.unavailable
      }
    } catch {
      sqlite3_close(connection)
      throw error
    }
  }

  deinit { sqlite3_close(database) }

  func metadata(ledgerKey: String) throws -> DurableLedgerMetadata? {
    let statement = try prepare(
      "SELECT byte_count, record_count, chain_sha256 FROM ledger_metadata WHERE ledger_key = ? LIMIT 1"
    )
    defer { sqlite3_finalize(statement) }
    try bind(ledgerKey, to: 1, in: statement)
    let result = sqlite3_step(statement)
    if result == SQLITE_DONE { return nil }
    guard result == SQLITE_ROW,
      let byteCount = Int64(exactly: sqlite3_column_int64(statement, 0)),
      let recordCount = Int(exactly: sqlite3_column_int64(statement, 1)),
      let chain = try text(column: 2, in: statement).hexadecimalData,
      byteCount >= 0, recordCount >= 0,
      recordCount == 0 ? chain.isEmpty : chain.count == 32
    else { throw DurableLedgerIndexError.unavailable }
    return DurableLedgerMetadata(
      byteCount: byteCount, recordCount: recordCount, chain: chain)
  }

  func count(ledgerKey: String) throws -> Int {
    let statement = try prepare(
      "SELECT COUNT(*) FROM ledger_records WHERE ledger_key = ?")
    defer { sqlite3_finalize(statement) }
    try bind(ledgerKey, to: 1, in: statement)
    guard sqlite3_step(statement) == SQLITE_ROW,
      let value = Int(exactly: sqlite3_column_int64(statement, 0)), value >= 0
    else { throw DurableLedgerIndexError.unavailable }
    return value
  }

  func dedupeKey(ledgerKey: String, primaryKey: String) throws -> String? {
    let statement = try prepare(
      "SELECT dedupe_key FROM ledger_records WHERE ledger_key = ? AND primary_key = ? LIMIT 1"
    )
    defer { sqlite3_finalize(statement) }
    try bind(ledgerKey, to: 1, in: statement)
    try bind(primaryKey, to: 2, in: statement)
    let result = sqlite3_step(statement)
    if result == SQLITE_DONE { return nil }
    guard result == SQLITE_ROW else { throw DurableLedgerIndexError.unavailable }
    return try text(column: 0, in: statement)
  }

  func containsDedupeKey(ledgerKey: String, dedupeKey: String) throws -> Bool {
    let statement = try prepare(
      "SELECT 1 FROM ledger_records WHERE ledger_key = ? AND dedupe_key = ? LIMIT 1")
    defer { sqlite3_finalize(statement) }
    try bind(ledgerKey, to: 1, in: statement)
    try bind(dedupeKey, to: 2, in: statement)
    let result = sqlite3_step(statement)
    if result == SQLITE_ROW { return true }
    guard result == SQLITE_DONE else { throw DurableLedgerIndexError.unavailable }
    return false
  }

  func beginDelta() throws {
    guard !transactionActive else { throw DurableLedgerIndexError.unavailable }
    try execute("BEGIN IMMEDIATE")
    transactionActive = true
  }

  func insert(ledgerKey: String, primaryKey: String, dedupeKey: String) throws {
    guard transactionActive, !ledgerKey.isEmpty, !primaryKey.isEmpty, !dedupeKey.isEmpty else {
      throw DurableLedgerIndexError.unavailable
    }
    let statement = try prepare(
      "INSERT INTO ledger_records(ledger_key, primary_key, dedupe_key) VALUES(?, ?, ?)")
    defer { sqlite3_finalize(statement) }
    try bind(ledgerKey, to: 1, in: statement)
    try bind(primaryKey, to: 2, in: statement)
    try bind(dedupeKey, to: 3, in: statement)
    let result = sqlite3_step(statement)
    if result == SQLITE_CONSTRAINT { throw DurableLedgerIndexError.duplicateEntry }
    guard result == SQLITE_DONE else { throw DurableLedgerIndexError.unavailable }
  }

  func finish(ledgerKey: String, metadata: DurableLedgerMetadata) throws {
    guard transactionActive else { throw DurableLedgerIndexError.unavailable }
    do {
      try setMetadata(ledgerKey: ledgerKey, metadata: metadata)
      try execute("COMMIT")
      transactionActive = false
    } catch {
      try? execute("ROLLBACK")
      transactionActive = false
      throw error
    }
  }

  func cancel() {
    guard transactionActive else { return }
    try? execute("ROLLBACK")
    transactionActive = false
  }

  /// Rebuilds one ledger in a single transaction without materializing identities in memory.
  func replaceLedger(
    ledgerKey: String,
    build: (_ insert: (String, String) throws -> Void) throws -> DurableLedgerMetadata
  ) throws {
    try beginDelta()
    do {
      try deleteLedger(ledgerKey)
      // Publish an empty parent row so the deferred foreign key is valid for an empty ledger too.
      try setMetadata(ledgerKey: ledgerKey, metadata: .empty)
      let final = try build { primary, dedupe in
        try self.insert(ledgerKey: ledgerKey, primaryKey: primary, dedupeKey: dedupe)
      }
      try setMetadata(ledgerKey: ledgerKey, metadata: final)
      try execute("COMMIT")
      transactionActive = false
    } catch {
      try? execute("ROLLBACK")
      transactionActive = false
      throw error
    }
  }

  private func deleteLedger(_ ledgerKey: String) throws {
    let records = try prepare("DELETE FROM ledger_records WHERE ledger_key = ?")
    defer { sqlite3_finalize(records) }
    try bind(ledgerKey, to: 1, in: records)
    guard sqlite3_step(records) == SQLITE_DONE else {
      throw DurableLedgerIndexError.unavailable
    }
    let metadata = try prepare("DELETE FROM ledger_metadata WHERE ledger_key = ?")
    defer { sqlite3_finalize(metadata) }
    try bind(ledgerKey, to: 1, in: metadata)
    guard sqlite3_step(metadata) == SQLITE_DONE else {
      throw DurableLedgerIndexError.unavailable
    }
  }

  private func setMetadata(ledgerKey: String, metadata: DurableLedgerMetadata) throws {
    guard metadata.byteCount >= 0, metadata.recordCount >= 0,
      metadata.recordCount == 0 ? metadata.chain.isEmpty : metadata.chain.count == 32
    else { throw DurableLedgerIndexError.unavailable }
    let statement = try prepare(
      "INSERT INTO ledger_metadata(ledger_key, byte_count, record_count, chain_sha256) VALUES(?, ?, ?, ?) ON CONFLICT(ledger_key) DO UPDATE SET byte_count=excluded.byte_count, record_count=excluded.record_count, chain_sha256=excluded.chain_sha256"
    )
    defer { sqlite3_finalize(statement) }
    try bind(ledgerKey, to: 1, in: statement)
    guard sqlite3_bind_int64(statement, 2, sqlite3_int64(metadata.byteCount)) == SQLITE_OK,
      sqlite3_bind_int64(statement, 3, sqlite3_int64(metadata.recordCount)) == SQLITE_OK
    else { throw DurableLedgerIndexError.unavailable }
    try bind(metadata.chain.hexadecimalString, to: 4, in: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw DurableLedgerIndexError.unavailable
    }
  }

  private func scalarText(_ sql: String) throws -> String? {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return try text(column: 0, in: statement)
  }

  private func scalarInt(_ sql: String) throws -> Int64? {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return Int64(sqlite3_column_int64(statement, 0))
  }

  private func execute(_ sql: String) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw DurableLedgerIndexError.unavailable
    }
  }

  private func prepare(_ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw DurableLedgerIndexError.unavailable }
    return statement
  }

  private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) throws {
    let result = value.withCString { pointer in
      sqlite3_bind_text(
        statement, index, pointer, Int32(value.lengthOfBytes(using: .utf8)), Self.transient)
    }
    guard result == SQLITE_OK else { throw DurableLedgerIndexError.unavailable }
  }

  private func text(column: Int32, in statement: OpaquePointer) throws -> String {
    guard let pointer = sqlite3_column_text(statement, column) else {
      throw DurableLedgerIndexError.unavailable
    }
    return String(
      decoding: UnsafeBufferPointer(
        start: pointer, count: Int(sqlite3_column_bytes(statement, column))),
      as: UTF8.self)
  }
}

enum DurableLedgerIndexError: Error, LocalizedError {
  case duplicateEntry
  case unavailable

  var errorDescription: String? {
    switch self {
    case .duplicateEntry:
      "The durable ledger contains a duplicate committed identity."
    case .unavailable:
      "The durable SQLite ledger index is unavailable or corrupt."
    }
  }
}

extension Data {
  fileprivate var hexadecimalString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}

extension String {
  fileprivate var hexadecimalData: Data? {
    guard count.isMultiple(of: 2) else { return nil }
    var bytes = Data()
    bytes.reserveCapacity(count / 2)
    var index = startIndex
    while index < endIndex {
      let next = self.index(index, offsetBy: 2)
      guard let byte = UInt8(self[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    return bytes
  }
}
