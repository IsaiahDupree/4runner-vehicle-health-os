import CryptoKit
import Foundation

public enum ReleaseTarget: String, Codable, Sendable {
  case androidHeadUnit = "ANDROID_HEAD_UNIT"
  case esp32OBDGateway = "ESP32_OBD_GATEWAY"
  case esp32ACSensorNode = "ESP32_AC_SENSOR_NODE"
}

public enum ReleaseArtifactKind: String, Codable, Sendable {
  case androidAPK = "ANDROID_APK"
  case esp32VHOSOTA = "ESP32_VHOSOTA"
  case esp32MergedRecovery = "ESP32_MERGED_RECOVERY"
}

public enum ReleaseChannel: String, Codable, Sendable {
  case development = "DEVELOPMENT"
  case beta = "BETA"
  case stable = "STABLE"
}

public enum ReleaseInstallMethod: String, Codable, Sendable {
  case androidPackageInstaller = "ANDROID_PACKAGE_INSTALLER"
  case mobileToESP32AuthenticatedWiFi = "MOBILE_TO_ESP32_AUTHENTICATED_WIFI"
  case usbSerialInitialFlash = "USB_SERIAL_INITIAL_FLASH"
}

public enum ReleaseReadiness: String, Codable, Sendable {
  case available = "AVAILABLE"
  case safetyGated = "SAFETY_GATED"
  case recoveryOnly = "RECOVERY_ONLY"
}

public struct AndroidReleaseMetadata: Codable, Equatable, Sendable {
  public let packageID: String
  public let versionCode: Int
  public let signingCertificateSHA256: String
  public let debugSigned: Bool

  private enum CodingKeys: String, CodingKey {
    case packageID = "packageId"
    case versionCode
    case signingCertificateSHA256 = "signingCertificateSha256"
    case debugSigned
  }
}

public struct ESP32ReleaseMetadata: Codable, Equatable, Sendable {
  public let chipFamily: String
  public let hardwareRevisions: [String]
  public let distributionSignature: String
  public let initialFlashRequired: Bool
}

public struct ReleaseArtifact: Codable, Equatable, Sendable, Identifiable {
  public let artifactID: String
  public let target: ReleaseTarget
  public let kind: ReleaseArtifactKind
  public let version: String
  public let channel: ReleaseChannel
  public let publishedAt: String
  public let sourceRepository: URL
  public let sourceCommit: String
  public let downloadURL: URL
  public let sha256: String
  public let byteCount: Int
  public let installMethod: ReleaseInstallMethod
  public let readiness: ReleaseReadiness
  public let releaseNotes: String
  public let android: AndroidReleaseMetadata?
  public let esp32: ESP32ReleaseMetadata?

  private enum CodingKeys: String, CodingKey {
    case artifactID = "artifactId"
    case target
    case kind
    case version
    case channel
    case publishedAt
    case sourceRepository
    case sourceCommit
    case downloadURL = "downloadUrl"
    case sha256
    case byteCount
    case installMethod
    case readiness
    case releaseNotes
    case android
    case esp32
  }

  public var id: String { artifactID }

  public func verifyDownloadedBytes(_ bytes: Data) throws {
    guard bytes.count == byteCount else { throw ReleaseCatalogError.artifactByteCountMismatch }
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    guard digest == sha256 else { throw ReleaseCatalogError.artifactHashMismatch }
  }
}

public struct ReleaseCatalog: Codable, Equatable, Sendable {
  public let contract: String
  public let contractVersion: String
  public let catalogID: UUID
  public let generatedAt: String
  public let artifacts: [ReleaseArtifact]

  private enum CodingKeys: String, CodingKey {
    case contract
    case contractVersion
    case catalogID = "catalogId"
    case generatedAt
    case artifacts
  }
}

