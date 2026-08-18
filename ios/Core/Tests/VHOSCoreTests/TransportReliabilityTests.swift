import CryptoKit
import Foundation
import Testing

@testable import VHOSCore

private let reliabilityFixtureName = "real-can-2026-08-18-627753796-256"
private let reliabilityFixtureSHA256 =
  "af2305021c2d48d89c55d1739da407d78ee28baa39cce63125d0656672f58aed"

@Test func realEvidenceSustainsFortyCyclesWhileIdentityLedgerRejectsReplayDuplicates() throws {
  let fixture = try loadReliabilityFixture()
  let cycles = 40
  var decoder = GatewayFrameStreamDecoder()
  var ledger = TransportReliabilityLedger()
  var accepted: [PassiveCANObservation] = []

  var wire = Data()

  for cycle in 0..<cycles {
    for (index, observation) in fixture.enumerated() {
      let outerSequence = UInt64(cycle * fixture.count + index + 1)
      wire.append(
        GatewayFrame(
          messageType: .rawCANFrame,
          sequence: outerSequence,
          monotonicMicroseconds: outerSequence * 2_000,
          payload: try observation.encodedLivePayload()
        ).encoded())
    }
  }

  let sizes = [1, 3, 20, 244, 5, 509, 64, 17, 1_024]
  var offset = 0
  var chunkIndex = 0
  while offset < wire.count {
    let count = min(sizes[chunkIndex % sizes.count], wire.count - offset)
    try consumeReliabilityChunk(
      Data(wire[offset..<(offset + count)]),
      decoder: &decoder,
      ledger: &ledger,
      accepted: &accepted,
      gatewayID: fixture[0].gatewayID
    )
    offset += count
    chunkIndex += 1
  }

  #expect(accepted.map(reliabilitySemantics) == fixture.map(reliabilitySemantics))
  #expect(ledger.snapshot.acceptedUniqueEvidence == 256)
  #expect(ledger.snapshot.duplicateEvidenceRejections == 9_984)
  #expect(decoder.recoveryCount == 0)
  #expect(decoder.bufferedByteCount == 0)
  #expect(decoder.maximumBufferedByteCount < 262_144)
}

@Test func realEvidenceRecoversAfterLossCorruptionAndNotificationReordering() throws {
  let fixture = try loadReliabilityFixture()
  for fault in ReliabilityFault.allCases {
    var decoder = GatewayFrameStreamDecoder()
    var ledger = TransportReliabilityLedger()
    var accepted: [PassiveCANObservation] = []
    var expected: [PassiveCANObservation] = []

    for (index, observation) in fixture.enumerated() {
      let outerSequence = UInt64(index + 1)
      let wire = GatewayFrame(
        messageType: .rawCANFrame,
        sequence: outerSequence,
        monotonicMicroseconds: outerSequence * 2_000,
        payload: try observation.encodedLivePayload()
      ).encoded()
      var fragments = reliabilityFragments(wire, sizes: [20])
      let impaired = (index + 1).isMultiple(of: fault.interval) && index + 1 < fixture.count
      if !impaired {
        expected.append(observation)
      } else {
        switch fault {
        case .notificationLoss:
          fragments.remove(at: min(2, fragments.count - 1))
        case .payloadCorruption:
          var damaged = wire
          damaged[GatewayFrame.headerLength + 4] ^= 0x80
          fragments = reliabilityFragments(damaged, sizes: [20])
        case .notificationReorder:
          fragments.swapAt(2, 3)
        }
      }
      for fragment in fragments {
        try consumeReliabilityChunk(
          fragment,
          decoder: &decoder,
          ledger: &ledger,
          accepted: &accepted,
          gatewayID: observation.gatewayID
        )
      }
    }

    #expect(
      accepted.map(reliabilitySemantics) == expected.map(reliabilitySemantics),
      "Fault \(fault) changed a surviving record"
    )
    #expect(decoder.recoveryCount > 0)
    #expect(decoder.corruptCandidateCount > 0)
    #expect(decoder.bufferedByteCount == 0)
    #expect(decoder.maximumBufferedByteCount < 262_144)
  }
}

