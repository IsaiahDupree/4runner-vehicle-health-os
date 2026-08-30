import CryptoKit
import Foundation

public enum CANUnitsAuthority: String, Codable, Equatable, Sendable {
  case observedStandard = "OBSERVED_STANDARD"
  case unverifiedCandidateUnit = "UNVERIFIED_CANDIDATE_UNIT"
  case rawOnlyCandidate = "RAW_ONLY_CANDIDATE"
  case unverifiedDerived = "UNVERIFIED_DERIVED"

  public var exposesEngineeringUnit: Bool {
    self == .observedStandard || self == .unverifiedCandidateUnit
  }
}

public struct CANDescriptiveStatistics: Codable, Equatable, Sendable {
  public let sampleCount: Int
  public let minimum: Double
  public let maximum: Double
  public let mean: Double
  public let populationStandardDeviation: Double
  public let peakToPeak: Double
  public let coefficientOfVariation: Double?
}

public struct CANUnitsLineage: Codable, Equatable, Sendable {
  public let formulaID: String
  public let formulaText: String
  public let formulaSHA256: String
  public let inputIDs: [String]
  public let inputSHA256: String
  public let evidenceSHA256: String
  public let sampleCount: Int
  public let sessionCount: Int
  public let evidenceSelection: String
}

public struct CANUnitsSignal: Identifiable, Codable, Equatable, Sendable {
  public let id: String
  public let signalID: String
  public let name: String
  public let source: String
  public let latestValue: Double
  public let unit: String
  public let latestRawValue: Double?
  public let latestObservedAt: String
  public let latestEvidenceReference: String
  public let authority: CANUnitsAuthority
  public let statistics: CANDescriptiveStatistics?
  public let definitionStatus: String
  public let validationGate: String?
  public let lineage: CANUnitsLineage
}

public struct CANRotationalSessionAnalysis: Identifiable, Codable, Equatable, Sendable {
  public let gatewayID: String
  public let sessionID: UInt32
  public let firstObservedAt: String
  public let lastObservedAt: String
  public let pairCount: Int
  public let maximumObservedPairSkewMicroseconds: UInt64
  public let candidateUnitRatio: CANDescriptiveStatistics
  public let pearsonCorrelation: Double?
  public let evidenceSHA256: String

  public var id: String { "\(gatewayID):\(sessionID)" }
}

public struct CANRotationalRelationship: Identifiable, Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let authority: CANUnitsAuthority
  public let numeratorSignalID: String
  public let denominatorSignalID: String
  public let unit: String
  public let pairCount: Int
  public let sessionCount: Int
  public let maximumPairSkewMicroseconds: UInt64
  public let minimumPairsPerSession: Int
  public let pairingRule: String
  public let candidateUnitRatio: CANDescriptiveStatistics
  public let sessions: [CANRotationalSessionAnalysis]
  public let lineage: CANUnitsLineage
}

public struct CANUnitsReport: Codable, Equatable, Sendable {
  public let evidenceSHA256: String
  public let observationCount: Int
  public let sessionCount: Int
  public let catalogID: String
  public let catalogVersion: String
  public let catalogSHA256: String
  public let signals: [CANUnitsSignal]
  public let relationships: [CANRotationalRelationship]

  public var standardSignals: [CANUnitsSignal] {
    signals.filter { $0.authority == .observedStandard }
  }

  public var candidateSignals: [CANUnitsSignal] {
    signals.filter {
      $0.authority == .unverifiedCandidateUnit || $0.authority == .rawOnlyCandidate
    }
  }
}

/// A typed, transport-neutral copy of the checked analysis report identity and record counts.
public struct CANUnitsContext: Codable, Equatable, Sendable {
  public let evidenceSHA256: String
  public let observationCount: Int
  public let sessionCount: Int
  public let catalogID: String
  public let catalogVersion: String
  public let catalogSHA256: String
  public let projectedRecordCounts: [String: Int]

