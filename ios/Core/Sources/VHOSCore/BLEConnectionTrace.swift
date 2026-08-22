import Foundation

public struct BLEConnectionTraceRecord: Codable, Equatable, Sendable {
  public static let currentContract = "ble.connection.event"
  public static let currentContractVersion = "1.0.0"

  public let contract: String
  public let contractVersion: String
  public let sequence: UInt64
  public let recordedAt: String
  public let monotonicMicroseconds: UInt64
  public let processInstance: String?
  public let event: String
  public let detail: String

  public init(
    sequence: UInt64,
    recordedAt: String,
    monotonicMicroseconds: UInt64,
    processInstance: String?,
    event: String,
    detail: String
  ) {
    contract = Self.currentContract
    contractVersion = Self.currentContractVersion
    self.sequence = sequence
    self.recordedAt = recordedAt
    self.monotonicMicroseconds = monotonicMicroseconds
    self.processInstance = processInstance
    self.event = event
    self.detail = detail
  }
}

public struct BLEConnectionTraceSummary: Equatable, Sendable {
  public let recordCount: Int
  public let fileCount: Int
  public let byteCount: Int64

  public init(recordCount: Int, fileCount: Int, byteCount: Int64) {
    self.recordCount = recordCount
    self.fileCount = fileCount
    self.byteCount = byteCount
  }
}

public enum BLEConnectionTraceError: Error, LocalizedError {
  case applicationSupportUnavailable
  case noTraceRecords

  public var errorDescription: String? {
    switch self {
    case .applicationSupportUnavailable:
      "The app's Application Support directory is unavailable."
    case .noTraceRecords:
      "No Bluetooth connection trace records are available yet."
    }
  }
}

/// A bounded, append-only NDJSON flight recorder for app-observable CoreBluetooth events.
///
/// It intentionally stores no bond keys, pairing secrets, raw HCI packets, or unrestricted
/// advertising payloads. Those are not exposed to an ordinary iOS application.
public final class BLEConnectionTraceRecorder: @unchecked Sendable {
  public static let defaultMaximumFileBytes = 512 * 1_024
  public static let defaultMaximumFiles = 8

  private let fileManager: FileManager
  private let directory: URL
  private let maximumFileBytes: Int
  private let maximumFiles: Int
  private let lock = NSLock()
  private var currentFileURL: URL?
  private var currentHandle: FileHandle?
  private var segmentIndex = 0
  private var nextSequence: UInt64
  private let fileStem: String

  public init(
    directory: URL,
    maximumFileBytes: Int = BLEConnectionTraceRecorder.defaultMaximumFileBytes,
    maximumFiles: Int = BLEConnectionTraceRecorder.defaultMaximumFiles,
    fileManager: FileManager = .default
  ) throws {
    precondition(maximumFileBytes > 0)
    precondition(maximumFiles > 0)
    self.fileManager = fileManager
    self.directory = directory
    self.maximumFileBytes = maximumFileBytes
    self.maximumFiles = maximumFiles
    fileStem =
      "ble-connection-\(Int(Date().timeIntervalSince1970 * 1_000))-\(UUID().uuidString.prefix(8))"
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    nextSequence = Self.maximumSequence(directory: directory, fileManager: fileManager) + 1
  }

  deinit {
    try? currentHandle?.close()
  }

  public static func defaultDirectory(fileManager: FileManager = .default) throws -> URL {
    guard
      let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { throw BLEConnectionTraceError.applicationSupportUnavailable }
    return
      support
      .appendingPathComponent("VehicleHealthOS-Evidence", isDirectory: true)
      .appendingPathComponent("BLEConnectionTrace", isDirectory: true)
  }

  @discardableResult
  public func append(
    recordedAt: String,
    monotonicMicroseconds: UInt64,
    processInstance: String?,
    message: String
  ) throws -> BLEConnectionTraceRecord {
    lock.lock()
    defer { lock.unlock() }

    let record = BLEConnectionTraceRecord(
      sequence: nextSequence,
      recordedAt: recordedAt,
      monotonicMicroseconds: monotonicMicroseconds,
      processInstance: processInstance,
      event: Self.eventName(from: message),
      detail: message
    )
    var line = try VHOSJSON.encoder().encode(record)
    line.append(0x0A)
    try prepareFile(forAdditionalBytes: line.count)
    guard let currentHandle else { throw CocoaError(.fileNoSuchFile) }
    try currentHandle.write(contentsOf: line)
    try currentHandle.synchronize()
    nextSequence += 1
    return record
  }

