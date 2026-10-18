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

public enum CANUnitsAnalyzer {
  public static let rotationalMaximumPairSkewMicroseconds: UInt64 = 125_000
  public static let rotationalMinimumPairsPerSession = 8
  public static let algorithmVersion = "1.0.0"

  public static func analyze(
    observations: [PassiveCANObservation],
    standardSamples: [J1979StandardSample] = []
  ) throws -> CANUnitsReport {
    try observations.forEach(validate)
    return try build(observations: observations, standardSamples: standardSamples)
  }
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

public struct CANDescriptiveStatistics: Codable, Equatable, Sendable {
  public let sampleCount: Int
  public let minimum: Double
  public let maximum: Double
  public let mean: Double
  public let populationStandardDeviation: Double
  public let peakToPeak: Double
  public let coefficientOfVariation: Double?
}
