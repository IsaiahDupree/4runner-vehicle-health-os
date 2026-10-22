import Foundation

public struct J1979ResponseEvidence: Codable, Equatable, Sendable {
  public let contract: String
  public let contractVersion: String
  public let gatewayID: String
  public let captureID: String
  public let observedAt: String
  public let gatewayMonotonicMicroseconds: UInt64
  public let sourceSequence: UInt64
  public let transport: String
  public let ecuAddress: String
  public let requestMode: UInt8
  public let requestPID: UInt8
  public let responsePayloadHex: String

  private enum CodingKeys: String, CodingKey {
    case contract
    case contractVersion
    case gatewayID = "gateway_id"
    case captureID = "capture_id"
    case observedAt = "observed_at"
    case gatewayMonotonicMicroseconds = "gateway_monotonic_microseconds"
    case sourceSequence = "source_sequence"
    case transport
    case ecuAddress = "ecu_address"
    case requestMode = "request_mode"
    case requestPID = "request_pid"
    case responsePayloadHex = "response_payload_hex"
  }

  public init(
    gatewayID: String,
    captureID: String,
    observedAt: String,
    gatewayMonotonicMicroseconds: UInt64,
    sourceSequence: UInt64,
    transport: String,
    ecuAddress: String,
    requestPID: UInt8,
    responsePayloadHex: String
  ) {
    contract = "obd.j1979-response"
    contractVersion = "1.0.0"
    self.gatewayID = gatewayID
    self.captureID = captureID
    self.observedAt = observedAt
    self.gatewayMonotonicMicroseconds = gatewayMonotonicMicroseconds
    self.sourceSequence = sourceSequence
    self.transport = transport
    self.ecuAddress = ecuAddress
    requestMode = 1
    self.requestPID = requestPID
    self.responsePayloadHex = responsePayloadHex
  }

  public func validatedPayload() throws -> Data {
    guard contract == "obd.j1979-response", contractVersion == "1.0.0", requestMode == 1,
      !gatewayID.isEmpty, !captureID.isEmpty, !ecuAddress.isEmpty,
      let payload = Data(hexadecimal: responsePayloadHex), payload.count >= 2,
      payload[0] == 0x41, payload[1] == requestPID
    else { throw J1979DecodeError.invalidResponse }
    return payload
  }

  public func matchesRecorderContext(gatewayID: String, captureSessionID: UInt32) -> Bool {
    self.gatewayID == gatewayID && captureID == "capture-\(captureSessionID)"
  }

  public static func decodePassiveWire(
    _ bytes: Data,
    gatewayID: String,
    observedAt: String
  ) throws -> J1979ResponseEvidence {
    guard bytes.count == 36, bytes[0] == 1, [1, 2].contains(bytes[1]),
      (2...7).contains(bytes[2])
    else { throw J1979DecodeError.invalidWireResponse }
    let responseLength = Int(bytes[2])
    let ecu = bytes.j1979UInt32LittleEndian(at: 4)
    let sourceSequence = bytes.j1979UInt64LittleEndian(at: 8)
    let monotonic = bytes.j1979UInt64LittleEndian(at: 16)
    let session = bytes.j1979UInt32LittleEndian(at: 24)
    let response = Data(bytes[28..<(28 + responseLength)])
    guard (0x7E8...0x7EF).contains(ecu), response.count >= 2, response[0] == 0x41
    else { throw J1979DecodeError.invalidWireResponse }
    return J1979ResponseEvidence(
      gatewayID: gatewayID,
      captureID: "capture-\(session)",
      observedAt: observedAt,
      gatewayMonotonicMicroseconds: monotonic,
      sourceSequence: sourceSequence,
      transport: bytes[1] == 2 ? "ISO_15765_11_250" : "ISO_15765_11_500",
      ecuAddress: String(format: "0x%03X", ecu),
      requestPID: response[1],
      responsePayloadHex: response.map { String(format: "%02X", $0) }.joined()
    )
  }
}

public struct J1979ECUAvailability: Codable, Equatable, Sendable, Identifiable {
  public var id: String { ecuAddress }
  public let ecuAddress: String
  public let queriedBasePIDs: [UInt8]
  public let supportedPIDs: [UInt8]
  public let enumerationComplete: Bool
  public let incompleteReason: String?
}

public struct J1979StandardSample: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let gatewayID: String
  public let captureID: String
  public let ecuAddress: String
  public let observedAt: String
  public let gatewayMonotonicMicroseconds: UInt64
  public let sourceSequence: UInt64
  public let pid: UInt8
  public let signalID: String
  public let name: String
  public let rawDataHex: String
  public let value: Double
  public let unit: String
  public let definitionRevision: String
}

public struct J1979Accumulator: Sendable {
  private static let supportedBasePIDs = Set(stride(from: UInt8(0), through: UInt8(224), by: 32))
  private var bitmapByECU: [String: [UInt8: Data]] = [:]
  private var supportedByECU: [String: Set<UInt8>] = [:]
  private var samplesByIdentity: [String: J1979StandardSample] = [:]
  private var contextKey: String?

