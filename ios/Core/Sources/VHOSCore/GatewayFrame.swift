import Foundation

public enum GatewayMessageType: UInt8, Codable, Sendable {
  case handshake = 1
  case rawCANFrame = 2
  case diagnosticResponse = 3
  case gatewayHealth = 4
  case captureMarker = 5
  case allowlistedDiagnosticRequest = 6
  case experimentPlan = 7
  case otaControl = 8
  case agentHandoffAcknowledgement = 9
  case experimentResult = 10
  case captureLogRequest = 11
  case captureLogIndex = 12
  case captureLogChunk = 13
}

public enum OTAControlOperation: String, Codable, Sendable {
  case activate = "ACTIVATE"
  case cancel = "CANCEL"
}

public struct OTAControlRequest: Codable, Equatable, Sendable {
  public let contract: String
  public let contractVersion: String
  public let operation: OTAControlOperation
  public let packageID: UUID
  public let firmwareVersion: String
  public let firmwareSHA256: String
  public let firmwareSizeBytes: Int
  public let approvedAt: String

  private enum CodingKeys: String, CodingKey {
    case contract
    case contractVersion
    case operation
    case packageID = "package_id"
    case firmwareVersion
    case firmwareSHA256 = "firmware_sha256"
    case firmwareSizeBytes
    case approvedAt
  }

  public init(
    operation: OTAControlOperation = .activate,
    packageID: UUID,
    firmwareVersion: String,
    firmwareSHA256: String,
    firmwareSizeBytes: Int,
    approvedAt: String
  ) {
    contract = "gateway.ota-control-request"
    contractVersion = "1.0.0"
    self.operation = operation
    self.packageID = packageID
    self.firmwareVersion = firmwareVersion
    self.firmwareSHA256 = firmwareSHA256
    self.firmwareSizeBytes = firmwareSizeBytes
    self.approvedAt = approvedAt
  }

  public func encoded() throws -> Data { try VHOSJSON.encoder().encode(self) }
}

public struct GatewayOTAStatus: Codable, Equatable, Sendable {
  public let contract: String
  public let contractVersion: String
  public let gatewayID: String?
  public let state: String
  public let detail: String
  public let packageID: UUID?
  public let firmwareVersion: String?
  public let sessionActive: Bool
  public let expiresInSeconds: UInt32
  public let maximumImageBytes: Int
  public let ssid: String?
  public let passphrase: String?
  public let uploadURL: String?
  public let bearerToken: String?

  private enum CodingKeys: String, CodingKey {
    case contract
    case contractVersion
    case state
    case detail
    case gatewayID = "gatewayId"
    case packageID = "packageId"
    case firmwareVersion
    case sessionActive
    case expiresInSeconds
    case maximumImageBytes
    case ssid
    case passphrase
    case uploadURL = "uploadUrl"
    case bearerToken
  }

  public var networkReady: Bool {
    state == "NETWORK_READY" && sessionActive && ssid != nil && passphrase != nil
      && uploadURL != nil && bearerToken != nil
  }
}

public struct CaptureLogRequest: Sendable {
  public enum Operation: UInt8, Sendable {
    case index = 0
    case read = 1
    case rotate = 2
    case pause = 3
    case resume = 4
  }

  public let operation: Operation
  public let slot: UInt8
  public let recordOffset: UInt32

  public init(operation: Operation, slot: UInt8 = 0, recordOffset: UInt32 = 0) {
    self.operation = operation
    self.slot = slot
    self.recordOffset = recordOffset
  }

  public func encoded() -> Data {
    var data = Data([1, operation.rawValue, slot, 0])
    data.appendLittleEndian(recordOffset)
    return data
  }
}

public struct CaptureLogIndex: Codable, Equatable, Sendable {
  public let contract: String
  public let contractVersion: String
  public let currentBytes: UInt32
  public let currentRecords: UInt32
  public let currentSessionID: UInt32
  public let freeBytes: UInt32
  public let logging: Bool
  public let mounted: Bool
  public let observedFrames: UInt64
  public let previousBytes: UInt32
  public let previousRecords: UInt32
  public let previousSessionID: UInt32
  public let queueDroppedRecords: UInt64
  public let recordBytes: UInt32
  public let retainedRecords: UInt64
  public let sampleSuppressedFrames: UInt64
  public let sampledFrames: UInt64
  public let storageWriteFailures: UInt64
  public let totalBytes: UInt32

