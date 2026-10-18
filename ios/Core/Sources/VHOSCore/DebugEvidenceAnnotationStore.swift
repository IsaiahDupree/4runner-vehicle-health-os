import CryptoKit
import Foundation

public enum DebugEvidenceAnnotationKind: String, Codable, CaseIterable, Sendable {
  case label = "LABEL"
  case eventMarker = "EVENT_MARKER"
}

public struct DebugEvidenceAnnotationRecord: Codable, Equatable, Sendable, Identifiable {
  public let contract: String
  public let contractVersion: String
  public let id: String
  public let appendedAt: String
  public let annotationKind: DebugEvidenceAnnotationKind
  public let markerKind: DiscoveryMarkerKind?
  public let label: String
  public let note: String
  public let source: DiscoveryEvidenceSource
  public let annotatorID: String?
  public let acquisitionAuthority: DiscoveryMutationAuthority
  public let sourceObservationID: String
  public let sourceObservationSHA256: String
  public let sourceObservation: PassiveCANObservation
  public let promotionAllowed: Bool

  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion, id, appendedAt, annotationKind, markerKind, label, note
    case source, acquisitionAuthority, sourceObservation, promotionAllowed
    case annotatorID = "annotatorId"
    case sourceObservationID = "sourceObservationId"
    case sourceObservationSHA256 = "sourceObservationSha256"
  }

  public static func label(
    id: String,
    appendedAt: String,
    label: String,
    note: String = "",
    source: DiscoveryEvidenceSource = .iPhone,
    annotatorID: String? = nil,
    observation: PassiveCANObservation
  ) throws -> Self {
    try Self(
      id: id, appendedAt: appendedAt, annotationKind: .label, markerKind: nil,
      label: label, note: note, source: source, annotatorID: annotatorID,
      observation: observation)
  }

  public static func eventMarker(
    id: String,
    appendedAt: String,
    markerKind: DiscoveryMarkerKind,
    label: String,
    note: String = "",
    source: DiscoveryEvidenceSource = .iPhone,
    annotatorID: String? = nil,
    observation: PassiveCANObservation
  ) throws -> Self {
    try Self(
      id: id, appendedAt: appendedAt, annotationKind: .eventMarker,
      markerKind: markerKind, label: label, note: note, source: source,
      annotatorID: annotatorID, observation: observation)
  }
}
