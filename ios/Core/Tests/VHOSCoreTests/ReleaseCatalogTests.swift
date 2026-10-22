import CryptoKit
import Foundation
import Testing
@testable import VHOSCore

@Test func releaseCatalogVerifiesSignatureAndArtifactBytes() throws {
  let artifact = Data("real-artifact".utf8)
  let hash = SHA256.hash(data: artifact).map { String(format: "%02x", $0) }.joined()
  let catalog = Data(
    """
    {"artifacts":[{"android":{"debug_signed":true,"package_id":"dev.vhos.headunit","signing_certificate_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","version_code":1},"artifact_id":"android-test","byte_count":13,"channel":"DEVELOPMENT","download_url":"https://github.com/owner/repo/releases/download/v1/app.apk","install_method":"ANDROID_PACKAGE_INSTALLER","kind":"ANDROID_APK","published_at":"2026-08-17T12:00:00Z","readiness":"AVAILABLE","release_notes":"Test artifact.","sha256":"\(hash)","source_commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","source_repository":"https://github.com/owner/repo","target":"ANDROID_HEAD_UNIT","version":"1.0.0"}],"catalog_id":"B80D8EBC-8CC1-4290-A50D-06E72CAEAE13","contract":"vhos.release-catalog","contract_version":"1.0.0","generated_at":"2026-08-17T12:00:00Z"}
    """.utf8)
  let privateKey = P256.Signing.PrivateKey()
  let signature = try privateKey.signature(for: catalog).derRepresentation.base64EncodedData()
  let publicKey = privateKey.publicKey.derRepresentation.base64EncodedData()

  let decoded = try ReleaseCatalogCodec.verifyAndDecode(
    catalogBytes: catalog,
    signatureBase64: signature,
    publicKeyDERBase64: publicKey)
  #expect(decoded.artifacts.single?.artifactID == "android-test")
  try decoded.artifacts[0].verifyDownloadedBytes(artifact)
  #expect(throws: ReleaseCatalogError.artifactHashMismatch) {
    try decoded.artifacts[0].verifyDownloadedBytes(Data("wrong-content".utf8))
  }
}

@Test func releaseCatalogRejectsSignatureFromAnotherKey() throws {
  let catalog = Data("{}".utf8)
  let signer = P256.Signing.PrivateKey()
  let other = P256.Signing.PrivateKey()
  let signature = try signer.signature(for: catalog).derRepresentation.base64EncodedData()
  #expect(throws: ReleaseCatalogError.invalidCatalogSignature) {
    try ReleaseCatalogCodec.verifyAndDecode(
      catalogBytes: catalog,
      signatureBase64: signature,
      publicKeyDERBase64: other.publicKey.derRepresentation.base64EncodedData())
  }
}

private extension Array {
  var single: Element? { count == 1 ? self[0] : nil }
}
