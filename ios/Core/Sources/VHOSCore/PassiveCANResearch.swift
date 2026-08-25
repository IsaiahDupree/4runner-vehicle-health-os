import CryptoKit
import Foundation

public struct PassiveCANCandidateTransform: Equatable, Sendable {
  public let transformID: String
  public let scale: Double
  public let offset: Double
  public let unit: String
  public let sourceIDs: [String]

  public init(
    transformID: String,
    scale: Double,
    offset: Double,
    unit: String,
    sourceIDs: [String]
  ) {
    self.transformID = transformID
    self.scale = scale
    self.offset = offset
    self.unit = unit
    self.sourceIDs = sourceIDs
  }
}

public struct PassiveCANResearchDefinition: Identifiable, Equatable, Sendable {
  public let id: String
  public let label: String
  public let candidateSemantic: String
  public let identifier: UInt32
  public let byteOffset: Int
  public let byteLength: Int
  public let mask: UInt64
  public let rightShift: Int
  public let signedBits: Int?
  public let status: String
  public let sourceIDs: [String]
  public let candidateTransform: PassiveCANCandidateTransform?
  public let validationGate: String

  public var identifierHex: String { String(format: "0x%03X", identifier) }

  public init(
    id: String,
    label: String,
    candidateSemantic: String,
    identifier: UInt32,
    byteOffset: Int,
    byteLength: Int,
    mask: UInt64,
    rightShift: Int = 0,
    signedBits: Int? = nil,
    status: String,
    sourceIDs: [String],
    candidateTransform: PassiveCANCandidateTransform? = nil,
    validationGate: String
  ) {
    self.id = id
    self.label = label
    self.candidateSemantic = candidateSemantic
    self.identifier = identifier
    self.byteOffset = byteOffset
    self.byteLength = byteLength
    self.mask = mask
    self.rightShift = rightShift
    self.signedBits = signedBits
    self.status = status
    self.sourceIDs = sourceIDs
    self.candidateTransform = candidateTransform
    self.validationGate = validationGate
  }
}

public enum PassiveCANResearchCatalog {
  public static let packID = "toyota.4runner.2005.passive-can-hypotheses"
  public static let packVersion = "0.4.1"
  public static let packSHA256 =
    "2eb734187bf79f04973621a3534ae6cc185d0f1cbb5a91fa71183c82055f69e8"
  public static let badge = "VALID RAW EVIDENCE • UNVERIFIED CROSS-MODEL CANDIDATE"

