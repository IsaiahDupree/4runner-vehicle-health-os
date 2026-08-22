import Foundation

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
  public static func load<Record: Decodable>(
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
        let record = try decoder.decode(Record.self, from: Data(line))
        try validate(record)
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

    try fileManager.createDirectory(
      at: quarantineDirectory,
      withIntermediateDirectories: true)
    let quarantineURL = quarantineDirectory.appendingPathComponent(
      "\(url.lastPathComponent).\(UUID().uuidString.lowercased()).truncated-tail")
    try uncommittedTail.write(to: quarantineURL, options: [.atomic])
    try committedBytes.write(to: url, options: [.atomic])

    return AppendOnlyNDJSONLoadResult(
      records: records,
      recovery: AppendOnlyNDJSONTailRecovery(
        sourceFileName: url.lastPathComponent,
        quarantineURL: quarantineURL,
        quarantinedByteCount: uncommittedTail.count,
        retainedRecordCount: records.count))
  }
}
