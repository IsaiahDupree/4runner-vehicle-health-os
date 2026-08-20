import CryptoKit
import Foundation
import Testing

@testable import VHOSCore

private let researchFixtureName = "real-can-2026-08-18-627753796-256"

@Test func freshApplicationSessionReloadsRealCANOffloadWithoutLossOrDuplication() throws {
  let source = try loadResearchFixture()
  let before = try PassiveCANResearchAnalyzer.analyze(source)
  let offload = try PassiveCANEvidenceArchive.encodeNDJSON(source)
  let offloadSHA = SHA256.hash(data: offload).map { String(format: "%02x", $0) }.joined()

  // This empty collection represents a new app process with no in-memory capture state.
  let reloaded = try PassiveCANEvidenceArchive.decodeNDJSON(offload)
  let firstImport = try PassiveCANEvidenceArchive.merge(existing: [], incoming: reloaded)
  let duplicateImport = try PassiveCANEvidenceArchive.merge(
    existing: firstImport.records, incoming: reloaded)
  let after = try PassiveCANResearchAnalyzer.analyze(firstImport.records)

  #expect(firstImport.appendedRecords == 256)
  #expect(firstImport.records.count == 256)
  #expect(duplicateImport.appendedRecords == 0)
  #expect(duplicateImport.records == firstImport.records)
  #expect(try PassiveCANEvidenceArchive.semanticSHA256(firstImport.records) == offloadSHA)
  #expect(after == before)
}

@Test func realRetainedCANProducesTraceableFailClosedResearchSeries() throws {
  let report = try PassiveCANResearchAnalyzer.analyze(loadResearchFixture())

  #expect(report.recordCount == 256)
  #expect(report.sessionCount == 1)
  #expect(report.packVersion == "0.4.0")
  #expect(report.packSHA256 == PassiveCANResearchCatalog.packSHA256)
  #expect(report.authority == "ENGINEERING_RESEARCH_ONLY")
  #expect(!report.ownerHealthDisplayAllowed)
  #expect(report.series.count == 7)

  let engine = try #require(report.series.first { $0.id == "toyota.2c4.engine-speed.be16" })
  #expect(engine.recordCount == 32)
  #expect(engine.distinctRawValues > 1)
  #expect(engine.candidateTransformID == "toyota-rpm-x0p78125")
  #expect(engine.displayUnit == "rpm")
  #expect(engine.displayMinimum == engine.rawMinimum * 0.78125)
  #expect(engine.points.allSatisfy { $0.displayValue == $0.rawValue * 0.78125 })

  let steering = try #require(
    report.series.first { $0.id == "toyota.025.steering-angle.signed12" })
  #expect(steering.recordCount == 33)
  #expect(!steering.usesCandidateTransform)
  #expect(steering.displayUnit == "raw count")
  #expect(steering.status == "HIGH_PRIORITY_CROSS_MODEL_CANDIDATE")
}

@Test func embeddedResearchCatalogIsPinnedToTheRepositorySignalPack() throws {
  let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let packURL = repositoryRoot.appendingPathComponent(
    "vehicle-signal-packs/toyota-4runner-2005-passive-can-hypotheses.v1.json")
  let bytes = try Data(contentsOf: packURL)
  let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  let document = try #require(
    try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
  let hypotheses = try #require(document["hypotheses"] as? [[String: Any]])
  let hypothesisIDs = Set(hypotheses.compactMap { $0["hypothesis_id"] as? String })

  #expect(sha == PassiveCANResearchCatalog.packSHA256)
  #expect(document["pack_id"] as? String == PassiveCANResearchCatalog.packID)
  #expect(document["pack_version"] as? String == PassiveCANResearchCatalog.packVersion)
  #expect(Set(PassiveCANResearchCatalog.definitions.map(\.id)).isSubset(of: hypothesisIDs))
}

@Test func researchArchiveRejectsEvidenceWithoutListenOnlyProof() throws {
  let source = try loadResearchFixture()
  let first = try #require(source.first)
  let unsafe = PassiveCANObservation(
    gatewayID: first.gatewayID,
    sessionID: first.sessionID,
    sourceSequence: first.sourceSequence,
    monotonicMicroseconds: first.monotonicMicroseconds,
    bitrateBps: first.bitrateBps,
    identifier: first.identifier,
    extended: first.extended,
    remoteRequest: first.remoteRequest,
    listenOnly: false,
    dataLength: first.dataLength,
    data: first.data,
    evidenceSource: first.evidenceSource,
    ingestedAt: first.ingestedAt
  )

  #expect(throws: PassiveCANArchiveError.self) {
    try PassiveCANResearchAnalyzer.analyze([unsafe])
  }
}

private func loadResearchFixture() throws -> [PassiveCANObservation] {
  let url = try #require(
    Bundle.module.url(
      forResource: researchFixtureName,
      withExtension: "ndjson",
      subdirectory: "Fixtures")
  )
  return try PassiveCANEvidenceArchive.decodeNDJSON(Data(contentsOf: url))
}
