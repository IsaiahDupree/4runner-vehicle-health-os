import Foundation
import VHOSCore

struct StoredEvidenceOutboxRecord: Codable, Equatable, Identifiable {
  let envelope: EvidenceOutboxEnvelope
  let payloadFilename: String
  var attemptCount: Int
  var lastAttemptAt: String?
  var lastError: String?
  var uploadedAt: String?

  var id: UUID { envelope.packageID }
}

final class EvidenceOutboxStore {
  private let fileManager: FileManager
  private let root: URL
  private let maximumPackages = 512

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    root = support.appendingPathComponent("VHOSEvidenceOutbox/v1", isDirectory: true)
    try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func enqueue(payload: Data, contentType: String) throws -> (StoredEvidenceOutboxRecord, Bool) {
    let candidate = try EvidenceOutboxEnvelope(contentType: contentType, payload: payload)
    if let existing = try records().first(where: { $0.envelope.sha256 == candidate.sha256 }) {
      return (existing, false)
    }
    guard try records().count < maximumPackages else {
      throw EvidenceOutboxStoreError.capacityReached
    }
    let directory = packageDirectory(candidate.packageID)
    let staging = root.appendingPathComponent(".\(candidate.packageID.uuidString).staging", isDirectory: true)
    if fileManager.fileExists(atPath: staging.path) { try fileManager.removeItem(at: staging) }
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    let payloadFilename = "evidence.vhossync"
    try payload.write(to: staging.appendingPathComponent(payloadFilename), options: .atomic)
    let record = StoredEvidenceOutboxRecord(
      envelope: candidate,
      payloadFilename: payloadFilename,
      attemptCount: 0,
      lastAttemptAt: nil,
      lastError: nil,
      uploadedAt: nil
    )
    try write(record, directory: staging)
    try candidate.validate(payload: payload)
    try fileManager.moveItem(at: staging, to: directory)
    return (record, true)
  }

  func records() throws -> [StoredEvidenceOutboxRecord] {
    guard fileManager.fileExists(atPath: root.path) else { return [] }
    return try fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    .compactMap { directory in
      let metadata = directory.appendingPathComponent("record.json")
      guard fileManager.fileExists(atPath: metadata.path) else { return nil }
      return try VHOSJSON.decoder().decode(
        StoredEvidenceOutboxRecord.self,
        from: Data(contentsOf: metadata, options: [.mappedIfSafe])
      )
    }
    .sorted { $0.envelope.createdAt < $1.envelope.createdAt }
  }

  func payloadURL(for record: StoredEvidenceOutboxRecord) throws -> URL {
    let url = packageDirectory(record.id).appendingPathComponent(record.payloadFilename)
    let payload = try Data(contentsOf: url, options: [.mappedIfSafe])
    try record.envelope.validate(payload: payload)
    return url
  }

  func markAttempt(_ record: StoredEvidenceOutboxRecord, error: String?) throws {
    var updated = record
    updated.attemptCount += 1
    updated.lastAttemptAt = Self.timestamp()
    updated.lastError = error
    try write(updated, directory: packageDirectory(record.id))
  }

  func markUploaded(_ record: StoredEvidenceOutboxRecord) throws {
    var updated = record
    updated.attemptCount += 1
    updated.lastAttemptAt = Self.timestamp()
    updated.lastError = nil
    updated.uploadedAt = Self.timestamp()
    try write(updated, directory: packageDirectory(record.id))
  }

  private func write(_ record: StoredEvidenceOutboxRecord, directory: URL) throws {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try VHOSJSON.encoder().encode(record).write(
      to: directory.appendingPathComponent("record.json"), options: .atomic)
  }

  private func packageDirectory(_ id: UUID) -> URL {
    root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
  }

  private static func timestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
  }
}

struct EvidenceOutboxUploader {
  func upload(
    _ record: StoredEvidenceOutboxRecord,
    payloadURL: URL,
    endpoint: URL,
    bearerToken: String
  ) async throws {
    guard endpoint.scheme?.lowercased() == "https", endpoint.host != nil else {
      throw EvidenceOutboxStoreError.httpsEndpointRequired
    }
    let payload = try Data(contentsOf: payloadURL, options: [.mappedIfSafe])
    try record.envelope.validate(payload: payload)
    let envelopeBytes = try VHOSJSON.encoder().encode(record.envelope)
    var request = URLRequest(
      url: endpoint.appendingPathComponent(record.envelope.packageID.uuidString.lowercased()))
    request.httpMethod = "POST"
    request.setValue(record.envelope.contentType, forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    request.setValue(record.envelope.packageID.uuidString, forHTTPHeaderField: "Idempotency-Key")
    request.setValue(record.envelope.sha256, forHTTPHeaderField: "X-VHOS-SHA256")
    request.setValue(
      envelopeBytes.base64EncodedString(), forHTTPHeaderField: "X-VHOS-Envelope-Base64")
    let (_, response) = try await URLSession.shared.upload(
      for: request,
      fromFile: payloadURL,
      delegate: EvidenceOutboxRedirectRejector()
    )
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw EvidenceOutboxStoreError.uploadRejected(
        (response as? HTTPURLResponse)?.statusCode ?? -1)
    }
  }
}

private final class EvidenceOutboxRedirectRejector: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

enum EvidenceOutboxStoreError: Error, LocalizedError {
  case capacityReached
  case httpsEndpointRequired
  case uploadRejected(Int)

  var errorDescription: String? {
    switch self {
    case .capacityReached:
      "The private evidence outbox reached its bounded package capacity."
    case .httpsEndpointRequired:
      "The private evidence inbox must use an HTTPS endpoint."
    case .uploadRejected(let status):
      "The private evidence inbox rejected the package with HTTP status \(status)."
    }
  }
}