  public init() {}

  public var availability: [J1979ECUAvailability] {
    bitmapByECU.keys.sorted().map { ecu in
      let bitmaps = bitmapByECU[ecu] ?? [:]
      let supported = supportedByECU[ecu] ?? []
      let (complete, reason) = Self.completeness(bitmaps: bitmaps, supported: supported)
      return J1979ECUAvailability(
        ecuAddress: ecu,
        queriedBasePIDs: bitmaps.keys.sorted(),
        supportedPIDs: supported.sorted(),
        enumerationComplete: complete,
        incompleteReason: reason
      )
    }
  }

  public var standardSamples: [J1979StandardSample] {
    samplesByIdentity.values.sorted {
      if $0.gatewayMonotonicMicroseconds == $1.gatewayMonotonicMicroseconds {
        return $0.signalID < $1.signalID
      }
      return $0.gatewayMonotonicMicroseconds < $1.gatewayMonotonicMicroseconds
    }
  }

  @discardableResult
  public mutating func ingest(_ response: J1979ResponseEvidence) throws -> J1979StandardSample? {
    let payload = try response.validatedPayload()
    let incomingContext = "\(response.gatewayID)|\(response.captureID)|\(response.transport)"
    if contextKey != incomingContext {
      bitmapByECU.removeAll(keepingCapacity: true)
      supportedByECU.removeAll(keepingCapacity: true)
      samplesByIdentity.removeAll(keepingCapacity: true)
      contextKey = incomingContext
    }
    let data = Data(payload.dropFirst(2))
    if Self.supportedBasePIDs.contains(response.requestPID) {
      guard data.count == 4 else { throw J1979DecodeError.invalidSupportedPIDBitmap }
      bitmapByECU[response.ecuAddress, default: [:]][response.requestPID] = data
      supportedByECU[response.ecuAddress, default: []].formUnion(
        try Self.decodeBitmap(basePID: response.requestPID, bitmap: data))
      return nil
    }
    guard let definition = Self.definitions[response.requestPID],
      let ecu = availability.first(where: { $0.ecuAddress == response.ecuAddress }),
      ecu.enumerationComplete, ecu.supportedPIDs.contains(response.requestPID)
    else { return nil }
    guard data.count >= definition.byteCount else { throw J1979DecodeError.insufficientData }
    let relevant = Data(data.prefix(definition.byteCount))
    let raw = relevant.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    let value = Double(raw) * definition.multiplier / definition.divisor + definition.offset
    let identity =
      "\(response.gatewayID):\(response.captureID):\(response.ecuAddress):\(response.gatewayMonotonicMicroseconds):\(response.sourceSequence):\(response.requestPID)"
    let sample = J1979StandardSample(
      id: identity,
      gatewayID: response.gatewayID,
      captureID: response.captureID,
      ecuAddress: response.ecuAddress,
      observedAt: response.observedAt,
      gatewayMonotonicMicroseconds: response.gatewayMonotonicMicroseconds,
      sourceSequence: response.sourceSequence,
      pid: response.requestPID,
      signalID: definition.signalID,
      name: definition.name,
      rawDataHex: relevant.map { String(format: "%02X", $0) }.joined(),
      value: value,
      unit: definition.unit,
      definitionRevision: Self.definitionRevision
    )
    samplesByIdentity[identity] = sample
    return sample
  }

  public static func decodeBitmap(basePID: UInt8, bitmap: Data) throws -> [UInt8] {
    guard supportedBasePIDs.contains(basePID), bitmap.count == 4 else {
      throw J1979DecodeError.invalidSupportedPIDBitmap
    }
    let value = bitmap.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    return (1...32).compactMap { offset in
      guard value & (UInt32(1) << UInt32(32 - offset)) != 0 else { return nil }
      let candidate = Int(basePID) + offset
      guard candidate <= Int(UInt8.max) else { return nil }
      return UInt8(candidate)
    }
  }

  private static func completeness(
    bitmaps: [UInt8: Data], supported: Set<UInt8>
  ) -> (Bool, String?) {
    guard bitmaps[0] != nil else { return (false, "PID 0x00 availability response is missing.") }
    var base = 0
    while base < 224 {
      let continuation = base + 32
      guard supported.contains(UInt8(continuation)) else { return (true, nil) }
      guard bitmaps[UInt8(continuation)] != nil else {
        return (
          false, String(format: "PID 0x%02X availability response is required.", continuation)
        )
      }
      base = continuation
    }
    return (true, nil)
  }

  private struct Definition: Sendable {
    let signalID: String
    let name: String
    let byteCount: Int
    let multiplier: Double
    let divisor: Double
    let offset: Double
    let unit: String
  }

