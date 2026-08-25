import CryptoKit
import Foundation

public struct EvidenceOutboxAuthority: Codable, Equatable, Sendable {
  public let mayInterpret: Bool
  public let mayProposeExperiment: Bool
  public let mayActivateExperiment: Bool
  public let mayEmitVehicleFrames: Bool

  private enum CodingKeys: String, CodingKey {
    case mayInterpret
    case mayProposeExperiment
    case mayActivateExperiment
    case mayEmitVehicleFrames
  }

  public init() {
    mayInterpret = true
    mayProposeExperiment = true
    mayActivateExperiment = false
    mayEmitVehicleFrames = false
  }
}

public struct EvidenceOutboxEnvelope: Codable, Equatable, Sendable, Identifiable {
  public static let allowedContentTypes: Set<String> = [
    "application/vnd.vhos.evidence-sync+zip",
    "application/vnd.vhos.agent-evidence+json",
    "application/vnd.vhos.discovery-draft-evidence+json",
    "application/vnd.vhos.import-provenance-receipt+json",
  ]

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
    case packageID = "packageId"
    case createdAt
    case contentType
    case byteCount
    case sha256
    case authority
    case redactionPolicy
  }

  public var id: UUID { packageID }

  public init(
    packageID: UUID = UUID(),
    createdAt: String = ISO8601DateFormatter().string(from: Date()),
    contentType: String,
    payload: Data
  ) throws {
    guard !payload.isEmpty, payload.count <= 128 * 1024 * 1024,
      Self.allowedContentTypes.contains(contentType),
      EvidenceContractScalarValidation.isWallTime(createdAt)
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
      redactionPolicy == "OWNER_PRIVATE_V1", byteCount > 0, byteCount <= 128 * 1024 * 1024,
      byteCount == payload.count, EvidenceContractScalarValidation.isWallTime(createdAt),
      Self.allowedContentTypes.contains(contentType), sha256 == Self.digest(payload),
      authority.mayInterpret,
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