  public init(
    evidenceSHA256: String,
    observationCount: Int,
    sessionCount: Int,
    catalogID: String,
    catalogVersion: String,
    catalogSHA256: String,
    projectedRecordCounts: [String: Int]
  ) {
    self.evidenceSHA256 = evidenceSHA256
    self.observationCount = observationCount
    self.sessionCount = sessionCount
    self.catalogID = catalogID
    self.catalogVersion = catalogVersion
    self.catalogSHA256 = catalogSHA256
    self.projectedRecordCounts = projectedRecordCounts
  }
}

public enum CANUnitsAnalyzer {
  public static let rotationalMaximumPairSkewMicroseconds: UInt64 = 250_000
  public static let rotationalMinimumPairsPerSession = 8
  public static let algorithmVersion = "1.0.0"

  private static let catalogID = "toyota.4runner.2005.passive-can-hypotheses"
  private static let catalogVersion = "0.4.1"
  private static let catalogSHA256 =
    "2eb734187bf79f04973621a3534ae6cc185d0f1cbb5a91fa71183c82055f69e8"

  private struct Transform: Sendable {
    let id: String
    let scale: Double
    let offset: Double
    let unit: String
  }

  private struct FieldDefinition: Sendable {
    let id: String
    let label: String
    let signalID: String
    let identifier: UInt32
    let byteOffset: Int
    let byteLength: Int
    let mask: UInt64
    let signedBits: Int?
    let status: String
    let transform: Transform?
    let validationGate: String
  }

  private struct ValueProjection: Sendable {
    let definitionID: String
    let observation: PassiveCANObservation
    let rawValue: Double
    let displayValue: Double
  }

  private struct SessionKey: Hashable {
    let gatewayID: String
    let sessionID: UInt32
  }

  private struct FormulaManifest: Codable {
    let formulaID: String
    let formulaText: String
    let algorithmVersion: String
  }

  private struct InputManifest: Codable {
    let inputIDs: [String]
  }

  private struct RotationalPair {
    let engine: ValueProjection
    let turbine: ValueProjection
    let skewMicroseconds: UInt64
  }

  private static let definitions: [FieldDefinition] = [
    FieldDefinition(
      id: "toyota.2c4.engine-speed.be16", label: "Engine speed candidate",
      signalID: "engine.speed", identifier: 0x2C4, byteOffset: 0, byteLength: 2,
      mask: 0xFFFF, signedBits: nil, status: "HIGH_PRIORITY_CROSS_MODEL_CANDIDATE",
      transform: Transform(
        id: "toyota-rpm-x0p78125", scale: 0.78125, offset: 0, unit: "rpm"),
      validationGate:
        "Compare against SAE J1979 PID 0x0C or Toyota Techstream engine speed on the same monotonic timeline."),
    FieldDefinition(
      id: "toyota.2c4.intake-air-temperature.byte3",
      label: "Intake-air temperature raw candidate",
      signalID: "engine.intake-air-temperature", identifier: 0x2C4, byteOffset: 3,
      byteLength: 1, mask: 0xFF, signedBits: nil, status: "CROSS_MODEL_CANDIDATE",
      transform: nil,
      validationGate:
        "Resolve the conflicting cross-model formulas against SAE J1979 PID 0x0F or Techstream before applying a temperature scale."),
    FieldDefinition(
      id: "toyota.2d0.turbine-speed.be16", label: "Transmission turbine-speed candidate",
      signalID: "transmission.turbine-speed", identifier: 0x2D0, byteOffset: 0,
      byteLength: 2, mask: 0xFFFF, signedBits: nil, status: "CROSS_MODEL_CANDIDATE",
      transform: Transform(
        id: "fj-turbine-rpm-x0p390625", scale: 0.390625, offset: 0, unit: "rpm"),
      validationGate:
        "Compare with Techstream turbine/input speed, engine speed, vehicle speed, gear, and converter lockup across a labeled drive."),
    FieldDefinition(
      id: "toyota.2d0.selector-code.byte2", label: "Transmission selector raw candidate",
      signalID: "transmission.selector-code", identifier: 0x2D0, byteOffset: 2,
      byteLength: 1, mask: 0x7F, signedBits: nil, status: "CROSS_MODEL_CANDIDATE",
      transform: nil,
      validationGate:
        "Record explicit P, R, N, D, and manual-selector markers and require stable repeatable one-to-one codes."),
    FieldDefinition(
      id: "toyota.2c1.accelerator-pedal.byte6", label: "Accelerator-pedal candidate",
      signalID: "engine.accelerator-pedal-position", identifier: 0x2C1, byteOffset: 6,
      byteLength: 1, mask: 0xFF, signedBits: nil,
      status: "HIGH_PRIORITY_CROSS_MODEL_CANDIDATE",
      transform: Transform(
        id: "fj-pedal-x0p5-percent", scale: 0.5, offset: 0, unit: "percent"),
      validationGate:
        "Compare against SAE J1979 PID 0x49 when supported or Techstream accelerator position at separated stable pedal levels."),
    FieldDefinition(
      id: "toyota.025.steering-angle.signed12", label: "Steering-angle raw candidate",
      signalID: "steering.wheel-angle", identifier: 0x025, byteOffset: 0,
      byteLength: 2, mask: 0x0FFF, signedBits: 12,
      status: "HIGH_PRIORITY_CROSS_MODEL_CANDIDATE", transform: nil,
      validationGate:
        "Resolve conflicting scale and direction formulas with Techstream center, left, and right markers, then repeat after an ignition cycle."),
    FieldDefinition(
      id: "toyota.224.brake-pressure.be16-low9", label: "Brake-pressure raw candidate",
      signalID: "brakes.pedal-pressure", identifier: 0x224, byteOffset: 4,
      byteLength: 2, mask: 0x01FF, signedBits: nil, status: "CROSS_MODEL_CANDIDATE",
      transform: nil,
      validationGate:
        "Capture released, light, medium, and firm brake applications with an independent pressure reference."),
  ]

