import CryptoKit
import Foundation

private struct DiscoveryEndedDraftRecord: Codable, Equatable, Sendable {
  let contract: String
  let contractVersion: String
  let id: String
  let templateID: String
  let templateVersion: String
  let captureID: String
  let gatewayID: String
  let gatewaySessionID: UInt32
  let startedAt: String
  let startMonotonicMicroseconds: UInt64
  let firstSourceSequence: UInt64
  let acquisitionAuthority: DiscoveryMutationAuthority?
  let ownerSafetyAcknowledgedAt: String?
  let state: String
  let endedAt: String?
  let endMonotonicMicroseconds: UInt64?
  let lastSourceSequence: UInt64?

  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion, id, templateVersion, startedAt
    case startMonotonicMicroseconds, firstSourceSequence, acquisitionAuthority
    case ownerSafetyAcknowledgedAt, state, endedAt, endMonotonicMicroseconds
    case lastSourceSequence
    case templateID = "templateId"
    case captureID = "captureId"
    case gatewayID = "gatewayId"
    case gatewaySessionID = "gatewaySessionId"
  }
}

/// Exact terminal Discovery-run lineage required before a retained archive can be finalized.
///
/// This is not an authority grant. It binds the exact canonical bytes of an already-ended,
/// append-only app draft to one gateway recorder session and one durable `capture_...` identity.
/// Legacy drafts without a sealed acquisition authority cannot cross this boundary.
public struct DiscoveryCaptureTerminalRun: Codable, Equatable, Sendable, Identifiable {
  public let contract: String
  public let contractVersion: String
  public let id: String
  public let captureID: String
  public let templateID: String
  public let templateVersion: String
  public let gatewayID: String
  public let gatewaySessionID: UInt32
  public let startedAt: String
  public let endedAt: String
  public let startMonotonicMicroseconds: UInt64
  public let endMonotonicMicroseconds: UInt64
  public let firstSourceSequence: UInt64
  public let lastSourceSequence: UInt64
  /// Acquisition authority sealed when the append-only Discovery draft began.
  public let acquisitionAuthority: DiscoveryMutationAuthority
  /// Explicit owner acknowledgement required only for app-local evidence acquisition.
  public let ownerSafetyAcknowledgedAt: String?
  /// A finalized capture can only reference the immutable ENDED draft snapshot.
  public let terminalState: String
  /// SHA-256 of the exact canonical ended-draft bytes read from the append-only ledger.
  public let terminalSnapshotSHA256: String
  /// Embedded canonical bytes allow every later load to revalidate the digest and copied fields.
  public let terminalSnapshotCanonicalJSON: Data

  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion, id, templateVersion, startedAt, endedAt
    case startMonotonicMicroseconds, endMonotonicMicroseconds, firstSourceSequence
    case lastSourceSequence, acquisitionAuthority, ownerSafetyAcknowledgedAt, terminalState
    case terminalSnapshotCanonicalJSON = "terminalSnapshotCanonicalJson"
    case terminalSnapshotSHA256 = "terminalSnapshotSha256"
    case captureID = "captureId"
    case templateID = "templateId"
    case gatewayID = "gatewayId"
    case gatewaySessionID = "gatewaySessionId"
  }

  public init(canonicalEndedDraft: Data) throws {
    let draft = try Self.validatedEndedDraft(canonicalEndedDraft)
    guard let acquisitionAuthority = draft.acquisitionAuthority,
      let endedAt = draft.endedAt,
      let endMonotonicMicroseconds = draft.endMonotonicMicroseconds,
      let lastSourceSequence = draft.lastSourceSequence
    else { throw DiscoveryCaptureFinalizationError.invalidTerminalRun }
    contract = "vhos.discovery.capture-terminal-run"
    contractVersion = "1.0.0"
    id = draft.id
    captureID = draft.captureID
    templateID = draft.templateID
    templateVersion = draft.templateVersion
    gatewayID = draft.gatewayID
    gatewaySessionID = draft.gatewaySessionID
    startedAt = draft.startedAt
    self.endedAt = endedAt
    startMonotonicMicroseconds = draft.startMonotonicMicroseconds
    self.endMonotonicMicroseconds = endMonotonicMicroseconds
    firstSourceSequence = draft.firstSourceSequence
    self.lastSourceSequence = lastSourceSequence
    self.acquisitionAuthority = acquisitionAuthority
    ownerSafetyAcknowledgedAt = draft.ownerSafetyAcknowledgedAt
    terminalState = draft.state
    terminalSnapshotCanonicalJSON = canonicalEndedDraft
    terminalSnapshotSHA256 = DiscoveryCaptureManifest.sha256(canonicalEndedDraft)
  }

  public func validateContract() throws {
    let draft = try Self.validatedEndedDraft(terminalSnapshotCanonicalJSON)
    guard contract == "vhos.discovery.capture-terminal-run", contractVersion == "1.0.0",
      terminalSnapshotSHA256 == DiscoveryCaptureManifest.sha256(terminalSnapshotCanonicalJSON),
      id == draft.id, captureID == draft.captureID, templateID == draft.templateID,
      templateVersion == draft.templateVersion, gatewayID == draft.gatewayID,
      gatewaySessionID == draft.gatewaySessionID, startedAt == draft.startedAt,
      endedAt == draft.endedAt, startMonotonicMicroseconds == draft.startMonotonicMicroseconds,
      endMonotonicMicroseconds == draft.endMonotonicMicroseconds,
      firstSourceSequence == draft.firstSourceSequence,
      lastSourceSequence == draft.lastSourceSequence,
      acquisitionAuthority == draft.acquisitionAuthority,
      ownerSafetyAcknowledgedAt == draft.ownerSafetyAcknowledgedAt,
      terminalState == draft.state
    else { throw DiscoveryCaptureFinalizationError.invalidTerminalRun }
  }

  private static func validatedEndedDraft(_ bytes: Data) throws -> DiscoveryEndedDraftRecord {
    guard !bytes.isEmpty, bytes.count <= 64 * 1_024,
      let draft = try? VHOSJSON.decoder().decode(DiscoveryEndedDraftRecord.self, from: bytes),
      (try? VHOSJSON.encoder().encode(draft)) == bytes,
      draft.contract == "vhos.ios.discovery-test-run-draft",
      draft.contractVersion == "1.0.0", draft.state == "ENDED",
      DiscoveryContractValidation.isDomainID(draft.id, prefix: "run"),
      DiscoveryContractValidation.isDomainID(draft.captureID, prefix: "capture"),
      DiscoveryContractValidation.isSemanticID(draft.templateID),
      DiscoveryContractValidation.isSemanticVersion(draft.templateVersion),
      DiscoveryContractValidation.isBoundedText(draft.gatewayID, maximum: 160),
      let acquisitionAuthority = draft.acquisitionAuthority,
      let start = DiscoveryContractValidation.wallDate(draft.startedAt),
      let endedAt = draft.endedAt,
      let end = DiscoveryContractValidation.wallDate(endedAt), start <= end,
      let endMonotonic = draft.endMonotonicMicroseconds,
      draft.startMonotonicMicroseconds <= endMonotonic,
      let lastSequence = draft.lastSourceSequence,
      draft.firstSourceSequence > 0, draft.firstSourceSequence <= lastSequence
    else { throw DiscoveryCaptureFinalizationError.invalidTerminalRun }
    // DEBUG_UNVERIFIED may bind any valid test template because its purpose is offline/current
    // passive evidence labeling without pre-import gates. Its distinct persisted authority keeps
    // the result permanently ineligible for PARKED, gateway-command, or promotion authority.
    // All other non-PARKED scopes remain restricted to the exact selector-bootstrap procedure.
    if acquisitionAuthority != .parked, acquisitionAuthority != .debugUnverified {
      let canonicalTemplate = try DiscoveryMutationPolicy.parkSelectorBootstrapTemplate()
      guard draft.templateID == canonicalTemplate.id,
        draft.templateVersion == canonicalTemplate.templateVersion
      else { throw DiscoveryCaptureFinalizationError.invalidTerminalRun }
    }
    if acquisitionAuthority.requiresOwnerSafetyAcknowledgement {
      guard DiscoveryMutationPolicy.ownerSafetyAcknowledgementIsValid(
        draft.ownerSafetyAcknowledgedAt,
        runStartedAt: draft.startedAt,
        required: true)
      else { throw DiscoveryCaptureFinalizationError.invalidTerminalRun }
    } else if draft.ownerSafetyAcknowledgedAt != nil {
      throw DiscoveryCaptureFinalizationError.invalidTerminalRun
    }
    return draft
  }
}

