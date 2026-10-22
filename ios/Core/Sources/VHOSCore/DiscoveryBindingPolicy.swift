import Foundation

/// How a Discovery marker chooses the CAN observation it binds to.
///
/// This policy exists because of a field incident (2026-08-24): the app
/// selected the binding observation by sorting retained observations by
/// LARGEST sessionID and taking the first. A legacy record carrying a
/// wrapped 64-bit session value (2^64 − 279,472) therefore won selection
/// forever, and fifteen markers across three test runs were appended to
/// the append-only ledger sharing one immutable evidence coordinate
/// (sequence 1,553) — which voids the correlation analysis those markers
/// exist to feed. Session identifiers are opaque labels; magnitude means
/// nothing. Recency is carried by the gateway's monotonic clock, and a
/// marker after another marker in the same session must move forward on
/// that clock or it is not a second event.
public enum DiscoveryBindingPolicy {

  /// The last marker already committed for a test run, used to enforce
  /// forward progress within one gateway session.
  public struct RecordedMarkerContext: Equatable, Sendable {
    public let gatewaySessionID: UInt32
    public let gatewayMonotonicMicroseconds: UInt64

    public init(gatewaySessionID: UInt32, gatewayMonotonicMicroseconds: UInt64) {
      self.gatewaySessionID = gatewaySessionID
      self.gatewayMonotonicMicroseconds = gatewayMonotonicMicroseconds
    }
  }

  public enum BindingRejection: Error, Equatable, Sendable {
    /// No observation exists after filtering implausible sessions.
    case noPlausibleObservation
    /// A preferred gateway/session was named and no retained observation
    /// matches it exactly.
    case preferredContextUnavailable
    /// The candidate does not advance the gateway monotonic clock past
    /// the last committed marker in the same session — the evidence
    /// timeline is stalled (for example a frozen replay archive), so a
    /// new marker would duplicate an existing evidence coordinate.
    case timelineStalled(lastMonotonicMicroseconds: UInt64)
  }

  /// A raw session value is plausible when it is nonzero and fits the
  /// gateway wire contract's 32-bit session field. Values outside that
  /// range can only come from corruption or from records written by
  /// builds predating the current types; they are quarantined from
  /// selection, correlation, and binding — never silently repaired.
  public static func sessionValueIsPlausible(_ raw: UInt64) -> Bool {
    raw != 0 && raw <= UInt64(UInt32.max)
  }

  public static func sessionValueIsPlausible(_ raw: UInt32) -> Bool {
    raw != 0
  }

  /// Deterministic ordering for presenting retained observations:
  /// freshest first by monotonic clock, then by source sequence, then by
  /// session id purely as a stable tiebreak (never as a recency signal).
  public static func presentationOrder(
    _ observations: [PassiveCANObservation]
  ) -> [PassiveCANObservation] {
    observations.sorted {
      if $0.monotonicMicroseconds != $1.monotonicMicroseconds {
        return $0.monotonicMicroseconds > $1.monotonicMicroseconds
      }
      if $0.sourceSequence != $1.sourceSequence {
        return $0.sourceSequence > $1.sourceSequence
      }
      return $0.sessionID > $1.sessionID
    }
  }

  /// Select the observation a new marker will bind to.
  ///
  /// - Plausible sessions only; implausible records never win anything.
  /// - When a preferred gateway/session is named (a run already bound to
  ///   a context), only an exact match is acceptable.
  /// - Otherwise the freshest observation by monotonic clock wins.
  /// - When the run has already committed a marker in the same session,
  ///   the candidate must be strictly later on the monotonic clock:
  ///   two taps may never share an evidence coordinate.
  public static func selectBindingObservation(
    from observations: [PassiveCANObservation],
    preferredGatewayID: String? = nil,
    preferredSessionID: UInt32? = nil,
    lastRecordedMarker: RecordedMarkerContext? = nil
  ) -> Result<PassiveCANObservation, BindingRejection> {
    let plausible = observations.filter { sessionValueIsPlausible($0.sessionID) }
    guard !plausible.isEmpty else { return .failure(.noPlausibleObservation) }

    let candidate: PassiveCANObservation
    if let preferredGatewayID, let preferredSessionID {
      let bound = plausible.filter {
        $0.gatewayID == preferredGatewayID && $0.sessionID == preferredSessionID
      }
      guard let freshest = presentationOrder(bound).first else {
        return .failure(.preferredContextUnavailable)
      }
      candidate = freshest
    } else {
      guard preferredGatewayID == nil, preferredSessionID == nil else {
        return .failure(.preferredContextUnavailable)
      }
      candidate = presentationOrder(plausible)[0]
    }

    if let last = lastRecordedMarker,
      candidate.sessionID == last.gatewaySessionID,
      candidate.monotonicMicroseconds <= last.gatewayMonotonicMicroseconds
    {
      return .failure(
        .timelineStalled(
          lastMonotonicMicroseconds: last.gatewayMonotonicMicroseconds))
    }
    return .success(candidate)
  }
}
