import CryptoKit
import Foundation
import Testing

@testable import VHOSCore

private let discoveryFixtureName = "real-can-2026-08-18-627753796-256"
private let discoveryCaptureID = "capture_01K32Q6T000000000000000000"
private let discoveryVehicleID = "veh_01K32Q6T000000000000000001"
private let discoveryCandidateID = "candidate_01K32Q6T000000000000000002"
private let discoveryReviewerID = "reviewer_01K32Q6T000000000000000003"

@Test func discoveryIDsAreValidMonotonicCrockfordULIDs() throws {
  let instant = try #require(ISO8601DateFormatter().date(from: "2026-08-18T17:20:27Z"))
  let first = try DiscoveryIDGenerator.make(prefix: "marker", at: instant)
  let second = try DiscoveryIDGenerator.make(prefix: "marker", at: instant)

  #expect(first < second)
  #expect(first.range(of: "^marker_[0-9A-HJKMNP-TV-Z]{26}$", options: .regularExpression) != nil)
  #expect(second.range(of: "[ILOU]", options: .regularExpression) == nil)
  #expect(throws: DiscoveryContractError.self) {
    try DiscoveryIDGenerator.make(prefix: "invalid-prefix", at: instant)
  }
}

@Test func realRetainedEvidenceProducesExactObservedDiscoverySummary() throws {
  let observations = try loadDiscoveryFixture()
  let session = try makeRealCaptureSession(observations)
  let summary = try DiscoveryEvidenceAnalyzer.summarize(
    observations: observations, session: session)

  #expect(summary.authority == .observed)
  #expect(summary.retainedRecordCount == 256)
  #expect(summary.uniqueIdentifierCount == 17)
  #expect(summary.gatewaySessionCount == 1)
  #expect(summary.standardFrameCount == 256)
  #expect(summary.extendedFrameCount == 0)
  #expect(summary.observedBitratesBps == [500_000])
  #expect(summary.unretainedSourceSequencePositionCount == 3_617)
  #expect(
    summary.archiveSHA256 == "af2305021c2d48d89c55d1739da407d78ee28baa39cce63125d0656672f58aed")
  #expect(session.wallClockBasis == .evidenceIngestionTime)

  let encoded = try VHOSJSON.encoder().encode(session)
  let decoded = try VHOSJSON.decoder().decode(CaptureSession.self, from: encoded)
  try decoded.validateContract()
  #expect(decoded == session)

  let capability = try DiscoveryEvidenceAnalyzer.makePassiveCapability(summary: summary)
  let snapshot = try VehicleCapabilitySnapshot(
    id: "capability_01K32Q6T000000000000000003",
    vehicleID: discoveryVehicleID,
    captureID: discoveryCaptureID,
    capturedAt: "2026-08-18T17:37:45Z",
    gatewayID: "esp32-9454c5b08d14",
    passiveBus: capability,
    obdECUs: [],
    standardSignalIDs: [],
    candidateSignalIDs: ["engine.speed-candidate"],
    validatedSignalIDs: [],
    evidenceReferences: ["archive-sha256:\(summary.archiveSHA256)"])
  #expect(snapshot.authority == .observed)
  #expect(snapshot.passiveBus?.protocols == [.can11Bit500K])
  #expect(snapshot.validatedSignalIDs.isEmpty)
}

@Test func discoverySummaryRejectsCaptureThatDoesNotMatchRealEvidence() throws {
  let observations = try loadDiscoveryFixture()
  let session = try makeRealCaptureSession(
    observations,
    archiveSHA256: String(repeating: "0", count: 64))

  #expect(throws: DiscoveryContractError.evidenceDoesNotMatchCapture) {
    try DiscoveryEvidenceAnalyzer.summarize(observations: observations, session: session)
  }
}