  public static let definitionRevision = "d3259214a9e0340c4a6cff9ec5f8ff5953eee6f2"
  private static let definitions: [UInt8: Definition] = [
    0x04: Definition(
      signalID: "obd.engine.calculated_load", name: "Calculated engine load", byteCount: 1,
      multiplier: 100, divisor: 255, offset: 0, unit: "%"),
    0x05: Definition(
      signalID: "obd.engine.coolant_temperature", name: "Engine coolant temperature", byteCount: 1,
      multiplier: 1, divisor: 1, offset: -40, unit: "degC"),
    0x06: Definition(
      signalID: "obd.engine.short_fuel_trim_bank1", name: "Short-term fuel trim bank 1",
      byteCount: 1, multiplier: 100, divisor: 128, offset: -100, unit: "%"),
    0x07: Definition(
      signalID: "obd.engine.long_fuel_trim_bank1", name: "Long-term fuel trim bank 1", byteCount: 1,
      multiplier: 100, divisor: 128, offset: -100, unit: "%"),
    0x08: Definition(
      signalID: "obd.engine.short_fuel_trim_bank2", name: "Short-term fuel trim bank 2",
      byteCount: 1, multiplier: 100, divisor: 128, offset: -100, unit: "%"),
    0x09: Definition(
      signalID: "obd.engine.long_fuel_trim_bank2", name: "Long-term fuel trim bank 2", byteCount: 1,
      multiplier: 100, divisor: 128, offset: -100, unit: "%"),
    0x0A: Definition(
      signalID: "obd.engine.fuel_pressure", name: "Fuel pressure", byteCount: 1, multiplier: 3,
      divisor: 1, offset: 0, unit: "kPa"),
    0x0B: Definition(
      signalID: "obd.engine.intake_manifold_pressure", name: "Intake manifold absolute pressure",
      byteCount: 1, multiplier: 1, divisor: 1, offset: 0, unit: "kPa"),
    0x0C: Definition(
      signalID: "obd.engine.speed", name: "Engine speed", byteCount: 2, multiplier: 1, divisor: 4,
      offset: 0, unit: "rpm"),
    0x0D: Definition(
      signalID: "obd.vehicle.speed", name: "Vehicle speed", byteCount: 1, multiplier: 1, divisor: 1,
      offset: 0, unit: "km/h"),
    0x0E: Definition(
      signalID: "obd.engine.timing_advance", name: "Timing advance", byteCount: 1, multiplier: 1,
      divisor: 2, offset: -64, unit: "deg"),
    0x0F: Definition(
      signalID: "obd.engine.intake_air_temperature", name: "Intake air temperature", byteCount: 1,
      multiplier: 1, divisor: 1, offset: -40, unit: "degC"),
    0x10: Definition(
      signalID: "obd.engine.mass_air_flow", name: "Mass air flow", byteCount: 2, multiplier: 1,
      divisor: 100, offset: 0, unit: "g/s"),
    0x11: Definition(
      signalID: "obd.engine.throttle_position", name: "Absolute throttle position", byteCount: 1,
      multiplier: 100, divisor: 255, offset: 0, unit: "%"),
    0x1F: Definition(
      signalID: "obd.engine.run_time", name: "Time since engine start", byteCount: 2, multiplier: 1,
      divisor: 1, offset: 0, unit: "s"),
  ]
}

public enum J1979DecodeError: Error, Equatable, LocalizedError {
  case invalidResponse
  case invalidWireResponse
  case invalidSupportedPIDBitmap
  case insufficientData

  public var errorDescription: String? {
    switch self {
    case .invalidResponse:
      "The J1979 response did not contain a matching positive Mode 01 response."
    case .invalidWireResponse: "The passive J1979 wire response is malformed or unsupported."
    case .invalidSupportedPIDBitmap: "The supported-PID response must contain a four-byte bitmap."
    case .insufficientData:
      "The J1979 response did not contain enough bytes for its pinned definition."
    }
  }
}

extension Data {
  fileprivate func j1979UInt32LittleEndian(at offset: Int) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { $0 | (UInt32(self[offset + $1]) << UInt32($1 * 8)) }
  }

  fileprivate func j1979UInt64LittleEndian(at offset: Int) -> UInt64 {
    (0..<8).reduce(UInt64(0)) { $0 | (UInt64(self[offset + $1]) << UInt64($1 * 8)) }
  }

  fileprivate init?(hexadecimal: String) {
    guard hexadecimal.count.isMultiple(of: 2), !hexadecimal.isEmpty,
      hexadecimal.allSatisfy(\.isHexDigit)
    else { return nil }
    self.init(capacity: hexadecimal.count / 2)
    var index = hexadecimal.startIndex
    while index < hexadecimal.endIndex {
      let end = hexadecimal.index(index, offsetBy: 2)
      guard let byte = UInt8(hexadecimal[index..<end], radix: 16) else { return nil }
      append(byte)
      index = end
    }
  }
}
