import Foundation
#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Evidence retained when an interrupted append leaves bytes after the ledger's final commit
/// boundary. NDJSON records are committed only by a trailing line-feed byte.
public struct AppendOnlyNDJSONTailRecovery: Equatable, Sendable {
  public let sourceFileName: String
  public let quarantineURL: URL
  public let quarantinedByteCount: Int
  public let retainedRecordCount: Int

  public init(
    sourceFileName: String,
    quarantineURL: URL,
    quarantinedByteCount: Int,
    retainedRecordCount: Int
  ) {
    self.sourceFileName = sourceFileName
    self.quarantineURL = quarantineURL
    self.quarantinedByteCount = quarantinedByteCount
    self.retainedRecordCount = retainedRecordCount
  }
}

public struct AppendOnlyNDJSONLoadResult<Record> {
  public let records: [Record]
  public let recovery: AppendOnlyNDJSONTailRecovery?

  public init(records: [Record], recovery: AppendOnlyNDJSONTailRecovery?) {
    self.records = records
    self.recovery = recovery
  }
}

public enum AppendOnlyNDJSONLedgerError: Error, Equatable, LocalizedError {
  case invalidCommittedRecord(fileName: String, line: Int)

  public var errorDescription: String? {
    switch self {
    case .invalidCommittedRecord(let fileName, let line):
      "The committed append-only ledger \(fileName) is invalid at line \(line)."
    }
  }
}

/// Reads a newline-committed NDJSON ledger and repairs only an interrupted final append.
///
/// A line-feed is the commit boundary. Bytes following the final line-feed are never decoded as
/// evidence, even when they happen to form valid JSON. They are atomically quarantined before the
/// source ledger is atomically rewritten to its exact committed prefix. Invalid committed records
/// fail closed and leave both the source ledger and quarantine directory unchanged.
public enum AppendOnlyNDJSONLedger {
  public static func load<Record: Codable>(
    from url: URL,
    quarantineDirectory: URL,
    fileManager: FileManager = .default,
    decoder: JSONDecoder = VHOSJSON.decoder(),
    validate: (Record) throws -> Void
  ) throws -> AppendOnlyNDJSONLoadResult<Record> {
    guard fileManager.fileExists(atPath: url.path) else {
      return AppendOnlyNDJSONLoadResult(records: [], recovery: nil)
    }

    let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard !bytes.isEmpty else {
      return AppendOnlyNDJSONLoadResult(records: [], recovery: nil)
    }

    let committedByteCount: Int
    let uncommittedTail: Data?
    if bytes.last == 0x0A {
      committedByteCount = bytes.count
      uncommittedTail = nil
    } else if let finalLineFeed = bytes.lastIndex(of: 0x0A) {
      let committedEnd = bytes.index(after: finalLineFeed)
      committedByteCount = bytes.distance(from: bytes.startIndex, to: committedEnd)
      uncommittedTail = Data(bytes[committedEnd...])
    } else {
      committedByteCount = 0
      uncommittedTail = bytes
    }

    let committedBytes = Data(bytes.prefix(committedByteCount))
    var committedLines = committedBytes.split(
      separator: 0x0A,
      omittingEmptySubsequences: false)
    if committedBytes.last == 0x0A, committedLines.last?.isEmpty == true {
      committedLines.removeLast()
    }

    let records: [Record] = try committedLines.enumerated().map { index, line in
      guard !line.isEmpty else {
        throw AppendOnlyNDJSONLedgerError.invalidCommittedRecord(
          fileName: url.lastPathComponent,
          line: index + 1)
      }
      do {
        let lineBytes = Data(line)
        let record = try decoder.decode(Record.self, from: lineBytes)
        try validate(record)
        guard try VHOSJSON.encoder().encode(record) == lineBytes else {
          throw AppendOnlyNDJSONLedgerError.invalidCommittedRecord(
            fileName: url.lastPathComponent,
            line: index + 1)
        }
        return record
      } catch {
        throw AppendOnlyNDJSONLedgerError.invalidCommittedRecord(
          fileName: url.lastPathComponent,
          line: index + 1)
      }
    }

    guard let uncommittedTail, !uncommittedTail.isEmpty else {
      return AppendOnlyNDJSONLoadResult(records: records, recovery: nil)
    }

    try DurableEvidenceFile.ensureDirectory(
      quarantineDirectory,
      fileManager: fileManager)
    let quarantineURL = quarantineDirectory.appendingPathComponent(
      "\(url.lastPathComponent).\(UUID().uuidString.lowercased()).truncated-tail")
    // Preserve and durably publish the exact interrupted bytes before replacing the source with
    // its committed prefix. A power loss can leave either the original source or the recovered
    // source plus quarantine, but never an acknowledged tail with no preserved copy.
    try DurableEvidenceFile.replace(
      uncommittedTail,
      at: quarantineURL,
      fileManager: fileManager)
    try DurableEvidenceFile.replace(
      committedBytes,
      at: url,
      fileManager: fileManager)

    return AppendOnlyNDJSONLoadResult(
      records: records,
      recovery: AppendOnlyNDJSONTailRecovery(
        sourceFileName: url.lastPathComponent,
        quarantineURL: quarantineURL,
        quarantinedByteCount: uncommittedTail.count,
        retainedRecordCount: records.count))
  }
}

/// Minimal file + parent-directory durability primitives shared by append-only evidence ledgers.
public enum DurableEvidenceFile {
  public static func ensureDirectory(
    _ directory: URL,
    fileManager: FileManager = .default
  ) throws {
    guard !fileManager.fileExists(atPath: directory.path) else { return }
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try synchronizeDirectory(directory.deletingLastPathComponent())
  }

  public static func appendCommittedLine(
    _ canonicalRecord: Data,
    to url: URL,
    fileManager: FileManager = .default
  ) throws {
    guard !canonicalRecord.isEmpty, !canonicalRecord.contains(0x0A) else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    var committed = canonicalRecord
    committed.append(0x0A)
    if !fileManager.fileExists(atPath: url.path) {
      try replace(committed, at: url, fileManager: fileManager)
      return
    }
    let handle = try FileHandle(forWritingTo: url)
    do {
      try handle.seekToEnd()
      try handle.write(contentsOf: committed)
      try synchronizeFile(handle.fileDescriptor)
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }
  }

  public static func replace(
    _ bytes: Data,
    at url: URL,
    fileManager: FileManager = .default
  ) throws {
    let directory = url.deletingLastPathComponent()
    try ensureDirectory(directory, fileManager: fileManager)
    let temporary = directory.appendingPathComponent(
      ".\(url.lastPathComponent).\(UUID().uuidString.lowercased()).durable-write")
    guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    do {
      let handle = try FileHandle(forWritingTo: temporary)
      do {
        try handle.write(contentsOf: bytes)
        try synchronizeFile(handle.fileDescriptor)
        try handle.close()
      } catch {
        try? handle.close()
        throw error
      }
      guard rename(temporary.path, url.path) == 0 else {
        throw CocoaError(.fileWriteUnknown)
      }
      try synchronizeDirectory(directory)
    } catch {
      try? fileManager.removeItem(at: temporary)
      throw error
    }
  }

  private static func synchronizeFile(_ descriptor: Int32) throws {
    #if canImport(Darwin)
      if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
        throw CocoaError(.fileWriteUnknown)
      }
    #else
      guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    #endif
  }

  private static func synchronizeDirectory(_ directory: URL) throws {
    let descriptor = open(directory.path, O_RDONLY)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
  }
}
