import Foundation
import Testing

@testable import VHOSCore

// The live engineering-units lane. These pin the two properties that make
// a live gauge trustworthy: it shares its math with the retained analysis,
// and it tells the truth when the bus goes quiet.

private func frame(
  identifier: UInt32 = 0x2C4,
  data: [UInt8],
  gatewayID: String = "esp32-9454c5b08d14",
  sessionID: UInt32 = 1_007_674_331,
  sourceSequence: UInt64,
  monotonicMicroseconds: UInt64 = 1_000,
  extended: Bool = false,
  remoteRequest: Bool = false,
  listenOnly: Bool = true,
  dataLength: UInt8 = 8,
  evidenceSource: String = "ble-live",
  ingestedAt: String = "2026-08-28T15:00:00Z"
) -> PassiveCANObservation {
  PassiveCANObservation(
    gatewayID: gatewayID,
    sessionID: sessionID,
    sourceSequence: sourceSequence,
    monotonicMicroseconds: monotonicMicroseconds,
    bitrateBps: 500_000,
    identifier: identifier,
    extended: extended,
    remoteRequest: remoteRequest,
    listenOnly: listenOnly,
    dataLength: dataLength,
    data: data,
    evidenceSource: evidenceSource,
    ingestedAt: ingestedAt)
}

// 997 counts × 0.78125 rpm/count = 778.90625 rpm — the exact value on the
// device's retained dashboard, so live and retained provably agree.
private let engineSpeed997: [UInt8] = [0x03, 0xE5, 0, 0, 0, 0, 0, 0]

@Test func liveProjectionMatchesTheRetainedTransformExactly() throws {
  let readings = CANUnitsAnalyzer.projectLive(
    frame(data: engineSpeed997, sourceSequence: 1))
  let rpm = try #require(readings.first { $0.signalID == "engine.speed" })

  #expect(rpm.rawValue == 997)
  #expect(abs(rpm.displayValue - 778.90625) < 0.000_01)
  #expect(rpm.unit == "rpm")
  #expect(rpm.authority == .unverifiedCandidateUnit)
}

@Test func liveNeverLaundersAnUnvalidatedTransformIntoObserved() {
  // Every pinned candidate is unverified or raw-only. Nothing in the live
  // lane may claim OBSERVED_STANDARD — that authority belongs to SAE
  // J1979 decoding, not to a candidate formula that happens to be current.
  let authorities = Set(CANUnitsAnalyzer.candidateFields.map(\.authority))

  #expect(!authorities.contains(.observedStandard))
  #expect(authorities.isSubset(of: [.unverifiedCandidateUnit, .rawOnlyCandidate]))
}

@Test func rawOnlyCandidatesExposeNoEngineeringUnit() {
  for field in CANUnitsAnalyzer.candidateFields where field.authority == .rawOnlyCandidate {
    #expect(field.unit == nil, "raw-only candidate \(field.id) must not present a unit")
    #expect(!field.authority.exposesEngineeringUnit)
  }
}

@Test func aQuietBusGoesStaleThenExpiredNeverFrozenAsCurrent() throws {
  var accumulator = CANLiveUnitsAccumulator()
  let start = Date(timeIntervalSince1970: 1_800_000_000)
  accumulator.ingest(frame(data: engineSpeed997, sourceSequence: 1), receivedAt: start)

  let fresh = try #require(
    accumulator.channel(for: "toyota.2c4.engine-speed.be16", now: start.addingTimeInterval(1)))
  #expect(fresh.freshness == .live)

  let quiet = try #require(
    accumulator.channel(for: "toyota.2c4.engine-speed.be16", now: start.addingTimeInterval(9)))
  #expect(quiet.freshness == .stale)
  // The value is still readable — it is simply no longer claimed as now.
  #expect(quiet.latest?.displayValue == fresh.latest?.displayValue)

  let abandoned = try #require(
    accumulator.channel(for: "toyota.2c4.engine-speed.be16", now: start.addingTimeInterval(120)))
  #expect(abandoned.freshness == .expired)
}

@Test func repeatedSequenceNumbersAreNotCountedAsNewEvidence() throws {
  // The same lesson as the marker ledger: a frame that does not advance
  // the source sequence within a session is not a second observation.
  var accumulator = CANLiveUnitsAccumulator()
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  #expect(!accumulator.ingest(frame(data: engineSpeed997, sourceSequence: 7), receivedAt: now).isEmpty)
  #expect(accumulator.ingest(frame(data: engineSpeed997, sourceSequence: 7), receivedAt: now).isEmpty)
  #expect(accumulator.ingest(frame(data: engineSpeed997, sourceSequence: 6), receivedAt: now).isEmpty)

  let channel = try #require(
    accumulator.channel(for: "toyota.2c4.engine-speed.be16", now: now))
  #expect(channel.sampleCount == 1)
}

