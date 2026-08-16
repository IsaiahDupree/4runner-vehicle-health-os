import Foundation

public struct AgentAuthorityBoundary: Codable, Equatable, Sendable {
  public let mayInterpretEvidence: Bool
  public let mayRankHypotheses: Bool
  public let mayProposeSignedExperimentPlans: Bool
  public let mayActivateVehicleExperiment: Bool
  public let mayEmitRawVehicleFrames: Bool

  public init(
    mayInterpretEvidence: Bool = true,
    mayRankHypotheses: Bool = true,
    mayProposeSignedExperimentPlans: Bool = true,
    mayActivateVehicleExperiment: Bool = false,
    mayEmitRawVehicleFrames: Bool = false
  ) {
    self.mayInterpretEvidence = mayInterpretEvidence
    self.mayRankHypotheses = mayRankHypotheses
    self.mayProposeSignedExperimentPlans = mayProposeSignedExperimentPlans
    self.mayActivateVehicleExperiment = mayActivateVehicleExperiment
    self.mayEmitRawVehicleFrames = mayEmitRawVehicleFrames
  }
}

public struct AgentEvidenceHandoff: Codable, Equatable, Sendable {
  public let contract: String
  public let contractVersion: String
  public let generatedAt: String
  public let gatewayID: String
  public let hardwareRevision: String
  public let firmwareBuildID: String
  public let activeConfigID: String
  public let activeConfigVersion: String
  public let vehicleMotion: VehicleMotion
  public let experimentResults: [ProtocolExperimentResult]
  public let authority: AgentAuthorityBoundary

  private enum CodingKeys: String, CodingKey {
    case contract
    case contractVersion
    case generatedAt
    case gatewayID = "gatewayId"
    case hardwareRevision
    case firmwareBuildID = "firmwareBuildId"
    case activeConfigID = "activeConfigId"
    case activeConfigVersion
    case vehicleMotion
    case experimentResults
    case authority
  }

  public init(
    contract: String = "agent.evidence-handoff",
    contractVersion: String = "1.0.0",
    generatedAt: String,
    handshake: GatewayHandshake,
    health: GatewayHealth,
    experimentResults: [ProtocolExperimentResult],
    authority: AgentAuthorityBoundary = AgentAuthorityBoundary()
  ) {
    self.contract = contract
    self.contractVersion = contractVersion
    self.generatedAt = generatedAt
    gatewayID = handshake.gatewayID
    hardwareRevision = handshake.hardwareRevision
    firmwareBuildID = handshake.firmwareBuildID
    activeConfigID = handshake.activeConfigID
    activeConfigVersion = handshake.activeConfigVersion
    vehicleMotion = health.vehicleMotion
    self.experimentResults = experimentResults
    self.authority = authority
  }

  public func encoded() throws -> Data {
    try VHOSJSON.encoder().encode(self)
  }
}
