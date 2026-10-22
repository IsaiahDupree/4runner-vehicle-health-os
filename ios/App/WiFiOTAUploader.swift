import Foundation
import NetworkExtension

struct WiFiOTAUploader {
  func upload(firmware: Data, to url: URL, bearerToken: String) async throws -> String {
    try validateLocalOTAURL(url)
    guard bearerToken.count >= 32, bearerToken.count <= 80 else {
      throw WiFiOTAError.invalidSessionToken
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 180
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    request.setValue(String(firmware.count), forHTTPHeaderField: "Content-Length")
    let (body, response) = try await URLSession.shared.upload(for: request, from: firmware)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw WiFiOTAError.uploadRejected(
        (response as? HTTPURLResponse)?.statusCode,
        String(data: body, encoding: .utf8)
      )
    }
    return
      "Firmware accepted by the gateway. Keep vehicle power stable while probationary boot and self-test complete."
  }

  private func validateLocalOTAURL(_ url: URL) throws {
    guard url.scheme == "http",
      ["/api/v1/ota/image", "/upload/ota.bin"].contains(url.path),
      let host = url.host?.lowercased()
    else {
      throw WiFiOTAError.invalidEndpoint
    }
    if host == "localhost" || host.hasSuffix(".local") { return }
    let parts = host.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else {
      throw WiFiOTAError.nonLocalEndpoint
    }
    let local =
      parts[0] == 10
      || (parts[0] == 172 && (16...31).contains(parts[1]))
      || (parts[0] == 192 && parts[1] == 168)
    guard local else { throw WiFiOTAError.nonLocalEndpoint }
  }
}

@MainActor
struct TemporaryGatewayNetwork {
  func join(ssid: String, passphrase: String) async throws {
    guard !ssid.isEmpty, ssid.count <= 32, passphrase.count >= 8, passphrase.count <= 63 else {
      throw WiFiOTAError.invalidNetworkCredentials
    }
    let configuration = NEHotspotConfiguration(
      ssid: ssid,
      passphrase: passphrase,
      isWEP: false
    )
    configuration.hidden = true
    configuration.joinOnce = true
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      NEHotspotConfigurationManager.shared.apply(configuration) { error in
        if let error = error as NSError? {
          if error.domain == NEHotspotConfigurationErrorDomain,
            error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue
          {
            continuation.resume(returning: ())
          } else {
            continuation.resume(throwing: WiFiOTAError.networkJoinFailed(error.localizedDescription))
          }
        } else {
          continuation.resume(returning: ())
        }
      }
    }
    try await Task.sleep(for: .seconds(2))
  }

  func remove(ssid: String) {
    NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
  }
}

enum WiFiOTAError: Error, LocalizedError {
  case invalidEndpoint
  case nonLocalEndpoint
  case invalidSessionToken
  case invalidNetworkCredentials
  case networkJoinFailed(String)
  case uploadRejected(Int?, String?)

  var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      "OTA is restricted to a recognized local gateway upload endpoint."
    case .nonLocalEndpoint: "OTA is restricted to private IPv4 or .local gateway addresses."
    case .invalidSessionToken: "The encrypted BLE OTA session token is invalid."
    case .invalidNetworkCredentials: "The temporary gateway Wi-Fi credentials are invalid."
    case .networkJoinFailed(let detail): "Could not join the temporary gateway network: \(detail)"
    case .uploadRejected(let status, let detail):
      "Gateway rejected the firmware upload\(status.map { " (HTTP \($0))" } ?? "")\(detail.map { ": \($0)" } ?? "")."
    }
  }
}
