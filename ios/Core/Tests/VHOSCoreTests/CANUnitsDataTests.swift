import Foundation
import Testing

@testable import VHOSCore

private let canUnitsFixtureName = "real-can-2026-08-18-627753796-256"
private let canUnitsFixtureSHA256 =
  "af2305021c2d48d89c55d1739da407d78ee28baa39cce63125d0656672f58aed"
private let canUnitsCorpusSessions = [
  "1007674331", "1846258254", "2020748856", "2175731012",
  "4020849719", "627753796", "628897492", "740616386",
]

@Test func realRetainedCANProducesUnitRowsFromEveryMatchingObservation() throws {
  let observations = try loadCANUnitsFixture()
  let result = try CANUnitsAnalyzer.analyze(observations: observations)

  #expect(result.evidenceSHA256 == canUnitsFixtureSHA256)
  #expect(result.observationCount == 256)
  #expect(result.sessionCount == 1)
  #expect(result.standardSignals.isEmpty)
  #expect(result.candidateSignals.count == 7)

  let engine = try #require(
    result.candidateSignals.first { $0.id == "toyota.2c4.engine-speed.be16" })
  let engineStats = try #require(engine.statistics)
  #expect(engine.authority == .unverifiedCandidateUnit)
  #expect(engine.unit == "rpm")
  #expect(engineStats.sampleCount == 32)
  #expect(engine.lineage.sampleCount == 32)
  #expect(engineStats.minimum == 0)
  #expect(engineStats.maximum == 1_394.53125)
  #expect(abs(engineStats.mean - 1_060.4248046875) < 0.000_000_001)
  #expect(engine.lineage.formulaID == "toyota-rpm-x0p78125")
  #expect(engine.lineage.formulaSHA256.count == 64)
  #expect(engine.lineage.inputSHA256.count == 64)
  #expect(engine.lineage.evidenceSHA256.count == 64)

  let rawTemperature = try #require(
    result.candidateSignals.first {
      $0.id == "toyota.2c4.intake-air-temperature.byte3"
    })
  #expect(rawTemperature.authority == .rawOnlyCandidate)
  #expect(rawTemperature.unit == "raw count")
  #expect(rawTemperature.lineage.sampleCount == 32)

  let relationship = try #require(result.relationships.first)
  let session = try #require(relationship.sessions.first)
  #expect(relationship.authority == .unverifiedDerived)
  #expect(relationship.pairCount == 27)
  #expect(relationship.sessionCount == 1)
  #expect(relationship.candidateUnitRatio.sampleCount == 27)
  #expect(session.pairCount == 27)
  #expect(session.maximumObservedPairSkewMicroseconds <= 250_000)
  #expect(try #require(session.pearsonCorrelation) > 0.97)
  #expect(relationship.pairingRule.contains("no cross-session interpolation"))
  #expect(relationship.lineage.sampleCount == relationship.pairCount)
}

@Test func eightRealSessionsStaySeparatedAndOrderIndependent() throws {
  let observations = try loadCANUnitsCorpus()
  let forward = try CANUnitsAnalyzer.analyze(observations: observations)
  let reverseOrder = try CANUnitsAnalyzer.analyze(observations: observations.reversed())

  #expect(forward == reverseOrder)
  #expect(forward.observationCount == 5_176)
  #expect(forward.sessionCount == 8)

  let engine = try #require(
    forward.candidateSignals.first { $0.id == "toyota.2c4.engine-speed.be16" })
  let turbine = try #require(
    forward.candidateSignals.first { $0.id == "toyota.2d0.turbine-speed.be16" })
  #expect(engine.statistics?.sampleCount == 659)
  #expect(engine.lineage.sampleCount == 659)
  #expect(engine.lineage.sessionCount == 8)
  #expect(turbine.statistics?.sampleCount == 626)
  #expect(turbine.lineage.sampleCount == 626)
  #expect(turbine.lineage.sessionCount == 8)

  let relationship = try #require(forward.relationships.first)
  #expect(relationship.sessionCount == 8)
  #expect(relationship.sessions.count == 8)
  #expect(relationship.pairCount == 616)
  #expect(relationship.candidateUnitRatio.sampleCount == 616)
  #expect(relationship.sessions.allSatisfy { $0.pairCount >= 8 })
  #expect(
    relationship.sessions.allSatisfy {
      $0.maximumObservedPairSkewMicroseconds <= 250_000
    })
  #expect(Set(relationship.sessions.map(\.sessionID)).count == 8)
  #expect(relationship.lineage.evidenceSHA256.count == 64)
}

