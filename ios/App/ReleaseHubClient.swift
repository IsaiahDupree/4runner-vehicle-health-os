import Foundation
import Observation
import VHOSCore

@MainActor
@Observable
final class ReleaseHubClient {
  private static let catalogURL = URL(
    string: "https://github.com/IsaiahDupree/4runner-vhos-release-hub/releases/latest/download/releases.json"
  )!
  private static let signatureURL = URL(
    string: "https://github.com/IsaiahDupree/4runner-vhos-release-hub/releases/latest/download/releases.json.sig"
  )!

  private(set) var catalog: ReleaseCatalog?
  private(set) var stagedURLs: [String: URL] = [:]
  private(set) var isLoading = false
  private(set) var status = "Release catalog has not been checked."

  func refresh() async throws {
    isLoading = true
    defer { isLoading = false }
    let catalogBytes = try await download(Self.catalogURL, maximumBytes: 1_048_576)
    let signatureBytes = try await download(Self.signatureURL, maximumBytes: 4_096)
    guard let keyURL = Bundle.main.url(
      forResource: "catalog-development-p256-public", withExtension: "der.base64")
    else { throw ReleaseHubError.missingCatalogTrustRoot }
    let publicKey = try Data(contentsOf: keyURL)
    catalog = try ReleaseCatalogCodec.verifyAndDecode(
      catalogBytes: catalogBytes,
      signatureBase64: signatureBytes,
      publicKeyDERBase64: publicKey)
    status = "Verified signed catalog with \(catalog?.artifacts.count ?? 0) target artifacts."
  }

  func stage(_ artifact: ReleaseArtifact) async throws -> URL {
    guard catalog?.artifacts.contains(where: { $0.artifactID == artifact.artifactID }) == true else {
      throw ReleaseHubError.artifactNotInVerifiedCatalog
    }
    isLoading = true
    defer { isLoading = false }
    let bytes = try await download(artifact.downloadURL, maximumBytes: artifact.byteCount)
    try artifact.verifyDownloadedBytes(bytes)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "VHOSReleaseHub", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let output = directory.appendingPathComponent(artifact.downloadURL.lastPathComponent)
    try bytes.write(to: output, options: .atomic)
    stagedURLs[artifact.artifactID] = output
    status = "Verified and staged \(artifact.artifactID)."
    return output
  }

  private func download(_ url: URL, maximumBytes: Int) async throws -> Data {
    guard url.scheme == "https", url.host == "github.com" else {
      throw ReleaseHubError.untrustedDownloadHost
    }
    let (bytes, response) = try await URLSession.shared.data(from: url)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw ReleaseHubError.downloadRejected
    }
    guard bytes.count <= maximumBytes else { throw ReleaseHubError.downloadTooLarge }
    return bytes
  }
}

enum ReleaseHubError: Error, LocalizedError {
  case missingCatalogTrustRoot
  case artifactNotInVerifiedCatalog
  case untrustedDownloadHost
  case downloadRejected
  case downloadTooLarge

  var errorDescription: String? {
    switch self {
    case .missingCatalogTrustRoot: "The pinned VHOS release-catalog public key is missing."
    case .artifactNotInVerifiedCatalog: "The artifact is not present in the verified release catalog."
    case .untrustedDownloadHost: "Release downloads are restricted to the pinned GitHub host."
    case .downloadRejected: "The release server rejected the download."
    case .downloadTooLarge: "The release download exceeded its signed size boundary."
    }
  }
}
