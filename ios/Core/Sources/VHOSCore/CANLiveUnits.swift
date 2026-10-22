import Foundation

/// Live engineering-unit rendering from the passive CAN stream.
///
/// The retained-analysis lane (`CANUnitsAnalyzer.analyze`) answers "what
/// was in the archive". This lane answers "what is on the bus right now",
/// using the SAME pinned catalog and the SAME extraction/transform math
/// (`CANUnitsAnalyzer.projectLive`) so the two can never disagree about a
/// formula.
///
/// Two rules this type refuses to bend:
///
/// 1. **Live does not launder authority.** A value carrying a pinned but
///    target-unvalidated transform is `unverifiedCandidateUnit` whether it
///    came from flash or from the antenna a millisecond ago. Making a
///    number live makes it *current*, not *verified*.
/// 2. **Silence is visible.** When frames stop, a reading goes `stale` and
///    then `expired` — it never freezes at its last value while continuing
///    to look current. (The 2026-08-24 marker incident was exactly this
///    failure in a different surface: a frozen timeline presented as a
///    live one.)
public enum CANLiveUnits {

  /// Freshness of a live reading, judged against the phone's clock.
  public enum Freshness: String, Codable, Equatable, Sendable {
    /// Updated within the live window; safe to read as "now".
    case live = "LIVE"
    /// No update recently: shown, but explicitly marked as not current.
    case stale = "STALE"
    /// Old enough that the value is no longer meaningful as a reading.
    case expired = "EXPIRED"
  }

  /// Seconds since the last sample after which a reading is no longer
  /// presented as live. Matches the app's existing five-second evidence
  /// freshness limit for current-timeline claims.
  public static let liveWindowSeconds: TimeInterval = 5
  /// Seconds after which a reading is treated as expired rather than
  /// merely stale.
  public static let expiryWindowSeconds: TimeInterval = 30
  /// Maximum samples retained per field for the rolling sparkline.
  public static let defaultWindowCapacity = 240
  /// Maximum unpinned CAN identifiers retained at once. The gateway's
  /// in-memory recent window is also capped at 100 observations, so this can
  /// represent every distinct identifier in one complete bootstrap window
  /// while keeping long-running state bounded.
  public static let defaultRawIdentifierCapacity = 100

  public static func freshness(
    ageSeconds: TimeInterval
  ) -> Freshness {
    if ageSeconds < 0 { return .stale }
    if ageSeconds <= liveWindowSeconds { return .live }
    if ageSeconds <= expiryWindowSeconds { return .stale }
    return .expired
  }
}

/// One pinned candidate field a viewer can select and watch.
public struct CANLiveFieldDescriptor: Identifiable, Codable, Equatable, Sendable {
  public let id: String
  public let label: String
  public let signalID: String
  public let identifier: UInt32
  /// nil for raw-only candidates: there is no validated engineering unit.
  public let unit: String?
  public let source: String
  public let authority: CANUnitsAuthority
  public let definitionStatus: String
  public let validationGate: String

  public init(
    id: String, label: String, signalID: String, identifier: UInt32,
    unit: String?, source: String, authority: CANUnitsAuthority,
    definitionStatus: String, validationGate: String
  ) {
    self.id = id
    self.label = label
    self.signalID = signalID
    self.identifier = identifier
    self.unit = unit
    self.source = source
    self.authority = authority
    self.definitionStatus = definitionStatus
    self.validationGate = validationGate
  }

  public var identifierHex: String { String(format: "%03X", identifier) }
}

/// A single projected value from one live frame.
public struct CANLiveReading: Identifiable, Codable, Equatable, Sendable {
  public let fieldID: String
  public let signalID: String
  public let label: String
  public let rawValue: Double
  public let displayValue: Double
  public let unit: String?
  public let authority: CANUnitsAuthority
  public let gatewayID: String
  public let sessionID: UInt32
  public let sourceSequence: UInt64
  public let monotonicMicroseconds: UInt64
  public let observedAt: String

  public init(
    fieldID: String, signalID: String, label: String, rawValue: Double,
    displayValue: Double, unit: String?, authority: CANUnitsAuthority,
    gatewayID: String, sessionID: UInt32, sourceSequence: UInt64,
    monotonicMicroseconds: UInt64, observedAt: String
  ) {
    self.fieldID = fieldID
    self.signalID = signalID
    self.label = label
    self.rawValue = rawValue
    self.displayValue = displayValue
    self.unit = unit
    self.authority = authority
    self.gatewayID = gatewayID
    self.sessionID = sessionID
    self.sourceSequence = sourceSequence
    self.monotonicMicroseconds = monotonicMicroseconds
    self.observedAt = observedAt
  }