/// Canonical manifest for one exact passive-CAN archive prefix.
///
/// The manifest is hashed as canonical VHOS JSON. Its digest is copied into the corresponding
/// `CaptureSession`, so candidate provenance resolves to immutable archive, profile, marker, and
/// gateway facts rather than a mutable "latest" projection.
public struct DiscoveryCaptureManifest: Codable, Equatable, Sendable {
  public let contract: String
  public let contractVersion: String
  public let captureID: String
  public let vehicleID: String
  public let vehicleProfileSHA256: String
  public let vehicleProfileByteCount: Int
  public let archiveSHA256: String
  public let archiveByteCount: Int
  public let retainedRecordCount: Int
  public let startedAt: String
  public let endedAt: String
  public let wallClockBasis: CaptureWallClockBasis
  public let startMonotonicMicroseconds: UInt64
  public let endMonotonicMicroseconds: UInt64
  public let firstSourceSequence: UInt64
  public let lastSourceSequence: UInt64
  public let gateway: CaptureGatewayProvenance
  public let gatewaySessionIDs: [UInt32]
  public let busBitratesBps: [UInt32]
  public let listenOnly: Bool
  public let terminalRun: DiscoveryCaptureTerminalRun
  public let eventMarkerIDs: [String]
  public let eventMarkersSHA256: String
  public let physicalMeasurementIDs: [String]
  public let physicalMeasurementsSHA256: String
  public let finalizedAt: String
  public let authority: DiscoveryAuthorityStatus

  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion, vehicleProfileByteCount, archiveByteCount
    case retainedRecordCount, startedAt, endedAt, wallClockBasis
    case startMonotonicMicroseconds, endMonotonicMicroseconds, firstSourceSequence
    case lastSourceSequence, gateway, busBitratesBps, listenOnly, terminalRun
    case finalizedAt, authority
    case captureID = "captureId"
    case vehicleID = "vehicleId"
    case vehicleProfileSHA256 = "vehicleProfileSha256"
    case archiveSHA256 = "archiveSha256"
    case gatewaySessionIDs = "gatewaySessionIds"
    case eventMarkerIDs = "eventMarkerIds"
    case eventMarkersSHA256 = "eventMarkersSha256"
    case physicalMeasurementIDs = "physicalMeasurementIds"
    case physicalMeasurementsSHA256 = "physicalMeasurementsSha256"
  }

  fileprivate init(
    captureID: String,
    vehicleID: String,
    vehicleProfileSHA256: String,
    vehicleProfileByteCount: Int,
    archiveSHA256: String,
    archiveByteCount: Int,
    retainedRecordCount: Int,
    startedAt: String,
    endedAt: String,
    startMonotonicMicroseconds: UInt64,
    endMonotonicMicroseconds: UInt64,
    firstSourceSequence: UInt64,
    lastSourceSequence: UInt64,
    gateway: CaptureGatewayProvenance,
    gatewaySessionID: UInt32,
    busBitratesBps: [UInt32],
    terminalRun: DiscoveryCaptureTerminalRun,
    eventMarkers: [EventMarker],
    physicalMeasurements: [PhysicalMeasurement],
    finalizedAt: String
  ) throws {
    let sortedMarkers = eventMarkers.sorted(by: DiscoveryOrdering.marker)
    let sortedMeasurements = physicalMeasurements.sorted(by: DiscoveryOrdering.measurement)
    contract = "vhos.discovery.capture-manifest"
    contractVersion = "1.0.0"
    self.captureID = captureID
    self.vehicleID = vehicleID
    self.vehicleProfileSHA256 = vehicleProfileSHA256
    self.vehicleProfileByteCount = vehicleProfileByteCount
    self.archiveSHA256 = archiveSHA256
    self.archiveByteCount = archiveByteCount
    self.retainedRecordCount = retainedRecordCount
    self.startedAt = startedAt
    self.endedAt = endedAt
    wallClockBasis = .evidenceIngestionTime
    self.startMonotonicMicroseconds = startMonotonicMicroseconds
    self.endMonotonicMicroseconds = endMonotonicMicroseconds
    self.firstSourceSequence = firstSourceSequence
    self.lastSourceSequence = lastSourceSequence
    self.gateway = gateway
    gatewaySessionIDs = [gatewaySessionID]
    self.busBitratesBps = Array(Set(busBitratesBps)).sorted()
    listenOnly = true
    self.terminalRun = terminalRun
    eventMarkerIDs = sortedMarkers.map(\.id)
    eventMarkersSHA256 = Self.sha256(try VHOSJSON.encoder().encode(sortedMarkers))
    physicalMeasurementIDs = sortedMeasurements.map(\.id)
    physicalMeasurementsSHA256 = Self.sha256(
      try VHOSJSON.encoder().encode(sortedMeasurements))
    self.finalizedAt = finalizedAt
    authority = .observed
    try validateContract()
  }

  public func validateContract() throws {
    try terminalRun.validateContract()
    guard contract == "vhos.discovery.capture-manifest", contractVersion == "1.0.0",
      authority == .observed,
      DiscoveryContractValidation.isDomainID(captureID, prefix: "capture"),
      DiscoveryContractValidation.isDomainID(vehicleID, prefix: "veh"),
      DiscoveryContractValidation.isSHA256(vehicleProfileSHA256),
      vehicleProfileByteCount > 0,
      DiscoveryContractValidation.isSHA256(archiveSHA256), archiveByteCount > 0,
      retainedRecordCount > 0,
      let start = DiscoveryContractValidation.wallDate(startedAt),
      let end = DiscoveryContractValidation.wallDate(endedAt), start <= end,
      wallClockBasis == .evidenceIngestionTime,
      startMonotonicMicroseconds <= endMonotonicMicroseconds,
      firstSourceSequence > 0, firstSourceSequence <= lastSourceSequence,
      gatewaySessionIDs.count == 1,
      !busBitratesBps.isEmpty,
      busBitratesBps.allSatisfy({ $0 == 250_000 || $0 == 500_000 }), listenOnly,
      terminalRun.captureID == captureID,
      terminalRun.gatewayID == gateway.gatewayID,
      gatewaySessionIDs == [terminalRun.gatewaySessionID],
      (startMonotonicMicroseconds...endMonotonicMicroseconds).contains(
        terminalRun.startMonotonicMicroseconds),
      (startMonotonicMicroseconds...endMonotonicMicroseconds).contains(
        terminalRun.endMonotonicMicroseconds),
      (firstSourceSequence...lastSourceSequence).contains(terminalRun.firstSourceSequence),
      (firstSourceSequence...lastSourceSequence).contains(terminalRun.lastSourceSequence),
      Set(eventMarkerIDs).count == eventMarkerIDs.count,
      eventMarkerIDs.allSatisfy({ DiscoveryContractValidation.isDomainID($0, prefix: "marker") }),
      DiscoveryContractValidation.isSHA256(eventMarkersSHA256),
      Set(physicalMeasurementIDs).count == physicalMeasurementIDs.count,
      physicalMeasurementIDs.allSatisfy({
        DiscoveryContractValidation.isDomainID($0, prefix: "measurement")
      }), DiscoveryContractValidation.isSHA256(physicalMeasurementsSHA256),
      let finalized = DiscoveryContractValidation.wallDate(finalizedAt),
      let runEnded = DiscoveryContractValidation.wallDate(terminalRun.endedAt),
      finalized >= runEnded, finalized >= end,
      Self.hasCompleteGatewayProvenance(gateway)
    else { throw DiscoveryCaptureFinalizationError.invalidManifest }
  }

  fileprivate static func hasCompleteGatewayProvenance(
    _ gateway: CaptureGatewayProvenance
  ) -> Bool {
    [
      gateway.hardwareRevision, gateway.firmwareVersion, gateway.firmwareBuildID,
      gateway.protocolVersion, gateway.activeConfigID, gateway.activeConfigVersion,
    ].allSatisfy { value in
      value.map({ DiscoveryContractValidation.isBoundedText($0, maximum: 160) }) ?? false
    }
  }

  fileprivate static func sha256(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
}