  private enum CodingKeys: String, CodingKey {
    case contract
    case contractVersion
    case currentBytes
    case currentRecords
    case currentSessionID = "currentSessionId"
    case freeBytes
    case logging
    case mounted
    case observedFrames
    case previousBytes
    case previousRecords
    case previousSessionID = "previousSessionId"
    case queueDroppedRecords
    case recordBytes
    case retainedRecords
    case sampleSuppressedFrames
    case sampledFrames
    case storageWriteFailures
    case totalBytes
  }
}

public struct PassiveCANObservation: Codable, Equatable, Sendable, Identifiable {
  public let contract: String
  public let contractVersion: String
  public let gatewayID: String
  public let sessionID: UInt32
  public let sourceSequence: UInt64
  public let monotonicMicroseconds: UInt64
  public let bitrateBps: UInt32
  public let identifier: UInt32
  public let extended: Bool
  public let remoteRequest: Bool
  public let listenOnly: Bool
  public let dataLength: UInt8
  public let data: [UInt8]
  public let evidenceSource: String
  public let ingestedAt: String

  private enum CodingKeys: String, CodingKey {
    case contract
    case contractVersion
    case gatewayID = "gatewayId"
    case sessionID = "sessionId"
    case sourceSequence
    case monotonicMicroseconds
    case bitrateBps
    case identifier
    case extended
    case remoteRequest
    case listenOnly
    case dataLength
    case data
    case evidenceSource
    case ingestedAt
  }

  public var id: String { "\(gatewayID):\(sessionID):\(sourceSequence)" }
  public var identifierHex: String {
    String(format: extended ? "%08X" : "%03X", identifier)
  }
  public var dataHex: String {
    data.prefix(Int(dataLength)).map { String(format: "%02X", $0) }.joined(separator: " ")
  }

  public func matchesRecorderContext(gatewayID: String, captureSessionID: UInt32) -> Bool {
    self.gatewayID == gatewayID && sessionID == captureSessionID
  }

  public init(
    gatewayID: String,
    sessionID: UInt32,
    sourceSequence: UInt64,
    monotonicMicroseconds: UInt64,
    bitrateBps: UInt32,
    identifier: UInt32,
    extended: Bool,
    remoteRequest: Bool,
    listenOnly: Bool,
    dataLength: UInt8,
    data: [UInt8],
    evidenceSource: String,
    ingestedAt: String
  ) {
    contract = "gateway.passive-can-observation"
    contractVersion = "1.0.0"
    self.gatewayID = gatewayID
    self.sessionID = sessionID
    self.sourceSequence = sourceSequence
    self.monotonicMicroseconds = monotonicMicroseconds
    self.bitrateBps = bitrateBps
    self.identifier = identifier
    self.extended = extended
    self.remoteRequest = remoteRequest
    self.listenOnly = listenOnly
    self.dataLength = dataLength
    self.data = Array(data.prefix(8))
    self.evidenceSource = evidenceSource
    self.ingestedAt = ingestedAt
  }

  /// Rebuild the deployed 36-byte live record for offline historical replay.
  /// Callers must continue to label the resulting stream as replay, never live telemetry.
  public func encodedLivePayload() throws -> Data {
    guard dataLength <= 8, data.count == 8 else {
      throw CaptureLogError.invalidObservationDataShape(length: Int(dataLength), bytes: data.count)
    }
    guard bitrateBps == 250_000 || bitrateBps == 500_000 else {
      throw CaptureLogError.unsupportedBitrate(bitrateBps)
    }
    var payload = Data([
      1,
      (extended ? 0x01 : 0) | (remoteRequest ? 0x02 : 0) | (listenOnly ? 0x04 : 0),
      dataLength,
      bitrateBps == 250_000 ? 2 : 1,
    ])
    payload.appendLittleEndian(identifier)
    payload.appendLittleEndian(sourceSequence)
    payload.appendLittleEndian(monotonicMicroseconds)
    payload.appendLittleEndian(sessionID)
    payload.append(contentsOf: data)
    return payload
  }

  public static func decodeLive(
    _ payload: Data,
    gatewayID: String,
    ingestedAt: String
  ) throws -> PassiveCANObservation {
    guard payload.count == 36, payload[0] == 1 else {
      throw CaptureLogError.invalidLiveRecordLength(payload.count)
    }
    return decodeFields(
      payload,
      gatewayID: gatewayID,
      sessionID: payload.readUInt32LittleEndian(at: 24),
      dataOffset: 28,
      evidenceSource: "ble-live",
      ingestedAt: ingestedAt
    )
  }

