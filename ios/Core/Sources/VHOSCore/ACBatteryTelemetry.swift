import Foundation

public struct ACBatteryIdentity: Decodable, Equatable, Sendable {
  public let sourceID: String
  public let bootID: String
  public let buildID: String

  private enum CodingKeys: String, CodingKey {
    case contract, role, capabilities
    case version = "contract_version"
    case sourceID = "source_id"
    case bootID = "boot_id"
    case buildID = "firmware_build_id"
    case hardware = "hardware_revision"
    case protocolVersion = "protocol_version"
  }

  public init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    sourceID = try fields.decode(String.self, forKey: .sourceID)
    bootID = try fields.decode(String.self, forKey: .bootID)
    buildID = try fields.decode(String.self, forKey: .buildID)
    let capability = try fields.decode(Set<String>.self, forKey: .capabilities)
    guard try fields.decode(String.self, forKey: .contract) == "sensor.node.battery.handshake",
      try fields.decode(String.self, forKey: .version) == "1.0.0",
      try fields.decode(String.self, forKey: .role) == "AC_SENSOR",
      try fields.decode(String.self, forKey: .hardware) == "AC_R8",
      try fields.decode(String.self, forKey: .protocolVersion) == "1.0",
      capability.isSuperset(of: ["battery.max17260", "battery.pack_ntc"]),
      sourceID.wholeMatch(of: /ac-[0-9a-f]{12}/) != nil,
      bootID.wholeMatch(of: /[0-9a-f]{16}/) != nil,
      buildID.wholeMatch(of: /[0-9a-f]{12,64}/) != nil
    else { throw ACBatteryError.identity }
  }
}

public enum ACBatteryError: Error {
  case identity
  case frame
  case value
}

public struct ACBatteryReading: Equatable, Sendable {
  public let result: ResultCode
  public let volts: Double?
  public let milliamps: Double?
  public let averageMilliamps: Double?
  public let stateOfCharge: Double?
  public let remainingMilliampHours: Double?
  public let fullMilliampHours: Double?
  public let healthPercent: Double?
  public let equivalentCycles: Double?
  public let secondsToEmpty: Double?
  public let secondsToFull: Double?
  public let packCelsius: Double?

  public var signedWatts: Double? {
    guard let volts, let milliamps else { return nil }
    return volts * milliamps / 1000
  }

  public enum ResultCode: UInt8, Sendable {
    case valid
    case gaugeIO
    case model
    case range
    case packTemperature
  }

  public static func frame(_ data: Data, expected: GatewayMessageType) throws -> GatewayFrame {
    let frame = try GatewayFrame.decode(data, maximumPayloadBytes: 320)
    guard data.count == GatewayFrame.headerLength + frame.payload.count,
      frame.messageType == expected, frame.protocolMinor == 0, frame.flags == 0
    else { throw ACBatteryError.frame }
    return frame
  }

  public init(frame: GatewayFrame) throws {
    let bytes = Array(frame.payload)
    guard frame.messageType == .acBattery, bytes.count == 32, bytes[0] == 1, bytes[3] == 0,
      let result = ResultCode(rawValue: bytes[2])
    else { throw ACBatteryError.frame }
    let flags = bytes[1]
    let gauge = flags & 1 != 0
    let ntc = flags & 2 != 0
    guard flags <= 3, gauge == (result == .valid || result == .packTemperature),
      ntc == (result == .valid)
    else { throw ACBatteryError.value }

    func word(_ offset: Int) -> UInt16 {
      UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
    func signed(_ offset: Int) -> Double { Double(Int16(bitPattern: word(offset))) }
    let voltage = Double(word(6)) * 0.000078125
    let soc = Double(word(12)) / 256
    let temp = signed(26) / 100
    guard !gauge || ((2.0...4.35).contains(voltage) && soc <= 100 && word(16) > 0 && word(4) & 2 == 0),
      !ntc || (-40.0...85.0).contains(temp)
    else { throw ACBatteryError.value }

    self.result = result
    let average = signed(10) * 0.15625
    volts = gauge ? voltage : nil
    milliamps = gauge ? signed(8) * 0.15625 : nil
    averageMilliamps = gauge ? average : nil
    stateOfCharge = gauge ? soc : nil
    remainingMilliampHours = gauge ? Double(word(14)) / 2 : nil
    fullMilliampHours = gauge ? Double(word(16)) / 2 : nil
    healthPercent = gauge ? Double(word(18)) / 256 : nil
    equivalentCycles = gauge ? Double(word(20)) / 100 : nil
    secondsToEmpty = gauge && average < -5 && word(22) != .max ? Double(word(22)) * 5.625 : nil
    secondsToFull = gauge && average > 5 && word(24) != .max ? Double(word(24)) * 5.625 : nil
    packCelsius = ntc ? temp : nil
  }
}