/// Complete input to the offline finalization boundary.
///
/// Both byte buffers must come from already-persisted evidence. `vehicleProfileSHA256` is an
/// independently resolved expected digest; finalization rejects a caller that cannot make the
/// persisted profile bytes match it.
public struct DiscoveryCaptureFinalizationInput: Sendable {
  public let captureID: String
  public let vehicleID: String
  public let vehicleProfileArtifact: Data
  public let vehicleProfileSHA256: String
  public let archiveNDJSON: Data
  public let gateway: CaptureGatewayProvenance
  public let terminalRun: DiscoveryCaptureTerminalRun
  public let eventMarkers: [EventMarker]
  public let physicalMeasurements: [PhysicalMeasurement]
  public let finalizedAt: String
  public let notes: String

  public init(
    captureID: String,
    vehicleID: String,
    vehicleProfileArtifact: Data,
    vehicleProfileSHA256: String,
    archiveNDJSON: Data,
    gateway: CaptureGatewayProvenance,
    terminalRun: DiscoveryCaptureTerminalRun,
    eventMarkers: [EventMarker],
    physicalMeasurements: [PhysicalMeasurement] = [],
    finalizedAt: String,
    notes: String = ""
  ) {
    self.captureID = captureID
    self.vehicleID = vehicleID
    self.vehicleProfileArtifact = vehicleProfileArtifact
    self.vehicleProfileSHA256 = vehicleProfileSHA256.lowercased()
    self.archiveNDJSON = archiveNDJSON
    self.gateway = gateway
    self.terminalRun = terminalRun
    self.eventMarkers = eventMarkers
    self.physicalMeasurements = physicalMeasurements
    self.finalizedAt = finalizedAt
    self.notes = notes
  }
}