  fileprivate static func decodeStored(
    _ record: Data,
    gatewayID: String,
    sessionID: UInt32,
    ingestedAt: String
  ) throws -> PassiveCANObservation {
    guard record.count == 36, record[0] == 1 else {
      throw CaptureLogError.invalidStoredRecordLength(record.count)
    }
    let expected = record.readUInt32LittleEndian(at: 32)
    let actual = CRC32C.checksum(record.prefix(32))
    guard expected == actual else {
      throw CaptureLogError.recordCRC(expected: expected, actual: actual)
    }
    return decodeFields(
      record,
      gatewayID: gatewayID,
      sessionID: sessionID,
      dataOffset: 24,
      evidenceSource: "gateway-flash",
      ingestedAt: ingestedAt
    )
  }

  private static func decodeFields(
    _ bytes: Data,
    gatewayID: String,
    sessionID: UInt32,
    dataOffset: Int,
    evidenceSource: String,
    ingestedAt: String
  ) -> PassiveCANObservation {
    let flags = bytes[1]
    return PassiveCANObservation(
      gatewayID: gatewayID,
      sessionID: sessionID,
      sourceSequence: bytes.readUInt64LittleEndian(at: 8),
      monotonicMicroseconds: bytes.readUInt64LittleEndian(at: 16),
      bitrateBps: bytes[3] == 2 ? 250_000 : 500_000,
      identifier: bytes.readUInt32LittleEndian(at: 4),
      extended: flags & 0x01 != 0,
      remoteRequest: flags & 0x02 != 0,
      listenOnly: flags & 0x04 != 0,
      dataLength: min(bytes[2], 8),
      data: Array(bytes[dataOffset..<(dataOffset + 8)]),
      evidenceSource: evidenceSource,
      ingestedAt: ingestedAt
    )
  }
}

public struct CaptureLogChunk: Equatable, Sendable {
  public let slot: UInt8
  public let endOfFile: Bool
  public let recordOffset: UInt32
  public let sessionID: UInt32
  public let records: [PassiveCANObservation]

  public static func decode(
    _ payload: Data,
    gatewayID: String,
    ingestedAt: String
  ) throws -> CaptureLogChunk {
    guard payload.count >= 16, payload[0] == 1 else {
      throw CaptureLogError.invalidChunkHeader
    }
    let count = Int(payload.readUInt16LittleEndian(at: 8))
    let recordBytes = Int(payload.readUInt16LittleEndian(at: 10))
    guard recordBytes == 36 else { throw CaptureLogError.unsupportedRecordSize(recordBytes) }
    guard payload.count == 16 + count * recordBytes else {
      throw CaptureLogError.invalidChunkLength(
        expected: 16 + count * recordBytes, actual: payload.count)
    }
    let sessionID = payload.readUInt32LittleEndian(at: 12)
    let records = try (0..<count).map { index in
      let start = 16 + index * recordBytes
      return try PassiveCANObservation.decodeStored(
        Data(payload[start..<(start + recordBytes)]),
        gatewayID: gatewayID,
        sessionID: sessionID,
        ingestedAt: ingestedAt
      )
    }
    return CaptureLogChunk(
      slot: payload[1],
      endOfFile: payload[2] == 1,
      recordOffset: payload.readUInt32LittleEndian(at: 4),
      sessionID: sessionID,
      records: records
    )
  }
}

public enum CaptureLogError: Error, Equatable, LocalizedError {
  case invalidLiveRecordLength(Int)
  case invalidStoredRecordLength(Int)
  case invalidChunkHeader
  case unsupportedRecordSize(Int)
  case invalidChunkLength(expected: Int, actual: Int)
  case recordCRC(expected: UInt32, actual: UInt32)
  case invalidObservationDataShape(length: Int, bytes: Int)
  case unsupportedBitrate(UInt32)

  public var errorDescription: String? {
    switch self {
    case .invalidLiveRecordLength(let count): "Invalid live CAN record length: \(count)."
    case .invalidStoredRecordLength(let count): "Invalid stored CAN record length: \(count)."
    case .invalidChunkHeader: "Capture-log chunk header is invalid."
    case .unsupportedRecordSize(let count): "Unsupported capture record size: \(count)."
    case .invalidChunkLength(let expected, let actual):
      "Capture-log chunk length mismatch: expected \(expected), received \(actual)."
    case .recordCRC(let expected, let actual):
      "Capture record CRC32C mismatch: expected \(expected), received \(actual)."
    case .invalidObservationDataShape(let length, let bytes):
      "CAN observation data shape is invalid: DLC \(length), payload storage \(bytes) bytes."
    case .unsupportedBitrate(let bitrate): "Unsupported CAN bitrate: \(bitrate)."
    }
  }
}

