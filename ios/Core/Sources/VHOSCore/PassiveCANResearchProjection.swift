import Foundation

public enum PassiveCANResearchValueAuthority: String, Codable, Equatable, Sendable {
  case referencedCrossModelTransform = "UNVERIFIED_CROSS_MODEL_TRANSFORM"
  case rawOnlyConflictingDefinition = "RAW_ONLY_CONFLICTING_DEFINITION"
  case rawOnlyUnvalidatedTransform = "RAW_ONLY_UNVALIDATED_TRANSFORM"

  public var exposesEngineeringUnit: Bool {
    self == .referencedCrossModelTransform
  }
}

/// One immutable, derived candidate sample bound to one exact passive-CAN observation.
///
/// The source observation remains durable truth. This projection is replay-only research output:
/// it cannot grant PARKED authority, drive owner health, or enter the promoted signal registry.
public struct PassiveCANResearchProjection: Identifiable, Equatable, Sendable {
  public let definitionID: String
  public let label: String
  public let candidateSemantic: String
  public let identifierHex: String
  public let sourceObservationID: String
  public let sourceGatewayID: String
  public let sourceSessionID: UInt32
  public let sourceSequence: UInt64
  public let sourceMonotonicMicroseconds: UInt64
  public let sourceIngestedAt: String
  public let sourceEvidenceKind: String
  public let sourceListenOnly: Bool
  public let packID: String
  public let packVersion: String
  public let packSHA256: String
  public let definitionSourceIDs: [String]
  public let transformSourceIDs: [String]
  public let rawValue: Double
  public let displayValue: Double
  public let displayUnit: String
  public let candidateTransformID: String?
  public let valueAuthority: PassiveCANResearchValueAuthority
  public let validationGate: String
  public let authority: DiscoveryAuthorityStatus
  public let replayOnly: Bool
  public let promotionAllowed: Bool
  public let ownerHealthDisplayAllowed: Bool

  public var id: String { "\(sourceObservationID):\(definitionID)" }
}

/// Pure projection from validated passive evidence into pinned research candidates.
///
/// The projector has no clock, storage, connection, or mutable registry dependency. It only uses
/// the checked-in, hash-pinned research catalog and the bytes carried by the supplied observation.
public enum PassiveCANResearchProjector {
  public static func project(
    _ observation: PassiveCANObservation
  ) throws -> [PassiveCANResearchProjection] {
    try PassiveCANEvidenceArchive.validate(observation)
    return PassiveCANResearchCatalog.definitions.compactMap { definition in
      projection(of: observation, using: definition)
    }
  }

  static func projection(
    of observation: PassiveCANObservation,
    using definition: PassiveCANResearchDefinition
  ) -> PassiveCANResearchProjection? {
    guard observation.identifier == definition.identifier, !observation.extended,
      !observation.remoteRequest,
      let rawValue = extract(definition, from: observation)
    else { return nil }

    let transform = definition.candidateTransform
    return PassiveCANResearchProjection(
      definitionID: definition.id,
      label: definition.label,
      candidateSemantic: definition.candidateSemantic,
      identifierHex: definition.identifierHex,
      sourceObservationID: observation.id,
      sourceGatewayID: observation.gatewayID,
      sourceSessionID: observation.sessionID,
      sourceSequence: observation.sourceSequence,
      sourceMonotonicMicroseconds: observation.monotonicMicroseconds,
      sourceIngestedAt: observation.ingestedAt,
      sourceEvidenceKind: observation.evidenceSource,
      sourceListenOnly: observation.listenOnly,
      packID: PassiveCANResearchCatalog.packID,
      packVersion: PassiveCANResearchCatalog.packVersion,
      packSHA256: PassiveCANResearchCatalog.packSHA256,
      definitionSourceIDs: definition.sourceIDs,
      transformSourceIDs: transform?.sourceIDs ?? [],
      rawValue: rawValue,
      displayValue: transform.map { rawValue * $0.scale + $0.offset } ?? rawValue,
      displayUnit: transform?.unit ?? "raw count",
      candidateTransformID: transform?.transformID,
      valueAuthority: valueAuthority(for: definition),
      validationGate: definition.validationGate,
      authority: .candidate,
      replayOnly: true,
      promotionAllowed: false,
      ownerHealthDisplayAllowed: false
    )
  }

  static func valueAuthority(
    for definition: PassiveCANResearchDefinition
  ) -> PassiveCANResearchValueAuthority {
    if definition.candidateTransform != nil { return .referencedCrossModelTransform }
    if definition.validationGate.localizedCaseInsensitiveContains("conflict") {
      return .rawOnlyConflictingDefinition
    }
    return .rawOnlyUnvalidatedTransform
  }

  private static func extract(
    _ definition: PassiveCANResearchDefinition,
    from observation: PassiveCANObservation
  ) -> Double? {
    let end = definition.byteOffset + definition.byteLength
    guard definition.byteLength > 0, definition.byteLength <= 8,
      end <= Int(observation.dataLength), end <= observation.data.count
    else { return nil }
    var word: UInt64 = 0
    for byte in observation.data[definition.byteOffset..<end] {
      word = (word << 8) | UInt64(byte)
    }
    let masked = (word >> UInt64(definition.rightShift)) & definition.mask
    if let bits = definition.signedBits, bits > 0, bits < 64 {
      let signBit = UInt64(1) << UInt64(bits - 1)
      if masked & signBit != 0 {
        return Double(Int64(masked) - Int64(UInt64(1) << UInt64(bits)))
      }
    }
    return Double(masked)
  }
}