@Test func newestStandardReadingIsDeduplicatedPerSignal() throws {
  let observations = try loadCANUnitsFixture()
  let samples = try makeTwoStandardRPMReadings()
  let result = try CANUnitsAnalyzer.analyze(
    observations: observations,
    standardSamples: samples.reversed())

  #expect(result.standardSignals.count == 1)
  #expect(result.signals.first?.authority == .observedStandard)
  let standard = try #require(result.standardSignals.first)
  #expect(standard.signalID == "obd.engine.speed")
  #expect(standard.latestValue == 1_408)
  #expect(standard.latestObservedAt == "2026-08-18T12:00:02Z")
  #expect(standard.lineage.sampleCount == 2)
  #expect(standard.lineage.sessionCount == 1)
  #expect(standard.statistics == nil)
}

@Test func standardEvidenceCanRenderWithoutPassiveObservations() throws {
  let samples = try makeTwoStandardRPMReadings()
  let result = try CANUnitsAnalyzer.analyze(
    observations: [], standardSamples: samples)

  #expect(result.observationCount == 0)
  #expect(result.sessionCount == 0)
  #expect(result.candidateSignals.isEmpty)
  #expect(result.relationships.isEmpty)
  #expect(result.standardSignals.count == 1)
  #expect(result.standardSignals.first?.latestValue == 1_408)
}

@Test func checkedContextCannotDescribeDifferentEvidence() throws {
  let observations = try loadCANUnitsFixture()
  let context = try CANUnitsAnalyzer.makeContext(observations: observations)
  let shortened = Array(observations.dropLast())

  #expect(throws: CANUnitsError.contextMismatch) {
    try CANUnitsAnalyzer.analyze(observations: shortened, context: context)
  }
}

private func loadCANUnitsFixture() throws -> [PassiveCANObservation] {
  let url = try #require(
    Bundle.module.url(
      forResource: canUnitsFixtureName,
      withExtension: "ndjson",
      subdirectory: "Fixtures"))
  return try decodeCANUnitsFile(url)
}

private func loadCANUnitsCorpus() throws -> [PassiveCANObservation] {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let directory = root.appendingPathComponent(
    "test-replay/real-can-2026-08-18/sessions", isDirectory: true)
  return try canUnitsCorpusSessions.flatMap { session in
    try decodeCANUnitsFile(directory.appendingPathComponent("\(session).ndjson"))
  }
}

private func decodeCANUnitsFile(_ url: URL) throws -> [PassiveCANObservation] {
  try Data(contentsOf: url).split(separator: 0x0A).map { line in
    try VHOSJSON.decoder().decode(PassiveCANObservation.self, from: Data(line))
  }
}

private func makeTwoStandardRPMReadings() throws -> [J1979StandardSample] {
  var accumulator = J1979Accumulator()
  try accumulator.ingest(
    canUnitsResponse(
      pid: 0x00, payload: "410000180000", time: 1,
      observedAt: "2026-08-18T12:00:00Z"))
  try accumulator.ingest(
    canUnitsResponse(
      pid: 0x0C, payload: "410C156C", time: 2,
      observedAt: "2026-08-18T12:00:01Z"))
  try accumulator.ingest(
    canUnitsResponse(
      pid: 0x0C, payload: "410C1600", time: 3,
      observedAt: "2026-08-18T12:00:02Z"))
  return accumulator.standardSamples
}

private func canUnitsResponse(
  pid: UInt8,
  payload: String,
  time: UInt64,
  observedAt: String
) -> J1979ResponseEvidence {
  J1979ResponseEvidence(
    gatewayID: "esp32-9454c5b08d14",
    captureID: "capture-627753796",
    observedAt: observedAt,
    gatewayMonotonicMicroseconds: time,
    sourceSequence: time,
    transport: "ISO_15765_11_500",
    ecuAddress: "0x7E8",
    requestPID: pid,
    responsePayloadHex: payload)
}