  public static let definitions: [PassiveCANResearchDefinition] = [
    PassiveCANResearchDefinition(
      id: "toyota.2c4.engine-speed.be16",
      label: "Engine speed candidate",
      candidateSemantic: "engine.speed",
      identifier: 0x2C4,
      byteOffset: 0,
      byteLength: 2,
      mask: 0xFFFF,
      status: "HIGH_PRIORITY_CROSS_MODEL_CANDIDATE",
      sourceIDs: [
        "csu-toyota-can-2010-camry", "sae-ruth-bartlett-daily-camry-2012",
        "realdash-fj-cruiser-cedfdf49", "aim-community-dbc-6e2f88f",
        "aim-community-auris-6e2f88f", "aim-community-lexus-is-f-6e2f88f",
        "yaris-listen-only-ddd7a2b", "nfi-lexus-is250-evu-2016",
      ],
      candidateTransform: PassiveCANCandidateTransform(
        transformID: "toyota-rpm-x0p78125",
        scale: 0.78125,
        offset: 0,
        unit: "rpm",
        sourceIDs: [
          "realdash-fj-cruiser-cedfdf49", "aim-community-dbc-6e2f88f",
          "aim-community-auris-6e2f88f", "aim-community-lexus-is-f-6e2f88f",
        ]
      ),
      validationGate:
        "Compare against SAE J1979 PID 0x0C or Toyota Techstream engine speed on the same monotonic timeline."
    ),
    PassiveCANResearchDefinition(
      id: "toyota.2c4.intake-air-temperature.byte3",
      label: "Intake-air temperature raw candidate",
      candidateSemantic: "engine.intake-air-temperature",
      identifier: 0x2C4,
      byteOffset: 3,
      byteLength: 1,
      mask: 0xFF,
      status: "CROSS_MODEL_CANDIDATE",
      sourceIDs: ["realdash-fj-cruiser-cedfdf49", "aim-community-lexus-is-f-6e2f88f"],
      validationGate:
        "Resolve the conflicting cross-model formulas against SAE J1979 PID 0x0F or Techstream before applying a temperature scale."
    ),
    PassiveCANResearchDefinition(
      id: "toyota.2d0.turbine-speed.be16",
      label: "Transmission turbine-speed candidate",
      candidateSemantic: "transmission.turbine-speed",
      identifier: 0x2D0,
      byteOffset: 0,
      byteLength: 2,
      mask: 0xFFFF,
      status: "CROSS_MODEL_CANDIDATE",
      sourceIDs: [
        "csu-toyota-can-2010-camry", "sae-ruth-bartlett-daily-camry-2012",
        "realdash-fj-cruiser-cedfdf49", "nfi-lexus-is250-evu-2016",
      ],
      candidateTransform: PassiveCANCandidateTransform(
        transformID: "fj-turbine-rpm-x0p390625",
        scale: 0.390625,
        offset: 0,
        unit: "rpm",
        sourceIDs: ["realdash-fj-cruiser-cedfdf49"]
      ),
      validationGate:
        "Compare with Techstream turbine/input speed, engine speed, vehicle speed, gear, and converter lockup across a labeled drive."
    ),
    PassiveCANResearchDefinition(
      id: "toyota.2d0.selector-code.byte2",
      label: "Transmission selector raw candidate",
      candidateSemantic: "transmission.selector-code",
      identifier: 0x2D0,
      byteOffset: 2,
      byteLength: 1,
      mask: 0x7F,
      status: "CROSS_MODEL_CANDIDATE",
      sourceIDs: ["realdash-fj-cruiser-cedfdf49", "nfi-lexus-is250-evu-2016"],
      validationGate:
        "Record explicit P, R, N, D, and manual-selector markers and require stable repeatable one-to-one codes."
    ),
    PassiveCANResearchDefinition(
      id: "toyota.2c1.accelerator-pedal.byte6",
      label: "Accelerator-pedal candidate",
      candidateSemantic: "engine.accelerator-pedal-position",
      identifier: 0x2C1,
      byteOffset: 6,
      byteLength: 1,
      mask: 0xFF,
      status: "HIGH_PRIORITY_CROSS_MODEL_CANDIDATE",
      sourceIDs: [
        "csu-toyota-can-2010-camry", "realdash-fj-cruiser-cedfdf49",
        "comma-opendbc-b4ef5e1", "aim-community-dbc-6e2f88f",
        "aim-community-auris-6e2f88f", "aim-community-lexus-is-f-6e2f88f",
        "nfi-lexus-is250-evu-2016",
      ],
      candidateTransform: PassiveCANCandidateTransform(
        transformID: "fj-pedal-x0p5-percent",
        scale: 0.5,
        offset: 0,
        unit: "percent",
        sourceIDs: [
          "realdash-fj-cruiser-cedfdf49", "comma-opendbc-b4ef5e1",
          "aim-community-auris-6e2f88f", "aim-community-lexus-is-f-6e2f88f",
        ]
      ),
      validationGate:
        "Compare against SAE J1979 PID 0x49 when supported or Techstream accelerator position at separated stable pedal levels."
    ),
    PassiveCANResearchDefinition(
      id: "toyota.025.steering-angle.signed12",
      label: "Steering-angle raw candidate",
      candidateSemantic: "steering.wheel-angle",
      identifier: 0x025,
      byteOffset: 0,
      byteLength: 2,
      mask: 0x0FFF,
      signedBits: 12,
      status: "HIGH_PRIORITY_CROSS_MODEL_CANDIDATE",
      sourceIDs: [
        "csu-toyota-can-2010-camry", "realdash-fj-cruiser-cedfdf49",
        "comma-opendbc-b4ef5e1", "aim-community-dbc-6e2f88f",
        "aim-community-lexus-is-f-6e2f88f",
      ],
      validationGate:
        "Resolve conflicting scale and direction formulas with Techstream center, left, and right markers, then repeat after an ignition cycle."
    ),
    PassiveCANResearchDefinition(
      id: "toyota.224.brake-pressure.be16-low9",
      label: "Brake-pressure raw candidate",
      candidateSemantic: "brakes.pedal-pressure",
      identifier: 0x224,
      byteOffset: 4,
      byteLength: 2,
      mask: 0x01FF,
      status: "CROSS_MODEL_CANDIDATE",
      sourceIDs: [
        "csu-toyota-can-2010-camry", "realdash-fj-cruiser-cedfdf49",
        "aim-community-dbc-6e2f88f", "aim-community-auris-6e2f88f",
        "aim-community-lexus-is-f-6e2f88f",
      ],
      validationGate:
        "Capture released, light, medium, and firm brake applications with an independent pressure reference."
    ),
  ]
}