@Test func theRollingWindowEvictsOldestAndKeepsOrder() throws {
  var accumulator = CANLiveUnitsAccumulator(capacity: 3)
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  for (index, counts) in [UInt16(800), 1_600, 2_400, 3_200].enumerated() {
    let bytes: [UInt8] = [UInt8(counts >> 8), UInt8(counts & 0xFF), 0, 0, 0, 0, 0, 0]
    accumulator.ingest(
      frame(data: bytes, sourceSequence: UInt64(index + 1)), receivedAt: now)
  }

  let channel = try #require(
    accumulator.channel(for: "toyota.2c4.engine-speed.be16", now: now))
  #expect(channel.sampleCount == 3)
  #expect(channel.window.count == 3)
  // oldest-first, and the very first sample (800 counts) was evicted
  #expect(channel.window == [1_600, 2_400, 3_200].map { Double($0) * 0.78125 })
  #expect(channel.latest?.rawValue == 3_200)
}

@Test func oneFrameCanFeedEveryFieldThatClaimsIt() {
  // 0x2C4 carries engine speed (bytes 0-1) and intake air temperature
  // (byte 3): one frame, two readings, no duplication of math.
  let readings = CANUnitsAnalyzer.projectLive(
    frame(data: [0x03, 0xE5, 0x00, 0x5A, 0, 0, 0, 0], sourceSequence: 1))

  #expect(readings.count >= 2)
  #expect(readings.contains { $0.signalID == "engine.speed" })
  #expect(readings.contains { $0.signalID == "engine.intake-air-temperature" })
}

@Test func pinnedIdentifierAlsoKeepsAnExactUnitlessRawFrameChannel() throws {
  var accumulator = CANLiveUnitsAccumulator()
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let payload: [UInt8] = [0x03, 0xE5, 0xAA, 0x5A, 0x10, 0x20, 0x30, 0x40]

  _ = accumulator.ingest(
    frame(identifier: 0x2C4, data: payload, sourceSequence: 1), receivedAt: now)

  #expect(accumulator.observedFields.contains { $0.signalID == "engine.speed" })
  let raw = try #require(
    accumulator.observedRawIdentifiers.first { $0.identifier == 0x2C4 })
  #expect(raw.unit == nil)
  #expect(raw.authority == .rawOnlyCandidate)
  let rawChannel = try #require(accumulator.rawChannel(for: raw.id, now: now))
  #expect(rawChannel.latest.data == payload)
  #expect(rawChannel.latest.dataHex == "03 E5 AA 5A 10 20 30 40")
}

@Test func unknownIdentifierIsVisibleOnlyAsExactRawEvidence() throws {
  var accumulator = CANLiveUnitsAccumulator()
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let updated = accumulator.ingest(
    frame(
      identifier: 0x023, data: [0x02, 0x00, 0x02, 0x11, 0x38, 0x00, 0x77, 0xFF],
      sourceSequence: 1, dataLength: 7),
    receivedAt: now)

  let descriptor = try #require(accumulator.observedRawIdentifiers.first)
  #expect(updated == [descriptor.id])
  #expect(accumulator.hasSamples)
  #expect(accumulator.observedFields.isEmpty)
  #expect(descriptor.identifier == 0x023)
  #expect(descriptor.label == "CAN 0x023")
  #expect(descriptor.authority == .rawOnlyCandidate)
  #expect(descriptor.unit == nil)
  #expect(!descriptor.authority.exposesEngineeringUnit)
  let channel = try #require(accumulator.rawChannel(for: descriptor.id, now: now))
  #expect(channel.latest.dataLength == 7)
  #expect(channel.latest.data == [0x02, 0x00, 0x02, 0x11, 0x38, 0x00, 0x77])
  #expect(channel.latest.dataHex == "02 00 02 11 38 00 77")
}

@Test func rawIdentifierInventoryIsBoundedByLeastRecentUpdate() {
  var accumulator = CANLiveUnitsAccumulator(rawIdentifierCapacity: 2)
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  accumulator.ingest(
    frame(identifier: 0x600, data: [1, 0, 0, 0, 0, 0, 0, 0], sourceSequence: 1),
    receivedAt: now)
  accumulator.ingest(
    frame(identifier: 0x601, data: [2, 0, 0, 0, 0, 0, 0, 0], sourceSequence: 2),
    receivedAt: now)
  // Refresh 0x600 so 0x601 is the least-recently-updated identifier.
  accumulator.ingest(
    frame(identifier: 0x600, data: [3, 0, 0, 0, 0, 0, 0, 0], sourceSequence: 3),
    receivedAt: now)
  accumulator.ingest(
    frame(identifier: 0x602, data: [4, 0, 0, 0, 0, 0, 0, 0], sourceSequence: 4),
    receivedAt: now)

  let identifiers = Set(accumulator.observedRawIdentifiers.map(\.identifier))
  #expect(accumulator.observedRawIdentifiers.count == 2)
  #expect(identifiers == [0x600, 0x602])
}

