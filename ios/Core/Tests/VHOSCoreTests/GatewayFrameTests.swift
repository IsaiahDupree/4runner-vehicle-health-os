import Foundation
import Testing

@testable import VHOSCore

@Test func otaActivationContractUsesExplicitIdentifiersAndDecodesCredentials() throws {
  let packageID = UUID(uuidString: "8D963E52-9FC9-4B3B-9C60-4A72C5E0148D")!
  let request = OTAControlRequest(
    packageID: packageID,
    firmwareVersion: "0.1.0-dev.12",
    firmwareSHA256: String(repeating: "a", count: 64),
    firmwareSizeBytes: 600_000,
    approvedAt: "2026-08-17T12:00:00Z"
  )
  let object = try #require(
    JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any]
  )
  #expect(object["contract"] as? String == "gateway.ota-control-request")
  #expect(object["package_id"] as? String == packageID.uuidString)
  #expect(object["firmware_sha256"] as? String == String(repeating: "a", count: 64))
  #expect(object["firmware_size_bytes"] as? Int == 600_000)

  let status = try VHOSJSON.decoder().decode(
    GatewayOTAStatus.self,
    from: Data(
      """
      {"bearer_token":"token","contract":"gateway.ota-status","contract_version":"1.0.0","detail":"ready","expires_in_seconds":300,"firmware_version":"0.1.0-dev.12","gateway_id":"esp32-b08d14","maximum_image_bytes":1572864,"package_id":"\(packageID.uuidString)","passphrase":"password","session_active":true,"ssid":"VHOS-OTA-B08D14","state":"NETWORK_READY","upload_url":"http://192.168.4.1/api/v1/ota/image"}
      """.utf8))
  #expect(status.networkReady)
  #expect(status.gatewayID == "esp32-b08d14")
  #expect(status.packageID == packageID)
  #expect(status.uploadURL == "http://192.168.4.1/api/v1/ota/image")
}

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

@Test func captureLogChunkValidatesRecordsAndPreservesEvidenceLineage() throws {
  var record = Data(repeating: 0, count: 36)
  record[0] = 1
  record[1] = 0x04
  record[2] = 8
  record[3] = 1
  func write<T: FixedWidthInteger>(_ value: T, at offset: Int) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { bytes in
      record.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
  }
  write(UInt32(0x7E8), at: 4)
  write(UInt64(91), at: 8)
  write(UInt64(1_500_000), at: 16)
  record.replaceSubrange(24..<32, with: [0x06, 0x41, 0x00, 0xBE, 0x3E, 0xB8, 0x13, 0x10])
  write(CRC32C.checksum(record.prefix(32)), at: 32)

  var payload = Data(repeating: 0, count: 16)
  payload[0] = 1
  payload[1] = 0
  payload[2] = 1
  func writeHeader<T: FixedWidthInteger>(_ value: T, at offset: Int) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { bytes in
      payload.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
  }
  writeHeader(UInt32(12), at: 4)
  writeHeader(UInt16(1), at: 8)
  writeHeader(UInt16(36), at: 10)
  writeHeader(UInt32(44), at: 12)
  payload.append(record)

  let chunk = try CaptureLogChunk.decode(
    payload,
    gatewayID: "esp32-test",
    ingestedAt: "2026-08-16T23:00:00Z"
  )

  #expect(chunk.recordOffset == 12)
  #expect(chunk.endOfFile)
  #expect(chunk.records.first?.sessionID == 44)
  #expect(chunk.records.first?.sourceSequence == 91)
  #expect(chunk.records.first?.identifierHex == "7E8")
  #expect(chunk.records.first?.dataHex == "06 41 00 BE 3E B8 13 10")
  #expect(chunk.records.first?.listenOnly == true)
  #expect(chunk.records.first?.evidenceSource == "gateway-flash")
}

@Test func captureLogIndexDecodesSnakeCaseSessionIdentifiers() throws {
  let payload = Data(
    """
    {
      "contract":"gateway.capture-log-index","contract_version":"1.0.0",
      "current_bytes":68,"current_records":1,"current_session_id":3088939464,
      "free_bytes":900000,"logging":true,"mounted":true,"observed_frames":10,
      "previous_bytes":32,"previous_records":0,"previous_session_id":7,
      "queue_dropped_records":0,"record_bytes":36,"retained_records":1,
      "sample_suppressed_frames":9,"sampled_frames":1,"storage_write_failures":0,
      "total_bytes":983040
    }
    """.utf8)

  let index = try VHOSJSON.decoder().decode(CaptureLogIndex.self, from: payload)

  #expect(index.currentSessionID == 3_088_939_464)
  #expect(index.previousSessionID == 7)
  #expect(index.recordBytes == 36)
  #expect(index.logging)
}
