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

  fileprivate func readUInt64LittleEndian(at offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for index in 0..<8 {
      value |= UInt64(self[offset + index]) << UInt64(index * 8)
    }
    return value
  }
}
