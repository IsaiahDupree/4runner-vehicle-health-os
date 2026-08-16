import CryptoKit
import Foundation
import Security
import VHOSCore

enum KeyStoreKey: String {
  case firmwareReleasePublicKey
  case experimentSigningPrivateKey
}

struct KeyStore {
  let service: String

  func data(for key: KeyStoreKey) throws -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key.rawValue,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else {
      throw KeyStoreError.status(status)
    }
    return data
  }

  func set(_ data: Data, for key: KeyStoreKey) throws {
    let identity: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key.rawValue,
    ]
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let update = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
    if update == errSecItemNotFound {
      var insertion = identity
      for (key, value) in attributes { insertion[key] = value }
      let add = SecItemAdd(insertion as CFDictionary, nil)
      guard add == errSecSuccess else { throw KeyStoreError.status(add) }
    } else if update != errSecSuccess {
      throw KeyStoreError.status(update)
    }
  }
}

enum KeyStoreError: Error, LocalizedError {
  case status(OSStatus)

  var errorDescription: String? {
    switch self {
    case .status(let status): "Keychain operation failed with status \(status)."
    }
  }
}

enum ReleasePublicKeyParser {
  static func parse(_ value: String) throws -> Data {
    let compact = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let data: Data?
    if compact.count == 64, compact.allSatisfy(\.isHexDigit) {
      data = Data(
        stride(from: 0, to: compact.count, by: 2).compactMap { index in
          let start = compact.index(compact.startIndex, offsetBy: index)
          let end = compact.index(start, offsetBy: 2)
          return UInt8(compact[start..<end], radix: 16)
        })
    } else {
      data = Data(base64Encoded: compact)
    }
    guard let data, data.count == 32 else { throw FirmwarePackageError.invalidPublicKey }
    return data
  }
}

struct ExperimentSigner {
  let keyStore: KeyStore

  func sign(_ approval: ExperimentApproval) throws -> SignedExperimentPlanEnvelope {
    let privateKey: Curve25519.Signing.PrivateKey
    if let stored = try keyStore.data(for: .experimentSigningPrivateKey) {
      privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: stored)
    } else {
      privateKey = Curve25519.Signing.PrivateKey()
      try keyStore.set(privateKey.rawRepresentation, for: .experimentSigningPrivateKey)
    }
    let approvalData = try VHOSJSON.encoder().encode(approval)
    let signature = try privateKey.signature(for: approvalData)
    let keyID = SHA256.hash(data: privateKey.publicKey.rawRepresentation)
      .map { String(format: "%02x", $0) }
      .joined()
    return SignedExperimentPlanEnvelope(
      approval: approval,
      signingKeyID: keyID,
      signature: signature
    )
  }
}