  public var id: String { "\(fieldID):\(sessionID):\(sourceSequence)" }
}

/// The rendered state of one watched field: latest value, freshness, the
/// rolling window for a sparkline, and window statistics.
public struct CANLiveChannel: Identifiable, Equatable, Sendable {
  public let field: CANLiveFieldDescriptor
  public let latest: CANLiveReading?
  public let freshness: CANLiveUnits.Freshness
  public let ageSeconds: TimeInterval?
  /// Oldest-first display values in the retained window.
  public let window: [Double]
  public let statistics: CANDescriptiveStatistics?
  public let sampleCount: Int

  public var id: String { field.id }

  /// A live channel never claims verification it does not have.
  public var exposesEngineeringUnit: Bool { field.authority.exposesEngineeringUnit }
}

/// Exact identity of an observed raw CAN frame. It deliberately contains no
/// semantic signal name or engineering unit, even when the same identifier
/// also feeds one or more separately displayed pinned candidate fields.
public struct CANLiveRawIdentifierDescriptor: Identifiable, Codable, Equatable, Sendable {
  public let identifier: UInt32
  public let extended: Bool

  public init(identifier: UInt32, extended: Bool) {
    self.identifier = identifier
    self.extended = extended
  }

  public var id: String {
    "raw:\(extended ? "extended" : "standard"):\(String(identifier, radix: 16))"
  }
  public var identifierHex: String {
    String(format: extended ? "%08X" : "%03X", identifier)
  }
  public var label: String { "CAN 0x\(identifierHex)" }
  public var authority: CANUnitsAuthority { .rawOnlyCandidate }
  public var unit: String? { nil }
}

/// One exact raw observation for any accepted identifier, including one that
/// also feeds a separately presented pinned candidate field.
public struct CANLiveRawReading: Identifiable, Codable, Equatable, Sendable {
  public let descriptor: CANLiveRawIdentifierDescriptor
  public let remoteRequest: Bool
  public let dataLength: UInt8
  /// Exact payload prefix only; padding outside DLC is never displayed.
  public let data: [UInt8]
  public let bitrateBps: UInt32
  public let gatewayID: String
  public let sessionID: UInt32
  public let sourceSequence: UInt64
  public let monotonicMicroseconds: UInt64
  public let observedAt: String

  public var id: String { "\(descriptor.id):\(sessionID):\(sourceSequence)" }
  public var dataHex: String {
    data.map { String(format: "%02X", $0) }.joined(separator: " ")
  }
}

/// Latest exact bytes and bounded update history for one raw identifier.
public struct CANLiveRawChannel: Identifiable, Equatable, Sendable {
  public let descriptor: CANLiveRawIdentifierDescriptor
  public let latest: CANLiveRawReading
  public let freshness: CANLiveUnits.Freshness
  public let ageSeconds: TimeInterval
  public let sampleCount: Int
  /// Current payload byte positions that differ from the previous update.
  /// Empty means either first observation or no byte changed.
  public let changedByteIndices: [Int]
  public let dataLengthChanged: Bool

  public var id: String { descriptor.id }
}

/// Accumulates live observations into per-field rolling windows.
///
/// Pure and synchronous: callers push observations in, read channels out.
/// It holds no clock of its own — every freshness judgement takes an
/// explicit `now`, so tests are deterministic and a paused UI cannot
/// silently age values.
public struct CANLiveUnitsAccumulator: Sendable {
  private struct Sample: Sendable {
    let reading: CANLiveReading
    let receivedAt: Date
  }

  private struct RawSample: Sendable {
    let reading: CANLiveRawReading
    let receivedAt: Date
  }

  private var samplesByField: [String: [Sample]] = [:]
  private var rawSamplesByIdentifier: [String: [RawSample]] = [:]
  /// Least-recently-updated first; bounded eviction removes index zero.
  private var rawIdentifierRecency: [String] = []
  private let capacity: Int
  private let rawIdentifierCapacity: Int
  public let fields: [CANLiveFieldDescriptor]

  public init(
    fields: [CANLiveFieldDescriptor] = CANUnitsAnalyzer.candidateFields,
    capacity: Int = CANLiveUnits.defaultWindowCapacity,
    rawIdentifierCapacity: Int = CANLiveUnits.defaultRawIdentifierCapacity
  ) {
    self.fields = fields
    self.capacity = max(1, capacity)
    self.rawIdentifierCapacity = max(1, rawIdentifierCapacity)
  }