  public func summary() -> BLEConnectionTraceSummary {
    lock.lock()
    defer { lock.unlock() }
    try? currentHandle?.synchronize()
    return Self.inspect(directory: directory, fileManager: fileManager)
  }

  public func export(to destinationDirectory: URL) throws -> URL {
    lock.lock()
    defer { lock.unlock() }
    try currentHandle?.synchronize()
    let files = traceFiles()
    guard !files.isEmpty else { throw BLEConnectionTraceError.noTraceRecords }
    try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    let destination = destinationDirectory.appendingPathComponent(
      "ble-connection-flight-recorder.ndjson")
    if fileManager.fileExists(atPath: destination.path) {
      try fileManager.removeItem(at: destination)
    }
    fileManager.createFile(atPath: destination.path, contents: nil)
    let output = try FileHandle(forWritingTo: destination)
    defer { try? output.close() }
    for file in files {
      let bytes = try Data(contentsOf: file, options: [.mappedIfSafe])
      try output.write(contentsOf: bytes)
      if bytes.last != 0x0A { try output.write(contentsOf: Data([0x0A])) }
    }
    try output.synchronize()
    return destination
  }

  private func prepareFile(forAdditionalBytes additionalBytes: Int) throws {
    if let currentFileURL {
      let size = (try? currentFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      if size + additionalBytes <= maximumFileBytes || size == 0 { return }
      try currentHandle?.close()
      currentHandle = nil
      self.currentFileURL = nil
      segmentIndex += 1
    }
    guard currentFileURL == nil else { return }
    let file = directory.appendingPathComponent(
      String(format: "%@-%03d.ndjson", fileStem, segmentIndex))
    if !fileManager.fileExists(atPath: file.path) {
      fileManager.createFile(atPath: file.path, contents: nil)
    }
    currentFileURL = file
    currentHandle = try FileHandle(forWritingTo: file)
    try currentHandle?.seekToEnd()
    try pruneOldFiles()
  }

  private func pruneOldFiles() throws {
    let files = traceFiles()
    guard files.count > maximumFiles else { return }
    let removeCount = files.count - maximumFiles
    for file in files.prefix(removeCount) where file != currentFileURL {
      try fileManager.removeItem(at: file)
    }
  }

  private func traceFiles() -> [URL] {
    let files =
      (try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
      )) ?? []
    return
      files
      .filter { $0.pathExtension == "ndjson" && $0.lastPathComponent.hasPrefix("ble-connection-") }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private static func inspect(directory: URL, fileManager: FileManager) -> BLEConnectionTraceSummary
  {
    let files =
      ((try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
      )) ?? [])
      .filter { $0.pathExtension == "ndjson" && $0.lastPathComponent.hasPrefix("ble-connection-") }
    var records = 0
    var bytes: Int64 = 0
    for file in files {
      guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else { continue }
      records += data.reduce(into: 0) { count, byte in
        if byte == 0x0A { count += 1 }
      }
      bytes += Int64(data.count)
    }
    return BLEConnectionTraceSummary(
      recordCount: records,
      fileCount: files.count,
      byteCount: bytes)
  }

  private static func maximumSequence(directory: URL, fileManager: FileManager) -> UInt64 {
    let files =
      ((try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )) ?? [])
      .filter {
        $0.pathExtension == "ndjson" && $0.lastPathComponent.hasPrefix("ble-connection-")
      }
    var maximum: UInt64 = 0
    for file in files {
      guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else { continue }
      for line in data.split(separator: 0x0A) {
        guard
          let record = try? VHOSJSON.decoder().decode(
            BLEConnectionTraceRecord.self, from: Data(line))
        else { continue }
        maximum = max(maximum, record.sequence)
      }
    }
    return maximum
  }

  private static func eventName(from message: String) -> String {
    let tokens = message.split(whereSeparator: { $0.isWhitespace })
    guard !tokens.isEmpty else { return "UNKNOWN" }
    let first = String(tokens[0])
    if first.hasPrefix("client="), tokens.count > 1 { return String(tokens[1]) }
    return first
  }
}