public enum ReleaseCatalogCodec {
  public static func verifyAndDecode(
    catalogBytes: Data,
    signatureBase64: Data,
    publicKeyDERBase64: Data
  ) throws -> ReleaseCatalog {
    guard catalogBytes.count <= 1_048_576,
      let signatureText = String(data: signatureBase64, encoding: .utf8),
      let publicKeyText = String(data: publicKeyDERBase64, encoding: .utf8),
      let signatureData = Data(base64Encoded: signatureText.trimmingCharacters(in: .whitespacesAndNewlines)),
      let publicKeyData = Data(base64Encoded: publicKeyText.trimmingCharacters(in: .whitespacesAndNewlines))
    else { throw ReleaseCatalogError.invalidTrustMaterial }

    let publicKey: P256.Signing.PublicKey
    let signature: P256.Signing.ECDSASignature
    do {
      publicKey = try P256.Signing.PublicKey(derRepresentation: publicKeyData)
      signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
    } catch {
      throw ReleaseCatalogError.invalidTrustMaterial
    }
    guard publicKey.isValidSignature(signature, for: catalogBytes) else {
      throw ReleaseCatalogError.invalidCatalogSignature
    }

    let catalog: ReleaseCatalog
    do {
      catalog = try VHOSJSON.decoder().decode(ReleaseCatalog.self, from: catalogBytes)
    } catch {
      throw ReleaseCatalogError.invalidCatalog
    }
    try validate(catalog)
    return catalog
  }

  private static func validate(_ catalog: ReleaseCatalog) throws {
    guard catalog.contract == "vhos.release-catalog", catalog.contractVersion == "1.0.0",
      ISO8601DateFormatter().date(from: catalog.generatedAt) != nil,
      catalog.artifacts.count <= 100,
      Set(catalog.artifacts.map(\.artifactID)).count == catalog.artifacts.count
    else { throw ReleaseCatalogError.invalidCatalog }

    for artifact in catalog.artifacts {
      guard artifact.artifactID.range(of: "^[a-z0-9][a-z0-9._-]{0,119}$", options: .regularExpression) != nil,
        !artifact.version.isEmpty, artifact.version.count <= 80,
        ISO8601DateFormatter().date(from: artifact.publishedAt) != nil,
        artifact.sourceRepository.scheme == "https", artifact.sourceRepository.host == "github.com",
        artifact.downloadURL.scheme == "https", artifact.downloadURL.host == "github.com",
        artifact.sourceCommit.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
        artifact.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
        (1...134_217_728).contains(artifact.byteCount),
        !artifact.releaseNotes.isEmpty, artifact.releaseNotes.count <= 1_000
      else { throw ReleaseCatalogError.invalidArtifact(artifact.artifactID) }

      switch artifact.target {
      case .androidHeadUnit:
        guard artifact.kind == .androidAPK,
          artifact.installMethod == .androidPackageInstaller,
          artifact.android?.packageID == "dev.vhos.headunit",
          artifact.android?.signingCertificateSHA256.range(
            of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
          artifact.esp32 == nil
        else { throw ReleaseCatalogError.invalidArtifact(artifact.artifactID) }
      case .esp32OBDGateway:
        guard artifact.kind == .esp32VHOSOTA,
          artifact.installMethod == .mobileToESP32AuthenticatedWiFi,
          artifact.esp32?.distributionSignature == "ED25519",
          artifact.android == nil
        else { throw ReleaseCatalogError.invalidArtifact(artifact.artifactID) }
      case .esp32ACSensorNode:
        guard artifact.kind == .esp32MergedRecovery,
          artifact.installMethod == .usbSerialInitialFlash,
          artifact.readiness == .recoveryOnly,
          artifact.esp32?.initialFlashRequired == true,
          artifact.android == nil
        else { throw ReleaseCatalogError.invalidArtifact(artifact.artifactID) }
      }
    }
  }
}

public enum ReleaseCatalogError: Error, Equatable, LocalizedError {
  case invalidTrustMaterial
  case invalidCatalogSignature
  case invalidCatalog
  case invalidArtifact(String)
  case artifactByteCountMismatch
  case artifactHashMismatch

  public var errorDescription: String? {
    switch self {
    case .invalidTrustMaterial: "The release catalog trust material is invalid."
    case .invalidCatalogSignature: "The release catalog signature is invalid."
    case .invalidCatalog: "The release catalog contract is invalid or unsupported."
    case .invalidArtifact(let id): "Release artifact metadata is invalid for \(id)."
    case .artifactByteCountMismatch: "The downloaded artifact byte count does not match the signed catalog."
    case .artifactHashMismatch: "The downloaded artifact SHA-256 does not match the signed catalog."
    }
  }
}