@Test func booleanAnalyzerUsesRealFramesButNeverPromotesCircularTestLabels() throws {
  let observations = try loadDiscoveryFixture()
  let field = try CandidateFieldDefinition(
    protocolID: .can11Bit500K,
    identifier: 0x022,
    extended: false,
    byteOffset: 3,
    bitOffset: 0,
    bitLength: 1,
    byteOrder: .bigEndian,
    signed: false)
  let matching = observations.filter { $0.identifier == 0x022 }
    .sorted { $0.monotonicMicroseconds < $1.monotonicMicroseconds }
  var lastState: Bool?
  var markers: [EventMarker] = []
  for observation in matching {
    let state = (observation.data[3] & 0x01) == 0x01
    guard state != lastState else { continue }
    markers.append(
      try EventMarker(
        id: DiscoveryIDGenerator.make(prefix: "marker"),
        captureID: discoveryCaptureID,
        gatewayMonotonicMicroseconds: observation.monotonicMicroseconds,
        recordedAt: observation.ingestedAt,
        kind: state ? .brakePressed : .brakeReleased,
        label: "Raw-bit transition label for deterministic analyzer verification",
        source: .gateway,
        nearestCANSequence: observation.sourceSequence,
        note:
          "Derived from this raw bit only; it is not brake ground truth and grants no vehicle authority."
      ))
    lastState = state
  }

  let result = try BooleanCandidateAnalyzer.evaluate(
    field: field,
    observations: observations,
    markers: markers,
    trueKinds: [.brakePressed],
    falseKinds: [.brakeReleased])

  #expect(result.pairedObservationCount == 32)
  #expect(result.correlation == 1)
  #expect(result.repeatability == 1)
  #expect(result.falseActivationCount == 0)
  #expect(result.authority == .candidate)
  #expect(result.authority.rawValue == "EXPERIMENTAL_CANDIDATE")
  #expect(result.observationReferences == matching.map(\.id))
}

@Test func defaultPromotionFailsClosedAndRequiresEveryEvidenceGateAndReviewer() throws {
  let observations = try loadDiscoveryFixture()
  let candidate = try makeRealCandidate(observations)
  let archiveSHA = try PassiveCANEvidenceArchive.semanticSHA256(observations)
  let partialChecklist = try SignalValidationChecklist(
    candidateID: candidate.id,
    evaluatedAt: "2026-08-18T17:40:00Z",
    items: [
      try SignalValidationItem(
        requirement: .sourceDefined,
        status: .satisfied,
        evidenceReferences: ["archive-sha256:\(archiveSHA)"],
        rationale: "The gateway capture and cross-model research source IDs are preserved."),
      try SignalValidationItem(
        requirement: .targetVehicleCapture,
        status: .satisfied,
        evidenceReferences: ["capture:\(discoveryCaptureID)"],
        rationale: "The candidate occurs in the retained target capture."),
    ])

  let decision = try SignalPromotionGate.evaluate(
    candidate: candidate,
    checklist: partialChecklist,
    evaluatedAt: "2026-08-18T17:41:00Z")

  #expect(!decision.promotionAllowed)
  #expect(decision.authority == .candidate)
  #expect(decision.blockers.contains("MISSING_CHECK:INDEPENDENT_CORROBORATION"))
  #expect(decision.blockers.contains("MISSING_CHECK:REPEATABILITY_ACROSS_CONTROLLED_TESTS"))
  #expect(decision.blockers.contains("MISSING_CHECK:STALE_BEHAVIOR_DEFINED"))
  #expect(decision.blockers.contains("MISSING_OR_NONAPPROVING_REVIEW"))
}

@Test func completeReviewedChecklistExercisesPromotionAllowedContractPath() throws {
  let observations = try loadDiscoveryFixture()
  let candidate = try makeRealCandidate(observations)
  let source = "contract-test-evidence:real-fixture-af230502"
  let items = try SignalValidationRequirement.allCases.map {
    try SignalValidationItem(
      requirement: $0,
      status: .satisfied,
      evidenceReferences: ["\(source):\($0.rawValue)"],
      rationale: "Contract test supplies an explicit evidence reference for this gate.")
  }
  let approval = try SignalValidationApproval(
    reviewerID: discoveryReviewerID,
    reviewedAt: "2026-08-18T17:42:00Z",
    decision: .approve,
    evidenceReference: "\(source):review-approval",
    note: "Exercises the fully evidenced contract path; this is not a vehicle signal assertion.")
  let checklist = try SignalValidationChecklist(
    candidateID: candidate.id,
    evaluatedAt: "2026-08-18T17:42:00Z",
    items: items,
    approval: approval)
  let decision = try SignalPromotionGate.evaluate(
    candidate: candidate,
    checklist: checklist,
    evaluatedAt: "2026-08-18T17:43:00Z")

  #expect(checklist.authority == .validated)
  #expect(checklist.authority.rawValue == "VEHICLE_VALIDATED")
  #expect(decision.promotionAllowed)
  #expect(decision.blockers.isEmpty)
  #expect(decision.authority == .promoted)
}

