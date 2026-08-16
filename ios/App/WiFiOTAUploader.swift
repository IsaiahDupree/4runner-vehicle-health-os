import Foundation

struct WiFiOTAUploader {
  func upload(firmware: Data, to url: URL) async throws -> String {
    try validateLocalOTAURL(url)
    let boundary = "VHOS-\(UUID().uuidString)"
    var body = Data()
    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(
      Data("Content-Disposition: form-data; name=\"file\"; filename=\"ota.bin\"\r\n".utf8))
    body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
    body.append(firmware)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
    let (_, response) = try await URLSession.shared.upload(for: request, from: body)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw WiFiOTAError.uploadRejected((response as? HTTPURLResponse)?.statusCode)
    }
    return
      "Firmware accepted by the gateway. Keep vehicle power stable while probationary boot and self-test complete."
  }

  private func validateLocalOTAURL(_ url: URL) throws {
    guard url.scheme == "http", url.path == "/upload/ota.bin", let host = url.host?.lowercased()
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

enum WiFiOTAError: Error, LocalizedError {
  case invalidEndpoint
  case nonLocalEndpoint
  case uploadRejected(Int?)

  var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      "OTA is restricted to HTTP /upload/ota.bin endpoints advertised by the gateway."
    case .nonLocalEndpoint: "OTA is restricted to private IPv4 or .local gateway addresses."
    case .uploadRejected(let status):
      "Gateway rejected the firmware upload\(status.map { " (HTTP \($0))" } ?? "")."
    }
  }
}