  public static func analyze(
    observations: [PassiveCANObservation],
    standardSamples: [J1979StandardSample] = []
  ) throws -> CANUnitsReport {
    let context = try makeContext(observations: observations)
    return try analyze(
      observations: observations, context: context, standardSamples: standardSamples)
  }

  public static func makeContext(
    observations: [PassiveCANObservation]
  ) throws -> CANUnitsContext {
    try observations.forEach(validate)
    let values = project(observations)
    let counts = Dictionary(grouping: values, by: \.definitionID).mapValues(\.count)
    return CANUnitsContext(
      evidenceSHA256: try evidenceSHA256(observations),
      observationCount: observations.count,
      sessionCount: Set(observations.map {
        SessionKey(gatewayID: $0.gatewayID, sessionID: $0.sessionID)
      }).count,
      catalogID: catalogID,
      catalogVersion: catalogVersion,
      catalogSHA256: catalogSHA256,
      projectedRecordCounts: counts)
  }

  public static func analyze(
    observations: [PassiveCANObservation],
    context: CANUnitsContext,
    standardSamples: [J1979StandardSample] = []
  ) throws -> CANUnitsReport {
    try observations.forEach(validate)
    let expected = try makeContext(observations: observations)
    guard expected == context else { throw CANUnitsError.contextMismatch }
    let values = project(observations)
    let grouped = Dictionary(grouping: values, by: \.definitionID)
    let standards = try makeStandardSignals(standardSamples)
    let candidates: [CANUnitsSignal] = try definitions.compactMap {
      definition -> CANUnitsSignal? in
      guard let projections = grouped[definition.id], !projections.isEmpty else { return nil }
      return try makeCandidateSignal(definition, projections)
    }
    return CANUnitsReport(
      evidenceSHA256: context.evidenceSHA256,
      observationCount: context.observationCount,
      sessionCount: context.sessionCount,
      catalogID: context.catalogID,
      catalogVersion: context.catalogVersion,
      catalogSHA256: context.catalogSHA256,
      signals: standards + candidates,
      relationships: try makeRotationalRelationships(grouped))
  }

  private static func validate(_ observation: PassiveCANObservation) throws {
    guard observation.contract == "gateway.passive-can-observation",
      observation.contractVersion == "1.0.0"
    else { throw CANUnitsError.invalidObservation(observation.id) }
    guard !observation.gatewayID.isEmpty, observation.sourceSequence > 0,
      observation.dataLength <= 8, observation.data.count == 8,
      observation.identifier <= (observation.extended ? 0x1FFF_FFFF : 0x7FF),
      observation.bitrateBps == 250_000 || observation.bitrateBps == 500_000,
      observation.listenOnly
    else { throw CANUnitsError.invalidObservation(observation.id) }
  }

