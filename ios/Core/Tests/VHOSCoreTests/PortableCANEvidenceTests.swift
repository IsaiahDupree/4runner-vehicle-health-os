import Foundation
import Testing

@testable import VHOSCore

private let portableCANFixtureName = "real-can-2026-08-18-627753796-256"

@Test func portableCANProjectionDecodesLiveAndFlashAndPrefersFlashOverlap() throws {
  let observation = try #require(try loadPortableCANFixture().first)
  let live = try portableCANRecord(
    observation: observation,
    messageType: .rawCANFrame,
    frameSequence: 10,
    ingestedAt: "2026-08-22T12:00:00Z"
  )
  let flash = try portableCANRecord(
    observation: observation,
    messageType: .captureLogChunk,
    frameSequence: 11,
    ingestedAt: "2026-08-22T12:00:01Z"
  )

  let projected = try PortableCANEvidence.project([live, flash])
  let reverseOrder = try PortableCANEvidence.project([flash, live])
  let result = try #require(projected.first)

  #expect(projected.count == 1)
  #expect(reverseOrder == projected)
  #expect(result.id == observation.id)
  #expect(result.evidenceSource == "gateway-flash")
  #expect(result.ingestedAt == "2026-08-22T12:00:01Z")
  #expect(result.identifier == observation.identifier)
  #expect(result.data == observation.data)
}

@Test func portableCANProjectionSkipsValidatedNonCANFrames() throws {
  let frame = GatewayFrame(
    messageType: .gatewayHealth,
    sequence: 1,
    monotonicMicroseconds: 2,
    payload: Data("{\"contract\":\"gateway.health\"}".utf8)
  )
  let record = PortableLogicalFrame(
    frame: frame,
    sourceRole: .acSensor,
    sourceID: "ac-sensor",
    ingestedAt: "2026-08-22T12:00:00Z"
  )

  #expect(try PortableCANEvidence.project([record]).isEmpty)
}

@Test func portableCANProjectionRejectsCANFromACSensorRole() throws {
  let observation = try #require(try loadPortableCANFixture().first)
  let record = try portableCANRecord(
    observation: observation,
    messageType: .rawCANFrame,
    sourceRole: .acSensor,
    frameSequence: 20,
    ingestedAt: "2026-08-22T12:00:00Z"
  )

  #expect(throws: PortableCANEvidenceError.self) {
    try PortableCANEvidence.project([record])
  }
}

@Test func portableCANProjectionRejectsMissingListenOnlyProof() throws {
  let source = try #require(try loadPortableCANFixture().first)
  let unsafe = replacing(source, listenOnly: false)
  let record = try portableCANRecord(
    observation: unsafe,
    messageType: .rawCANFrame,
    frameSequence: 30,
    ingestedAt: "2026-08-22T12:00:00Z"
  )

  #expect(throws: PassiveCANArchiveError.self) {
    try PortableCANEvidence.project([record])
  }
}

@Test func portableCANReconciliationRejectsConflictingPhysicalEvidence() throws {
  let source = try #require(try loadPortableCANFixture().first)
  var changedData = source.data
  changedData[0] ^= 0x01
  let conflicting = replacing(source, data: changedData, evidenceSource: "ble-live")

  #expect(throws: PortableCANEvidenceError.self) {
    try PortableCANEvidence.reconcile(existing: [source], projected: [conflicting])
  }
}

@Test func portableCANReconciliationRejectsUnknownProvenance() throws {
  let source = try #require(try loadPortableCANFixture().first)
  let unknown = replacing(source, evidenceSource: "unverified-import")

  #expect(throws: PortableCANEvidenceError.self) {
    try PortableCANEvidence.reconcile(existing: [], projected: [unknown])
  }
}

private func portableCANRecord(
  observation: PassiveCANObservation,
  messageType: GatewayMessageType,
  sourceRole: EvidenceSourceRole = .obdCAN,
  frameSequence: UInt64,
  ingestedAt: String
) throws -> PortableLogicalFrame {
  let payload: Data
  switch messageType {
  case .rawCANFrame:
    payload = try observation.encodedLivePayload()
  case .captureLogChunk:
    payload = captureLogChunkPayload(observation)
  default:
    Issue.record("The portable CAN test helper only supports CAN evidence messages.")
    payload = Data()
  }
  return PortableLogicalFrame(
    frame: GatewayFrame(
      messageType: messageType,
      sequence: frameSequence,
      monotonicMicroseconds: observation.monotonicMicroseconds,
      payload: payload
    ),
    sourceRole: sourceRole,
    sourceID: observation.gatewayID,
    ingestedAt: ingestedAt
  )
}

private func captureLogChunkPayload(_ observation: PassiveCANObservation) -> Data {
  var record = Data(repeating: 0, count: 36)
  record[0] = 1
  record[1] =
    (observation.extended ? 0x01 : 0)
    | (observation.remoteRequest ? 0x02 : 0)
    | (observation.listenOnly ? 0x04 : 0)
  record[2] = observation.dataLength
  record[3] = observation.bitrateBps == 250_000 ? 2 : 1
  write(observation.identifier, to: &record, at: 4)
  write(observation.sourceSequence, to: &record, at: 8)
  write(observation.monotonicMicroseconds, to: &record, at: 16)
  record.replaceSubrange(24..<32, with: observation.data)
  write(CRC32C.checksum(record.prefix(32)), to: &record, at: 32)

  var payload = Data(repeating: 0, count: 16)
  payload[0] = 1
  payload[2] = 1
  write(UInt16(1), to: &payload, at: 8)
  write(UInt16(36), to: &payload, at: 10)
  write(observation.sessionID, to: &payload, at: 12)
  payload.append(record)
  return payload
}

private func write<T: FixedWidthInteger>(_ value: T, to data: inout Data, at offset: Int) {
  var littleEndian = value.littleEndian
  withUnsafeBytes(of: &littleEndian) { bytes in
    data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
  }
}

private func replacing(
  _ source: PassiveCANObservation,
  listenOnly: Bool? = nil,
  data: [UInt8]? = nil,
  evidenceSource: String? = nil
) -> PassiveCANObservation {
  PassiveCANObservation(
    gatewayID: source.gatewayID,
    sessionID: source.sessionID,
    sourceSequence: source.sourceSequence,
    monotonicMicroseconds: source.monotonicMicroseconds,
    bitrateBps: source.bitrateBps,
    identifier: source.identifier,
    extended: source.extended,
    remoteRequest: source.remoteRequest,
    listenOnly: listenOnly ?? source.listenOnly,
    dataLength: source.dataLength,
    data: data ?? source.data,
    evidenceSource: evidenceSource ?? source.evidenceSource,
    ingestedAt: source.ingestedAt
  )
}

private func loadPortableCANFixture() throws -> [PassiveCANObservation] {
  let url = try #require(
    Bundle.module.url(
      forResource: portableCANFixtureName,
      withExtension: "ndjson",
      subdirectory: "Fixtures"
    )
  )
  return try PassiveCANEvidenceArchive.decodeNDJSON(Data(contentsOf: url))
}