@Test func recommendedNextTestIsDeterministicAcrossInputOrder() throws {
  let candidate = try makeRealCandidate(loadDiscoveryFixture())
  let checklist = try SignalValidationChecklist(
    candidateID: candidate.id,
    evaluatedAt: "2026-08-18T17:40:00Z",
    items: [
      try SignalValidationItem(
        requirement: .independentCorroboration,
        status: .missing,
        evidenceReferences: [],
        rationale: "No synchronized independent reference is present in this retained capture.")
    ])
  let alpha = try makeTemplate(
    id: "discovery.test.alpha",
    gates: [.independentCorroboration, .repeatabilityAcrossControlledTests])
  let beta = try makeTemplate(
    id: "discovery.test.beta",
    gates: [.independentCorroboration, .repeatabilityAcrossControlledTests])

  let first = try DiscoveryTestRecommender.recommend(
    id: "recommendation_01K32Q6T000000000000000004",
    candidate: candidate,
    checklist: checklist,
    templates: [beta, alpha],
    generatedAt: "2026-08-18T17:44:00Z")
  let second = try DiscoveryTestRecommender.recommend(
    id: "recommendation_01K32Q6T000000000000000005",
    candidate: candidate,
    checklist: checklist,
    templates: [alpha, beta],
    generatedAt: "2026-08-18T17:44:00Z")

  #expect(first.templateID == "discovery.test.alpha")
  #expect(second.templateID == first.templateID)
  #expect(first.addressedRequirements == second.addressedRequirements)
  #expect(first.authority == .candidate)
}

@Test func discoveryContractsRoundTripCanonicalSnakeCase() throws {
  let observations = try loadDiscoveryFixture()
  let firstObservation = try #require(observations.first)
  let marker = try EventMarker(
    id: "marker_01K32Q6T000000000000000006",
    captureID: discoveryCaptureID,
    gatewayMonotonicMicroseconds: firstObservation.monotonicMicroseconds,
    recordedAt: firstObservation.ingestedAt,
    kind: .measurementTaken,
    label: "Retained archive ingestion observed",
    source: .gateway,
    nearestCANSequence: firstObservation.sourceSequence,
    note: "Records an evidence-pipeline event, not a vehicle-state claim.")
  let measurement = try PhysicalMeasurement(
    id: "measurement_01K32Q6T000000000000000007",
    captureID: discoveryCaptureID,
    gatewayMonotonicMicroseconds: firstObservation.monotonicMicroseconds,
    recordedAt: firstObservation.ingestedAt,
    signalID: "vehicle.network-bitrate",
    value: Double(firstObservation.bitrateBps),
    unit: "bit/s",
    method: "Gateway passive-CAN observation metadata",
    instrumentID: firstObservation.gatewayID,
    source: .gateway,
    quality: .good,
    nearestCANSequence: firstObservation.sourceSequence,
    note: "Observed transport configuration; it is not an OBD protocol confirmation.")
  let candidate = try makeRealCandidate(observations)
  let checklist = try SignalValidationChecklist(
    candidateID: candidate.id,
    evaluatedAt: "2026-08-18T17:40:00Z",
    items: [
      try SignalValidationItem(
        requirement: .independentCorroboration,
        status: .missing,
        evidenceReferences: [],
        rationale: "No synchronized independent reference is present in this capture.")
    ])
  let template = try makeTemplate(
    id: "discovery.test.roundtrip",
    gates: [.independentCorroboration])
  let recommendation = try DiscoveryTestRecommender.recommend(
    id: "recommendation_01K32Q6T000000000000000008",
    candidate: candidate,
    checklist: checklist,
    templates: [template],
    generatedAt: "2026-08-18T17:44:00Z")

  #expect(try roundTrip(marker) == marker)
  #expect(try roundTrip(measurement) == measurement)
  #expect(try roundTrip(candidate) == candidate)
  #expect(try roundTrip(checklist) == checklist)
  #expect(try roundTrip(template) == template)
  #expect(try roundTrip(recommendation) == recommendation)

  let captureJSON = try #require(
    try JSONSerialization.jsonObject(
      with: VHOSJSON.encoder().encode(try makeRealCaptureSession(observations)))
      as? [String: Any])
  #expect(captureJSON["vehicle_id"] as? String == discoveryVehicleID)
  #expect(captureJSON["archive_sha256"] as? String != nil)
  #expect(captureJSON["wall_clock_basis"] as? String == "EVIDENCE_INGESTION_TIME")
}

