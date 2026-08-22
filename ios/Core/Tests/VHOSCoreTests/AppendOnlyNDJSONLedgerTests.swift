import Foundation
import Testing

@testable import VHOSCore

private struct LedgerTestRecord: Codable, Equatable {
  let sequence: Int
  let value: String
}

private enum LedgerTestValidationError: Error {
  case invalidSequence
}

@Test func appendOnlyLedgerRecoversCommittedRecordsAndQuarantinesTruncatedTail() throws {
  let fixture = try makeLedgerFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let records = [
    LedgerTestRecord(sequence: 1, value: "first"),
    LedgerTestRecord(sequence: 2, value: "second"),
  ]
  let committed = try committedLedgerBytes(records)
  let truncatedTail = Data(#"{"sequence":3,"value":"interrupted""#.utf8)
  var source = committed
  source.append(truncatedTail)
  try source.write(to: fixture.ledger, options: [.atomic])

  let result: AppendOnlyNDJSONLoadResult<LedgerTestRecord> =
    try AppendOnlyNDJSONLedger.load(
      from: fixture.ledger,
      quarantineDirectory: fixture.quarantine,
      validate: { _ in })

  #expect(result.records == records)
  let recovery = try #require(result.recovery)
  #expect(recovery.sourceFileName == fixture.ledger.lastPathComponent)
  #expect(recovery.quarantinedByteCount == truncatedTail.count)
  #expect(recovery.retainedRecordCount == records.count)
  #expect(try Data(contentsOf: fixture.ledger) == committed)
  #expect(try Data(contentsOf: recovery.quarantineURL) == truncatedTail)

  let secondRead: AppendOnlyNDJSONLoadResult<LedgerTestRecord> =
    try AppendOnlyNDJSONLedger.load(
      from: fixture.ledger,
      quarantineDirectory: fixture.quarantine,
      validate: { _ in })
  #expect(secondRead.records == records)
  #expect(secondRead.recovery == nil)
}

@Test func appendOnlyLedgerRejectsInteriorCorruptionWithoutRepairOrQuarantine() throws {
  let fixture = try makeLedgerFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  var source = try committedLedgerBytes([LedgerTestRecord(sequence: 1, value: "first")])
  source.append(Data("{invalid-json}\n".utf8))
  source.append(Data(#"{"sequence":3"#.utf8))
  try source.write(to: fixture.ledger, options: [.atomic])

  do {
    let _: AppendOnlyNDJSONLoadResult<LedgerTestRecord> =
      try AppendOnlyNDJSONLedger.load(
        from: fixture.ledger,
        quarantineDirectory: fixture.quarantine,
        validate: { _ in })
    Issue.record("Expected committed interior corruption to fail closed")
  } catch let error as AppendOnlyNDJSONLedgerError {
    #expect(
      error
        == .invalidCommittedRecord(fileName: fixture.ledger.lastPathComponent, line: 2))
  }

  #expect(try Data(contentsOf: fixture.ledger) == source)
  #expect(!FileManager.default.fileExists(atPath: fixture.quarantine.path))
}

@Test func appendOnlyLedgerDoesNotAcceptValidJSONWithoutCommitBoundary() throws {
  let fixture = try makeLedgerFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let first = LedgerTestRecord(sequence: 1, value: "committed")
  let uncommitted = LedgerTestRecord(sequence: 2, value: "complete-looking")
  let committed = try committedLedgerBytes([first])
  let uncommittedBytes = try VHOSJSON.encoder().encode(uncommitted)
  var source = committed
  source.append(uncommittedBytes)
  try source.write(to: fixture.ledger, options: [.atomic])

  let result: AppendOnlyNDJSONLoadResult<LedgerTestRecord> =
    try AppendOnlyNDJSONLedger.load(
      from: fixture.ledger,
      quarantineDirectory: fixture.quarantine,
      validate: { _ in })

  #expect(result.records == [first])
  let recovery = try #require(result.recovery)
  #expect(try Data(contentsOf: recovery.quarantineURL) == uncommittedBytes)
  #expect(try Data(contentsOf: fixture.ledger) == committed)
}

@Test func appendOnlyLedgerRejectsInvalidTerminatedFinalRecord() throws {
  let fixture = try makeLedgerFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  var source = try committedLedgerBytes([LedgerTestRecord(sequence: 1, value: "first")])
  source.append(Data("{invalid-json}\n".utf8))
  try source.write(to: fixture.ledger, options: [.atomic])

  do {
    let _: AppendOnlyNDJSONLoadResult<LedgerTestRecord> =
      try AppendOnlyNDJSONLedger.load(
        from: fixture.ledger,
        quarantineDirectory: fixture.quarantine,
        validate: { _ in })
    Issue.record("Expected an invalid committed final record to fail closed")
  } catch let error as AppendOnlyNDJSONLedgerError {
    #expect(
      error
        == .invalidCommittedRecord(fileName: fixture.ledger.lastPathComponent, line: 2))
  }

  #expect(try Data(contentsOf: fixture.ledger) == source)
  #expect(!FileManager.default.fileExists(atPath: fixture.quarantine.path))
}

@Test func appendOnlyLedgerRejectsSemanticallyInvalidInteriorRecord() throws {
  let fixture = try makeLedgerFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let committedRecords = [
    LedgerTestRecord(sequence: 1, value: "first"),
    LedgerTestRecord(sequence: 0, value: "invalid-sequence"),
  ]
  var source = try committedLedgerBytes(committedRecords)
  source.append(Data(#"{"sequence":3"#.utf8))
  try source.write(to: fixture.ledger, options: [.atomic])

  do {
    let _: AppendOnlyNDJSONLoadResult<LedgerTestRecord> =
      try AppendOnlyNDJSONLedger.load(
        from: fixture.ledger,
        quarantineDirectory: fixture.quarantine,
        validate: { record in
          guard record.sequence > 0 else { throw LedgerTestValidationError.invalidSequence }
        })
    Issue.record("Expected an invalid committed domain record to fail closed")
  } catch let error as AppendOnlyNDJSONLedgerError {
    #expect(
      error
        == .invalidCommittedRecord(fileName: fixture.ledger.lastPathComponent, line: 2))
  }

  #expect(try Data(contentsOf: fixture.ledger) == source)
  #expect(!FileManager.default.fileExists(atPath: fixture.quarantine.path))
}

private func makeLedgerFixture() throws -> (root: URL, ledger: URL, quarantine: URL) {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "vhos-append-only-ledger-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return (
    root,
    root.appendingPathComponent("evidence.ndjson"),
    root.appendingPathComponent("Quarantine", isDirectory: true)
  )
}

private func committedLedgerBytes(_ records: [LedgerTestRecord]) throws -> Data {
  try records.reduce(into: Data()) { bytes, record in
    bytes.append(try VHOSJSON.encoder().encode(record))
    bytes.append(0x0A)
  }
}