public struct DiscoveryCaptureFinalizationResult: Equatable, Sendable {
  public let capture: CaptureSession
  public let manifest: DiscoveryCaptureManifest
  public let archiveNDJSON: Data
  public let vehicleProfileArtifact: Data

  public init(
    capture: CaptureSession,
    manifest: DiscoveryCaptureManifest,
    archiveNDJSON: Data,
    vehicleProfileArtifact: Data
  ) {
    self.capture = capture
    self.manifest = manifest
    self.archiveNDJSON = archiveNDJSON
    self.vehicleProfileArtifact = vehicleProfileArtifact
  }
}

public enum DiscoveryCaptureFinalizer {
  public static let maximumArchiveBytes = 64 * 1_024 * 1_024
  public static let maximumVehicleProfileBytes = 4 * 1_024 * 1_024

  public static func finalize(
    _ input: DiscoveryCaptureFinalizationInput
  ) throws -> DiscoveryCaptureFinalizationResult {
    guard DiscoveryContractValidation.isDomainID(input.captureID, prefix: "capture"),
      DiscoveryContractValidation.isDomainID(input.vehicleID, prefix: "veh"),
      DiscoveryContractValidation.isSHA256(input.vehicleProfileSHA256),
      !input.vehicleProfileArtifact.isEmpty,
      input.vehicleProfileArtifact.count <= maximumVehicleProfileBytes,
      DiscoveryCaptureManifest.sha256(input.vehicleProfileArtifact)
        == input.vehicleProfileSHA256,
      DiscoveryContractValidation.isWallTime(input.finalizedAt), input.notes.count <= 2_000
    else { throw DiscoveryCaptureFinalizationError.incompleteVehicleProfile }
    guard DiscoveryCaptureManifest.hasCompleteGatewayProvenance(input.gateway) else {
      throw DiscoveryCaptureFinalizationError.incompleteGatewayProvenance
    }
    try input.terminalRun.validateContract()
    guard input.terminalRun.captureID == input.captureID,
      input.terminalRun.gatewayID == input.gateway.gatewayID
    else { throw DiscoveryCaptureFinalizationError.terminalRunScopeMismatch }

    let inspected = try inspectArchive(
      input.archiveNDJSON,
      expectedGatewayID: input.gateway.gatewayID,
      expectedGatewaySessionID: input.terminalRun.gatewaySessionID)
    guard (inspected.startMonotonicMicroseconds...inspected.endMonotonicMicroseconds)
      .contains(input.terminalRun.startMonotonicMicroseconds),
      (inspected.startMonotonicMicroseconds...inspected.endMonotonicMicroseconds)
        .contains(input.terminalRun.endMonotonicMicroseconds),
      (inspected.firstSourceSequence...inspected.lastSourceSequence)
        .contains(input.terminalRun.firstSourceSequence),
      (inspected.firstSourceSequence...inspected.lastSourceSequence)
        .contains(input.terminalRun.lastSourceSequence)
    else { throw DiscoveryCaptureFinalizationError.terminalRunOutsideArchive }

    let markers = input.eventMarkers.sorted(by: DiscoveryOrdering.marker)
    let measurements = input.physicalMeasurements.sorted(by: DiscoveryOrdering.measurement)
    guard Set(markers.map(\.id)).count == markers.count,
      Set(measurements.map(\.id)).count == measurements.count
    else { throw DiscoveryCaptureFinalizationError.duplicateEvidenceIdentity }
    let runMonotonicRange = input.terminalRun.startMonotonicMicroseconds...input.terminalRun.endMonotonicMicroseconds
    let runSequenceRange = input.terminalRun.firstSourceSequence...input.terminalRun.lastSourceSequence
    for marker in markers {
      try marker.validateContract()
      guard marker.captureID == input.captureID,
        marker.gatewaySessionID == input.terminalRun.gatewaySessionID,
        runMonotonicRange.contains(marker.gatewayMonotonicMicroseconds),
        let sequence = marker.nearestCANSequence,
        runSequenceRange.contains(sequence)
      else { throw DiscoveryCaptureFinalizationError.evidenceOutsideTerminalRun(marker.id) }
    }
    for measurement in measurements {
      try measurement.validateContract()
      guard measurement.captureID == input.captureID,
        measurement.gatewaySessionID == input.terminalRun.gatewaySessionID,
        runMonotonicRange.contains(measurement.gatewayMonotonicMicroseconds),
        let sequence = measurement.nearestCANSequence,
        runSequenceRange.contains(sequence)
      else { throw DiscoveryCaptureFinalizationError.evidenceOutsideTerminalRun(measurement.id) }
    }

    let archiveSHA256 = DiscoveryCaptureManifest.sha256(input.archiveNDJSON)
    let manifest = try DiscoveryCaptureManifest(
      captureID: input.captureID,
      vehicleID: input.vehicleID,
      vehicleProfileSHA256: input.vehicleProfileSHA256,
      vehicleProfileByteCount: input.vehicleProfileArtifact.count,
      archiveSHA256: archiveSHA256,
      archiveByteCount: input.archiveNDJSON.count,
      retainedRecordCount: inspected.recordCount,
      startedAt: inspected.startedAt,
      endedAt: inspected.endedAt,
      startMonotonicMicroseconds: inspected.startMonotonicMicroseconds,
      endMonotonicMicroseconds: inspected.endMonotonicMicroseconds,
      firstSourceSequence: inspected.firstSourceSequence,
      lastSourceSequence: inspected.lastSourceSequence,
      gateway: input.gateway,
      gatewaySessionID: input.terminalRun.gatewaySessionID,
      busBitratesBps: inspected.busBitratesBps,
      terminalRun: input.terminalRun,
      eventMarkers: markers,
      physicalMeasurements: measurements,
      finalizedAt: input.finalizedAt)
    let manifestSHA256 = DiscoveryCaptureManifest.sha256(
      try VHOSJSON.encoder().encode(manifest))
    let capture = try CaptureSession(
      id: input.captureID,
      vehicleID: input.vehicleID,
      vehicleProfileSHA256: input.vehicleProfileSHA256,
      startedAt: inspected.startedAt,
      endedAt: inspected.endedAt,
      wallClockBasis: .evidenceIngestionTime,
      startMonotonicMicroseconds: inspected.startMonotonicMicroseconds,
      endMonotonicMicroseconds: inspected.endMonotonicMicroseconds,
      gateway: input.gateway,
      gatewaySessionIDs: [input.terminalRun.gatewaySessionID],
      busBitratesBps: inspected.busBitratesBps,
      listenOnly: true,
      retainedRecordCount: inspected.recordCount,
      firstSourceSequence: inspected.firstSourceSequence,
      lastSourceSequence: inspected.lastSourceSequence,
      archiveSHA256: archiveSHA256,
      manifestSHA256: manifestSHA256,
      testTemplateID: input.terminalRun.templateID,
      testTemplateVersion: input.terminalRun.templateVersion,
      eventMarkers: markers,
      physicalMeasurements: measurements,
      notes: input.notes)
    return DiscoveryCaptureFinalizationResult(
      capture: capture,
      manifest: manifest,
      archiveNDJSON: input.archiveNDJSON,
      vehicleProfileArtifact: input.vehicleProfileArtifact)
  }

