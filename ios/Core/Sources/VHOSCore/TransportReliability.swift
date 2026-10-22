import Foundation

/// Durable CAN evidence identity. It survives BLE reconnects and rejects replayed delivery.
public struct CANEvidenceIdentity: Hashable, Sendable {
  public let gatewayID: String
  public let sessionID: UInt32
  public let sourceSequence: UInt64

  public init(gatewayID: String, sessionID: UInt32, sourceSequence: UInt64) {
    self.gatewayID = gatewayID
    self.sessionID = sessionID
    self.sourceSequence = sourceSequence
  }

  public init(_ observation: PassiveCANObservation) {
    self.init(
      gatewayID: observation.gatewayID,
      sessionID: observation.sessionID,
      sourceSequence: observation.sourceSequence
    )
  }
}

public enum TransportDeliveryDecision: String, Equatable, Sendable {
  case accepted = "ACCEPTED"
  case duplicateEvidence = "DUPLICATE_EVIDENCE"
  case staleLinkEpoch = "STALE_LINK_EPOCH"
  case outerSequenceRegression = "OUTER_SEQUENCE_REGRESSION"
}

public enum TransportQualityClass: String, Equatable, Sendable {
  case healthy = "HEALTHY"
  case degraded = "DEGRADED"
}

public struct TransportReliabilitySnapshot: Equatable, Sendable {
  public let activeLinkEpoch: UInt64
  public let acceptedUniqueEvidence: Int
  public let duplicateEvidenceRejections: Int
  public let staleEpochRejections: Int
  public let outerSequenceRegressionRejections: Int
  public let outerSequenceGaps: UInt64
  public let reconnects: Int

  public var quality: TransportQualityClass {
    if duplicateEvidenceRejections == 0, staleEpochRejections == 0,
      outerSequenceRegressionRejections == 0, outerSequenceGaps == 0, reconnects == 0
    {
      return .healthy
    }
    return .degraded
  }
}

/// Pure application-boundary state used by the iPhone and deterministic offline link tests.
///
/// The current link epoch rejects late Core Bluetooth callbacks from an older physical link.
/// Evidence identity remains global across reconnects so a restored or repeated notification can
/// never append the same vehicle observation twice.
public struct TransportReliabilityLedger: Sendable {
  public private(set) var activeLinkEpoch: UInt64 = 1
  public private(set) var acceptedUniqueEvidence = 0
  public private(set) var duplicateEvidenceRejections = 0
  public private(set) var staleEpochRejections = 0
  public private(set) var outerSequenceRegressionRejections = 0
  public private(set) var outerSequenceGaps: UInt64 = 0
  public private(set) var reconnects = 0

  private var identities = Set<CANEvidenceIdentity>()
  private var lastOuterSequence: UInt64?

  public init() {}

  @discardableResult
  public mutating func beginReconnectedPhysicalLink() -> UInt64 {
    activeLinkEpoch &+= 1
    reconnects += 1
    lastOuterSequence = nil
    return activeLinkEpoch
  }

  public mutating func receive(
    _ observation: PassiveCANObservation,
    outerSequence: UInt64,
    linkEpoch: UInt64
  ) -> TransportDeliveryDecision {
    guard linkEpoch == activeLinkEpoch else {
      staleEpochRejections += 1
      return .staleLinkEpoch
    }
    let identity = CANEvidenceIdentity(observation)
    guard !identities.contains(identity) else {
      duplicateEvidenceRejections += 1
      return .duplicateEvidence
    }
    if let lastOuterSequence, outerSequence <= lastOuterSequence {
      outerSequenceRegressionRejections += 1
      return .outerSequenceRegression
    }
    if let lastOuterSequence {
      let delta = outerSequence - lastOuterSequence
      if delta > 1 { outerSequenceGaps += delta - 1 }
    }
    self.lastOuterSequence = outerSequence
    identities.insert(identity)
    acceptedUniqueEvidence += 1
    return .accepted
  }

  public var snapshot: TransportReliabilitySnapshot {
    TransportReliabilitySnapshot(
      activeLinkEpoch: activeLinkEpoch,
      acceptedUniqueEvidence: acceptedUniqueEvidence,
      duplicateEvidenceRejections: duplicateEvidenceRejections,
      staleEpochRejections: staleEpochRejections,
      outerSequenceRegressionRejections: outerSequenceRegressionRejections,
      outerSequenceGaps: outerSequenceGaps,
      reconnects: reconnects
    )
  }
}
