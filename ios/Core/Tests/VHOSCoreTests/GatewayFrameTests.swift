import Foundation
import Testing

@testable import VHOSCore

@Test func gatewayFrameRoundTripsAndStreamsAcrossChunks() throws {
  let first = GatewayFrame(
    messageType: .gatewayHealth, sequence: 7, monotonicMicroseconds: 42,
    payload: Data("health".utf8))
  let second = GatewayFrame(
    messageType: .experimentResult, sequence: 8, monotonicMicroseconds: 99,
    payload: Data("result".utf8))
  #expect(try GatewayFrame.decode(first.encoded()) == first)

  let combined = first.encoded() + second.encoded()
  var decoder = GatewayFrameStreamDecoder()
  #expect(try decoder.append(Data(combined.prefix(11))).isEmpty)
  #expect(try decoder.append(Data(combined.dropFirst(11))) == [first, second])
}

@Test func gatewayFrameRejectsCorruption() throws {
  let frame = GatewayFrame(
    messageType: .gatewayHealth, sequence: 1, monotonicMicroseconds: 1, payload: Data([1, 2, 3]))
  var corrupted = frame.encoded()
  corrupted[GatewayFrame.headerLength] ^= 0xFF
  #expect(throws: GatewayFrameError.self) {
    try GatewayFrame.decode(corrupted)
  }
}

@Test func gatewayHealthPreservesUnavailableStorageAsNull() throws {
  let payload = Data(
    """
    {
      "bus_error_count": 0,
      "bus_off_count": 0,
      "can_bitrate_bps": 250000,
      "can_controller_running": true,
      "can_extended_frames": 0,
      "can_frames_250k": 12,
      "can_frames_500k": 0,
      "can_passive_lock": true,
      "can_scan_cycles": 1,
      "can_scan_state": "LOCKED_250K",
      "can_standard_frames": 12,
      "capture_active": false,
      "contract": "gateway.health",
      "contract_version": "1.0.0",
      "dropped_frames": 0,
      "listen_only": true,
      "observed_at": "monotonic_us:42",
      "passive_can_candidate": "CAN_11_250",
      "received_frames": 12,
      "storage_free_bytes": null,
      "supply_millivolts": null,
      "vehicle_motion": "UNKNOWN"
    }
    """.utf8)

  let health = try VHOSJSON.decoder().decode(GatewayHealth.self, from: payload)

  #expect(health.storageFreeBytes == nil)
  #expect(health.supplyMillivolts == nil)
  #expect(health.listenOnly)
  #expect(health.canScanState == .locked250K)
  #expect(health.canBitrateBps == 250_000)
  #expect(health.canPassiveLock == true)
  #expect(health.canStandardFrames == 12)
  #expect(health.passiveCanCandidate == "CAN_11_250")
  #expect(health.receivedFrames == health.canStandardFrames! + health.canExtendedFrames!)
}
