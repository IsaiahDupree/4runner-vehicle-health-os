import Foundation

public enum DiscoveryIDGenerator {
  public static func make(prefix: String, at date: Date = Date()) throws -> String {
    try state.make(prefix: prefix, at: date)
  }

  private static let state = MonotonicULIDState()
}

public struct DiscoveryEvidenceSummary: Codable, Equatable, Sendable {
  public let contract: String
  public let contractVersion: String
  public let captureID: String
  public let archiveSHA256: String
  public let retainedRecordCount: Int
  public let uniqueIdentifierCount: Int
  public let gatewaySessionCount: Int
  public let startMonotonicMicroseconds: UInt64
  public let endMonotonicMicroseconds: UInt64
  public let firstSourceSequence: UInt64
  public let lastSourceSequence: UInt64
  public let unretainedSourceSequencePositionCount: UInt64
  public let standardFrameCount: Int
  public let extendedFrameCount: Int
  public let observedBitratesBps: [UInt32]
  public let markerCount: Int
  public let measurementCount: Int
  public let authority: DiscoveryAuthorityStatus

  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion, retainedRecordCount, uniqueIdentifierCount
    case gatewaySessionCount, startMonotonicMicroseconds, endMonotonicMicroseconds
    case firstSourceSequence, lastSourceSequence, unretainedSourceSequencePositionCount
    case standardFrameCount, extendedFrameCount, observedBitratesBps, markerCount
    case measurementCount, authority
    case captureID = "captureId"
    case archiveSHA256 = "archiveSha256"
  }
}

public struct BooleanCandidateEvaluation: Codable, Equatable, Sendable {
  public let contract: String
  public let contractVersion: String
  public let field: CandidateFieldDefinition
  public let pairedObservationCount: Int
  public let trueObservationCount: Int
  public let falseObservationCount: Int
  public let trueStateMode: UInt64
  public let falseStateMode: UInt64
  public let correlation: Double
  public let repeatability: Double
  public let falseActivationCount: Int
  public let markerIDs: [String]
  public let observationReferences: [String]
  public let algorithmID: String
  public let algorithmVersion: String
  public let authority: DiscoveryAuthorityStatus

  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion, field, pairedObservationCount, trueObservationCount
    case falseObservationCount, trueStateMode, falseStateMode, correlation, repeatability
    case falseActivationCount, observationReferences, algorithmVersion, authority
    case markerIDs = "markerIds"
    case algorithmID = "algorithmId"
  }

  public var metrics: CandidateSignalMetrics {
    get throws {
      try CandidateSignalMetrics(
        correlation: correlation, repeatability: repeatability,
        falseActivationCount: falseActivationCount,
        analyzedObservationCount: pairedObservationCount, analyzedCaptureCount: 1,
        controlledTestCount: 0,
        behaviorShape: .boolean, algorithmID: algorithmID,
        algorithmVersion: algorithmVersion)
    }
  }
}