  fileprivate static func inspectArchive(
    _ bytes: Data,
    expectedGatewayID: String,
    expectedGatewaySessionID: UInt32
  ) throws -> DiscoveryCaptureArchiveInspection {
    guard !bytes.isEmpty else { throw DiscoveryCaptureFinalizationError.emptyArchive }
    guard bytes.count <= maximumArchiveBytes else {
      throw DiscoveryCaptureFinalizationError.archiveTooLarge(bytes.count)
    }
    guard bytes.last == 0x0A else {
      throw DiscoveryCaptureFinalizationError.archiveIsNotCommittedNDJSON
    }
    var lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
    guard lines.last?.isEmpty == true else {
      throw DiscoveryCaptureFinalizationError.archiveIsNotCommittedNDJSON
    }
    lines.removeLast()
    guard !lines.isEmpty, lines.allSatisfy({ !$0.isEmpty }) else {
      throw DiscoveryCaptureFinalizationError.archiveIsNotCommittedNDJSON
    }

    var observations: [PassiveCANObservation] = []
    observations.reserveCapacity(lines.count)
    var identities = Set<String>()
    var sourceSequences = Set<UInt64>()
    var priorSequence: UInt64?
    var priorMonotonic: UInt64?
    for (index, line) in lines.enumerated() {
      let lineBytes = Data(line)
      let observation: PassiveCANObservation
      do {
        observation = try VHOSJSON.decoder().decode(
          PassiveCANObservation.self,
          from: lineBytes)
        try PassiveCANEvidenceArchive.validate(observation)
      } catch {
        throw DiscoveryCaptureFinalizationError.invalidArchiveRecord(index + 1)
      }
      guard try VHOSJSON.encoder().encode(observation) == lineBytes else {
        throw DiscoveryCaptureFinalizationError.nonCanonicalArchiveRecord(index + 1)
      }
      guard observation.gatewayID == expectedGatewayID,
        observation.sessionID == expectedGatewaySessionID
      else {
        throw DiscoveryCaptureFinalizationError.archiveScopeMismatch(observation.id)
      }
      guard identities.insert(observation.id).inserted,
        sourceSequences.insert(observation.sourceSequence).inserted
      else {
        throw DiscoveryCaptureFinalizationError.sequenceConflict(observation.sourceSequence)
      }
      if let priorSequence, observation.sourceSequence <= priorSequence {
        throw DiscoveryCaptureFinalizationError.sequenceNotStrictlyIncreasing(
          previous: priorSequence,
          current: observation.sourceSequence)
      }
      if let priorMonotonic, observation.monotonicMicroseconds < priorMonotonic {
        throw DiscoveryCaptureFinalizationError.monotonicTimeReversed(observation.id)
      }
      guard DiscoveryContractValidation.isWallTime(observation.ingestedAt) else {
        throw DiscoveryCaptureFinalizationError.invalidIngestionTime(observation.id)
      }
      priorSequence = observation.sourceSequence
      priorMonotonic = observation.monotonicMicroseconds
      observations.append(observation)
    }
    guard let first = observations.first, let last = observations.last else {
      throw DiscoveryCaptureFinalizationError.emptyArchive
    }
    let wallOrdered = try observations.sorted { left, right in
      guard let leftDate = DiscoveryContractValidation.wallDate(left.ingestedAt),
        let rightDate = DiscoveryContractValidation.wallDate(right.ingestedAt)
      else { throw DiscoveryCaptureFinalizationError.invalidIngestionTime(left.id) }
      if leftDate != rightDate { return leftDate < rightDate }
      return left.sourceSequence < right.sourceSequence
    }
    return DiscoveryCaptureArchiveInspection(
      recordCount: observations.count,
      startedAt: wallOrdered.first!.ingestedAt,
      endedAt: wallOrdered.last!.ingestedAt,
      startMonotonicMicroseconds: first.monotonicMicroseconds,
      endMonotonicMicroseconds: last.monotonicMicroseconds,
      firstSourceSequence: first.sourceSequence,
      lastSourceSequence: last.sourceSequence,
      busBitratesBps: Array(Set(observations.map(\.bitrateBps))).sorted())
  }
}

