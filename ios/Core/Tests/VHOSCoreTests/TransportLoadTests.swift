import Foundation
import Testing

@testable import VHOSCore

/// Contract traffic only: these payloads exercise framing, CRC32C, fragmentation, and ordering.
/// They are deliberately not presented as vehicle observations.
@Test func gatewayStreamSustains8192OrderedFramesAcrossHostileFragmentation() throws {
  let frameCount = 8_192
  let frames = (0..<frameCount).map { index in
    GatewayFrame(
      messageType: .gatewayHealth,
      sequence: UInt64(index + 1),
      monotonicMicroseconds: UInt64(index) * 2_000,
      payload: deterministicTransportPayload(index: index, byteCount: 160)
    )
  }
  var wire = Data()
  for frame in frames { wire.append(frame.encoded()) }

  let chunkSizes = [1, 3, 20, 244, 5, 509, 64, 17, 1024]
  var decoder = GatewayFrameStreamDecoder()
  var decoded: [GatewayFrame] = []
  var offset = 0
  var chunkIndex = 0
  while offset < wire.count {
    let count = min(chunkSizes[chunkIndex % chunkSizes.count], wire.count - offset)
    decoded.append(contentsOf: try decoder.append(Data(wire[offset..<(offset + count)])))
    offset += count
    chunkIndex += 1
  }

  #expect(decoded.count == frameCount)
  #expect(decoded == frames)
  #expect(decoded.last?.sequence == UInt64(frameCount))
  #expect(decoder.recoveryCount == 0)
  #expect(decoder.discardedByteCount == 0)
}

@Test func gatewayStreamRecoversAfterOneNotificationFragmentIsLost() throws {
  let first = GatewayFrame(
    messageType: .gatewayHealth,
    sequence: 41,
    monotonicMicroseconds: 82_000,
    payload: deterministicTransportPayload(index: 41, byteCount: 720)
  ).encoded()
  let second = GatewayFrame(
    messageType: .gatewayHealth,
    sequence: 42,
    monotonicMicroseconds: 84_000,
    payload: deterministicTransportPayload(index: 42, byteCount: 720)
  )
  let third = GatewayFrame(
    messageType: .gatewayHealth,
    sequence: 43,
    monotonicMicroseconds: 86_000,
    payload: deterministicTransportPayload(index: 43, byteCount: 720)
  )

  // This reproduces the field failure class: the first frame has a valid header,
  // but one ATT notification-sized payload range never reaches the receiver.
  var damagedWire = Data(first.prefix(244))
  damagedWire.append(first.dropFirst(488))
  damagedWire.append(second.encoded())
  damagedWire.append(third.encoded())

  var decoder = GatewayFrameStreamDecoder()
  var decoded: [GatewayFrame] = []
  for offset in stride(from: 0, to: damagedWire.count, by: 97) {
    decoded.append(
      contentsOf: try decoder.append(
        Data(damagedWire[offset..<min(offset + 97, damagedWire.count)])))
  }

  #expect(decoded == [second, third])
  #expect(decoder.recoveryCount > 0)
  #expect(decoder.corruptCandidateCount > 0)
  #expect(decoder.discardedByteCount > 0)
  #expect(decoder.bufferedByteCount == 0)
}

@Test func gatewayStreamRecoversFromNoiseAndCorruptPayloadWithoutResettingLink() throws {
  let first = GatewayFrame(
    messageType: .rawCANFrame,
    sequence: 90,
    monotonicMicroseconds: 180_000,
    payload: deterministicTransportPayload(index: 90, byteCount: 36)
  )
  let second = GatewayFrame(
    messageType: .rawCANFrame,
    sequence: 91,
    monotonicMicroseconds: 182_000,
    payload: deterministicTransportPayload(index: 91, byteCount: 36)
  )
  var corrupt = first.encoded()
  corrupt[GatewayFrame.headerLength + 4] ^= 0x80
  let wire = Data([0x00, 0x56, 0x48, 0x99, 0x01]) + corrupt + second.encoded()

  var decoder = GatewayFrameStreamDecoder()
  let decoded = try decoder.append(wire)

  #expect(decoded == [second])
  #expect(decoder.recoveryCount >= 2)
  #expect(decoder.corruptCandidateCount == 1)
  #expect(decoder.bufferedByteCount == 0)
}

@Test func evidenceBundleSustains2048ChecksummedRecordsThroughExportAndImport() throws {
  let recordCount = 2_048
  let records = (0..<recordCount).map { index in
    let frame = GatewayFrame(
      messageType: .gatewayHealth,
      sequence: UInt64(index + 1),
      monotonicMicroseconds: UInt64(index) * 2_000,
      payload: deterministicTransportPayload(index: index, byteCount: 96)
    )
    return PortableLogicalFrame(
      frame: frame,
      sourceRole: .obdCAN,
      sourceID: "transport-load-contract",
      ingestedAt: "2026-08-18T12:00:00Z"
    )
  }

  let archive = try EvidenceSyncBundle.encode(
    records: records,
    creator: EvidenceBundleCreator(
      platform: "IOS",
      applicationID: "com.isaiahdupree.VehicleHealthOS.tests",
      applicationVersion: "transport-load-v1",
      deviceModel: "host-contract-runner"
    ),
    bundleID: UUID(uuidString: "D61D85CF-5960-4AB4-86A5-2279D541F970")!,
    createdAt: "2026-08-18T12:00:00Z"
  )
  let imported = try EvidenceSyncBundle.decode(archive)
  let first = try #require(imported.records.first).validatedFrame()
  let last = try #require(imported.records.last).validatedFrame()

  #expect(imported.records.count == recordCount)
  #expect(imported.records == records)
  #expect(first.sequence == 1)
  #expect(last.sequence == UInt64(recordCount))
}

private func deterministicTransportPayload(index: Int, byteCount: Int) -> Data {
  Data((0..<byteCount).map { byte in UInt8((index &* 31 &+ byte &* 17) % 251) })
}