public enum DiscoveryEvidenceAnalyzer {
  public static func summarize(
    observations: [PassiveCANObservation],
    session: CaptureSession
  ) throws -> DiscoveryEvidenceSummary {
    guard !observations.isEmpty else { throw DiscoveryContractError.emptyEvidence }
    try session.validateContract()
    try observations.forEach(PassiveCANEvidenceArchive.validate)
    let ordered = observations.sorted(by: observationOrder)
    guard Set(ordered.map(\.id)).count == ordered.count else {
      throw DiscoveryContractError.evidenceDoesNotMatchCapture
    }
    let archiveSHA = try PassiveCANEvidenceArchive.semanticSHA256(ordered)
    let sessions = Set(ordered.map(\.sessionID))
    let bitrates = Array(Set(ordered.map(\.bitrateBps))).sorted()
    let startMonotonicMicroseconds = ordered.map(\.monotonicMicroseconds).min()!
    let endMonotonicMicroseconds = ordered.map(\.monotonicMicroseconds).max()!
    guard ordered.count == session.retainedRecordCount,
      ordered.allSatisfy({ $0.gatewayID == session.gateway.gatewayID }),
      sessions == Set(session.gatewaySessionIDs), bitrates == session.busBitratesBps,
      ordered.allSatisfy(\.listenOnly),
      startMonotonicMicroseconds == session.startMonotonicMicroseconds,
      endMonotonicMicroseconds == session.endMonotonicMicroseconds,
      ordered.map(\.sourceSequence).min() == session.firstSourceSequence,
      ordered.map(\.sourceSequence).max() == session.lastSourceSequence,
      archiveSHA == session.archiveSHA256
    else { throw DiscoveryContractError.evidenceDoesNotMatchCapture }

    return DiscoveryEvidenceSummary(
      contract: "vhos.discovery.evidence-summary",
      contractVersion: "1.0.0",
      captureID: session.id,
      archiveSHA256: archiveSHA,
      retainedRecordCount: ordered.count,
      uniqueIdentifierCount: Set(ordered.map { "\($0.extended):\($0.identifier)" }).count,
      gatewaySessionCount: sessions.count,
      startMonotonicMicroseconds: startMonotonicMicroseconds,
      endMonotonicMicroseconds: endMonotonicMicroseconds,
      firstSourceSequence: ordered.map(\.sourceSequence).min()!,
      lastSourceSequence: ordered.map(\.sourceSequence).max()!,
      unretainedSourceSequencePositionCount: unretainedSourceSequencePositionCount(ordered),
      standardFrameCount: ordered.count(where: { !$0.extended }),
      extendedFrameCount: ordered.count(where: \.extended),
      observedBitratesBps: bitrates,
      markerCount: session.eventMarkers.count,
      measurementCount: session.physicalMeasurements.count,
      authority: .observed)
  }

  public static func makePassiveCapability(
    summary: DiscoveryEvidenceSummary
  ) throws -> PassiveBusCapability {
    let protocols = summary.observedBitratesBps.flatMap { bitrate -> [DiscoveryProtocol] in
      let hasStandard = summary.standardFrameCount > 0
      let hasExtended = summary.extendedFrameCount > 0
      switch bitrate {
      case 500_000:
        return [hasStandard ? .can11Bit500K : nil, hasExtended ? .can29Bit500K : nil]
          .compactMap { $0 }
      case 250_000:
        return [hasStandard ? .can11Bit250K : nil, hasExtended ? .can29Bit250K : nil]
          .compactMap { $0 }
      default: return []
      }
    }
    return try PassiveBusCapability(
      protocols: protocols,
      retainedRecordCount: summary.retainedRecordCount,
      uniqueIdentifierCount: summary.uniqueIdentifierCount,
      observedBitratesBps: summary.observedBitratesBps,
      standardFrameCount: summary.standardFrameCount,
      extendedFrameCount: summary.extendedFrameCount,
      evidenceSHA256: summary.archiveSHA256)
  }

  private static func unretainedSourceSequencePositionCount(
    _ observations: [PassiveCANObservation]
  ) -> UInt64 {
    let groups = Dictionary(grouping: observations) { "\($0.gatewayID):\($0.sessionID)" }
    return groups.values.reduce(0) { total, records in
      let sequences = records.map(\.sourceSequence).sorted()
      let groupGaps = zip(sequences, sequences.dropFirst()).reduce(UInt64(0)) {
        partial, pair in
        let (left, right) = pair
        return partial + (right > left + 1 ? right - left - 1 : 0)
      }
      return total + groupGaps
    }
  }

  private static func observationOrder(
    _ left: PassiveCANObservation, _ right: PassiveCANObservation
  ) -> Bool {
    if left.gatewayID != right.gatewayID { return left.gatewayID < right.gatewayID }
    if left.sessionID != right.sessionID { return left.sessionID < right.sessionID }
    if left.monotonicMicroseconds != right.monotonicMicroseconds {
      return left.monotonicMicroseconds < right.monotonicMicroseconds
    }
    return left.sourceSequence < right.sourceSequence
  }
}