private struct DiscoveryCaptureArchiveInspection {
  let recordCount: Int
  let startedAt: String
  let endedAt: String
  let startMonotonicMicroseconds: UInt64
  let endMonotonicMicroseconds: UInt64
  let firstSourceSequence: UInt64
  let lastSourceSequence: UInt64
  let busBitratesBps: [UInt32]
}

public struct FinalizedCaptureLedgerEntry: Codable, Equatable, Sendable, Identifiable {
  public let contract: String
  public let contractVersion: String
  public let id: String
  public let capture: CaptureSession
  public let manifest: DiscoveryCaptureManifest
  public let archiveFileName: String
  public let manifestFileName: String
  public let vehicleProfileFileName: String
  public let committedAt: String

  public init(
    capture: CaptureSession,
    manifest: DiscoveryCaptureManifest,
    committedAt: String
  ) throws {
    contract = "vhos.discovery.finalized-capture-ledger-entry"
    contractVersion = "1.0.0"
    id = capture.id
    self.capture = capture
    self.manifest = manifest
    archiveFileName = "\(capture.archiveSHA256).ndjson"
    manifestFileName = "\(capture.manifestSHA256).json"
    vehicleProfileFileName = "\(capture.vehicleProfileSHA256).profile"
    self.committedAt = committedAt
    try validateContract()
  }

  public func validateContract() throws {
    try capture.validateContract()
    try manifest.validateContract()
    let canonicalManifest = try VHOSJSON.encoder().encode(manifest)
    guard contract == "vhos.discovery.finalized-capture-ledger-entry",
      contractVersion == "1.0.0", id == capture.id,
      manifest.captureID == capture.id,
      manifest.vehicleID == capture.vehicleID,
      manifest.vehicleProfileSHA256 == capture.vehicleProfileSHA256,
      manifest.archiveSHA256 == capture.archiveSHA256,
      DiscoveryCaptureManifest.sha256(canonicalManifest) == capture.manifestSHA256,
      manifest.retainedRecordCount == capture.retainedRecordCount,
      manifest.startedAt == capture.startedAt, manifest.endedAt == capture.endedAt,
      manifest.wallClockBasis == capture.wallClockBasis,
      manifest.startMonotonicMicroseconds == capture.startMonotonicMicroseconds,
      manifest.endMonotonicMicroseconds == capture.endMonotonicMicroseconds,
      manifest.firstSourceSequence == capture.firstSourceSequence,
      manifest.lastSourceSequence == capture.lastSourceSequence,
      manifest.gateway == capture.gateway,
      manifest.gatewaySessionIDs == capture.gatewaySessionIDs,
      manifest.busBitratesBps == capture.busBitratesBps,
      manifest.listenOnly == capture.listenOnly,
      manifest.terminalRun.templateID == capture.testTemplateID,
      manifest.terminalRun.templateVersion == capture.testTemplateVersion,
      manifest.eventMarkerIDs == capture.eventMarkers.map(\.id),
      manifest.eventMarkersSHA256
        == DiscoveryCaptureManifest.sha256(try VHOSJSON.encoder().encode(capture.eventMarkers)),
      manifest.physicalMeasurementIDs == capture.physicalMeasurements.map(\.id),
      manifest.physicalMeasurementsSHA256
        == DiscoveryCaptureManifest.sha256(
          try VHOSJSON.encoder().encode(capture.physicalMeasurements)),
      archiveFileName == "\(capture.archiveSHA256).ndjson",
      manifestFileName == "\(capture.manifestSHA256).json",
      vehicleProfileFileName == "\(capture.vehicleProfileSHA256).profile",
      DiscoveryContractValidation.isWallTime(committedAt)
    else { throw DiscoveryCaptureFinalizationError.invalidLedgerEntry }
  }
}

public struct FinalizedCaptureLedgerSnapshot: Equatable, Sendable {
  public let entries: [FinalizedCaptureLedgerEntry]
  public let recovery: AppendOnlyNDJSONTailRecovery?

  public init(
    entries: [FinalizedCaptureLedgerEntry],
    recovery: AppendOnlyNDJSONTailRecovery?
  ) {
    self.entries = entries
    self.recovery = recovery
  }
}

/// Offline, append-only finalized-capture persistence.
///
/// Content-addressed archive, profile, and manifest files are published durably before the ledger
/// line that references them. A crash may leave an unreferenced immutable file, but never a
/// committed ledger record whose evidence was acknowledged before it existed.
public final class FinalizedCaptureStore: @unchecked Sendable {
  public static let ledgerFileName = "finalized-captures.ndjson"
  public static let maximumEntryCount = 10_000

  public let storageDirectory: URL
  public let ledgerURL: URL
  public let archiveDirectory: URL
  public let manifestDirectory: URL
  public let vehicleProfileDirectory: URL
  public let quarantineDirectory: URL

  private let fileManager: FileManager
  private let pathLock: NSLock

  public init(storageDirectory: URL, fileManager: FileManager = .default) {
    self.storageDirectory = storageDirectory
    self.fileManager = fileManager
    ledgerURL = storageDirectory.appendingPathComponent(Self.ledgerFileName)
    archiveDirectory = storageDirectory.appendingPathComponent("archives", isDirectory: true)
    manifestDirectory = storageDirectory.appendingPathComponent("manifests", isDirectory: true)
    vehicleProfileDirectory = storageDirectory.appendingPathComponent(
      "vehicle-profiles", isDirectory: true)
    quarantineDirectory = storageDirectory.appendingPathComponent(
      "InterruptedFinalizedCaptureLedger", isDirectory: true)
    pathLock = FinalizedCapturePathLockRegistry.shared.lock(
      for: ledgerURL.standardizedFileURL.path)
  }

