import Foundation
import VHOSCore

struct EvidenceSyncImportSummary: Sendable {
  let bundleID: UUID
  let verifiedRecords: Int
  let appendedRecords: Int
}

final class PortableFrameStore {
  private let fileManager: FileManager
  private let root: URL
  private let framesURL: URL
  private var knownRecordIDs: Set<String>?

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    root = support.appendingPathComponent("VHOSPortableFrames/v1", isDirectory: true)
    framesURL = root.appendingPathComponent("logical-frames.ndjson")
    try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func append(
    frame: GatewayFrame,
    sourceRole: EvidenceSourceRole,
    sourceID: String,
    ingestedAt: String
  ) throws -> Bool {
    let record = PortableLogicalFrame(
      frame: frame,
      sourceRole: sourceRole,
      sourceID: sourceID,
      ingestedAt: ingestedAt
    )
    return try append(record)
  }

  func append(_ record: PortableLogicalFrame) throws -> Bool {
    _ = try record.validatedFrame()
    var identities = try recordIDs()
    guard identities.insert(record.id).inserted else { return false }
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    if !fileManager.fileExists(atPath: framesURL.path) {
      guard fileManager.createFile(atPath: framesURL.path, contents: nil) else {
        throw PortableFrameStoreError.createFailed
      }
    }
    var line = try VHOSJSON.encoder().encode(record)
    line.append(0x0A)
    let handle = try FileHandle(forWritingTo: framesURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
    knownRecordIDs = identities
    return true
  }

  func records(limit: Int = 100_000) throws -> [PortableLogicalFrame] {
    guard (1...100_000).contains(limit) else { throw PortableFrameStoreError.invalidLimit }
    guard fileManager.fileExists(atPath: framesURL.path) else { return [] }
    let bytes = try Data(contentsOf: framesURL, options: [.mappedIfSafe])
    let lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: true)
    var result: [PortableLogicalFrame] = []
    for line in lines.suffix(limit) {
      let record = try VHOSJSON.decoder().decode(PortableLogicalFrame.self, from: Data(line))
      _ = try record.validatedFrame()
      result.append(record)
    }
    return result
  }

  func count() -> Int { (try? recordIDs().count) ?? 0 }

  func export(
    applicationID: String,
    applicationVersion: String,
    deviceModel: String
  ) throws -> URL {
    let available = try records()
    guard !available.isEmpty else { throw PortableFrameStoreError.noEvidence }
    let bytes = try EvidenceSyncBundle.encode(
      records: available,
      creator: EvidenceBundleCreator(
        platform: "IOS",
        applicationID: applicationID,
        applicationVersion: applicationVersion,
        deviceModel: deviceModel
      )
    )
    let outputDirectory = fileManager.temporaryDirectory.appendingPathComponent(
      "VehicleHealthOS-Evidence", isDirectory: true)
    try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let output = outputDirectory.appendingPathComponent("vhos-evidence-sync.vhossync")
    try bytes.write(to: output, options: .atomic)
    return output
  }

  func importBundle(_ bytes: Data) throws -> EvidenceSyncImportSummary {
    let bundle = try EvidenceSyncBundle.decode(bytes)
    var appended = 0
    for record in bundle.records where try append(record) { appended += 1 }
    return EvidenceSyncImportSummary(
      bundleID: bundle.manifest.bundleID,
      verifiedRecords: bundle.records.count,
      appendedRecords: appended
    )
  }

  private func recordIDs() throws -> Set<String> {
    if let knownRecordIDs { return knownRecordIDs }
    guard fileManager.fileExists(atPath: framesURL.path) else {
      knownRecordIDs = []
      return []
    }
    let values = Set(try records().map(\.id))
    knownRecordIDs = values
    return values
  }
}

enum PortableFrameStoreError: Error, LocalizedError {
  case createFailed
  case invalidLimit
  case noEvidence

  var errorDescription: String? {
    switch self {
    case .createFailed: "The iPhone could not create its append-only portable evidence store."
    case .invalidLimit: "The portable evidence query limit is invalid."
    case .noEvidence: "No validated VHOS logical frames are stored on this iPhone yet."
    }
  }
}
