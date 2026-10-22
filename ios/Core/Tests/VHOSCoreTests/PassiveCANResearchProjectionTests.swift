import Foundation
import Testing

@testable import VHOSCore

private let projectionFixtureName = "real-can-2026-08-18-627753796-256"

@Test func projectorBindsCandidateValueAndAuthorityToExactRealObservation() throws {
  let observations = try loadProjectionFixture()
  let observation = try #require(
    observations.first { $0.identifier == 0x2C4 && $0.sourceSequence == 3_793 })
  let projections = try PassiveCANResearchProjector.project(observation)
  let engine = try #require(
    projections.first { $0.definitionID == "toyota.2c4.engine-speed.be16" })

  #expect(projections.count == 2)
  #expect(engine.sourceObservationID == observation.id)
  #expect(engine.sourceGatewayID == observation.gatewayID)
  #expect(engine.sourceSessionID == observation.sessionID)
  #expect(engine.sourceSequence == observation.sourceSequence)
  #expect(engine.sourceMonotonicMicroseconds == observation.monotonicMicroseconds)
  #expect(engine.sourceIngestedAt == observation.ingestedAt)
  #expect(engine.sourceEvidenceKind == "gateway-flash")
  #expect(engine.sourceListenOnly)
  #expect(engine.packID == PassiveCANResearchCatalog.packID)
  #expect(engine.packVersion == PassiveCANResearchCatalog.packVersion)
  #expect(engine.packSHA256 == PassiveCANResearchCatalog.packSHA256)
  #expect(engine.rawValue == 1_506)
  #expect(engine.displayValue == 1_176.5625)
  #expect(engine.displayUnit == "rpm")
  #expect(engine.candidateTransformID == "toyota-rpm-x0p78125")
  #expect(engine.valueAuthority == .referencedCrossModelTransform)
  #expect(engine.authority == .candidate)
  #expect(engine.replayOnly)
  #expect(!engine.promotionAllowed)
  #expect(!engine.ownerHealthDisplayAllowed)
}

@Test func projectorKeepsConflictingPhysicalMeaningRawOnly() throws {
  let observation = try #require(
    try loadProjectionFixture().first {
      $0.identifier == 0x2C4 && $0.sourceSequence == 3_793
    })
  let projection = try #require(
    try PassiveCANResearchProjector.project(observation).first {
      $0.definitionID == "toyota.2c4.intake-air-temperature.byte3"
    })

  #expect(projection.rawValue == 31)
  #expect(projection.displayValue == projection.rawValue)
  #expect(projection.displayUnit == "raw count")
  #expect(projection.candidateTransformID == nil)
  #expect(projection.transformSourceIDs.isEmpty)
  #expect(projection.valueAuthority == .rawOnlyConflictingDefinition)
  #expect(projection.authority == .candidate)
  #expect(projection.replayOnly)
  #expect(!projection.promotionAllowed)
}

@Test func projectorReturnsNoMeaningForRealObservationOutsidePinnedCatalog() throws {
  let observation = try #require(try loadProjectionFixture().first { $0.identifier == 0x020 })
  #expect(try PassiveCANResearchProjector.project(observation).isEmpty)
}

@Test func projectorRejectsObservationWithoutListenOnlyProof() throws {
  let source = try #require(try loadProjectionFixture().first { $0.identifier == 0x2C4 })
  let unsafe = PassiveCANObservation(
    gatewayID: source.gatewayID,
    sessionID: source.sessionID,
    sourceSequence: source.sourceSequence,
    monotonicMicroseconds: source.monotonicMicroseconds,
    bitrateBps: source.bitrateBps,
    identifier: source.identifier,
    extended: source.extended,
    remoteRequest: source.remoteRequest,
    listenOnly: false,
    dataLength: source.dataLength,
    data: source.data,
    evidenceSource: source.evidenceSource,
    ingestedAt: source.ingestedAt
  )

  #expect(throws: PassiveCANArchiveError.self) {
    try PassiveCANResearchProjector.project(unsafe)
  }
}

@Test func researchSeriesLatestValueRetainsTheRealSourceEndpoint() throws {
  let report = try PassiveCANResearchAnalyzer.analyze(loadProjectionFixture())
  let engine = try #require(
    report.series.first { $0.id == "toyota.2c4.engine-speed.be16" })
  let latest = try #require(engine.latestPoint)

  #expect(latest.sourceSequence == 3_793)
  #expect(latest.rawValue == 1_506)
  #expect(latest.displayValue == 1_176.5625)
  #expect(engine.displayUnit == "rpm")
  #expect(engine.valueAuthority == .referencedCrossModelTransform)

  let intake = try #require(
    report.series.first { $0.id == "toyota.2c4.intake-air-temperature.byte3" })
  #expect(intake.valueAuthority == .rawOnlyConflictingDefinition)
}

private func loadProjectionFixture() throws -> [PassiveCANObservation] {
  let url = try #require(
    Bundle.module.url(
      forResource: projectionFixtureName,
      withExtension: "ndjson",
      subdirectory: "Fixtures")
  )
  return try PassiveCANEvidenceArchive.decodeNDJSON(Data(contentsOf: url))
}
