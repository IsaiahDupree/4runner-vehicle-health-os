import Foundation

public struct SynchronizedReferenceSample: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let gatewayMonotonicMicroseconds: UInt64
  public let signalID: String
  public let value: Double
  public let unit: String
  public let source: String
  public let recordedAt: String
  public let nearestCANSequence: UInt64?
  public let evidenceNote: String

  public init(
    id: UUID = UUID(),
    gatewayMonotonicMicroseconds: UInt64,
    signalID: String,
    value: Double,
    unit: String,
    source: String,
    recordedAt: String,
    nearestCANSequence: UInt64?,
    evidenceNote: String
  ) throws {
    let semanticID = signalID.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard semanticID.range(of: #"^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)+$"#, options: .regularExpression) != nil,
      !normalizedUnit.isEmpty, normalizedUnit.count <= 32,
      !normalizedSource.isEmpty, normalizedSource.count <= 160,
      value.isFinite, ISO8601DateFormatter().date(from: recordedAt) != nil
    else { throw SynchronizedReferenceError.invalidSample }
    self.id = id
    self.gatewayMonotonicMicroseconds = gatewayMonotonicMicroseconds
    self.signalID = semanticID
    self.value = value
    self.unit = normalizedUnit
    self.source = normalizedSource
    self.recordedAt = recordedAt
    self.nearestCANSequence = nearestCANSequence
    self.evidenceNote = String(evidenceNote.prefix(500))
  }
}

public enum SynchronizedReferenceCSV {
  public static func encode(_ samples: [SynchronizedReferenceSample]) -> Data {
    var lines = [
      "gateway_monotonic_microseconds,signal_id,value,unit,source,recorded_at,nearest_can_sequence,evidence_note"
    ]
    lines += samples.sorted {
      if $0.gatewayMonotonicMicroseconds == $1.gatewayMonotonicMicroseconds {
        return $0.id.uuidString < $1.id.uuidString
      }
      return $0.gatewayMonotonicMicroseconds < $1.gatewayMonotonicMicroseconds
    }.map { sample in
      [
        String(sample.gatewayMonotonicMicroseconds), sample.signalID,
        String(format: "%.9g", sample.value), sample.unit, sample.source, sample.recordedAt,
        sample.nearestCANSequence.map(String.init) ?? "", sample.evidenceNote,
      ].map(csvField).joined(separator: ",")
    }
    return Data((lines.joined(separator: "\n") + "\n").utf8)
  }

  private static func csvField(_ value: String) -> String {
    guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
    else { return value }
    return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
  }
}

public enum SynchronizedReferenceError: Error, Equatable, LocalizedError {
  case invalidSample

  public var errorDescription: String? {
    "A synchronized reference sample requires a semantic signal ID, finite value, unit, source, and ISO-8601 timestamp."
  }
}