public enum BooleanCandidateAnalyzer {
  public static func evaluate(
    capture: CaptureSession,
    field: CandidateFieldDefinition,
    observations: [PassiveCANObservation],
    markers: [EventMarker],
    trueKinds: Set<DiscoveryMarkerKind>,
    falseKinds: Set<DiscoveryMarkerKind>
  ) throws -> BooleanCandidateEvaluation {
    guard !observations.isEmpty, !markers.isEmpty, !trueKinds.isEmpty, !falseKinds.isEmpty,
      trueKinds.isDisjoint(with: falseKinds)
    else { throw DiscoveryContractError.emptyEvidence }
    try capture.validateContract()
    _ = try DiscoveryEvidenceAnalyzer.summarize(observations: observations, session: capture)
    for marker in markers { try marker.validateContract() }
    var retainedMarkers: [String: EventMarker] = [:]
    for marker in capture.eventMarkers {
      guard retainedMarkers.updateValue(marker, forKey: marker.id) == nil else {
        throw DiscoveryContractError.evidenceDoesNotMatchCapture
      }
    }
    let retainedSequenceIdentities = Set(
      observations.map { "\($0.gatewayID):\($0.sessionID):\($0.sourceSequence)" })
    let sessionMonotonicWindows = Dictionary(grouping: observations, by: \.sessionID).mapValues {
      records in
      (records.map(\.monotonicMicroseconds).min()!, records.map(\.monotonicMicroseconds).max()!)
    }
    guard Set(markers.map(\.id)).count == markers.count,
      markers.allSatisfy({ marker in
        guard let gatewaySessionID = marker.gatewaySessionID,
          let sessionWindow = sessionMonotonicWindows[gatewaySessionID]
        else { return false }
        return marker.captureID == capture.id && retainedMarkers[marker.id] == marker
          && capture.gatewaySessionIDs.contains(gatewaySessionID)
          && (sessionWindow.0...sessionWindow.1).contains(
            marker.gatewayMonotonicMicroseconds)
          && marker.nearestCANSequence.map({ sequence in
            retainedSequenceIdentities.contains(
              "\(capture.gateway.gatewayID):\(gatewaySessionID):\(sequence)")
          }) ?? true
      })
    else { throw DiscoveryContractError.evidenceDoesNotMatchCapture }

    let relevantMarkers = markers.filter {
      trueKinds.contains($0.kind) || falseKinds.contains($0.kind)
    }
    .sorted(by: DiscoveryOrdering.marker)
    guard relevantMarkers.contains(where: { trueKinds.contains($0.kind) }),
      relevantMarkers.contains(where: { falseKinds.contains($0.kind) })
    else { throw DiscoveryContractError.emptyEvidence }

    let filtered = observations.filter {
      $0.identifier == field.identifier && $0.extended == field.extended
        && $0.bitrateBps == field.protocolID.canBitrateBps && !$0.remoteRequest
    }.sorted {
      if $0.sessionID != $1.sessionID { return $0.sessionID < $1.sessionID }
      if $0.monotonicMicroseconds != $1.monotonicMicroseconds {
        return $0.monotonicMicroseconds < $1.monotonicMicroseconds
      }
      return $0.sourceSequence < $1.sourceSequence
    }
    var paired: [(observation: PassiveCANObservation, raw: UInt64, truth: Bool)] = []
    var markersBySession: [UInt32: [EventMarker]] = [:]
    for marker in relevantMarkers {
      guard let gatewaySessionID = marker.gatewaySessionID else {
        throw DiscoveryContractError.evidenceDoesNotMatchCapture
      }
      markersBySession[gatewaySessionID, default: []].append(marker)
    }
    let observationsBySession = Dictionary(grouping: filtered, by: \.sessionID)
    for sessionID in observationsBySession.keys.sorted() {
      let sessionMarkers = markersBySession[sessionID] ?? []
      var markerIndex = 0
      var currentTruth: Bool?
      for observation in observationsBySession[sessionID] ?? [] {
        while markerIndex < sessionMarkers.count,
          sessionMarkers[markerIndex].gatewayMonotonicMicroseconds
            <= observation.monotonicMicroseconds
        {
          currentTruth = trueKinds.contains(sessionMarkers[markerIndex].kind)
          markerIndex += 1
        }
        guard let truth = currentTruth,
          let raw = extract(field: field, observation: observation)
        else { continue }
        paired.append((observation, raw, truth))
      }
    }

    let trueRaw = paired.filter(\.truth).map(\.raw)
    let falseRaw = paired.filter { !$0.truth }.map(\.raw)
    guard !trueRaw.isEmpty, !falseRaw.isEmpty,
      let trueMode = mode(trueRaw), let falseMode = mode(falseRaw), trueMode != falseMode,
      let correlation = pearson(
        paired.map { Double($0.raw) }, paired.map { $0.truth ? 1.0 : 0.0 })
    else { throw DiscoveryContractError.emptyEvidence }

    let repeatable = paired.count {
      $0.truth ? $0.raw == trueMode : $0.raw == falseMode
    }
    let falseActivations = paired.count { !$0.truth && $0.raw == trueMode }
    return BooleanCandidateEvaluation(
      contract: "vhos.discovery.boolean-candidate-evaluation",
      contractVersion: "1.0.0",
      field: field,
      pairedObservationCount: paired.count,
      trueObservationCount: trueRaw.count,
      falseObservationCount: falseRaw.count,
      trueStateMode: trueMode,
      falseStateMode: falseMode,
      correlation: correlation,
      repeatability: Double(repeatable) / Double(paired.count),
      falseActivationCount: falseActivations,
      markerIDs: relevantMarkers.map(\.id),
      observationReferences: paired.map(\.observation.id),
      algorithmID: "discovery.boolean-marker-correlation",
      algorithmVersion: "1.0.0",
      authority: .candidate)
  }