public enum GatewayFrameError: Error, Equatable, LocalizedError {
  case incompleteHeader
  case invalidMagic
  case unsupportedProtocolMajor(UInt8)
  case unsupportedMessageType(UInt8)
  case payloadTooLarge(Int)
  case incompletePayload(expected: Int, actual: Int)
  case headerCRC(expected: UInt32, actual: UInt32)
  case payloadCRC(expected: UInt32, actual: UInt32)

  public var errorDescription: String? {
    switch self {
    case .incompleteHeader: "Gateway frame header is incomplete."
    case .invalidMagic: "Gateway frame magic is invalid."
    case .unsupportedProtocolMajor(let value):
      "Unsupported gateway protocol major version \(value)."
    case .unsupportedMessageType(let value): "Unsupported gateway message type \(value)."
    case .payloadTooLarge(let value):
      "Gateway payload exceeds the configured limit: \(value) bytes."
    case .incompletePayload(let expected, let actual):
      "Gateway payload is incomplete: expected \(expected), received \(actual)."
    case .headerCRC(let expected, let actual):
      "Gateway header CRC32C mismatch: expected \(expected), received \(actual)."
    case .payloadCRC(let expected, let actual):
      "Gateway payload CRC32C mismatch: expected \(expected), received \(actual)."
    }
  }
}

public struct GatewayFrame: Equatable, Sendable {
  public static let magic = Data([0x56, 0x48, 0x4F, 0x53])
  public static let headerLength = 36
  public static let defaultMaximumPayloadBytes = 1_048_576

  public let protocolMajor: UInt8
  public let protocolMinor: UInt8
  public let messageType: GatewayMessageType
  public let flags: UInt8
  public let sequence: UInt64
  public let monotonicMicroseconds: UInt64
  public let payload: Data

  public init(
    protocolMajor: UInt8 = 1,
    protocolMinor: UInt8 = 0,
    messageType: GatewayMessageType,
    flags: UInt8 = 0,
    sequence: UInt64,
    monotonicMicroseconds: UInt64,
    payload: Data
  ) {
    self.protocolMajor = protocolMajor
    self.protocolMinor = protocolMinor
    self.messageType = messageType
    self.flags = flags
    self.sequence = sequence
    self.monotonicMicroseconds = monotonicMicroseconds
    self.payload = payload
  }

  public func encoded() -> Data {
    var header = Data()
    header.append(Self.magic)
    header.append(protocolMajor)
    header.append(protocolMinor)
    header.append(messageType.rawValue)
    header.append(flags)
    header.appendLittleEndian(UInt32(payload.count))
    header.appendLittleEndian(sequence)
    header.appendLittleEndian(monotonicMicroseconds)
    header.appendLittleEndian(CRC32C.checksum(payload))
    header.appendLittleEndian(CRC32C.checksum(header))
    return header + payload
  }

  public static func decode(
    _ data: Data,
    maximumPayloadBytes: Int = defaultMaximumPayloadBytes
  ) throws -> GatewayFrame {
    guard data.count >= headerLength else { throw GatewayFrameError.incompleteHeader }
    guard data.prefix(4) == magic else { throw GatewayFrameError.invalidMagic }

    let protocolMajor = data[4]
    guard protocolMajor == 1 else {
      throw GatewayFrameError.unsupportedProtocolMajor(protocolMajor)
    }
    guard let messageType = GatewayMessageType(rawValue: data[6]) else {
      throw GatewayFrameError.unsupportedMessageType(data[6])
    }

    let payloadLength = Int(data.readUInt32LittleEndian(at: 8))
    guard payloadLength <= maximumPayloadBytes else {
      throw GatewayFrameError.payloadTooLarge(payloadLength)
    }
    let expectedLength = headerLength + payloadLength
    guard data.count >= expectedLength else {
      throw GatewayFrameError.incompletePayload(expected: expectedLength, actual: data.count)
    }

    let expectedPayloadCRC = data.readUInt32LittleEndian(at: 28)
    let expectedHeaderCRC = data.readUInt32LittleEndian(at: 32)
    let actualHeaderCRC = CRC32C.checksum(data.prefix(32))
    guard expectedHeaderCRC == actualHeaderCRC else {
      throw GatewayFrameError.headerCRC(expected: expectedHeaderCRC, actual: actualHeaderCRC)
    }

    let payload = Data(data[headerLength..<expectedLength])
    let actualPayloadCRC = CRC32C.checksum(payload)
    guard expectedPayloadCRC == actualPayloadCRC else {
      throw GatewayFrameError.payloadCRC(expected: expectedPayloadCRC, actual: actualPayloadCRC)
    }

    return GatewayFrame(
      protocolMajor: protocolMajor,
      protocolMinor: data[5],
      messageType: messageType,
      flags: data[7],
      sequence: data.readUInt64LittleEndian(at: 12),
      monotonicMicroseconds: data.readUInt64LittleEndian(at: 20),
      payload: payload
    )
  }
}

