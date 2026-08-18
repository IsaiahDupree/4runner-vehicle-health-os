import CryptoKit
import Foundation

public struct EvidenceOutboxAuthority: Codable, Equatable, Sendable {
  public let mayInterpret: Bool
  public let mayProposeExperiment: Bool
  public let mayActivateExperiment: Bool
  public let mayEmitVehicleFrames: Bool

  private enum CodingKeys: String, CodingKey {
    case mayInterpret = "may_interpret"
    case mayProposeExperiment = "may_propose_experiment"
    case mayActivateExperiment = "may_activate_experiment"
    case mayEmitVehicleFrames = "may_emit_vehicle_frames"
  }

  public init() {
    mayInterpret = true
    mayProposeExperiment = true
    mayActivateExperiment = false
    mayEmitVehicleFrames = false
  }
}

public struct EvidenceOutboxEnvelope: Codable, Equatable, Sendable, Identifiable {
  public let contract: String
  public let contractVersion: String
  public let packageID: UUID
  public let createdAt: String
  public let contentType: String
  public let byteCount: Int
  public let sha256: String
  public let authority: EvidenceOutboxAuthority
  public let redactionPolicy: String

  private enum CodingKeys: String, CodingKey {
    case contract
    case contractVersion
    case packageID = "package_id"
    case createdAt = "created_at"
    case contentType = "content_type"
    case byteCount = "byte_count"
    case sha256
    case authority
    case redactionPolicy = "redaction_policy"
  }

  public var id: UUID { packageID }

  public init(
    packageID: UUID = UUID(),
    createdAt: String = ISO8601DateFormatter().string(from: Date()),
    contentType: String,
    payload: Data
  ) throws {
    guard !payload.isEmpty, payload.count <= 128 * 1024 * 1024,
      [
        "application/vnd.vhos.evidence-sync+zip",
        "application/vnd.vhos.agent-evidence+json",
      ].contains(contentType)
    else { throw EvidenceOutboxError.invalidEnvelope }
    contract = "evidence.outbox-envelope"
    contractVersion = "1.0.0"
    self.packageID = packageID
    self.createdAt = createdAt
    self.contentType = contentType
    byteCount = payload.count
    sha256 = Self.digest(payload)
    authority = EvidenceOutboxAuthority()
    redactionPolicy = "OWNER_PRIVATE_V1"
  }

  public func validate(payload: Data) throws {
    guard contract == "evidence.outbox-envelope", contractVersion == "1.0.0",
      redactionPolicy == "OWNER_PRIVATE_V1", byteCount == payload.count,
      sha256 == Self.digest(payload), authority.mayInterpret,
      authority.mayProposeExperiment, !authority.mayActivateExperiment,
      !authority.mayEmitVehicleFrames
    else { throw EvidenceOutboxError.invalidEnvelope }
  }

  private static func digest(_ payload: Data) -> String {
    SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
  }
}

public enum EvidenceOutboxError: Error, Equatable, LocalizedError {
  case invalidEnvelope

  public var errorDescription: String? {
    switch self {
    case .invalidEnvelope:
      "The evidence outbox envelope, hash, redaction policy, or authority boundary is invalid."
    }
  }
}