  private static func extract(
    field: CandidateFieldDefinition,
    observation: PassiveCANObservation
  ) -> UInt64? {
    let byteCount = (field.bitOffset + field.bitLength + 7) / 8
    guard field.byteOffset + byteCount <= Int(observation.dataLength),
      field.byteOffset + byteCount <= observation.data.count
    else { return nil }
    let bytes = observation.data[field.byteOffset..<(field.byteOffset + byteCount)]
    let assembled: UInt64
    switch field.byteOrder {
    case .bigEndian:
      assembled = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    case .littleEndian:
      assembled = bytes.enumerated().reduce(UInt64(0)) {
        $0 | (UInt64($1.element) << UInt64($1.offset * 8))
      }
    }
    let mask = field.bitLength == 64 ? UInt64.max : (UInt64(1) << UInt64(field.bitLength)) - 1
    return (assembled >> UInt64(field.bitOffset)) & mask
  }

  private static func mode(_ values: [UInt64]) -> UInt64? {
    Dictionary(grouping: values, by: { $0 }).map { ($0.key, $0.value.count) }
      .sorted { left, right in
        if left.1 != right.1 { return left.1 > right.1 }
        return left.0 < right.0
      }.first?.0
  }

  private static func pearson(_ left: [Double], _ right: [Double]) -> Double? {
    guard left.count == right.count, left.count >= 2 else { return nil }
    let leftMean = left.reduce(0, +) / Double(left.count)
    let rightMean = right.reduce(0, +) / Double(right.count)
    var numerator = 0.0
    var leftSquared = 0.0
    var rightSquared = 0.0
    for (x, y) in zip(left, right) {
      let dx = x - leftMean
      let dy = y - rightMean
      numerator += dx * dy
      leftSquared += dx * dx
      rightSquared += dy * dy
    }
    let denominator = sqrt(leftSquared * rightSquared)
    guard denominator > 0 else { return nil }
    return numerator / denominator
  }
}