public struct GatewayFrameStreamDecoder: Sendable {
  private var buffer = Data()
  private let maximumPayloadBytes: Int

  /// Bytes discarded while finding the next CRC-valid VHOS frame boundary.
  /// A non-zero value is transport-quality evidence, not a vehicle fault.
  public private(set) var discardedByteCount = 0

  /// Number of times the decoder recovered from corrupt or missing transport bytes.
  public private(set) var recoveryCount = 0

  /// Number of complete-looking frame candidates rejected by a contract or CRC check.
  public private(set) var corruptCandidateCount = 0

  /// Largest incremental buffer observed in this decoder lifetime.
  /// This is communication-load evidence, not vehicle-health evidence.
  public private(set) var maximumBufferedByteCount = 0

  public var bufferedByteCount: Int { buffer.count }

  public init(maximumPayloadBytes: Int = GatewayFrame.defaultMaximumPayloadBytes) {
    self.maximumPayloadBytes = maximumPayloadBytes
  }

  public mutating func append(_ data: Data) throws -> [GatewayFrame] {
    buffer.append(data)
    maximumBufferedByteCount = max(maximumBufferedByteCount, buffer.count)
    var frames: [GatewayFrame] = []

    while true {
      guard alignToMagic() else { break }
      guard buffer.count >= GatewayFrame.headerLength else { break }

      let payloadLength = Int(buffer.readUInt32LittleEndian(at: 8))
      guard headerAtBufferStartIsValid(payloadLength: payloadLength) else {
        corruptCandidateCount += 1
        discardPrefix(1)
        continue
      }
      let frameLength = GatewayFrame.headerLength + payloadLength
      guard buffer.count >= frameLength else {
        // A later CRC-valid header before the claimed end proves that at least one
        // notification fragment from the current frame was lost. Recover immediately
        // instead of waiting forever for bytes that can no longer arrive.
        if let nextHeader = nextValidHeaderOffset(startingAt: GatewayFrame.magic.count) {
          corruptCandidateCount += 1
          discardPrefix(nextHeader)
          continue
        }
        if let nextMagic = nextMagicOffset(startingAt: GatewayFrame.magic.count) {
          corruptCandidateCount += 1
          discardPrefix(nextMagic)
        }
        break
      }
      let frameData = Data(buffer.prefix(frameLength))
      do {
        frames.append(
          try GatewayFrame.decode(frameData, maximumPayloadBytes: maximumPayloadBytes))
        // Data may retain a non-zero startIndex after removeFirst(), while the wire
        // readers intentionally use zero-based contract offsets. Rebase each tail.
        buffer = Data(buffer.dropFirst(frameLength))
      } catch {
        corruptCandidateCount += 1
        if let nextHeader = nextValidHeaderOffset(startingAt: 1) {
          discardPrefix(nextHeader)
        } else if let nextMagic = nextMagicOffset(startingAt: 1) {
          // Preserve a split candidate header until a later notification supplies
          // enough bytes to validate it. A false-positive magic is discarded then.
          discardPrefix(nextMagic)
          break
        } else {
          // Keep a possible split magic suffix so the next append can complete it.
          discardUnframedBytesPreservingMagicPrefix()
          break
        }
      }
    }
    return frames
  }

  public mutating func reset() {
    buffer.removeAll(keepingCapacity: true)
    discardedByteCount = 0
    recoveryCount = 0
    corruptCandidateCount = 0
    maximumBufferedByteCount = 0
  }