@Test func rawIdentifierUpdatesAreExactAndDuplicateSequencesDoNotCount() throws {
  var accumulator = CANLiveUnitsAccumulator()
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let first = frame(
    identifier: 0x223, data: [0x10, 0x20, 0x30, 0, 0, 0, 0, 0], sourceSequence: 10)
  let second = frame(
    identifier: 0x223, data: [0x10, 0x21, 0x30, 0, 0, 0, 0, 0], sourceSequence: 11)
  #expect(!accumulator.ingest(first, receivedAt: now).isEmpty)
  #expect(!accumulator.ingest(second, receivedAt: now.addingTimeInterval(1)).isEmpty)
  #expect(accumulator.ingest(second, receivedAt: now.addingTimeInterval(2)).isEmpty)

  let descriptor = try #require(accumulator.observedRawIdentifiers.first)
  let channel = try #require(
    accumulator.rawChannel(for: descriptor.id, now: now.addingTimeInterval(2)))
  #expect(channel.sampleCount == 2)
  #expect(channel.latest.sourceSequence == 11)
  #expect(channel.latest.dataHex == "10 21 30 00 00 00 00 00")
  #expect(channel.changedByteIndices == [1])
  #expect(!channel.dataLengthChanged)
}

@Test func rawIdentifierExpiresAndSessionResetRemovesOldInventory() throws {
  var accumulator = CANLiveUnitsAccumulator()
  let start = Date(timeIntervalSince1970: 1_800_000_000)
  accumulator.ingest(
    frame(identifier: 0x3D0, data: [1, 2, 3, 4, 5, 6, 7, 8], sourceSequence: 1),
    receivedAt: start)
  let descriptor = try #require(accumulator.observedRawIdentifiers.first)
  #expect(
    accumulator.rawChannel(for: descriptor.id, now: start.addingTimeInterval(1))?.freshness
      == .live)
  #expect(
    accumulator.rawChannel(for: descriptor.id, now: start.addingTimeInterval(9))?.freshness
      == .stale)
  #expect(
    accumulator.rawChannel(for: descriptor.id, now: start.addingTimeInterval(31))?.freshness
      == .expired)

  accumulator.reset()
  #expect(accumulator.observedRawIdentifiers.isEmpty)
  #expect(accumulator.rawChannel(for: descriptor.id, now: start) == nil)
  accumulator.ingest(
    frame(
      identifier: 0x420, data: [9, 8, 7, 6, 5, 4, 3, 2], sessionID: 2,
      sourceSequence: 1),
    receivedAt: start)
  #expect(accumulator.observedRawIdentifiers.map(\.identifier) == [0x420])
}

@Test func standardAndExtendedRawIdentifiersNeverCollide() {
  var accumulator = CANLiveUnitsAccumulator()
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  accumulator.ingest(
    frame(identifier: 0x600, data: [1, 0, 0, 0, 0, 0, 0, 0], sourceSequence: 1),
    receivedAt: now)
  accumulator.ingest(
    frame(
      identifier: 0x600, data: [2, 0, 0, 0, 0, 0, 0, 0], sourceSequence: 2,
      extended: true),
    receivedAt: now)

  let descriptors = accumulator.observedRawIdentifiers
  #expect(descriptors.count == 2)
  #expect(Set(descriptors.map(\.id)).count == 2)
  #expect(Set(descriptors.map(\.extended)) == [false, true])
}

@Test func remoteRequestDLCNeverBecomesZeroFilledPayload() throws {
  var accumulator = CANLiveUnitsAccumulator()
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  accumulator.ingest(
    frame(
      identifier: 0x600, data: [0, 0, 0, 0, 0, 0, 0, 0], sourceSequence: 1,
      remoteRequest: true, dataLength: 7),
    receivedAt: now)

  let descriptor = try #require(accumulator.observedRawIdentifiers.first)
  let channel = try #require(accumulator.rawChannel(for: descriptor.id, now: now))
  #expect(channel.latest.remoteRequest)
  #expect(channel.latest.dataLength == 7)
  #expect(channel.latest.data.isEmpty)
  #expect(channel.latest.dataHex.isEmpty)
}