  /// The pinned candidate-field catalog, exposed for live rendering.
  ///
  /// The live lane and the retained-analysis lane MUST share one copy of
  /// the extraction and transform math. Two implementations of the same
  /// formula is how a dashboard ends up showing a number the analysis
  /// disagrees with, so live consumers project through
  /// `projectLive(_:)` below rather than reimplementing scale/offset.
  public static var candidateFields: [CANLiveFieldDescriptor] {
    definitions.map {
      CANLiveFieldDescriptor(
        id: $0.id,
        label: $0.label,
        signalID: $0.signalID,
        identifier: $0.identifier,
        unit: $0.transform?.unit,
        source: "Passive CAN 0x"
          + String(format: "%03X", $0.identifier) + " · " + extractionFormula($0),
        authority: authority(for: $0),
        definitionStatus: $0.status,
        validationGate: $0.validationGate)
    }
  }

  /// Apply the pinned catalog to a single live observation.
  ///
  /// Returns one reading per catalog field the frame satisfies (a frame
  /// can feed several fields — 0x2C4 carries both engine speed and intake
  /// air temperature). Returns an empty array for frames no pinned field
  /// claims; it never guesses.
  public static func projectLive(
    _ observation: PassiveCANObservation
  ) -> [CANLiveReading] {
    definitions.compactMap { definition in
      guard observation.identifier == definition.identifier, !observation.extended,
        !observation.remoteRequest, let raw = extract(definition, observation)
      else { return nil }
      return CANLiveReading(
        fieldID: definition.id,
        signalID: definition.signalID,
        label: definition.label,
        rawValue: raw,
        displayValue: definition.transform.map { raw * $0.scale + $0.offset } ?? raw,
        unit: definition.transform?.unit,
        authority: authority(for: definition),
        gatewayID: observation.gatewayID,
        sessionID: observation.sessionID,
        sourceSequence: observation.sourceSequence,
        monotonicMicroseconds: observation.monotonicMicroseconds,
        observedAt: observation.ingestedAt)
    }
  }

  private static func authority(for definition: FieldDefinition) -> CANUnitsAuthority {
    definition.transform == nil ? .rawOnlyCandidate : .unverifiedCandidateUnit
  }

  private static func project(
    _ observations: [PassiveCANObservation]
  ) -> [ValueProjection] {
    observations.flatMap { observation in
      definitions.compactMap { definition in
        guard observation.identifier == definition.identifier, !observation.extended,
          !observation.remoteRequest, let raw = extract(definition, observation)
        else { return nil }
        return ValueProjection(
          definitionID: definition.id,
          observation: observation,
          rawValue: raw,
          displayValue: definition.transform.map { raw * $0.scale + $0.offset } ?? raw)
      }
    }
  }

  private static func extract(
    _ definition: FieldDefinition,
    _ observation: PassiveCANObservation
  ) -> Double? {
    let end = definition.byteOffset + definition.byteLength
    guard end <= Int(observation.dataLength), end <= observation.data.count else { return nil }
    var word: UInt64 = 0
    for byte in observation.data[definition.byteOffset..<end] {
      word = (word << 8) | UInt64(byte)
    }
    let masked = word & definition.mask
    if let bits = definition.signedBits {
      let signBit = UInt64(1) << UInt64(bits - 1)
      if masked & signBit != 0 {
        return Double(Int64(masked) - Int64(UInt64(1) << UInt64(bits)))
      }
    }
    return Double(masked)
  }

  private static func evidenceSHA256(
    _ observations: [PassiveCANObservation]
  ) throws -> String {
    var data = Data()
    for observation in observations.sorted(by: observationOrder) {
      try validate(observation)
      data.append(try VHOSJSON.encoder().encode(observation))
      data.append(0x0A)
    }
    return sha256(data)
  }