  public func load() throws -> FinalizedCaptureLedgerSnapshot {
    try withLock { try loadUnlocked() }
  }

  public func captures() throws -> [CaptureSession] {
    try load().entries.map(\.capture)
  }

  public func capture(id: String) throws -> CaptureSession? {
    try load().entries.first(where: { $0.capture.id == id })?.capture
  }

  /// Resolves only committed captures whose content-addressed archive, manifest, and vehicle
  /// profile have just been re-read and verified by `load()`.
  public func resolvedEntries(
    captureIDs: [String]
  ) throws -> [FinalizedCaptureLedgerEntry] {
    guard !captureIDs.isEmpty, Set(captureIDs).count == captureIDs.count else {
      throw DiscoveryCaptureFinalizationError.invalidLedgerEntry
    }
    let snapshot = try load()
    let entriesByID = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.capture.id, $0) })
    return try captureIDs.map { captureID in
      guard let entry = entriesByID[captureID] else {
        throw DiscoveryCaptureFinalizationError.committedCaptureNotFound(captureID)
      }
      return entry
    }
  }

  @discardableResult
  public func finalize(
    _ input: DiscoveryCaptureFinalizationInput
  ) throws -> FinalizedCaptureLedgerEntry {
    try withLock {
      let finalized = try DiscoveryCaptureFinalizer.finalize(input)
      let current = try loadUnlocked().entries
      guard current.count < Self.maximumEntryCount else {
        throw DiscoveryCaptureFinalizationError.capacityExceeded
      }
      guard !current.contains(where: { $0.capture.id == finalized.capture.id }) else {
        throw DiscoveryCaptureFinalizationError.duplicateCaptureIdentity(finalized.capture.id)
      }
      let entry = try FinalizedCaptureLedgerEntry(
        capture: finalized.capture,
        manifest: finalized.manifest,
        committedAt: input.finalizedAt)
      let archiveURL = archiveDirectory.appendingPathComponent(entry.archiveFileName)
      let manifestURL = manifestDirectory.appendingPathComponent(entry.manifestFileName)
      let profileURL = vehicleProfileDirectory.appendingPathComponent(
        entry.vehicleProfileFileName)
      try publishIfAbsent(finalized.archiveNDJSON, at: archiveURL)
      try publishIfAbsent(finalized.vehicleProfileArtifact, at: profileURL)
      try publishIfAbsent(try VHOSJSON.encoder().encode(finalized.manifest), at: manifestURL)
      try DurableEvidenceFile.ensureDirectory(storageDirectory, fileManager: fileManager)
      try DurableEvidenceFile.appendCommittedLine(
        try VHOSJSON.encoder().encode(entry),
        to: ledgerURL,
        fileManager: fileManager)
      return entry
    }
  }

  private func loadUnlocked() throws -> FinalizedCaptureLedgerSnapshot {
    let result: AppendOnlyNDJSONLoadResult<FinalizedCaptureLedgerEntry> =
      try AppendOnlyNDJSONLedger.load(
        from: ledgerURL,
        quarantineDirectory: quarantineDirectory,
        fileManager: fileManager
      ) { entry in
        try entry.validateContract()
      }
    guard result.records.count <= Self.maximumEntryCount else {
      throw DiscoveryCaptureFinalizationError.capacityExceeded
    }
    var identities = Set<String>()
    for entry in result.records {
      guard identities.insert(entry.capture.id).inserted else {
        throw DiscoveryCaptureFinalizationError.duplicateCaptureIdentity(entry.capture.id)
      }
      try verifyArtifacts(for: entry)
    }
    return FinalizedCaptureLedgerSnapshot(entries: result.records, recovery: result.recovery)
  }

  private func verifyArtifacts(for entry: FinalizedCaptureLedgerEntry) throws {
    let archiveURL = archiveDirectory.appendingPathComponent(entry.archiveFileName)
    let manifestURL = manifestDirectory.appendingPathComponent(entry.manifestFileName)
    let profileURL = vehicleProfileDirectory.appendingPathComponent(
      entry.vehicleProfileFileName)
    guard fileManager.fileExists(atPath: archiveURL.path),
      fileManager.fileExists(atPath: manifestURL.path),
      fileManager.fileExists(atPath: profileURL.path)
    else { throw DiscoveryCaptureFinalizationError.committedArtifactMissing(entry.capture.id) }
    let archive = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
    let manifestBytes = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
    let profile = try Data(contentsOf: profileURL, options: [.mappedIfSafe])
    let canonicalManifest = try VHOSJSON.encoder().encode(entry.manifest)
    guard DiscoveryCaptureManifest.sha256(archive) == entry.capture.archiveSHA256,
      archive.count == entry.manifest.archiveByteCount,
      DiscoveryCaptureManifest.sha256(manifestBytes) == entry.capture.manifestSHA256,
      manifestBytes == canonicalManifest,
      DiscoveryCaptureManifest.sha256(profile) == entry.capture.vehicleProfileSHA256,
      profile.count == entry.manifest.vehicleProfileByteCount
    else { throw DiscoveryCaptureFinalizationError.committedArtifactDigestMismatch(entry.capture.id) }
    let inspection = try DiscoveryCaptureFinalizer.inspectArchive(
      archive,
      expectedGatewayID: entry.capture.gateway.gatewayID,
      expectedGatewaySessionID: entry.manifest.terminalRun.gatewaySessionID)
    guard inspection.recordCount == entry.capture.retainedRecordCount,
      inspection.startedAt == entry.capture.startedAt,
      inspection.endedAt == entry.capture.endedAt,
      inspection.startMonotonicMicroseconds == entry.capture.startMonotonicMicroseconds,
      inspection.endMonotonicMicroseconds == entry.capture.endMonotonicMicroseconds,
      inspection.firstSourceSequence == entry.capture.firstSourceSequence,
      inspection.lastSourceSequence == entry.capture.lastSourceSequence,
      inspection.busBitratesBps == entry.capture.busBitratesBps
    else { throw DiscoveryCaptureFinalizationError.committedArtifactDigestMismatch(entry.capture.id) }
  }

  private func publishIfAbsent(_ bytes: Data, at url: URL) throws {
    if fileManager.fileExists(atPath: url.path) {
      guard try Data(contentsOf: url, options: [.mappedIfSafe]) == bytes else {
        throw DiscoveryCaptureFinalizationError.contentAddressConflict(url.lastPathComponent)
      }
      return
    }
    try DurableEvidenceFile.replace(bytes, at: url, fileManager: fileManager)
    guard try Data(contentsOf: url, options: [.mappedIfSafe]) == bytes else {
      throw DiscoveryCaptureFinalizationError.contentAddressConflict(url.lastPathComponent)
    }
  }

  private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
    pathLock.lock()
    defer { pathLock.unlock() }
    return try operation()
  }
}

