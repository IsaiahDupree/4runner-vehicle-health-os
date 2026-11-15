import Foundation
import Testing
@testable import VHOSCore

struct ACBatteryTelemetryTests {
  // From 4runner-ac-telemetry-node/tests/ac_battery_wire_vector.c using battery_wire.c.
  private let fixture = "56484f5301000e0020000000200000000000000020402c0000000000606211589c7c22c101030000000000c330f8c0f980497837004b2062ed09c00364008ffd00000000"

  private var raw: Data {
    let digits = Array(fixture)
    return Data(stride(from: 0, to: digits.count, by: 2).map { start in
      UInt8(String(digits[start...start + 1]), radix: 16)!
    })
  }

  @Test func decodesTheESP32FrameAndSuppressesTimeToFullDuringDischarge() throws {
    let frame = try ACBatteryReading.frame(raw, expected: .acBattery)
    let pack = try ACBatteryReading(frame: frame)
    #expect(frame.sequence == 32)
    #expect(frame.monotonicMicroseconds == 2_900_000)
    #expect(pack.volts == 3.9)
    #expect(pack.milliamps == -312.5)
    #expect(pack.averageMilliamps == -250)
    #expect(pack.stateOfCharge == 73.5)
    #expect(pack.healthPercent == 98.125)
    #expect(pack.remainingMilliampHours == 7100)
    #expect(pack.fullMilliampHours == 9600)
    #expect(pack.equivalentCycles == 25.41)
    #expect(pack.secondsToEmpty == 5400)
    #expect(pack.secondsToFull == nil)
    #expect(pack.packCelsius == -6.25)
  }

  @Test func rejectsCorruptCRCAndLeavesUnavailableMeasurementsEmpty() throws {
    var corrupted = raw
    corrupted[42] ^= 1
    #expect(throws: GatewayFrameError.self) {
      try ACBatteryReading.frame(corrupted, expected: .acBattery)
    }
    var payload = try ACBatteryReading.frame(raw, expected: .acBattery).payload
    payload[1] = 0
    payload[2] = 1
    let unavailable = GatewayFrame(messageType: .acBattery, sequence: 33, monotonicMicroseconds: 3_000_000, payload: payload)
    let pack = try ACBatteryReading(frame: unavailable)
    #expect(pack.result == .gaugeIO)
    #expect(pack.volts == nil)
    #expect(pack.stateOfCharge == nil)
    #expect(pack.packCelsius == nil)
  }
}