public enum SignalPromotionGate {
  public static func evaluate(
    candidate: CandidateSignal,
    checklist: SignalValidationChecklist,
    policy: SignalPromotionPolicy = .prdSignalDefinitionOfDone,
    evaluatedAt: String
  ) throws -> SignalPromotionDecision {
    try candidate.validateContract()
    try checklist.validateContract()
    _ = try SignalPromotionPolicy(
      policyID: policy.policyID, policyVersion: policy.policyVersion,
      requiredRequirements: policy.requiredRequirements,
      minimumCorrelation: policy.minimumCorrelation,
      minimumRepeatability: policy.minimumRepeatability)
    guard checklist.candidateID == candidate.id,
      DiscoveryContractValidation.isWallTime(evaluatedAt)
    else { throw DiscoveryContractError.invalidValidationChecklist }

    let byRequirement = Dictionary(
      uniqueKeysWithValues: checklist.items.map {
        ($0.requirement, $0)
      })
    var blockers: [String] = []
    var evidence: [String] = []
    for requirement in policy.requiredRequirements {
      guard let item = byRequirement[requirement] else {
        blockers.append("MISSING_CHECK:\(requirement.rawValue)")
        continue
      }
      guard item.status == .satisfied else {
        blockers.append("\(item.status.rawValue):\(requirement.rawValue)")
        continue
      }
      evidence.append(contentsOf: item.evidenceReferences)
    }
    if candidate.proposedCanonicalSignalID == nil {
      blockers.append("MISSING_CANONICAL_SIGNAL_ID")
    }
    if [.conflicting, .rejected].contains(candidate.reviewState) {
      blockers.append("REVIEW_STATE:\(candidate.reviewState.rawValue)")
    }
    guard let approval = checklist.approval, approval.decision == .approve else {
      blockers.append("MISSING_OR_NONAPPROVING_REVIEW")
      return try decision(
        candidate: candidate, policy: policy, evaluatedAt: evaluatedAt,
        blockers: blockers, evidence: evidence)
    }
    evidence.append(approval.evidenceReference)
    if let threshold = policy.minimumCorrelation {
      guard let correlation = candidate.metrics.correlation, abs(correlation) >= threshold else {
        blockers.append("CORRELATION_BELOW_POLICY")
        return try decision(
          candidate: candidate, policy: policy, evaluatedAt: evaluatedAt,
          blockers: blockers, evidence: evidence)
      }
    }
    if let threshold = policy.minimumRepeatability {
      guard let repeatability = candidate.metrics.repeatability, repeatability >= threshold else {
        blockers.append("REPEATABILITY_BELOW_POLICY")
        return try decision(
          candidate: candidate, policy: policy, evaluatedAt: evaluatedAt,
          blockers: blockers, evidence: evidence)
      }
    }
    // Contract v1 has no artifact resolver or reviewer-signature contract. Never turn caller-
    // supplied reference strings into vehicle authority. A future version must resolve exact
    // evidence bytes and authenticate the approving reviewer before removing these blockers.
    blockers.append("VERIFIED_EVIDENCE_RESOLVER_REQUIRED")
    blockers.append("SIGNED_REVIEWER_APPROVAL_REQUIRED")
    return try decision(
      candidate: candidate, policy: policy, evaluatedAt: evaluatedAt,
      blockers: blockers, evidence: evidence)
  }

  private static func decision(
    candidate: CandidateSignal,
    policy: SignalPromotionPolicy,
    evaluatedAt: String,
    blockers: [String],
    evidence: [String]
  ) throws -> SignalPromotionDecision {
    try SignalPromotionDecision(
      candidateID: candidate.id,
      evaluatedAt: evaluatedAt,
      policyID: policy.policyID,
      policyVersion: policy.policyVersion,
      blockers: blockers.sorted(),
      satisfiedEvidenceReferences: Array(Set(evidence)).sorted())
  }
}