public struct PassiveCANResearchPoint: Identifiable, Equatable, Sendable {
  public let gatewayID: String
  public let sessionID: UInt32
  public let sessionOrdinal: Int
  public let sourceSequence: UInt64
  public let elapsedSeconds: Double
  public let rawValue: Double
  public let displayValue: Double

  public var id: String { "\(gatewayID):\(sessionID):\(sourceSequence)" }
  public var sessionLabel: String { "Session \(sessionOrdinal)" }
}

public struct PassiveCANResearchSessionBounds: Identifiable, Equatable, Sendable {
  public let gatewayID: String
  public let sessionID: UInt32
  public let sessionOrdinal: Int
  public let captureStartSeconds: Double
  public let captureEndSeconds: Double
  public let firstPointSeconds: Double
  public let lastPointSeconds: Double
  public let pointCount: Int

  public var id: String { "\(gatewayID):\(sessionID):\(sessionOrdinal)" }
}

public struct PassiveCANResearchSeries: Identifiable, Equatable, Sendable {
  public let id: String
  public let label: String
  public let candidateSemantic: String
  public let identifierHex: String
  public let status: String
  public let recordCount: Int
  public let sessionCount: Int
  public let distinctRawValues: Int
  public let rawMinimum: Double
  public let rawMaximum: Double
  public let displayMinimum: Double
  public let displayMaximum: Double
  public let displayUnit: String
  public let candidateTransformID: String?
  public let sourceCount: Int
  public let validationGate: String
  public let sessionBounds: [PassiveCANResearchSessionBounds]
  public let points: [PassiveCANResearchPoint]

  public var usesCandidateTransform: Bool { candidateTransformID != nil }
  /// The analyzer preserves each capture-session endpoint while downsampling, so the final point
  /// remains the latest retained source observation represented by this series.
  public var latestPoint: PassiveCANResearchPoint? { points.last }
  public var valueAuthority: PassiveCANResearchValueAuthority {
    if usesCandidateTransform { return .referencedCrossModelTransform }
    if validationGate.localizedCaseInsensitiveContains("conflict") {
      return .rawOnlyConflictingDefinition
    }
    return .rawOnlyUnvalidatedTransform
  }
}

public struct PassiveCANResearchReport: Equatable, Sendable {
  public let generatedFromSHA256: String
  public let recordCount: Int
  public let sessionCount: Int
  public let packID: String
  public let packVersion: String
  public let packSHA256: String
  public let authority: String
  public let ownerHealthDisplayAllowed: Bool
  public let series: [PassiveCANResearchSeries]
}