@Test func reconnectClearsDeadBytesAndRejectsOldEpochWithoutForgettingEvidenceIdentity() throws {
  let fixture = try loadReliabilityFixture()
  let firstFrame = GatewayFrame(
    messageType: .rawCANFrame,
    sequence: 1,
    monotonicMicroseconds: 2_000,
    payload: try fixture[0].encodedLivePayload()
  ).encoded()
  let secondFrame = GatewayFrame(
    messageType: .rawCANFrame,
    sequence: 1,
    monotonicMicroseconds: 4_000,
    payload: try fixture[1].encodedLivePayload()
  ).encoded()
  var decoder = GatewayFrameStreamDecoder()
  var ledger = TransportReliabilityLedger()
  var accepted: [PassiveCANObservation] = []

  #expect(
    ledger.receive(fixture[0], outerSequence: 1, linkEpoch: ledger.activeLinkEpoch)
      == .accepted)

  _ = try decoder.append(Data(firstFrame.prefix(41)))
  #expect(decoder.bufferedByteCount == 41)
  decoder.resetBufferPreservingDiagnostics()
  #expect(decoder.bufferedByteCount == 0)
  #expect(decoder.recoveryCount == 1)

  let priorEpoch = ledger.activeLinkEpoch
  let currentEpoch = ledger.beginReconnectedPhysicalLink()
  #expect(
    ledger.receive(fixture[0], outerSequence: 1, linkEpoch: priorEpoch) == .staleLinkEpoch)
  #expect(
    ledger.receive(fixture[0], outerSequence: 1, linkEpoch: currentEpoch)
      == .duplicateEvidence)

  try consumeReliabilityChunk(
    secondFrame,
    decoder: &decoder,
    ledger: &ledger,
    accepted: &accepted,
    gatewayID: fixture[0].gatewayID,
    linkEpoch: currentEpoch
  )
  #expect(accepted.map(reliabilitySemantics) == [fixture[1]].map(reliabilitySemantics))
  let snapshot = ledger.snapshot
  #expect(snapshot.reconnects == 1)
  #expect(snapshot.staleEpochRejections == 1)
  #expect(snapshot.duplicateEvidenceRejections == 1)
  #expect(snapshot.acceptedUniqueEvidence == 2)
  #expect(snapshot.quality == .degraded)
}

@Test func burstDeliveryKeepsDecoderMemoryBoundedAndPreservesExactOrder() throws {
  let fixture = try loadReliabilityFixture()
  var decoder = GatewayFrameStreamDecoder()
  var ledger = TransportReliabilityLedger()
  var accepted: [PassiveCANObservation] = []

  for offset in stride(from: 0, to: fixture.count, by: 64) {
    var burst = Data()
    for index in offset..<min(offset + 64, fixture.count) {
      let sequence = UInt64(index + 1)
      burst.append(
        GatewayFrame(
          messageType: .rawCANFrame,
          sequence: sequence,
          monotonicMicroseconds: sequence * 2_000,
          payload: try fixture[index].encodedLivePayload()
        ).encoded())
    }
    try consumeReliabilityChunk(
      burst,
      decoder: &decoder,
      ledger: &ledger,
      accepted: &accepted,
      gatewayID: fixture[0].gatewayID
    )
  }

  #expect(accepted.map(reliabilitySemantics) == fixture.map(reliabilitySemantics))
  #expect(decoder.maximumBufferedByteCount == 4_608)
  #expect(decoder.bufferedByteCount == 0)
  #expect(ledger.snapshot.quality == .healthy)
}

private enum ReliabilityFault: CaseIterable, CustomStringConvertible {
  case notificationLoss
  case payloadCorruption
  case notificationReorder

  var interval: Int {
    switch self {
    case .notificationLoss: 41
    case .payloadCorruption: 43
    case .notificationReorder: 47
    }
  }

  var description: String {
    switch self {
    case .notificationLoss: "notification-loss"
    case .payloadCorruption: "payload-corruption"
    case .notificationReorder: "notification-reorder"
    }
  }
}

private func consumeReliabilityChunk(
  _ chunk: Data,
  decoder: inout GatewayFrameStreamDecoder,
  ledger: inout TransportReliabilityLedger,
  accepted: inout [PassiveCANObservation],
  gatewayID: String,
  linkEpoch: UInt64? = nil
) throws {
  let epoch = linkEpoch ?? ledger.activeLinkEpoch
  for frame in try decoder.append(chunk) {
    let observation = try PassiveCANObservation.decodeLive(
      frame.payload,
      gatewayID: gatewayID,
      ingestedAt: "2026-08-18T00:00:00Z"
    )
    if ledger.receive(observation, outerSequence: frame.sequence, linkEpoch: epoch) == .accepted {
      accepted.append(observation)
    }
  }
}

private func reliabilityFragments(_ wire: Data, sizes: [Int]) -> [Data] {
  var result: [Data] = []
  var offset = 0
  var index = 0
  while offset < wire.count {
    let count = min(sizes[index % sizes.count], wire.count - offset)
    result.append(Data(wire[offset..<(offset + count)]))
    offset += count
    index += 1
  }
  return result
}

private func loadReliabilityFixture() throws -> [PassiveCANObservation] {
  let url = try #require(
    Bundle.module.url(
      forResource: reliabilityFixtureName,
      withExtension: "ndjson",
      subdirectory: "Fixtures"
    ))
  let raw = try Data(contentsOf: url)
  let digest = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
  #expect(digest == reliabilityFixtureSHA256)
  return try raw.split(separator: 0x0A).map { line in
    try VHOSJSON.decoder().decode(PassiveCANObservation.self, from: Data(line))
  }
}

private func reliabilitySemantics(_ observation: PassiveCANObservation) -> String {
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
