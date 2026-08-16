import Foundation

public enum ProtocolTestState: String, Codable, Sendable {
  case notTested = "NOT_TESTED"
  case noLock = "NO_LOCK"
  case networkDetected = "NETWORK_DETECTED"
  case obdConfirmed = "OBD_CONFIRMED"
  case inconclusive = "INCONCLUSIVE"
  case rejected = "REJECTED"
}

public struct ProtocolTestStatus: Identifiable, Equatable, Sendable {
  public var id: String { protocolID.rawValue }

  public let protocolID: DiscoveryProtocol
  public let state: ProtocolTestState
  public let latestResult: ProtocolExperimentResult?

  public init(
    protocolID: DiscoveryProtocol,
    state: ProtocolTestState,
    latestResult: ProtocolExperimentResult?
  ) {
    self.protocolID = protocolID
    self.state = state
    self.latestResult = latestResult
  }
}

public struct ProtocolEvidenceSummary: Equatable, Sendable {
  public let tests: [ProtocolTestStatus]
  public let latestResult: ProtocolExperimentResult?
  public let latestNetworkConfirmation: ProtocolExperimentResult?
  public let latestOBDConfirmation: ProtocolExperimentResult?

  public init(results: [ProtocolExperimentResult]) {
    tests = DiscoveryProtocol.allCases.map { protocolID in
      let result = results.last { $0.candidate.protocolID == protocolID }
      return ProtocolTestStatus(
        protocolID: protocolID,
        state: result.map(Self.state(for:)) ?? .notTested,
        latestResult: result
      )
    }
    latestResult = results.last
    latestNetworkConfirmation = results.last {
      $0.outcome == .passiveLock || $0.outcome == .readConfirmed
    }
    latestOBDConfirmation = results.last { $0.outcome == .readConfirmed }
  }

  private static func state(for result: ProtocolExperimentResult) -> ProtocolTestState {
    switch result.outcome {
    case .noLock: .noLock
    case .passiveLock: .networkDetected
    case .readConfirmed: .obdConfirmed
    case .rejectedError: .rejected
    case .inconclusive: .inconclusive
    }
  }
}