  private static func observationOrder(
    _ left: PassiveCANObservation,
    _ right: PassiveCANObservation
  ) -> Bool {
    if left.ingestedAt != right.ingestedAt { return left.ingestedAt < right.ingestedAt }
    if left.gatewayID != right.gatewayID { return left.gatewayID < right.gatewayID }
    if left.sessionID != right.sessionID { return left.sessionID < right.sessionID }
    if left.monotonicMicroseconds != right.monotonicMicroseconds {
      return left.monotonicMicroseconds < right.monotonicMicroseconds
    }
    return left.sourceSequence < right.sourceSequence
  }

  private static func makeStandardSignals(
    _ samples: [J1979StandardSample]
  ) throws -> [CANUnitsSignal] {
    for sample in samples {
      guard !sample.id.isEmpty, !sample.gatewayID.isEmpty, !sample.captureID.isEmpty,
        !sample.ecuAddress.isEmpty, !sample.signalID.isEmpty, !sample.name.isEmpty,
        !sample.rawDataHex.isEmpty, !sample.unit.isEmpty, !sample.definitionRevision.isEmpty,
        sample.value.isFinite, wallDate(sample.observedAt) != nil
      else { throw CANUnitsError.invalidStandardSample(sample.id) }
    }
    let grouped = Dictionary(grouping: samples, by: \.signalID)
    return try grouped.keys.sorted().map { signalID in
      let values = grouped[signalID]!.sorted(by: standardSampleOrder)
      let latest = values.last!
      return try makeStandardSignal(latest: latest, values: values)
    }
  }

  private static func makeStandardSignal(
    latest: J1979StandardSample,
    values: [J1979StandardSample]
  ) throws -> CANUnitsSignal {
    let pid = String(format: "0x%02X", latest.pid)
    let formulaID =
      "sae-j1979.mode01.pid-\(String(format: "%02x", latest.pid)).\(latest.definitionRevision)"
    let formulaText =
      "value = pinned SAE J1979 Mode 01 PID \(pid) decoder revision \(latest.definitionRevision)"
    let inputs = [
      "sae-j1979.mode01.pid-\(String(format: "%02x", latest.pid)).response-bytes"
    ]
    let sessionCount = Set(values.map { "\($0.gatewayID):\($0.captureID)" }).count
    return CANUnitsSignal(
      id: "standard:\(latest.signalID)", signalID: latest.signalID, name: latest.name,
      source: "SAE J1979 Mode 01 PID \(pid) / ECU \(latest.ecuAddress)",
      latestValue: latest.value, unit: latest.unit, latestRawValue: nil,
      latestObservedAt: latest.observedAt, latestEvidenceReference: latest.id,
      authority: .observedStandard, statistics: nil,
      definitionStatus: "OBSERVED_STANDARD", validationGate: nil,
      lineage: try makeLineage(
        formulaID: formulaID, formulaText: formulaText, inputIDs: inputs,
        evidenceSHA256: sha256(try VHOSJSON.encoder().encode(values)),
        sampleCount: values.count, sessionCount: sessionCount,
        evidenceSelection:
          "All supplied current J1979 samples for this signal; deterministic latest reading selected."))
  }

  private static func makeCandidateSignal(
    _ definition: FieldDefinition,
    _ projections: [ValueProjection]
  ) throws -> CANUnitsSignal {
    let ordered = projections.sorted { observationOrder($0.observation, $1.observation) }
    let latest = ordered.last!
    let extractor = extractionFormula(definition)
    let formulaID = definition.transform?.id ?? "\(definition.id).raw-extractor"
    let formulaText = definition.transform.map {
      "display = (\(extractor)) * \(decimal($0.scale)) + \(decimal($0.offset))"
    } ?? "display = \(extractor)"
    let inputs = [
      "can.11bit.\(String(format: "0x%03x", definition.identifier)).bytes-\(definition.byteOffset)-\(definition.byteOffset + definition.byteLength - 1)"
    ]
    let sessionCount = Set(ordered.map {
      SessionKey(gatewayID: $0.observation.gatewayID, sessionID: $0.observation.sessionID)
    }).count
    return CANUnitsSignal(
      id: definition.id, signalID: definition.signalID, name: definition.label,
      source: "Passive CAN \(String(format: "0x%03X", definition.identifier)) / retained listen-only evidence",
      latestValue: latest.displayValue,
      unit: definition.transform?.unit ?? "raw count",
      latestRawValue: latest.rawValue,
      latestObservedAt: latest.observation.ingestedAt,
      latestEvidenceReference: latest.observation.id,
      authority: definition.transform == nil ? .rawOnlyCandidate : .unverifiedCandidateUnit,
      statistics: try descriptiveStatistics(ordered.map(\.displayValue)),
      definitionStatus: definition.status, validationGate: definition.validationGate,
      lineage: try makeLineage(
        formulaID: formulaID, formulaText: formulaText, inputIDs: inputs,
        evidenceSHA256: try evidenceSHA256(ordered.map(\.observation)),
        sampleCount: ordered.count, sessionCount: sessionCount,
        evidenceSelection:
          "Every retained observation matching the pinned identifier and field extractor; no chart downsampling."))
  }

