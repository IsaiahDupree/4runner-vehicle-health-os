import Foundation

public struct ExperimentApproval: Codable, Equatable, Sendable {
  public let contract: String
  public let contractVersion: String
  public let approvedAt: String
  public let approvedBy: String
  public let plan: ProtocolDiscoveryPlan

  public init(
    contract: String = "experiment.approval",
    contractVersion: String = "1.0.0",
    approvedAt: String,
    approvedBy: String = "local-owner",
    plan: ProtocolDiscoveryPlan
  ) {
    self.contract = contract
    self.contractVersion = contractVersion
    self.approvedAt = approvedAt
    self.approvedBy = approvedBy
    self.plan = plan
  }
}

public struct SignedExperimentPlanEnvelope: Codable, Equatable, Sendable {
  public let contract: String
  public let contractVersion: String
  public let approval: ExperimentApproval
  public let signingKeyID: String
  public let signatureBase64: String

  public init(
    contract: String = "experiment.signed-plan",
    contractVersion: String = "1.0.0",
    approval: ExperimentApproval,
    signingKeyID: String,
    signature: Data
  ) {
    self.contract = contract
    self.contractVersion = contractVersion
    self.approval = approval
    self.signingKeyID = signingKeyID
    signatureBase64 = signature.base64EncodedString()
  }

  private enum CodingKeys: String, CodingKey {
    case contract
    case contractVersion
    case approval
    case signingKeyID = "signingKeyId"
    case signatureBase64
  }

  public func encoded() throws -> Data {
    try VHOSJSON.encoder().encode(self)
  }
}