private final class FinalizedCapturePathLockRegistry: @unchecked Sendable {
  static let shared = FinalizedCapturePathLockRegistry()

  private let registryLock = NSLock()
  private var locksByCanonicalPath: [String: NSLock] = [:]

  func lock(for canonicalPath: String) -> NSLock {
    registryLock.lock()
    defer { registryLock.unlock() }
    if let existing = locksByCanonicalPath[canonicalPath] { return existing }
    let created = NSLock()
    locksByCanonicalPath[canonicalPath] = created
    return created
  }
}

public enum DiscoveryCaptureFinalizationError: Error, Equatable, LocalizedError {
  case invalidTerminalRun
  case invalidManifest
  case invalidLedgerEntry
  case incompleteVehicleProfile
  case incompleteGatewayProvenance
  case emptyArchive
  case archiveTooLarge(Int)
  case archiveIsNotCommittedNDJSON
  case invalidArchiveRecord(Int)
  case nonCanonicalArchiveRecord(Int)
  case archiveScopeMismatch(String)
  case sequenceConflict(UInt64)
  case sequenceNotStrictlyIncreasing(previous: UInt64, current: UInt64)
  case monotonicTimeReversed(String)
  case invalidIngestionTime(String)
  case terminalRunScopeMismatch
  case terminalRunOutsideArchive
  case duplicateEvidenceIdentity
  case evidenceOutsideTerminalRun(String)
  case duplicateCaptureIdentity(String)
  case capacityExceeded
  case contentAddressConflict(String)
  case committedArtifactMissing(String)
  case committedArtifactDigestMismatch(String)
  case committedCaptureNotFound(String)

  public var errorDescription: String? {
    switch self {
    case .invalidTerminalRun:
      "The terminal Discovery test-run lineage is invalid or incomplete."
    case .invalidManifest:
      "The finalized Discovery capture manifest is invalid."
    case .invalidLedgerEntry:
      "The finalized capture ledger entry does not match its evidence manifest."
    case .incompleteVehicleProfile:
      "Finalization requires exact persisted vehicle-profile bytes and their matching SHA-256."
    case .incompleteGatewayProvenance:
      "Finalization requires hardware, firmware, build, protocol, and active-configuration identity."
    case .emptyArchive:
      "Finalization requires a non-empty retained passive-CAN archive."
    case .archiveTooLarge(let bytes):
      "The sealed passive-CAN archive exceeds the bounded finalizer input (\(bytes) bytes)."
    case .archiveIsNotCommittedNDJSON:
      "The passive-CAN archive is not an exact newline-committed canonical NDJSON prefix."
    case .invalidArchiveRecord(let line):
      "The passive-CAN archive contains an invalid record at line \(line)."
    case .nonCanonicalArchiveRecord(let line):
      "The passive-CAN archive record at line \(line) is not canonical VHOS JSON."
    case .archiveScopeMismatch(let identity):
      "Passive-CAN record \(identity) belongs to another gateway or recorder session."
    case .sequenceConflict(let sequence):
      "The sealed archive contains conflicting or duplicate source sequence \(sequence)."
    case .sequenceNotStrictlyIncreasing(let previous, let current):
      "The sealed archive source sequence reversed from \(previous) to \(current)."
    case .monotonicTimeReversed(let identity):
      "Passive-CAN record \(identity) reverses gateway monotonic time."
    case .invalidIngestionTime(let identity):
      "Passive-CAN record \(identity) has no valid evidence-ingestion timestamp."
    case .terminalRunScopeMismatch:
      "The terminal Discovery run does not match the capture and gateway provenance."
    case .terminalRunOutsideArchive:
      "The terminal Discovery run falls outside the exact retained archive prefix."
    case .duplicateEvidenceIdentity:
      "The finalization input repeats a marker or physical-measurement identity."
    case .evidenceOutsideTerminalRun(let identity):
      "Evidence \(identity) is unbound or falls outside the exact terminal test-run bounds."
    case .duplicateCaptureIdentity(let identity):
      "Finalized capture \(identity) is already committed; corrections require a new identity."
    case .capacityExceeded:
      "The finalized capture ledger reached its bounded entry capacity."
    case .contentAddressConflict(let fileName):
      "Content-addressed evidence file \(fileName) conflicts with its existing bytes."
    case .committedArtifactMissing(let captureID):
      "Finalized capture \(captureID) references a missing immutable evidence artifact."
    case .committedArtifactDigestMismatch(let captureID):
      "Finalized capture \(captureID) no longer matches its immutable evidence artifact digest."
    case .committedCaptureNotFound(let captureID):
      "Finalized capture \(captureID) is not present in the verified evidence ledger."
    }
  }
}