  private static func makeRotationalRelationships(
    _ grouped: [String: [ValueProjection]]
  ) throws -> [CANRotationalRelationship] {
    let engineID = "toyota.2c4.engine-speed.be16"
    let turbineID = "toyota.2d0.turbine-speed.be16"
    guard let engines = grouped[engineID], let turbines = grouped[turbineID] else { return [] }
    let enginesBySession = Dictionary(grouping: engines) {
      SessionKey(gatewayID: $0.observation.gatewayID, sessionID: $0.observation.sessionID)
    }
    let turbinesBySession = Dictionary(grouping: turbines) {
      SessionKey(gatewayID: $0.observation.gatewayID, sessionID: $0.observation.sessionID)
    }
    let shared = Set(enginesBySession.keys).intersection(turbinesBySession.keys)
    var allPairs: [RotationalPair] = []
    var analyses: [CANRotationalSessionAnalysis] = []
    for key in shared.sorted(by: sessionKeyOrder) {
      let pairs = pair(
        engines: enginesBySession[key]!, turbines: turbinesBySession[key]!)
      guard pairs.count >= rotationalMinimumPairsPerSession else { continue }
      analyses.append(try makeSessionAnalysis(key: key, pairs: pairs))
      allPairs.append(contentsOf: pairs)
    }
    guard !allPairs.isEmpty else { return [] }
    return [try makeRelationship(
      engineID: engineID, turbineID: turbineID, pairs: allPairs, analyses: analyses)]
  }

  private static func pair(
    engines: [ValueProjection],
    turbines: [ValueProjection]
  ) -> [RotationalPair] {
    let orderedEngines = engines.sorted(by: monotonicOrder)
    let orderedTurbines = turbines.sorted(by: monotonicOrder)
    var unused = Set(orderedEngines.indices)
    var result: [RotationalPair] = []
    for turbine in orderedTurbines where turbine.displayValue.isFinite {
      let best = unused.compactMap { index -> (Int, UInt64)? in
        let engine = orderedEngines[index]
        guard engine.displayValue.isFinite, engine.displayValue != 0 else { return nil }
        return (
          index,
          absoluteDifference(
            engine.observation.monotonicMicroseconds,
            turbine.observation.monotonicMicroseconds))
      }.min { left, right in
        if left.1 != right.1 { return left.1 < right.1 }
        return orderedEngines[left.0].observation.sourceSequence
          < orderedEngines[right.0].observation.sourceSequence
      }
      guard let best, best.1 <= rotationalMaximumPairSkewMicroseconds else { continue }
      unused.remove(best.0)
      result.append(
        RotationalPair(
          engine: orderedEngines[best.0], turbine: turbine, skewMicroseconds: best.1))
    }
    return result
  }

  private static func makeSessionAnalysis(
    key: SessionKey,
    pairs: [RotationalPair]
  ) throws -> CANRotationalSessionAnalysis {
    let ratios = pairs.map { $0.turbine.displayValue / $0.engine.displayValue }
    let observations = pairs.flatMap { [$0.engine.observation, $0.turbine.observation] }
    let times = observations.map(\.ingestedAt).sorted()
    return CANRotationalSessionAnalysis(
      gatewayID: key.gatewayID, sessionID: key.sessionID,
      firstObservedAt: times.first!, lastObservedAt: times.last!,
      pairCount: pairs.count,
      maximumObservedPairSkewMicroseconds: pairs.map(\.skewMicroseconds).max()!,
      candidateUnitRatio: try descriptiveStatistics(ratios),
      pearsonCorrelation: pearson(
        pairs.map { $0.engine.displayValue }, pairs.map { $0.turbine.displayValue }),
      evidenceSHA256: try evidenceSHA256(observations))
  }