public enum PassiveCANResearchAnalyzer {
  public static func analyze(
    _ observations: [PassiveCANObservation],
    maximumPointsPerSeries: Int = 480
  ) throws -> PassiveCANResearchReport {
    guard maximumPointsPerSeries >= 16 else { throw PassiveCANArchiveError.invalidPointBudget }
    try observations.forEach(PassiveCANEvidenceArchive.validate)
    let timeline = buildTimeline(observations)
    let sessionCount = Set(observations.map { "\($0.gatewayID):\($0.sessionID)" }).count
    let projectedByDefinition = Dictionary(
      grouping: try observations.flatMap(PassiveCANResearchProjector.project),
      by: \.definitionID)
    let series: [PassiveCANResearchSeries] = try PassiveCANResearchCatalog.definitions.compactMap {
      definition -> PassiveCANResearchSeries? in
      let extracted = (projectedByDefinition[definition.id] ?? []).compactMap {
        projection -> PassiveCANResearchPoint? in
        guard let time = timeline.values[projection.sourceObservationID]
        else { return nil }
        return PassiveCANResearchPoint(
          gatewayID: projection.sourceGatewayID,
          sessionID: projection.sourceSessionID,
          sessionOrdinal: time.ordinal,
          sourceSequence: projection.sourceSequence,
          elapsedSeconds: time.elapsed,
          rawValue: projection.rawValue,
          displayValue: projection.displayValue
        )
      }
      let values = extracted.sorted(by: pointOrder)
      guard !values.isEmpty else { return nil }
      let rawValues = values.map(\.rawValue)
      let displayValues = values.map(\.displayValue)
      let sessionBounds = Dictionary(grouping: values, by: pointSessionKey).compactMap {
        key, sessionPoints -> PassiveCANResearchSessionBounds? in
        guard let capture = timeline.sessions[key], let first = sessionPoints.first,
          let last = sessionPoints.last
        else { return nil }
        return PassiveCANResearchSessionBounds(
          gatewayID: key.gatewayID,
          sessionID: key.sessionID,
          sessionOrdinal: capture.ordinal,
          captureStartSeconds: capture.startSeconds,
          captureEndSeconds: capture.endSeconds,
          firstPointSeconds: first.elapsedSeconds,
          lastPointSeconds: last.elapsedSeconds,
          pointCount: sessionPoints.count
        )
      }.sorted(by: sessionBoundsOrder)
      return PassiveCANResearchSeries(
        id: definition.id,
        label: definition.label,
        candidateSemantic: definition.candidateSemantic,
        identifierHex: definition.identifierHex,
        status: definition.status,
        recordCount: values.count,
        sessionCount: sessionBounds.count,
        distinctRawValues: Set(rawValues).count,
        rawMinimum: rawValues.min()!,
        rawMaximum: rawValues.max()!,
        displayMinimum: displayValues.min()!,
        displayMaximum: displayValues.max()!,
        displayUnit: definition.candidateTransform?.unit ?? "raw count",
        candidateTransformID: definition.candidateTransform?.transformID,
        sourceCount: definition.sourceIDs.count,
        validationGate: definition.validationGate,
        sessionBounds: sessionBounds,
        points: try downsample(values, maximumPoints: maximumPointsPerSeries)
      )
    }
    return PassiveCANResearchReport(
      generatedFromSHA256: try PassiveCANEvidenceArchive.semanticSHA256(observations),
      recordCount: observations.count,
      sessionCount: sessionCount,
      packID: PassiveCANResearchCatalog.packID,
      packVersion: PassiveCANResearchCatalog.packVersion,
      packSHA256: PassiveCANResearchCatalog.packSHA256,
      authority: "ENGINEERING_RESEARCH_ONLY",
      ownerHealthDisplayAllowed: false,
      series: series
    )
  }

  private struct TimelineValue {
    let elapsed: Double
    let ordinal: Int
  }

  private struct SessionKey: Hashable {
    let gatewayID: String
    let sessionID: UInt32
  }

  private struct TimelineSession {
    let ordinal: Int
    let startSeconds: Double
    let endSeconds: Double
  }

  private struct ResearchTimeline {
    let values: [String: TimelineValue]
    let sessions: [SessionKey: TimelineSession]
  }

  private static func buildTimeline(
    _ observations: [PassiveCANObservation]
  ) -> ResearchTimeline {
    let grouped = Dictionary(grouping: observations) {
      SessionKey(gatewayID: $0.gatewayID, sessionID: $0.sessionID)
    }
    let ordered = grouped.sorted { left, right in
      let leftDate = left.value.map(\.ingestedAt).min() ?? ""
      let rightDate = right.value.map(\.ingestedAt).min() ?? ""
      if leftDate != rightDate { return leftDate < rightDate }
      if left.key.gatewayID != right.key.gatewayID {
        return left.key.gatewayID < right.key.gatewayID
      }
      return left.key.sessionID < right.key.sessionID
    }
    var result: [String: TimelineValue] = [:]
    var sessions: [SessionKey: TimelineSession] = [:]
    var cursor = 0.0
    for (index, entry) in ordered.enumerated() {
      let minimum = entry.value.map(\.monotonicMicroseconds).min() ?? 0
      let maximum = entry.value.map(\.monotonicMicroseconds).max() ?? minimum
      let duration = Double(maximum - minimum) / 1_000_000
      sessions[entry.key] = TimelineSession(
        ordinal: index + 1,
        startSeconds: cursor,
        endSeconds: cursor + duration)
      for observation in entry.value {
        result[observation.id] = TimelineValue(
          elapsed: cursor + Double(observation.monotonicMicroseconds - minimum) / 1_000_000,
          ordinal: index + 1
        )
      }
      cursor += duration + 1
    }
    return ResearchTimeline(values: result, sessions: sessions)
  }

