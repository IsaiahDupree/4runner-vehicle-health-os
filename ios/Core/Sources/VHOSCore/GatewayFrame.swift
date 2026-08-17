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

  public var id: String { "\(gatewayID):\(sessionID):\(sourceSequence)" }
  public var identifierHex: String {
    String(format: extended ? "%08X" : "%03X", identifier)
  }
  public var dataHex: String {
    data.prefix(Int(dataLength)).map { String(format: "%02X", $0) }.joined(separator: " ")
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
      throw CaptureLogError.invalidChunkLength(expected: 16 + count * recordBytes, actual: payload.count)
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

  public init(maximumPayloadBytes: Int = GatewayFrame.defaultMaximumPayloadBytes) {
    self.maximumPayloadBytes = maximumPayloadBytes
  }

  public mutating func append(_ data: Data) throws -> [GatewayFrame] {
    buffer.append(data)
    var frames: [GatewayFrame] = []

    while buffer.count >= GatewayFrame.headerLength {
      guard buffer.prefix(4) == GatewayFrame.magic else {
        throw GatewayFrameError.invalidMagic
      }
      let payloadLength = Int(buffer.readUInt32LittleEndian(at: 8))
      guard payloadLength <= maximumPayloadBytes else {
        throw GatewayFrameError.payloadTooLarge(payloadLength)
      }
      let frameLength = GatewayFrame.headerLength + payloadLength
      guard buffer.count >= frameLength else { break }
      let frameData = Data(buffer.prefix(frameLength))
      frames.append(try GatewayFrame.decode(frameData, maximumPayloadBytes: maximumPayloadBytes))
      buffer = Data(buffer.dropFirst(frameLength))
    }
    return frames
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