  private static func makeRelationship(
    engineID: String,
    turbineID: String,
    pairs: [RotationalPair],
    analyses: [CANRotationalSessionAnalysis]
  ) throws -> CANRotationalRelationship {
    let orderedAnalyses = analyses.sorted(by: analysisOrder)
    let ratios = pairs.map { $0.turbine.displayValue / $0.engine.displayValue }
    let observations = pairs.flatMap { [$0.engine.observation, $0.turbine.observation] }
    let formulaID = "toyota.rotational-candidate-ratio.same-session.\(algorithmVersion)"
    let formulaText =
      "ratio = 0x2D0 candidate rpm / 0x2C4 candidate rpm; one-to-one nearest pairs within the same gateway and session, maximum skew \(rotationalMaximumPairSkewMicroseconds) us; Pearson correlation calculated per session only"
    return CANRotationalRelationship(
      id: "toyota.2d0-to-2c4.rotational-candidate-relationship",
      name: "Rotational candidate relationship", authority: .unverifiedDerived,
      numeratorSignalID: turbineID, denominatorSignalID: engineID, unit: "ratio",
      pairCount: pairs.count, sessionCount: orderedAnalyses.count,
      maximumPairSkewMicroseconds: rotationalMaximumPairSkewMicroseconds,
      minimumPairsPerSession: rotationalMinimumPairsPerSession,
      pairingRule:
        "One-to-one nearest retained observations inside one gateway and one capture session; no cross-session interpolation.",
      candidateUnitRatio: try descriptiveStatistics(ratios), sessions: orderedAnalyses,
      lineage: try makeLineage(
        formulaID: formulaID, formulaText: formulaText,
        inputIDs: [engineID, turbineID],
        evidenceSHA256: try evidenceSHA256(observations),
        sampleCount: pairs.count, sessionCount: orderedAnalyses.count,
        evidenceSelection:
          "Only qualifying same-session pairs; short sessions are excluded and never bridged."))
  }

  private static func makeLineage(
    formulaID: String,
    formulaText: String,
    inputIDs: [String],
    evidenceSHA256: String,
    sampleCount: Int,
    sessionCount: Int,
    evidenceSelection: String
  ) throws -> CANUnitsLineage {
    let inputs = inputIDs.sorted()
    let formula = FormulaManifest(
      formulaID: formulaID, formulaText: formulaText, algorithmVersion: algorithmVersion)
    return CANUnitsLineage(
      formulaID: formulaID, formulaText: formulaText,
      formulaSHA256: sha256(try VHOSJSON.encoder().encode(formula)),
      inputIDs: inputs,
      inputSHA256: sha256(try VHOSJSON.encoder().encode(InputManifest(inputIDs: inputs))),
      evidenceSHA256: evidenceSHA256, sampleCount: sampleCount, sessionCount: sessionCount,
      evidenceSelection: evidenceSelection)
  }

  private static func descriptiveStatistics(
    _ values: [Double]
  ) throws -> CANDescriptiveStatistics {
    guard !values.isEmpty, values.allSatisfy(\.isFinite) else {
      throw CANUnitsError.invalidStatisticsInput
    }
    let ordered = values.sorted()
    let mean = ordered.reduce(0, +) / Double(ordered.count)
    let squared = ordered.reduce(0) { sum, value in
      let delta = value - mean
      return sum + delta * delta
    }
    let deviation = sqrt(squared / Double(ordered.count))
    return CANDescriptiveStatistics(
      sampleCount: ordered.count, minimum: ordered.first!, maximum: ordered.last!,
      mean: mean, populationStandardDeviation: deviation,
      peakToPeak: ordered.last! - ordered.first!,
      coefficientOfVariation: mean == 0 ? nil : deviation / abs(mean))
  }