  /// Ingest one live observation. Returns the pinned-field and raw-channel
  /// ids it actually updated. An unknown identifier updates only its exact
  /// raw channel; no signal meaning or unit is guessed.
  @discardableResult
  public mutating func ingest(
    _ observation: PassiveCANObservation,
    receivedAt: Date
  ) -> [String] {
    guard Self.isAdmissibleLiveObservation(observation) else { return [] }
    let readings = CANUnitsAnalyzer.projectLive(observation)
    var updatedFieldIDs: [String] = []
    for reading in readings {
      var samples = samplesByField[reading.fieldID] ?? []
      // Guard against replayed or duplicated frames: within one session the
      // source sequence must advance, or the sample is not new evidence.
      if let last = samples.last?.reading,
        last.sessionID == reading.sessionID,
        reading.sourceSequence <= last.sourceSequence
      {
        continue
      }
      samples.append(Sample(reading: reading, receivedAt: receivedAt))
      if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
      samplesByField[reading.fieldID] = samples
      updatedFieldIDs.append(reading.fieldID)
    }
    if let rawIdentifierID = ingestRaw(observation, receivedAt: receivedAt) {
      updatedFieldIDs.append(rawIdentifierID)
    }
    return updatedFieldIDs
  }

  /// Ingest a bounded arrival-ordered window from the gateway.
  ///
  /// The dashboard can be opened after frames have already arrived, and
  /// SwiftUI may coalesce several high-rate `latestCANObservation` changes
  /// into one render. Replaying the gateway's recent window closes both
  /// gaps. Exact gateway/session and live-source gates prevent a retained or
  /// previous-session observation from being relabeled as current. The
  /// observation's original phone-ingest wall time is retained so opening
  /// the screen cannot make an old frame look fresh.
  @discardableResult
  public mutating func ingestCurrentSession(
    _ observations: [PassiveCANObservation],
    gatewayID: String,
    sessionID: UInt32
  ) -> [String] {
    var updatedFieldIDs: [String] = []
    for observation in observations {
      guard observation.gatewayID == gatewayID, observation.sessionID == sessionID,
        observation.listenOnly, observation.evidenceSource == "ble-live",
        let receivedAt = Self.receivedAt(from: observation.ingestedAt)
      else { continue }
      updatedFieldIDs.append(contentsOf: ingest(observation, receivedAt: receivedAt))
    }
    return updatedFieldIDs
  }

  /// Drop everything. Used when the gateway session changes: a window may
  /// never blend samples from two capture sessions.
  public mutating func reset() {
    samplesByField.removeAll()
    rawSamplesByIdentifier.removeAll()
    rawIdentifierRecency.removeAll()
  }

  public var hasSamples: Bool {
    samplesByField.values.contains { !$0.isEmpty }
      || rawSamplesByIdentifier.values.contains { !$0.isEmpty }
  }

  /// Fields that have produced at least one live sample, in catalog order.
  public var observedFields: [CANLiveFieldDescriptor] {
    fields.filter { !(samplesByField[$0.id] ?? []).isEmpty }
  }

  /// Raw identifiers that have produced at least one accepted update,
  /// least-recently-updated first. Pinned candidate fields and raw frames are
  /// intentionally separate views of the same evidence.
  public var observedRawIdentifiers: [CANLiveRawIdentifierDescriptor] {
    rawIdentifierRecency.compactMap {
      rawSamplesByIdentifier[$0]?.last?.reading.descriptor
    }
  }

  public func channel(
    for fieldID: String,
    now: Date
  ) -> CANLiveChannel? {
    guard let field = fields.first(where: { $0.id == fieldID }) else { return nil }
    let samples = samplesByField[fieldID] ?? []
    guard let last = samples.last else {
      return CANLiveChannel(
        field: field, latest: nil, freshness: .expired, ageSeconds: nil,
        window: [], statistics: nil, sampleCount: 0)
    }
    let age = now.timeIntervalSince(last.receivedAt)
    let values = samples.map(\.reading.displayValue)
    return CANLiveChannel(
      field: field,
      latest: last.reading,
      freshness: CANLiveUnits.freshness(ageSeconds: age),
      ageSeconds: age,
      window: values,
      statistics: Self.statistics(values),
      sampleCount: samples.count)
  }