public enum DiscoveryTestRecommender {
  public static func recommend(
    id: String,
    candidate: CandidateSignal,
    checklist: SignalValidationChecklist,
    templates: [TestTemplate],
    generatedAt: String
  ) throws -> RecommendedDiscoveryTest {
    try candidate.validateContract()
    try checklist.validateContract()
    for template in templates { try template.validateContract() }
    guard checklist.candidateID == candidate.id else {
      throw DiscoveryContractError.invalidValidationChecklist
    }
    let satisfied = Set(
      checklist.items.filter { $0.status == .satisfied }.map(\.requirement))
    let unresolved = Set(SignalValidationRequirement.allCases).subtracting(satisfied)
    let ranked = templates.compactMap {
      template -> (TestTemplate, Set<SignalValidationRequirement>)? in
      let addressed = unresolved.intersection(template.targetedValidationRequirements)
      return addressed.isEmpty ? nil : (template, addressed)
    }.sorted { left, right in
      if left.1.count != right.1.count { return left.1.count > right.1.count }
      if left.0.id != right.0.id { return left.0.id < right.0.id }
      return left.0.templateVersion < right.0.templateVersion
    }
    guard DiscoveryContractValidation.isDomainID(id, prefix: "recommendation"),
      DiscoveryContractValidation.isWallTime(generatedAt),
      let winner = ranked.first
    else { throw DiscoveryContractError.noApplicableTestTemplate }
    return RecommendedDiscoveryTest(
      contract: "vhos.discovery.recommended-test",
      contractVersion: "1.0.0",
      id: id,
      candidateID: candidate.id,
      templateID: winner.0.id,
      templateVersion: winner.0.templateVersion,
      generatedAt: generatedAt,
      recommendationAlgorithmID: "discovery.unresolved-gate-coverage",
      recommendationAlgorithmVersion: "1.0.0",
      reason:
        "Addresses unresolved validation gates: \(winner.1.map(\.rawValue).sorted().joined(separator: ", ")).",
      addressedRequirements: winner.1.sorted { $0.rawValue < $1.rawValue },
      competingTemplateIDs: ranked.dropFirst().map(\.0.id),
      sourceEvidenceReferences: Array(
        Set(checklist.items.flatMap(\.evidenceReferences) + candidate.sourceReferences)
      ).sorted(),
      authority: .candidate)
  }
}

private final class MonotonicULIDState: @unchecked Sendable {
  private let lock = NSLock()
  private var lastTimestamp: UInt64 = 0
  private var lastRandom = [UInt8](repeating: 0, count: 10)

  func make(prefix: String, at date: Date) throws -> String {
    guard prefix.range(of: "^[a-z][a-z0-9]*$", options: .regularExpression) != nil,
      date.timeIntervalSince1970 >= 0
    else { throw DiscoveryContractError.invalidCaptureSession }
    let requested = UInt64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    guard requested <= 0xFFFF_FFFF_FFFF else {
      throw DiscoveryContractError.invalidCaptureSession
    }
    lock.lock()
    defer { lock.unlock() }
    var timestamp = requested
    if timestamp > lastTimestamp {
      lastRandom = secureRandomBytes(count: 10)
    } else {
      timestamp = lastTimestamp
      if !increment(&lastRandom) {
        guard timestamp < 0xFFFF_FFFF_FFFF else {
          throw DiscoveryContractError.invalidCaptureSession
        }
        timestamp += 1
        lastRandom = secureRandomBytes(count: 10)
      }
    }
    lastTimestamp = timestamp
    var bytes = (0..<6).map { offset in
      UInt8((timestamp >> UInt64((5 - offset) * 8)) & 0xFF)
    }
    bytes.append(contentsOf: lastRandom)
    return "\(prefix)_\(encodeULID(bytes))"
  }

  private func secureRandomBytes(count: Int) -> [UInt8] {
    var generator = SystemRandomNumberGenerator()
    return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
  }

  private func increment(_ bytes: inout [UInt8]) -> Bool {
    for index in bytes.indices.reversed() {
      if bytes[index] < .max {
        bytes[index] += 1
        return true
      }
      bytes[index] = 0
    }
    return false
  }

  private func encodeULID(_ bytes: [UInt8]) -> String {
    let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    var bits = [UInt8](repeating: 0, count: 130)
    for byteIndex in bytes.indices {
      for bitIndex in 0..<8 {
        bits[2 + byteIndex * 8 + bitIndex] =
          (bytes[byteIndex] >> UInt8(7 - bitIndex)) & 1
      }
    }
    return String(
      (0..<26).map { group in
        let value = (0..<5).reduce(0) { partial, offset in
          partial * 2 + Int(bits[group * 5 + offset])
        }
        return alphabet[value]
      })
  }
}