  /// Clears bytes owned by a dead physical link while preserving its quality counters.
  public mutating func resetBufferPreservingDiagnostics() {
    guard !buffer.isEmpty else { return }
    discardedByteCount += buffer.count
    recoveryCount += 1
    buffer.removeAll(keepingCapacity: true)
  }

  private mutating func alignToMagic() -> Bool {
    guard !buffer.isEmpty else { return false }
    if buffer.count >= GatewayFrame.magic.count,
      buffer.prefix(GatewayFrame.magic.count) == GatewayFrame.magic
    {
      return true
    }
    if let range = buffer.range(of: GatewayFrame.magic), range.lowerBound > buffer.startIndex {
      discardPrefix(buffer.distance(from: buffer.startIndex, to: range.lowerBound))
      return true
    }
    discardUnframedBytesPreservingMagicPrefix()
    return false
  }

  private func headerAtBufferStartIsValid(payloadLength: Int) -> Bool {
    guard payloadLength <= maximumPayloadBytes,
      buffer[4] == 1,
      GatewayMessageType(rawValue: buffer[6]) != nil
    else { return false }
    let expected = buffer.readUInt32LittleEndian(at: 32)
    return expected == CRC32C.checksum(buffer.prefix(32))
  }

  private func nextValidHeaderOffset(startingAt start: Int) -> Int? {
    guard buffer.count >= GatewayFrame.headerLength, start < buffer.count else { return nil }
    var searchStart = buffer.index(buffer.startIndex, offsetBy: start)
    while searchStart < buffer.endIndex,
      let range = buffer.range(
        of: GatewayFrame.magic,
        in: searchStart..<buffer.endIndex)
    {
      let offset = buffer.distance(from: buffer.startIndex, to: range.lowerBound)
      guard buffer.count - offset >= GatewayFrame.headerLength else { return nil }
      let candidate = Data(buffer.dropFirst(offset))
      let payloadLength = Int(candidate.readUInt32LittleEndian(at: 8))
      if payloadLength <= maximumPayloadBytes,
        candidate[4] == 1,
        GatewayMessageType(rawValue: candidate[6]) != nil,
        candidate.readUInt32LittleEndian(at: 32) == CRC32C.checksum(candidate.prefix(32))
      {
        return offset
      }
      searchStart = buffer.index(after: range.lowerBound)
    }
    return nil
  }

  private func nextMagicOffset(startingAt start: Int) -> Int? {
    guard start < buffer.count else { return nil }
    let searchStart = buffer.index(buffer.startIndex, offsetBy: start)
    guard let range = buffer.range(of: GatewayFrame.magic, in: searchStart..<buffer.endIndex)
    else { return nil }
    return buffer.distance(from: buffer.startIndex, to: range.lowerBound)
  }

  private mutating func discardPrefix(_ count: Int) {
    guard count > 0 else { return }
    let bounded = min(count, buffer.count)
    buffer = Data(buffer.dropFirst(bounded))
    discardedByteCount += bounded
    recoveryCount += 1
  }

  private mutating func discardUnframedBytesPreservingMagicPrefix() {
    let maximumSuffix = min(GatewayFrame.magic.count - 1, buffer.count)
    var suffixCount = 0
    if maximumSuffix > 0 {
      for count in stride(from: maximumSuffix, through: 1, by: -1) {
        if buffer.suffix(count) == GatewayFrame.magic.prefix(count) {
          suffixCount = count
          break
        }
      }
    }
    discardPrefix(buffer.count - suffixCount)
  }
}

public enum CRC32C {
  private static let polynomial: UInt32 = 0x82F6_3B78

  public static func checksum<T: DataProtocol>(_ bytes: T) -> UInt32 {
    var crc = UInt32.max
    for byte in bytes {
      crc ^= UInt32(byte)
      for _ in 0..<8 {
        crc = (crc >> 1) ^ ((crc & 1) == 1 ? polynomial : 0)
      }
    }
    return ~crc
  }
}

extension Data {
  fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
  }

  fileprivate func readUInt32LittleEndian(at offset: Int) -> UInt32 {
    UInt32(self[offset])
      | (UInt32(self[offset + 1]) << 8)
      | (UInt32(self[offset + 2]) << 16)
      | (UInt32(self[offset + 3]) << 24)
  }

  fileprivate func readUInt16LittleEndian(at offset: Int) -> UInt16 {
    UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
  }

  fileprivate func readUInt64LittleEndian(at offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for index in 0..<8 {
      value |= UInt64(self[offset + index]) << UInt64(index * 8)
    }
    return value
  }
}