  public func channels(now: Date) -> [CANLiveChannel] {
    observedFields.compactMap { channel(for: $0.id, now: now) }
  }

  public func rawChannel(
    for identifierID: String,
    now: Date
  ) -> CANLiveRawChannel? {
    guard let samples = rawSamplesByIdentifier[identifierID], let last = samples.last else {
      return nil
    }
    let previous = samples.dropLast().last?.reading
    let changedByteIndices: [Int]
    if let previous {
      changedByteIndices = last.reading.data.indices.filter { index in
        index >= previous.data.count || previous.data[index] != last.reading.data[index]
      }
    } else {
      changedByteIndices = []
    }
    let age = now.timeIntervalSince(last.receivedAt)
    return CANLiveRawChannel(
      descriptor: last.reading.descriptor,
      latest: last.reading,
      freshness: CANLiveUnits.freshness(ageSeconds: age),
      ageSeconds: age,
      sampleCount: samples.count,
      changedByteIndices: changedByteIndices,
      dataLengthChanged: previous.map { $0.dataLength != last.reading.dataLength } ?? false)
  }

  public func rawChannels(now: Date) -> [CANLiveRawChannel] {
    observedRawIdentifiers.compactMap { rawChannel(for: $0.id, now: now) }
  }

  private mutating func ingestRaw(
    _ observation: PassiveCANObservation,
    receivedAt: Date
  ) -> String? {
    let descriptor = CANLiveRawIdentifierDescriptor(
      identifier: observation.identifier, extended: observation.extended)
    var samples = rawSamplesByIdentifier[descriptor.id] ?? []
    if let last = samples.last?.reading,
      last.sessionID == observation.sessionID,
      observation.sourceSequence <= last.sourceSequence
    {
      return nil
    }
    // Remote-request frames carry a DLC but no payload. Never render the
    // record's padding bytes as if they were observed data.
    let payload = observation.remoteRequest
      ? [] : Array(observation.data.prefix(Int(observation.dataLength)))
    samples.append(
      RawSample(
        reading: CANLiveRawReading(
          descriptor: descriptor,
          remoteRequest: observation.remoteRequest,
          dataLength: observation.dataLength,
          data: payload,
          bitrateBps: observation.bitrateBps,
          gatewayID: observation.gatewayID,
          sessionID: observation.sessionID,
          sourceSequence: observation.sourceSequence,
          monotonicMicroseconds: observation.monotonicMicroseconds,
          observedAt: observation.ingestedAt),
        receivedAt: receivedAt))
    if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    if rawSamplesByIdentifier[descriptor.id] == nil,
      rawSamplesByIdentifier.count >= rawIdentifierCapacity,
      let evicted = rawIdentifierRecency.first
    {
      rawIdentifierRecency.removeFirst()
      rawSamplesByIdentifier.removeValue(forKey: evicted)
    }
    rawSamplesByIdentifier[descriptor.id] = samples
    rawIdentifierRecency.removeAll { $0 == descriptor.id }
    rawIdentifierRecency.append(descriptor.id)
    return descriptor.id
  }

  private static func isAdmissibleLiveObservation(_ observation: PassiveCANObservation) -> Bool {
    observation.contract == "gateway.passive-can-observation"
      && observation.contractVersion == "1.0.0"
      && observation.listenOnly
      && observation.evidenceSource == "ble-live"
      && observation.sourceSequence > 0
      && observation.dataLength <= 8
      && observation.data.count >= Int(observation.dataLength)
      && observation.identifier <= (observation.extended ? 0x1FFF_FFFF : 0x7FF)
      && (observation.bitrateBps == 250_000 || observation.bitrateBps == 500_000)
  }

  private static func receivedAt(from value: String) -> Date? {
    let plain = ISO8601DateFormatter()
    if let date = plain.date(from: value) { return date }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value)
  }

  static func statistics(_ values: [Double]) -> CANDescriptiveStatistics? {
    guard !values.isEmpty else { return nil }
    let count = Double(values.count)
    let minimum = values.min() ?? 0
    let maximum = values.max() ?? 0
    let mean = values.reduce(0, +) / count
    let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / count
    let deviation = variance.squareRoot()
    return CANDescriptiveStatistics(
      sampleCount: values.count,
      minimum: minimum,
      maximum: maximum,
      mean: mean,
      populationStandardDeviation: deviation,
      peakToPeak: maximum - minimum,
      coefficientOfVariation: mean == 0 ? nil : deviation / abs(mean))
  }
}