  private static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
    guard x.count == y.count, x.count >= rotationalMinimumPairsPerSession else { return nil }
    let meanX = x.reduce(0, +) / Double(x.count)
    let meanY = y.reduce(0, +) / Double(y.count)
    var covariance = 0.0
    var varianceX = 0.0
    var varianceY = 0.0
    for index in x.indices {
      let dx = x[index] - meanX
      let dy = y[index] - meanY
      covariance += dx * dy
      varianceX += dx * dx
      varianceY += dy * dy
    }
    let denominator = sqrt(varianceX * varianceY)
    guard denominator > 0, denominator.isFinite else { return nil }
    let value = covariance / denominator
    return value.isFinite ? max(-1, min(1, value)) : nil
  }

  private static func monotonicOrder(_ left: ValueProjection, _ right: ValueProjection) -> Bool {
    if left.observation.monotonicMicroseconds != right.observation.monotonicMicroseconds {
      return left.observation.monotonicMicroseconds < right.observation.monotonicMicroseconds
    }
    return left.observation.sourceSequence < right.observation.sourceSequence
  }

  private static func sessionKeyOrder(_ left: SessionKey, _ right: SessionKey) -> Bool {
    if left.gatewayID != right.gatewayID { return left.gatewayID < right.gatewayID }
    return left.sessionID < right.sessionID
  }

  private static func analysisOrder(
    _ left: CANRotationalSessionAnalysis,
    _ right: CANRotationalSessionAnalysis
  ) -> Bool {
    if left.firstObservedAt != right.firstObservedAt {
      return left.firstObservedAt < right.firstObservedAt
    }
    if left.gatewayID != right.gatewayID { return left.gatewayID < right.gatewayID }
    return left.sessionID < right.sessionID
  }

  private static func standardSampleOrder(
    _ left: J1979StandardSample,
    _ right: J1979StandardSample
  ) -> Bool {
    let leftDate = wallDate(left.observedAt)!
    let rightDate = wallDate(right.observedAt)!
    if leftDate != rightDate { return leftDate < rightDate }
    if left.gatewayID != right.gatewayID { return left.gatewayID < right.gatewayID }
    if left.captureID != right.captureID { return left.captureID < right.captureID }
    if left.gatewayMonotonicMicroseconds != right.gatewayMonotonicMicroseconds {
      return left.gatewayMonotonicMicroseconds < right.gatewayMonotonicMicroseconds
    }
    if left.sourceSequence != right.sourceSequence {
      return left.sourceSequence < right.sourceSequence
    }
    if left.ecuAddress != right.ecuAddress { return left.ecuAddress < right.ecuAddress }
    return left.id < right.id
  }

  private static func extractionFormula(_ definition: FieldDefinition) -> String {
    let lastByte = definition.byteOffset + definition.byteLength - 1
    let signed = definition.signedBits.map { ", signed\($0)" } ?? ""
    let mask = String(format: "0x%llX", definition.mask)
    return "bytes \(definition.byteOffset)...\(lastByte), mask \(mask)\(signed)"
  }

  private static func wallDate(_ value: String) -> Date? {
    let plain = ISO8601DateFormatter()
    if let date = plain.date(from: value) { return date }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value)
  }

  private static func absoluteDifference(_ left: UInt64, _ right: UInt64) -> UInt64 {
    left >= right ? left - right : right - left
  }

  private static func decimal(_ value: Double) -> String {
    String(format: "%.12g", value)
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public enum CANUnitsError: Error, Equatable, LocalizedError {
  case contextMismatch
  case invalidObservation(String)
  case invalidStandardSample(String)
  case invalidStatisticsInput

  public var errorDescription: String? {
    switch self {
    case .contextMismatch:
      "The CAN units context does not describe the supplied source evidence."
    case .invalidObservation(let id):
      "The CAN units input contains invalid passive observation \(id)."
    case .invalidStandardSample(let id):
      "The CAN units input contains invalid J1979 sample \(id)."
    case .invalidStatisticsInput:
      "CAN unit statistics require at least one finite value."
    }
  }
}