  private static func downsample(
    _ values: [PassiveCANResearchPoint],
    maximumPoints: Int
  ) throws -> [PassiveCANResearchPoint] {
    guard values.count > maximumPoints else { return values }

    let grouped = Dictionary(grouping: values, by: pointSessionKey)
    let mandatoryIDs = Set(
      grouped.values.flatMap { points in
        [points.first, points.last].compactMap { $0?.id }
      })
    guard mandatoryIDs.count <= maximumPoints else {
      throw PassiveCANArchiveError.insufficientPointBudget(required: mandatoryIDs.count)
    }

    var selectedIDs = mandatoryIDs
    let remainingCapacity = maximumPoints - selectedIDs.count
    guard remainingCapacity > 0 else { return values.filter { selectedIDs.contains($0.id) } }

    let bucketCount = max(1, Int(ceil(Double(remainingCapacity) / 2)))
    let bucketSize = Int(ceil(Double(values.count) / Double(bucketCount)))
    var shapeCandidateIDs = Set<String>()
    for start in stride(from: 0, to: values.count, by: bucketSize) {
      let bucket = values[start..<min(start + bucketSize, values.count)].filter {
        !selectedIDs.contains($0.id)
      }
      guard let minimum = bucket.min(by: minimumDisplayOrder),
        let maximum = bucket.max(by: maximumDisplayOrder)
      else { continue }
      shapeCandidateIDs.insert(minimum.id)
      shapeCandidateIDs.insert(maximum.id)
    }

    let shapeCandidates = values.filter { shapeCandidateIDs.contains($0.id) }
    for point in evenlySelected(shapeCandidates, count: remainingCapacity) {
      selectedIDs.insert(point.id)
    }
    let stillAvailable = maximumPoints - selectedIDs.count
    if stillAvailable > 0 {
      let remaining = values.filter { !selectedIDs.contains($0.id) }
      for point in evenlySelected(remaining, count: stillAvailable) {
        selectedIDs.insert(point.id)
      }
    }
    return values.filter { selectedIDs.contains($0.id) }
  }

  private static func pointSessionKey(_ point: PassiveCANResearchPoint) -> SessionKey {
    SessionKey(gatewayID: point.gatewayID, sessionID: point.sessionID)
  }

  private static func pointOrder(
    _ left: PassiveCANResearchPoint,
    _ right: PassiveCANResearchPoint
  ) -> Bool {
    if left.elapsedSeconds != right.elapsedSeconds {
      return left.elapsedSeconds < right.elapsedSeconds
    }
    if left.sessionOrdinal != right.sessionOrdinal {
      return left.sessionOrdinal < right.sessionOrdinal
    }
    if left.gatewayID != right.gatewayID { return left.gatewayID < right.gatewayID }
    if left.sessionID != right.sessionID { return left.sessionID < right.sessionID }
    return left.sourceSequence < right.sourceSequence
  }

  private static func sessionBoundsOrder(
    _ left: PassiveCANResearchSessionBounds,
    _ right: PassiveCANResearchSessionBounds
  ) -> Bool {
    if left.captureStartSeconds != right.captureStartSeconds {
      return left.captureStartSeconds < right.captureStartSeconds
    }
    if left.gatewayID != right.gatewayID { return left.gatewayID < right.gatewayID }
    return left.sessionID < right.sessionID
  }

  private static func minimumDisplayOrder(
    _ left: PassiveCANResearchPoint,
    _ right: PassiveCANResearchPoint
  ) -> Bool {
    if left.displayValue != right.displayValue { return left.displayValue < right.displayValue }
    return pointOrder(left, right)
  }

  private static func maximumDisplayOrder(
    _ left: PassiveCANResearchPoint,
    _ right: PassiveCANResearchPoint
  ) -> Bool {
    if left.displayValue != right.displayValue { return left.displayValue < right.displayValue }
    return pointOrder(left, right)
  }

  private static func evenlySelected(
    _ values: [PassiveCANResearchPoint],
    count: Int
  ) -> [PassiveCANResearchPoint] {
    guard count > 0, !values.isEmpty else { return [] }
    guard values.count > count else { return values }
    return (0..<count).map { index in
      values[index * values.count / count]
    }
  }
}

public struct PassiveCANMergeResult: Equatable, Sendable {
  public let records: [PassiveCANObservation]
  public let appendedRecords: Int
}

public enum PassiveCANEvidenceArchive {
  public static func encodeNDJSON(_ observations: [PassiveCANObservation]) throws -> Data {
    var bytes = Data()
    for observation in try sortedValidated(observations) {
      bytes.append(try VHOSJSON.encoder().encode(observation))
      bytes.append(0x0A)
    }
    return bytes
  }