@Test func recentBatchFindsPinnedFrameBeforeUnclaimedTailAndPreservesItsAge() throws {
  var accumulator = CANLiveUnitsAccumulator()
  let observations = [
    frame(
      data: engineSpeed997, sourceSequence: 10, monotonicMicroseconds: 1_000,
      ingestedAt: "2026-08-28T15:00:00Z"),
    frame(
      identifier: 0x7FE, data: [1, 2, 3, 4, 5, 6, 7, 8], sourceSequence: 11,
      monotonicMicroseconds: 2_000, ingestedAt: "2026-08-28T15:00:08Z"),
  ]

  let updated = accumulator.ingestCurrentSession(
    observations, gatewayID: "esp32-9454c5b08d14", sessionID: 1_007_674_331)

  #expect(updated.contains("toyota.2c4.engine-speed.be16"))
  let now = try #require(ISO8601DateFormatter().date(from: "2026-08-28T15:00:09Z"))
  let channel = try #require(
    accumulator.channel(for: "toyota.2c4.engine-speed.be16", now: now))
  #expect(channel.latest?.sourceSequence == 10)
  #expect(channel.latest?.rawValue == 997)
  #expect(channel.ageSeconds == 9)
  #expect(channel.freshness == .stale)
}

@Test func recentBatchAcceptsOnlyCurrentListenOnlyBLESession() throws {
  var accumulator = CANLiveUnitsAccumulator()
  let observations = [
    frame(data: engineSpeed997, sourceSequence: 1),
    frame(
      data: [0x10, 0, 0, 0, 0, 0, 0, 0], gatewayID: "other-gateway",
      sourceSequence: 2),
    frame(
      data: [0x20, 0, 0, 0, 0, 0, 0, 0], sessionID: 77,
      sourceSequence: 3),
    frame(
      data: [0x30, 0, 0, 0, 0, 0, 0, 0], sourceSequence: 4,
      listenOnly: false),
    frame(
      data: [0x40, 0, 0, 0, 0, 0, 0, 0], sourceSequence: 5,
      evidenceSource: "gateway-flash"),
  ]

  _ = accumulator.ingestCurrentSession(
    observations, gatewayID: "esp32-9454c5b08d14", sessionID: 1_007_674_331)

  let now = try #require(ISO8601DateFormatter().date(from: "2026-08-28T15:00:01Z"))
  let channel = try #require(
    accumulator.channel(for: "toyota.2c4.engine-speed.be16", now: now))
  #expect(channel.sampleCount == 1)
  #expect(channel.latest?.sourceSequence == 1)
  #expect(channel.latest?.rawValue == 997)
}

@Test func onlyFieldsWithLiveEvidenceBecomeSelectable() throws {
  var accumulator = CANLiveUnitsAccumulator()
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  #expect(accumulator.observedFields.isEmpty)

  accumulator.ingest(frame(data: engineSpeed997, sourceSequence: 1), receivedAt: now)

  let observed = accumulator.observedFields
  #expect(observed.contains { $0.id == "toyota.2c4.engine-speed.be16" })
  // A 0x2D0 turbine-speed field exists in the catalog but has produced no
  // live sample, so it must not appear as a watchable channel.
  #expect(!observed.contains { $0.identifier == 0x2D0 })
  #expect(accumulator.channels(now: now).count == observed.count)
}

@Test func windowStatisticsDescribeTheLiveWindow() throws {
  var accumulator = CANLiveUnitsAccumulator()
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  for (index, counts) in [UInt16(0), 1_280, 2_560].enumerated() {
    let bytes: [UInt8] = [UInt8(counts >> 8), UInt8(counts & 0xFF), 0, 0, 0, 0, 0, 0]
    accumulator.ingest(
      frame(data: bytes, sourceSequence: UInt64(index + 1)), receivedAt: now)
  }

  let stats = try #require(
    accumulator.channel(for: "toyota.2c4.engine-speed.be16", now: now)?.statistics)
  #expect(stats.sampleCount == 3)
  #expect(stats.minimum == 0)
  #expect(abs(stats.maximum - 2_000) < 0.000_01)  // 2560 × 0.78125
  #expect(abs(stats.mean - 1_000) < 0.000_01)
  #expect(abs(stats.peakToPeak - 2_000) < 0.000_01)
}

@Test func resetClearsWindowsSoSessionsNeverBlend() throws {
  var accumulator = CANLiveUnitsAccumulator()
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  accumulator.ingest(frame(data: engineSpeed997, sourceSequence: 1), receivedAt: now)
  #expect(accumulator.hasSamples)

  accumulator.reset()

  #expect(!accumulator.hasSamples)
  let channel = try #require(
    accumulator.channel(for: "toyota.2c4.engine-speed.be16", now: now))
  #expect(channel.latest == nil)
  #expect(channel.freshness == .expired)
}
