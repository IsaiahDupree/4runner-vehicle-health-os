import CryptoKit
import Foundation
import Testing

@testable import VHOSCore

private let realCANFixtureName = "real-can-2026-08-18-627753796-256"
private let realCANFixtureSHA256 =
  "af2305021c2d48d89c55d1739da407d78ee28baa39cce63125d0656672f58aed"

@Test func realCapturedCANFixtureIsPinnedAndRoundTripsTheDeployedLiveRecord() throws {
  let (raw, observations) = try loadRealCANFixture()

  #expect(
    SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined() == realCANFixtureSHA256)
  #expect(observations.count == 256)
  #expect(observations.allSatisfy { $0.sessionID == 627_753_796 })
  #expect(observations.allSatisfy { $0.listenOnly && $0.bitrateBps == 500_000 })

  for observation in observations {
    let decoded = try PassiveCANObservation.decodeLive(
      observation.encodedLivePayload(),
      gatewayID: observation.gatewayID,
      ingestedAt: observation.ingestedAt
    )
    #expect(replaySemantics(decoded) == replaySemantics(observation))
  }
}

@Test func realCapturedCANFixtureSustainsTwentyReplaysAcrossHostileFragments() throws {
  let (_, fixture) = try loadRealCANFixture()
  let expected = Array(repeating: fixture, count: 20).flatMap { $0 }
  var wire = Data()
  for (index, observation) in expected.enumerated() {
    wire.append(
      GatewayFrame(
        messageType: .rawCANFrame,
        sequence: UInt64(index + 1),
        monotonicMicroseconds: UInt64(index) * 2_000,
        payload: try observation.encodedLivePayload()
      ).encoded())
  }

  let sizes = [1, 3, 20, 244, 5, 509, 64, 17, 1_024]
  var decoder = GatewayFrameStreamDecoder()
  var decoded: [PassiveCANObservation] = []
  var offset = 0
  var chunk = 0
  while offset < wire.count {
    let count = min(sizes[chunk % sizes.count], wire.count - offset)
    for frame in try decoder.append(Data(wire[offset..<(offset + count)])) {
      decoded.append(
        try PassiveCANObservation.decodeLive(
          frame.payload,
          gatewayID: fixture[0].gatewayID,
          ingestedAt: fixture[0].ingestedAt
        ))
    }
    offset += count
    chunk += 1
  }

  #expect(decoded.count == 5_120)
  #expect(decoded.map(replaySemantics) == expected.map(replaySemantics))
  #expect(decoder.recoveryCount == 0)
  #expect(decoder.discardedByteCount == 0)
  #expect(decoder.bufferedByteCount == 0)
}

@Test func liveObservationRequiresExactCurrentRecorderContext() throws {
  let (_, observations) = try loadRealCANFixture()
  let observation = try #require(observations.first)

  #expect(
    observation.matchesRecorderContext(
      gatewayID: observation.gatewayID, captureSessionID: observation.sessionID))
  #expect(
    !observation.matchesRecorderContext(
      gatewayID: observation.gatewayID, captureSessionID: observation.sessionID + 1))
  #expect(
    !observation.matchesRecorderContext(
      gatewayID: "esp32-different", captureSessionID: observation.sessionID))
}

private func loadRealCANFixture() throws -> (Data, [PassiveCANObservation]) {
  let url = try #require(
    Bundle.module.url(
      forResource: realCANFixtureName, withExtension: "ndjson", subdirectory: "Fixtures")
  )
  let raw = try Data(contentsOf: url)
  let observations = try raw.split(separator: 0x0A).map { line in
    try VHOSJSON.decoder().decode(PassiveCANObservation.self, from: Data(line))
  }
  return (raw, observations)
}

private func replaySemantics(_ observation: PassiveCANObservation) -> String {
  [
    observation.gatewayID,
    String(observation.sessionID),
    String(observation.sourceSequence),
    String(observation.monotonicMicroseconds),
    String(observation.bitrateBps),
    String(observation.identifier),
    String(observation.extended),
    String(observation.remoteRequest),
    String(observation.listenOnly),
    String(observation.dataLength),
    observation.data.map(String.init).joined(separator: ","),
  ].joined(separator: "|")
}