private func makeRealCaptureSession(
  _ observations: [PassiveCANObservation],
  archiveSHA256 overrideArchiveSHA: String? = nil
) throws -> CaptureSession {
  let archiveSHA = try overrideArchiveSHA ?? PassiveCANEvidenceArchive.semanticSHA256(observations)
  let sequences = observations.map(\.sourceSequence)
  let monotonic = observations.map(\.monotonicMicroseconds)
  let ingested = observations.map(\.ingestedAt).sorted()
  return try CaptureSession(
    id: discoveryCaptureID,
    vehicleID: discoveryVehicleID,
    vehicleProfileSHA256: sha256("vehicle-profile:2005-4runner:configuration-unresolved"),
    startedAt: try #require(ingested.first),
    endedAt: try #require(ingested.last),
    wallClockBasis: .evidenceIngestionTime,
    startMonotonicMicroseconds: try #require(monotonic.min()),
    endMonotonicMicroseconds: try #require(monotonic.max()),
    gateway: CaptureGatewayProvenance(gatewayID: "esp32-9454c5b08d14"),
    gatewaySessionIDs: Array(Set(observations.map(\.sessionID))),
    busBitratesBps: Array(Set(observations.map(\.bitrateBps))),
    listenOnly: true,
    retainedRecordCount: observations.count,
    firstSourceSequence: try #require(sequences.min()),
    lastSourceSequence: try #require(sequences.max()),
    archiveSHA256: archiveSHA,
    manifestSHA256: sha256("capture-manifest:\(discoveryCaptureID):\(archiveSHA)"),
    notes: "Materialized from the retained 2026-08-18 gateway evidence fixture.")
}

private func makeRealCandidate(_ observations: [PassiveCANObservation]) throws -> CandidateSignal {
  let report = try PassiveCANResearchAnalyzer.analyze(observations)
  let series = try #require(
    report.series.first { $0.id == "toyota.2c4.engine-speed.be16" })
  return try CandidateSignal(
    id: discoveryCandidateID,
    createdAt: "2026-08-18T17:38:00Z",
    candidateSemantic: "engine.speed-candidate",
    proposedCanonicalSignalID: "engine.rpm",
    field: CandidateFieldDefinition(
      protocolID: .can11Bit500K,
      identifier: 0x2C4,
      extended: false,
      byteOffset: 0,
      bitOffset: 0,
      bitLength: 16,
      byteOrder: .bigEndian,
      signed: false),
    metrics: CandidateSignalMetrics(
      correlation: nil,
      repeatability: nil,
      falseActivationCount: 0,
      analyzedObservationCount: series.recordCount,
      analyzedCaptureCount: 1,
      controlledTestCount: 0,
      behaviorShape: .analog,
      algorithmID: "passive-can.research-analyzer",
      algorithmVersion: report.packVersion),
    reviewState: .needsMoreData,
    captureIDs: [discoveryCaptureID],
    testTemplateIDs: [],
    eventMarkerIDs: [],
    independentEvidenceReferences: [],
    sourceReferences: [
      "archive-sha256:\(report.generatedFromSHA256)",
      "signal-pack-sha256:\(report.packSHA256)",
    ])
}

private func makeTemplate(
  id: String,
  gates: [SignalValidationRequirement]
) throws -> TestTemplate {
  try TestTemplate(
    id: id,
    templateVersion: "1.0.0",
    title: "Parked corroboration capture",
    category: .engine,
    hypothesis: "Independent reference evidence can distinguish the candidate from alternatives.",
    requiredVehicleMotion: .parked,
    safetyInstructions: [
      "Keep the vehicle parked and follow the independent instrument procedure."
    ],
    requiredGatewayCapabilities: [.passiveCapture],
    targetedValidationRequirements: gates,
    steps: [
      try TestStep(
        id: "parked-reference-capture",
        sequence: 1,
        instruction: "Record the independent reference and retained CAN evidence on one timeline.")
    ])
}

private func loadDiscoveryFixture() throws -> [PassiveCANObservation] {
  let url = try #require(
    Bundle.module.url(
      forResource: discoveryFixtureName,
      withExtension: "ndjson",
      subdirectory: "Fixtures"))
  return try PassiveCANEvidenceArchive.decodeNDJSON(Data(contentsOf: url))
}

private func sha256(_ value: String) -> String {
  SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func roundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
  try VHOSJSON.decoder().decode(Value.self, from: VHOSJSON.encoder().encode(value))
}