  public static func decodeNDJSON(_ bytes: Data) throws -> [PassiveCANObservation] {
    var observations: [PassiveCANObservation] = []
    var identities = Set<String>()
    for (offset, line) in bytes.split(separator: 0x0A).enumerated() {
      do {
        let observation = try VHOSJSON.decoder().decode(
          PassiveCANObservation.self, from: Data(line))
        try validate(observation)
        guard identities.insert(observation.id).inserted else {
          throw PassiveCANArchiveError.duplicateIdentity(observation.id)
        }
        observations.append(observation)
      } catch let error as PassiveCANArchiveError {
        throw error
      } catch {
        throw PassiveCANArchiveError.invalidRecord(line: offset + 1)
      }
    }
    return sort(observations)
  }

  public static func merge(
    existing: [PassiveCANObservation],
    incoming: [PassiveCANObservation]
  ) throws -> PassiveCANMergeResult {
    var byIdentity: [String: PassiveCANObservation] = [:]
    for observation in try sortedValidated(existing) { byIdentity[observation.id] = observation }
    var appended = 0
    for observation in try sortedValidated(incoming) {
      if let current = byIdentity[observation.id] {
        guard current == observation else {
          throw PassiveCANArchiveError.identityCollision(observation.id)
        }
      } else {
        byIdentity[observation.id] = observation
        appended += 1
      }
    }
    return PassiveCANMergeResult(records: sort(Array(byIdentity.values)), appendedRecords: appended)
  }

  public static func semanticSHA256(_ observations: [PassiveCANObservation]) throws -> String {
    SHA256.hash(data: try encodeNDJSON(observations))
      .map { String(format: "%02x", $0) }.joined()
  }

  public static func validate(_ observation: PassiveCANObservation) throws {
    guard observation.contract == "gateway.passive-can-observation",
      observation.contractVersion == "1.0.0"
    else { throw PassiveCANArchiveError.unsupportedContract }
    guard !observation.gatewayID.isEmpty, observation.sourceSequence > 0,
      observation.dataLength <= 8, observation.data.count == 8,
      observation.identifier <= (observation.extended ? 0x1FFF_FFFF : 0x7FF),
      observation.bitrateBps == 250_000 || observation.bitrateBps == 500_000
    else { throw PassiveCANArchiveError.invalidShape(observation.id) }
    guard observation.listenOnly else {
      throw PassiveCANArchiveError.listenOnlyProofRequired(observation.id)
    }
  }

  private static func sortedValidated(
    _ observations: [PassiveCANObservation]
  ) throws -> [PassiveCANObservation] {
    try observations.forEach(validate)
    return sort(observations)
  }

  private static func sort(
    _ observations: [PassiveCANObservation]
  ) -> [PassiveCANObservation] {
    observations.sorted {
      if $0.ingestedAt != $1.ingestedAt { return $0.ingestedAt < $1.ingestedAt }
      if $0.gatewayID != $1.gatewayID { return $0.gatewayID < $1.gatewayID }
      if $0.sessionID != $1.sessionID { return $0.sessionID < $1.sessionID }
      if $0.monotonicMicroseconds != $1.monotonicMicroseconds {
        return $0.monotonicMicroseconds < $1.monotonicMicroseconds
      }
      return $0.sourceSequence < $1.sourceSequence
    }
  }
}

public enum PassiveCANArchiveError: Error, Equatable, LocalizedError {
  case unsupportedContract
  case invalidRecord(line: Int)
  case invalidShape(String)
  case listenOnlyProofRequired(String)
  case duplicateIdentity(String)
  case identityCollision(String)
  case invalidPointBudget
  case insufficientPointBudget(required: Int)

  public var errorDescription: String? {
    switch self {
    case .unsupportedContract: "The passive CAN archive contract is unsupported."
    case .invalidRecord(let line): "Passive CAN NDJSON line \(line) is invalid."
    case .invalidShape(let identity): "Passive CAN record \(identity) has an invalid shape."
    case .listenOnlyProofRequired(let identity):
      "Passive CAN record \(identity) does not retain listen-only proof."
    case .duplicateIdentity(let identity): "Passive CAN archive repeats identity \(identity)."
    case .identityCollision(let identity):
      "Passive CAN identity \(identity) has conflicting evidence bytes."
    case .invalidPointBudget: "A CAN research chart requires at least 16 retained points."
    case .insufficientPointBudget(let required):
      "A CAN research chart requires at least \(required) points to preserve every session boundary."
    }
  }
}
