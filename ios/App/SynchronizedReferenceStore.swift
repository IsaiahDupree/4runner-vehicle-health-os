import Foundation
import VHOSCore

final class SynchronizedReferenceStore {
  private let fileManager: FileManager
  private let ledgerURL: URL
  private let maximumSamples = 20_000

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    let directory = support.appendingPathComponent("VHOSSynchronizedReferences/v1", isDirectory: true)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    ledgerURL = directory.appendingPathComponent("reference-samples.ndjson")
  }

  func samples() throws -> [SynchronizedReferenceSample] {
    guard fileManager.fileExists(atPath: ledgerURL.path) else { return [] }
    return try Data(contentsOf: ledgerURL, options: [.mappedIfSafe]).split(separator: 0x0A)
      .enumerated().map { index, line in
        do {
          return try VHOSJSON.decoder().decode(SynchronizedReferenceSample.self, from: Data(line))
        } catch {
          throw SynchronizedReferenceStoreError.invalidLedgerRecord(index + 1)
        }
      }
  }

  @discardableResult
  func append(_ sample: SynchronizedReferenceSample) throws -> Bool {
    let existing = try samples()
    guard !existing.contains(where: {
      $0.id == sample.id
        || ($0.gatewayMonotonicMicroseconds == sample.gatewayMonotonicMicroseconds
          && $0.signalID == sample.signalID && $0.source == sample.source
          && $0.value == sample.value)
    }) else { return false }
    guard existing.count < maximumSamples else {
      throw SynchronizedReferenceStoreError.capacityReached
    }
    var record = try VHOSJSON.encoder().encode(sample)
    record.append(0x0A)
    if !fileManager.fileExists(atPath: ledgerURL.path) {
      try record.write(to: ledgerURL, options: [.atomic])
    } else {
      let handle = try FileHandle(forWritingTo: ledgerURL)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: record)
      try handle.synchronize()
    }
    return true
  }

  func exportURL() throws -> URL {
    let values = try samples()
    guard !values.isEmpty else { throw SynchronizedReferenceStoreError.noSamples }
    let directory = fileManager.temporaryDirectory.appendingPathComponent(
      "VehicleHealthOS-ReferenceCapture", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("synchronized-reference-samples.csv")
    try SynchronizedReferenceCSV.encode(values).write(to: url, options: [.atomic])
    return url
  }
}

enum SynchronizedReferenceStoreError: Error, LocalizedError {
  case capacityReached
  case invalidLedgerRecord(Int)
  case noSamples

  var errorDescription: String? {
    switch self {
    case .capacityReached:
      "The synchronized reference ledger reached its bounded sample capacity."
    case .invalidLedgerRecord(let line):
      "The append-only synchronized reference ledger is invalid at line \(line)."
    case .noSamples:
      "Record at least one Techstream or standard OBD reference sample before exporting."
    }
  }
}
