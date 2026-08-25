import Foundation

/// Projects checksummed portable transport records into durable passive-CAN observations.
///
/// This projection does not promote transport metadata into vehicle truth. Every portable
/// envelope is validated first, only the OBD/CAN source role may provide CAN evidence, and
/// every projected observation must retain listen-only proof. When the same physical frame
/// exists in both the BLE live stream and the gateway's CRC-protected flash log, the flash
/// record is retained as the stronger provenance.
public enum PortableCANEvidence {
  public static func project(
    _ records: [PortableLogicalFrame]
  ) throws -> [PassiveCANObservation] {
    var observations: [PassiveCANObservation] = []

    for record in records {
      let frame = try record.validatedFrame()
      switch frame.messageType {
      case .rawCANFrame:
        try requireOBDCANRole(record)
        let observation = try PassiveCANObservation.decodeLive(
          frame.payload,
          gatewayID: record.sourceID,
          ingestedAt: record.ingestedAt
        )
        try PassiveCANEvidenceArchive.validate(observation)
        observations.append(observation)

      case .captureLogChunk:
        try requireOBDCANRole(record)
        let chunk = try CaptureLogChunk.decode(
          frame.payload,
          gatewayID: record.sourceID,
          ingestedAt: record.ingestedAt
        )
        try chunk.records.forEach(PassiveCANEvidenceArchive.validate)
        observations.append(contentsOf: chunk.records)

      default:
        continue
      }
    }

    return try reconcile(existing: [], projected: observations)
  }

  /// Reconciles projected portable observations with an existing passive-CAN archive.
  ///
  /// Identity is the deployed gateway/session/source-sequence tuple. Equal physical evidence
  /// is de-duplicated independently of transfer time; gateway-flash wins over BLE live on an
  /// exact physical overlap. Reuse of an identity for different CAN evidence fails closed.
  public static func reconcile(
    existing: [PassiveCANObservation],
    projected: [PassiveCANObservation]
  ) throws -> [PassiveCANObservation] {
    var byIdentity: [String: PassiveCANObservation] = [:]

    for observation in existing + projected {
      try PassiveCANEvidenceArchive.validate(observation)
      try requireSupportedEvidenceSource(observation)

      guard let current = byIdentity[observation.id] else {
        byIdentity[observation.id] = observation
        continue
      }
      guard hasSamePhysicalEvidence(current, observation) else {
        throw PortableCANEvidenceError.identityCollision(observation.id)
      }
      if isPreferred(observation, over: current) {
        byIdentity[observation.id] = observation
      }
    }

    return try PassiveCANEvidenceArchive.merge(
      existing: [], incoming: Array(byIdentity.values)
    ).records
  }

  private static func requireOBDCANRole(_ record: PortableLogicalFrame) throws {
    guard record.sourceRole == .obdCAN else {
      throw PortableCANEvidenceError.invalidSourceRole(
        recordID: record.id,
        actual: record.sourceRole
      )
    }
  }

  private static func requireSupportedEvidenceSource(
    _ observation: PassiveCANObservation
  ) throws {
    guard
      observation.evidenceSource == "ble-live"
        || observation.evidenceSource == "gateway-flash"
    else {
      throw PortableCANEvidenceError.unsupportedEvidenceSource(
        identity: observation.id,
        source: observation.evidenceSource
      )
    }
  }

  private static func hasSamePhysicalEvidence(
    _ left: PassiveCANObservation,
    _ right: PassiveCANObservation
  ) -> Bool {
    left.contract == right.contract
      && left.contractVersion == right.contractVersion
      && left.gatewayID == right.gatewayID
      && left.sessionID == right.sessionID
      && left.sourceSequence == right.sourceSequence
      && left.monotonicMicroseconds == right.monotonicMicroseconds
      && left.bitrateBps == right.bitrateBps
      && left.identifier == right.identifier
      && left.extended == right.extended
      && left.remoteRequest == right.remoteRequest
      && left.listenOnly == right.listenOnly
      && left.dataLength == right.dataLength
      && left.data == right.data
  }

  private static func isPreferred(
    _ candidate: PassiveCANObservation,
    over current: PassiveCANObservation
  ) -> Bool {
    let candidateRank = candidate.evidenceSource == "gateway-flash" ? 1 : 0
    let currentRank = current.evidenceSource == "gateway-flash" ? 1 : 0
    if candidateRank != currentRank { return candidateRank > currentRank }

    // Ingestion time is not vehicle truth. This tie-break only makes duplicate transfer copies
    // deterministic; it never resolves a disagreement in the physical CAN evidence above.
    return candidate.ingestedAt < current.ingestedAt
  }
}

public enum PortableCANEvidenceError: Error, Equatable, LocalizedError {
  case invalidSourceRole(recordID: String, actual: EvidenceSourceRole)
  case unsupportedEvidenceSource(identity: String, source: String)
  case identityCollision(String)

  public var errorDescription: String? {
    switch self {
    case .invalidSourceRole(let recordID, let actual):
      "Portable CAN record \(recordID) has source role \(actual.rawValue); OBD_CAN is required."
    case .unsupportedEvidenceSource(let identity, let source):
      "Passive CAN record \(identity) has unsupported evidence source \(source)."
    case .identityCollision(let identity):
      "Passive CAN identity \(identity) contains conflicting physical evidence."
    }
  }
}
