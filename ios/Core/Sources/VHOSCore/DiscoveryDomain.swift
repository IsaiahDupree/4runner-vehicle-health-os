import Foundation

public enum DiscoveryAuthorityStatus: String, Codable, CaseIterable, Sendable {
  case observed = "OBSERVED"
  case candidate = "EXPERIMENTAL_CANDIDATE"
  case validated = "VEHICLE_VALIDATED"
  case definitionValidated = "DEFINITION_VALIDATED"
  case promoted = "PROMOTED"
}

public enum DiscoveryTestCategory: String, Codable, CaseIterable, Sendable {
  case engine = "ENGINE"
  case brakes = "BRAKES"
  case steering = "STEERING"
  case transmission = "TRANSMISSION"
  case hvac = "HVAC_AC"
  case suspension = "SUSPENSION"
  case tires = "TIRES"
  case electrical = "ELECTRICAL"
  case fourWheelDrive = "FOUR_WHEEL_DRIVE"
  case lighting = "LIGHTING"
  case custom = "CUSTOM"
}

public enum DiscoveryMarkerKind: String, Codable, CaseIterable, Sendable {
  case ignitionOn = "IGNITION_ON"
  case ignitionOff = "IGNITION_OFF"
  case engineStarted = "ENGINE_STARTED"
  case brakePressed = "BRAKE_PRESSED"
  case brakeReleased = "BRAKE_RELEASED"
  case acceleratorChanged = "ACCELERATOR_CHANGED"
  case steeringChanged = "STEERING_CHANGED"
  case acOn = "AC_ON"
  case acOff = "AC_OFF"
  case compressorObservedOn = "COMPRESSOR_OBSERVED_ON"
  case compressorObservedOff = "COMPRESSOR_OBSERVED_OFF"
  case measurementTaken = "MEASUREMENT_TAKEN"
  case noiseObserved = "NOISE_OBSERVED"
  case custom = "CUSTOM"
}

public enum DiscoveryEvidenceSource: String, Codable, CaseIterable, Sendable {
  case user = "USER"
  case iPhone = "IPHONE"
  case androidHeadUnit = "ANDROID_HEAD_UNIT"
  case gateway = "GATEWAY"
  case scanTool = "SCAN_TOOL"
  case externalInstrument = "EXTERNAL_INSTRUMENT"
  case addedSensor = "ADDED_SENSOR"
}

public enum MeasurementQuality: String, Codable, CaseIterable, Sendable {
  case good = "GOOD"
  case manuallyEntered = "MANUALLY_ENTERED"
  case instrumentUnverified = "INSTRUMENT_UNVERIFIED"
  case calibrationExpired = "CALIBRATION_EXPIRED"
  case uncertain = "UNCERTAIN"
}

public enum CaptureWallClockBasis: String, Codable, CaseIterable, Sendable {
  case captureEpochSynchronized = "CAPTURE_EPOCH_SYNCHRONIZED"
  case evidenceIngestionTime = "EVIDENCE_INGESTION_TIME"
}

public enum CandidateBehaviorShape: String, Codable, CaseIterable, Sendable {
  case boolean = "BOOLEAN"
  case analog = "ANALOG"
  case counter = "COUNTER"
  case stateCode = "STATE_CODE"
  case temperatureShaped = "TEMPERATURE_SHAPED"
  case unknown = "UNKNOWN"
}

public enum CandidateReviewState: String, Codable, CaseIterable, Sendable {
  case veryStrong = "VERY_STRONG"
  case likely = "LIKELY"
  case needsMoreData = "NEEDS_MORE_DATA"
  case conflicting = "CONFLICTING"
  case rejected = "REJECTED"
}

public enum CandidateByteOrder: String, Codable, CaseIterable, Sendable {
  case bigEndian = "BIG_ENDIAN"
  case littleEndian = "LITTLE_ENDIAN"
}

public enum SignalValidationRequirement: String, Codable, CaseIterable, Sendable {
  case signalDefinition = "SIGNAL_DEFINITION"
  case sourceDefined = "SOURCE_DEFINED"
  case decoderDefined = "DECODER_DEFINED"
  case typeAndUnitDefined = "TYPE_AND_UNIT_DEFINED"
  case plausibleRangeDefined = "PLAUSIBLE_RANGE_DEFINED"
  case freshnessDefined = "FRESHNESS_DEFINED"
  case vehicleApplicabilityResolved = "VEHICLE_APPLICABILITY_RESOLVED"
  case targetVehicleCapture = "TARGET_VEHICLE_CAPTURE"
  case repeatabilityAcrossControlledTests = "REPEATABILITY_ACROSS_CONTROLLED_TESTS"
  case independentCorroboration = "INDEPENDENT_CORROBORATION"
  case goldenReplay = "GOLDEN_REPLAY"
  case staleBehaviorDefined = "STALE_BEHAVIOR_DEFINED"
  case missingBehaviorDefined = "MISSING_BEHAVIOR_DEFINED"
  case outOfRangeBehaviorDefined = "OUT_OF_RANGE_BEHAVIOR_DEFINED"
  case provenancePreserved = "PROVENANCE_PRESERVED"
  case contradictionsPreserved = "CONTRADICTIONS_PRESERVED"
  case approvalReviewerRecorded = "APPROVAL_REVIEWER_RECORDED"
}

public enum SignalValidationItemStatus: String, Codable, CaseIterable, Sendable {
  case satisfied = "SATISFIED"
  case missing = "MISSING"
  case conflicting = "CONFLICTING"
  case notApplicable = "NOT_APPLICABLE"
}

public enum SignalValidationApprovalDecision: String, Codable, CaseIterable, Sendable {
  case approve = "APPROVE"
  case reject = "REJECT"
  case requestMoreEvidence = "REQUEST_MORE_EVIDENCE"
}

public struct TestStep: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let sequence: Int
  public let instruction: String
  public let suggestedDurationSeconds: Int?
  public let expectedMarkerKind: DiscoveryMarkerKind?
  public let requiresExplicitConfirmation: Bool

  public init(
    id: String,
    sequence: Int,
    instruction: String,
    suggestedDurationSeconds: Int? = nil,
    expectedMarkerKind: DiscoveryMarkerKind? = nil,
    requiresExplicitConfirmation: Bool = true
  ) throws {
    guard DiscoveryContractValidation.isSemanticID(id), sequence > 0,
      DiscoveryContractValidation.isBoundedText(instruction, maximum: 500),
      suggestedDurationSeconds.map({ (1...3_600).contains($0) }) ?? true
    else { throw DiscoveryContractError.invalidTestStep }
    self.id = id
    self.sequence = sequence
    self.instruction = instruction
    self.suggestedDurationSeconds = suggestedDurationSeconds
    self.expectedMarkerKind = expectedMarkerKind
    self.requiresExplicitConfirmation = requiresExplicitConfirmation
  }
}

public struct TestTemplate: Codable, Equatable, Sendable, Identifiable {
  public let contract: String
  public let contractVersion: String
  public let id: String
  public let templateVersion: String
  public let title: String
  public let category: DiscoveryTestCategory
  public let hypothesis: String
  public let requiredVehicleMotion: VehicleMotion
  public let safetyInstructions: [String]
  public let requiredGatewayCapabilities: [GatewayCapability]
  public let targetedValidationRequirements: [SignalValidationRequirement]
  public let steps: [TestStep]
  public let authority: DiscoveryAuthorityStatus

  public init(
    id: String,
    templateVersion: String,
    title: String,
    category: DiscoveryTestCategory,
    hypothesis: String,
    requiredVehicleMotion: VehicleMotion,
    safetyInstructions: [String],
    requiredGatewayCapabilities: [GatewayCapability],
    targetedValidationRequirements: [SignalValidationRequirement],
    steps: [TestStep]
  ) throws {
    guard DiscoveryContractValidation.isSemanticID(id),
      DiscoveryContractValidation.isSemanticVersion(templateVersion),
      DiscoveryContractValidation.isBoundedText(title, maximum: 160),
      DiscoveryContractValidation.isBoundedText(hypothesis, maximum: 1_000),
      !safetyInstructions.isEmpty,
      safetyInstructions.allSatisfy({
        DiscoveryContractValidation.isBoundedText($0, maximum: 500)
      }), !steps.isEmpty, Set(steps.map(\.sequence)).count == steps.count,
      Set(steps.map(\.id)).count == steps.count,
      steps.map(\.sequence).sorted() == Array(1...steps.count)
    else { throw DiscoveryContractError.invalidTestTemplate }
    for step in steps {
      _ = try TestStep(
        id: step.id, sequence: step.sequence, instruction: step.instruction,
        suggestedDurationSeconds: step.suggestedDurationSeconds,
        expectedMarkerKind: step.expectedMarkerKind,
        requiresExplicitConfirmation: step.requiresExplicitConfirmation)
    }
    contract = "vhos.discovery.test-template"
    contractVersion = "1.0.0"
    self.id = id
    self.templateVersion = templateVersion
    self.title = title
    self.category = category
    self.hypothesis = hypothesis
    self.requiredVehicleMotion = requiredVehicleMotion
    self.safetyInstructions = safetyInstructions
    self.requiredGatewayCapabilities = Array(Set(requiredGatewayCapabilities)).sorted {
      $0.rawValue < $1.rawValue
    }
    self.targetedValidationRequirements = Array(Set(targetedValidationRequirements)).sorted {
      $0.rawValue < $1.rawValue
    }
    self.steps = steps.sorted { $0.sequence < $1.sequence }
    authority = .definitionValidated
  }

  public func validateContract() throws {
    guard contract == "vhos.discovery.test-template", contractVersion == "1.0.0",
      authority == .definitionValidated
    else { throw DiscoveryContractError.unsupportedContract }
    _ = try TestTemplate(
      id: id, templateVersion: templateVersion, title: title, category: category,
      hypothesis: hypothesis, requiredVehicleMotion: requiredVehicleMotion,
      safetyInstructions: safetyInstructions,
      requiredGatewayCapabilities: requiredGatewayCapabilities,
      targetedValidationRequirements: targetedValidationRequirements, steps: steps)
  }
}

public struct EventMarker: Codable, Equatable, Sendable, Identifiable {
  public let contract: String
  public let contractVersion: String
  public let id: String
  public let captureID: String
  public let gatewayMonotonicMicroseconds: UInt64
  public let recordedAt: String
  public let kind: DiscoveryMarkerKind
  public let label: String
  public let source: DiscoveryEvidenceSource
  public let observerID: String?
  public let nearestCANSequence: UInt64?
  public let note: String
  public let authority: DiscoveryAuthorityStatus

  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion, id, gatewayMonotonicMicroseconds, recordedAt, kind, label
    case source, note, authority
    case captureID = "captureId"
    case observerID = "observerId"
    case nearestCANSequence = "nearestCanSequence"
  }

  public init(
    id: String,
    captureID: String,
    gatewayMonotonicMicroseconds: UInt64,
    recordedAt: String,
    kind: DiscoveryMarkerKind,
    label: String,
    source: DiscoveryEvidenceSource,
    observerID: String? = nil,
    nearestCANSequence: UInt64? = nil,
    note: String = ""
  ) throws {
    guard DiscoveryContractValidation.isDomainID(id, prefix: "marker"),
      DiscoveryContractValidation.isDomainID(captureID, prefix: "capture"),
      DiscoveryContractValidation.isWallTime(recordedAt),
      DiscoveryContractValidation.isBoundedText(label, maximum: 160),
      observerID.map({ DiscoveryContractValidation.isBoundedText($0, maximum: 160) }) ?? true,
      note.count <= 1_000
    else { throw DiscoveryContractError.invalidEventMarker }
    contract = "vhos.discovery.event-marker"
    contractVersion = "1.0.0"
    self.id = id
    self.captureID = captureID
    self.gatewayMonotonicMicroseconds = gatewayMonotonicMicroseconds
    self.recordedAt = recordedAt
    self.kind = kind
    self.label = label
    self.source = source
    self.observerID = observerID
    self.nearestCANSequence = nearestCANSequence
    self.note = note
    authority = .observed
  }

  public func validateContract() throws {
    guard contract == "vhos.discovery.event-marker", contractVersion == "1.0.0",
      authority == .observed
    else { throw DiscoveryContractError.unsupportedContract }
    _ = try EventMarker(
      id: id, captureID: captureID,
      gatewayMonotonicMicroseconds: gatewayMonotonicMicroseconds,
      recordedAt: recordedAt, kind: kind, label: label, source: source,
      observerID: observerID, nearestCANSequence: nearestCANSequence, note: note)
  }
}

public struct PhysicalMeasurement: Codable, Equatable, Sendable, Identifiable {
  public let contract: String
  public let contractVersion: String
  public let id: String
  public let captureID: String
  public let gatewayMonotonicMicroseconds: UInt64
  public let recordedAt: String
  public let signalID: String
  public let value: Double
  public let unit: String
  public let method: String
  public let instrumentID: String?
  public let calibrationReference: String?
  public let source: DiscoveryEvidenceSource
  public let quality: MeasurementQuality
  public let nearestCANSequence: UInt64?
  public let note: String
  public let authority: DiscoveryAuthorityStatus

  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion, id, gatewayMonotonicMicroseconds, recordedAt, value, unit
    case method, calibrationReference, source, quality, note, authority
    case captureID = "captureId"
    case signalID = "signalId"
    case instrumentID = "instrumentId"
    case nearestCANSequence = "nearestCanSequence"
  }

  public init(
    id: String,
    captureID: String,
    gatewayMonotonicMicroseconds: UInt64,
    recordedAt: String,
    signalID: String,
    value: Double,
    unit: String,
    method: String,
    instrumentID: String? = nil,
    calibrationReference: String? = nil,
    source: DiscoveryEvidenceSource,
    quality: MeasurementQuality,
    nearestCANSequence: UInt64? = nil,
    note: String = ""
  ) throws {
    guard DiscoveryContractValidation.isDomainID(id, prefix: "measurement"),
      DiscoveryContractValidation.isDomainID(captureID, prefix: "capture"),
      DiscoveryContractValidation.isWallTime(recordedAt),
      DiscoveryContractValidation.isSemanticID(signalID), value.isFinite,
      DiscoveryContractValidation.isUnit(unit),
      DiscoveryContractValidation.isBoundedText(method, maximum: 240),
      instrumentID.map({ DiscoveryContractValidation.isBoundedText($0, maximum: 160) }) ?? true,
      calibrationReference.map({
        DiscoveryContractValidation.isBoundedText($0, maximum: 240)
      }) ?? true, note.count <= 1_000
    else { throw DiscoveryContractError.invalidPhysicalMeasurement }
    contract = "vhos.discovery.physical-measurement"
    contractVersion = "1.0.0"
    self.id = id
    self.captureID = captureID
    self.gatewayMonotonicMicroseconds = gatewayMonotonicMicroseconds
    self.recordedAt = recordedAt
    self.signalID = signalID
    self.value = value
    self.unit = unit
    self.method = method
    self.instrumentID = instrumentID
    self.calibrationReference = calibrationReference
    self.source = source
    self.quality = quality
    self.nearestCANSequence = nearestCANSequence
    self.note = note
    authority = .observed
  }

  public func validateContract() throws {
    guard contract == "vhos.discovery.physical-measurement", contractVersion == "1.0.0",
      authority == .observed
    else { throw DiscoveryContractError.unsupportedContract }
    _ = try PhysicalMeasurement(
      id: id, captureID: captureID,
      gatewayMonotonicMicroseconds: gatewayMonotonicMicroseconds,
      recordedAt: recordedAt, signalID: signalID, value: value, unit: unit,
      method: method, instrumentID: instrumentID,
      calibrationReference: calibrationReference, source: source, quality: quality,
      nearestCANSequence: nearestCANSequence, note: note)
  }
}

public struct CaptureGatewayProvenance: Codable, Equatable, Sendable {
  public let gatewayID: String
  public let hardwareRevision: String?
  public let firmwareVersion: String?
  public let firmwareBuildID: String?
  public let protocolVersion: String?
  public let activeConfigID: String?
  public let activeConfigVersion: String?

  private enum CodingKeys: String, CodingKey {
    case hardwareRevision, firmwareVersion, protocolVersion, activeConfigVersion
    case gatewayID = "gatewayId"
    case firmwareBuildID = "firmwareBuildId"
    case activeConfigID = "activeConfigId"
  }

  public init(
    gatewayID: String,
    hardwareRevision: String? = nil,
    firmwareVersion: String? = nil,
    firmwareBuildID: String? = nil,
    protocolVersion: String? = nil,
    activeConfigID: String? = nil,
    activeConfigVersion: String? = nil
  ) throws {
    guard DiscoveryContractValidation.isBoundedText(gatewayID, maximum: 160),
      [
        hardwareRevision, firmwareVersion, firmwareBuildID, protocolVersion, activeConfigID,
        activeConfigVersion,
      ].allSatisfy({
        $0.map({ DiscoveryContractValidation.isBoundedText($0, maximum: 160) }) ?? true
      })
    else { throw DiscoveryContractError.invalidCaptureSession }
    self.gatewayID = gatewayID
    self.hardwareRevision = hardwareRevision
    self.firmwareVersion = firmwareVersion
    self.firmwareBuildID = firmwareBuildID
    self.protocolVersion = protocolVersion
    self.activeConfigID = activeConfigID
    self.activeConfigVersion = activeConfigVersion
  }
}

public struct CaptureSession: Codable, Equatable, Sendable, Identifiable {
  public let contract: String
  public let contractVersion: String
  public let id: String
  public let vehicleID: String
  public let vehicleProfileSHA256: String
  public let startedAt: String
  public let endedAt: String
  public let wallClockBasis: CaptureWallClockBasis
  public let startMonotonicMicroseconds: UInt64
  public let endMonotonicMicroseconds: UInt64
  public let gateway: CaptureGatewayProvenance
  public let gatewaySessionIDs: [UInt32]
  public let busBitratesBps: [UInt32]
  public let listenOnly: Bool
  public let retainedRecordCount: Int
  public let firstSourceSequence: UInt64
  public let lastSourceSequence: UInt64
  public let archiveSHA256: String
  public let manifestSHA256: String
  public let testTemplateID: String?
  public let testTemplateVersion: String?
  public let eventMarkers: [EventMarker]
  public let physicalMeasurements: [PhysicalMeasurement]
  public let notes: String
  public let authority: DiscoveryAuthorityStatus

  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion, id, startedAt, endedAt, wallClockBasis
    case startMonotonicMicroseconds, endMonotonicMicroseconds, gateway, busBitratesBps
    case listenOnly, retainedRecordCount, firstSourceSequence, lastSourceSequence
    case testTemplateVersion, eventMarkers, physicalMeasurements, notes, authority
    case vehicleID = "vehicleId"
    case vehicleProfileSHA256 = "vehicleProfileSha256"
    case gatewaySessionIDs = "gatewaySessionIds"
    case archiveSHA256 = "archiveSha256"
    case manifestSHA256 = "manifestSha256"
    case testTemplateID = "testTemplateId"
  }

  public init(
    id: String,
    vehicleID: String,
    vehicleProfileSHA256: String,
    startedAt: String,
    endedAt: String,
    wallClockBasis: CaptureWallClockBasis,
    startMonotonicMicroseconds: UInt64,
    endMonotonicMicroseconds: UInt64,
    gateway: CaptureGatewayProvenance,
    gatewaySessionIDs: [UInt32],
    busBitratesBps: [UInt32],
    listenOnly: Bool,
    retainedRecordCount: Int,
    firstSourceSequence: UInt64,
    lastSourceSequence: UInt64,
    archiveSHA256: String,
    manifestSHA256: String,
    testTemplateID: String? = nil,
    testTemplateVersion: String? = nil,
    eventMarkers: [EventMarker] = [],
    physicalMeasurements: [PhysicalMeasurement] = [],
    notes: String = ""
  ) throws {
    let hasTemplatePair = (testTemplateID == nil) == (testTemplateVersion == nil)
    guard DiscoveryContractValidation.isDomainID(id, prefix: "capture"),
      DiscoveryContractValidation.isDomainID(vehicleID, prefix: "veh"),
      DiscoveryContractValidation.isSHA256(vehicleProfileSHA256),
      let startDate = DiscoveryContractValidation.wallDate(startedAt),
      let endDate = DiscoveryContractValidation.wallDate(endedAt), startDate <= endDate,
      startMonotonicMicroseconds <= endMonotonicMicroseconds,
      !gatewaySessionIDs.isEmpty, Set(gatewaySessionIDs).count == gatewaySessionIDs.count,
      !busBitratesBps.isEmpty,
      busBitratesBps.allSatisfy({ $0 == 250_000 || $0 == 500_000 }), listenOnly,
      retainedRecordCount > 0, firstSourceSequence > 0,
      firstSourceSequence <= lastSourceSequence,
      DiscoveryContractValidation.isSHA256(archiveSHA256),
      DiscoveryContractValidation.isSHA256(manifestSHA256), hasTemplatePair,
      testTemplateID.map(DiscoveryContractValidation.isSemanticID) ?? true,
      testTemplateVersion.map(DiscoveryContractValidation.isSemanticVersion) ?? true,
      eventMarkers.allSatisfy({ $0.captureID == id }),
      physicalMeasurements.allSatisfy({ $0.captureID == id }), notes.count <= 2_000
    else { throw DiscoveryContractError.invalidCaptureSession }
    _ = try CaptureGatewayProvenance(
      gatewayID: gateway.gatewayID, hardwareRevision: gateway.hardwareRevision,
      firmwareVersion: gateway.firmwareVersion, firmwareBuildID: gateway.firmwareBuildID,
      protocolVersion: gateway.protocolVersion, activeConfigID: gateway.activeConfigID,
      activeConfigVersion: gateway.activeConfigVersion)
    for marker in eventMarkers { try marker.validateContract() }
    for measurement in physicalMeasurements { try measurement.validateContract() }
    contract = "vhos.discovery.capture-session"
    contractVersion = "1.0.0"
    self.id = id
    self.vehicleID = vehicleID
    self.vehicleProfileSHA256 = vehicleProfileSHA256
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.wallClockBasis = wallClockBasis
    self.startMonotonicMicroseconds = startMonotonicMicroseconds
    self.endMonotonicMicroseconds = endMonotonicMicroseconds
    self.gateway = gateway
    self.gatewaySessionIDs = gatewaySessionIDs.sorted()
    self.busBitratesBps = Array(Set(busBitratesBps)).sorted()
    self.listenOnly = listenOnly
    self.retainedRecordCount = retainedRecordCount
    self.firstSourceSequence = firstSourceSequence
    self.lastSourceSequence = lastSourceSequence
    self.archiveSHA256 = archiveSHA256
    self.manifestSHA256 = manifestSHA256
    self.testTemplateID = testTemplateID
    self.testTemplateVersion = testTemplateVersion
    self.eventMarkers = eventMarkers.sorted(by: DiscoveryOrdering.marker)
    self.physicalMeasurements = physicalMeasurements.sorted(by: DiscoveryOrdering.measurement)
    self.notes = notes
    authority = .observed
  }

  public func validateContract() throws {
    guard contract == "vhos.discovery.capture-session", contractVersion == "1.0.0",
      authority == .observed
    else { throw DiscoveryContractError.unsupportedContract }
    _ = try CaptureSession(
      id: id, vehicleID: vehicleID, vehicleProfileSHA256: vehicleProfileSHA256,
      startedAt: startedAt, endedAt: endedAt, wallClockBasis: wallClockBasis,
      startMonotonicMicroseconds: startMonotonicMicroseconds,
      endMonotonicMicroseconds: endMonotonicMicroseconds, gateway: gateway,
      gatewaySessionIDs: gatewaySessionIDs, busBitratesBps: busBitratesBps,
      listenOnly: listenOnly, retainedRecordCount: retainedRecordCount,
      firstSourceSequence: firstSourceSequence, lastSourceSequence: lastSourceSequence,
      archiveSHA256: archiveSHA256, manifestSHA256: manifestSHA256,
      testTemplateID: testTemplateID, testTemplateVersion: testTemplateVersion,
      eventMarkers: eventMarkers, physicalMeasurements: physicalMeasurements, notes: notes)
  }
}

public struct PassiveBusCapability: Codable, Equatable, Sendable {
  public let protocols: [DiscoveryProtocol]
  public let retainedRecordCount: Int
  public let uniqueIdentifierCount: Int
  public let observedBitratesBps: [UInt32]
  public let standardFrameCount: Int
  public let extendedFrameCount: Int
  public let evidenceSHA256: String

  private enum CodingKeys: String, CodingKey {
    case protocols, retainedRecordCount, uniqueIdentifierCount, observedBitratesBps
    case standardFrameCount, extendedFrameCount
    case evidenceSHA256 = "evidenceSha256"
  }

  public init(
    protocols: [DiscoveryProtocol],
    retainedRecordCount: Int,
    uniqueIdentifierCount: Int,
    observedBitratesBps: [UInt32],
    standardFrameCount: Int,
    extendedFrameCount: Int,
    evidenceSHA256: String
  ) throws {
    guard !protocols.isEmpty, retainedRecordCount > 0, uniqueIdentifierCount > 0,
      !observedBitratesBps.isEmpty,
      observedBitratesBps.allSatisfy({ $0 == 250_000 || $0 == 500_000 }),
      standardFrameCount >= 0, extendedFrameCount >= 0,
      standardFrameCount + extendedFrameCount == retainedRecordCount,
      DiscoveryContractValidation.isSHA256(evidenceSHA256)
    else { throw DiscoveryContractError.invalidCapabilitySnapshot }
    self.protocols = Array(Set(protocols)).sorted { $0.rawValue < $1.rawValue }
    self.retainedRecordCount = retainedRecordCount
    self.uniqueIdentifierCount = uniqueIdentifierCount
    self.observedBitratesBps = Array(Set(observedBitratesBps)).sorted()
    self.standardFrameCount = standardFrameCount
    self.extendedFrameCount = extendedFrameCount
    self.evidenceSHA256 = evidenceSHA256
  }
}

public struct VehicleCapabilitySnapshot: Codable, Equatable, Sendable, Identifiable {
  public let contract: String
  public let contractVersion: String
  public let id: String
  public let vehicleID: String
  public let captureID: String
  public let capturedAt: String
  public let gatewayID: String
  public let passiveBus: PassiveBusCapability?
  public let obdECUs: [J1979ECUAvailability]
  public let standardSignalIDs: [String]
  public let candidateSignalIDs: [String]
  public let validatedSignalIDs: [String]
  public let evidenceReferences: [String]
  public let authority: DiscoveryAuthorityStatus

  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion, id, capturedAt, passiveBus, evidenceReferences, authority
    case vehicleID = "vehicleId"
    case captureID = "captureId"
    case gatewayID = "gatewayId"
    case obdECUs = "obdEcus"
    case standardSignalIDs = "standardSignalIds"
    case candidateSignalIDs = "candidateSignalIds"
    case validatedSignalIDs = "validatedSignalIds"
  }

  public var obdECUCount: Int { obdECUs.count }
  public var supportedPIDCount: Int {
    Set(obdECUs.flatMap(\.supportedPIDs)).count
  }

  public init(
    id: String,
    vehicleID: String,
    captureID: String,
    capturedAt: String,
    gatewayID: String,
    passiveBus: PassiveBusCapability?,
    obdECUs: [J1979ECUAvailability],
    standardSignalIDs: [String],
    candidateSignalIDs: [String],
    validatedSignalIDs: [String],
    evidenceReferences: [String]
  ) throws {
    let allSignals = standardSignalIDs + candidateSignalIDs + validatedSignalIDs
    guard DiscoveryContractValidation.isDomainID(id, prefix: "capability"),
      DiscoveryContractValidation.isDomainID(vehicleID, prefix: "veh"),
      DiscoveryContractValidation.isDomainID(captureID, prefix: "capture"),
      DiscoveryContractValidation.isWallTime(capturedAt),
      DiscoveryContractValidation.isBoundedText(gatewayID, maximum: 160),
      allSignals.allSatisfy(DiscoveryContractValidation.isSemanticID),
      standardSignalIDs.count == Set(standardSignalIDs).count,
      candidateSignalIDs.count == Set(candidateSignalIDs).count,
      validatedSignalIDs.count == Set(validatedSignalIDs).count,
      !evidenceReferences.isEmpty,
      evidenceReferences.allSatisfy({
        DiscoveryContractValidation.isBoundedText($0, maximum: 240)
      })
    else { throw DiscoveryContractError.invalidCapabilitySnapshot }
    if let passiveBus {
      _ = try PassiveBusCapability(
        protocols: passiveBus.protocols,
        retainedRecordCount: passiveBus.retainedRecordCount,
        uniqueIdentifierCount: passiveBus.uniqueIdentifierCount,
        observedBitratesBps: passiveBus.observedBitratesBps,
        standardFrameCount: passiveBus.standardFrameCount,
        extendedFrameCount: passiveBus.extendedFrameCount,
        evidenceSHA256: passiveBus.evidenceSHA256)
    }
    contract = "vhos.discovery.vehicle-capability-snapshot"
    contractVersion = "1.0.0"
    self.id = id
    self.vehicleID = vehicleID
    self.captureID = captureID
    self.capturedAt = capturedAt
    self.gatewayID = gatewayID
    self.passiveBus = passiveBus
    self.obdECUs = obdECUs.sorted { $0.ecuAddress < $1.ecuAddress }
    self.standardSignalIDs = standardSignalIDs.sorted()
    self.candidateSignalIDs = candidateSignalIDs.sorted()
    self.validatedSignalIDs = validatedSignalIDs.sorted()
    self.evidenceReferences = Array(Set(evidenceReferences)).sorted()
    authority = .observed
  }

  public func validateContract() throws {
    guard contract == "vhos.discovery.vehicle-capability-snapshot",
      contractVersion == "1.0.0", authority == .observed
    else { throw DiscoveryContractError.unsupportedContract }
    _ = try VehicleCapabilitySnapshot(
      id: id, vehicleID: vehicleID, captureID: captureID, capturedAt: capturedAt,
      gatewayID: gatewayID, passiveBus: passiveBus, obdECUs: obdECUs,
      standardSignalIDs: standardSignalIDs, candidateSignalIDs: candidateSignalIDs,
      validatedSignalIDs: validatedSignalIDs, evidenceReferences: evidenceReferences)
  }
}

public struct CandidateFieldDefinition: Codable, Equatable, Sendable {
  public let protocolID: DiscoveryProtocol
  public let identifier: UInt32
  public let extended: Bool
  public let byteOffset: Int
  public let bitOffset: Int
  public let bitLength: Int
  public let byteOrder: CandidateByteOrder
  public let signed: Bool

  private enum CodingKeys: String, CodingKey {
    case identifier, extended, byteOffset, bitOffset, bitLength, byteOrder, signed
    case protocolID = "protocolId"
  }

  public var identifierHex: String {
    String(format: extended ? "0x%08X" : "0x%03X", identifier)
  }

  public init(
    protocolID: DiscoveryProtocol,
    identifier: UInt32,
    extended: Bool,
    byteOffset: Int,
    bitOffset: Int,
    bitLength: Int,
    byteOrder: CandidateByteOrder,
    signed: Bool
  ) throws {
    guard protocolID.isPassiveCAN,
      identifier <= (extended ? 0x1FFF_FFFF : 0x7FF),
      (0...7).contains(byteOffset), (0...7).contains(bitOffset),
      (1...64).contains(bitLength), byteOffset * 8 + bitOffset + bitLength <= 64
    else { throw DiscoveryContractError.invalidCandidateSignal }
    self.protocolID = protocolID
    self.identifier = identifier
    self.extended = extended
    self.byteOffset = byteOffset
    self.bitOffset = bitOffset
    self.bitLength = bitLength
    self.byteOrder = byteOrder
    self.signed = signed
  }
}

public struct CandidateSignalMetrics: Codable, Equatable, Sendable {
  public let correlation: Double?
  public let repeatability: Double?
  public let falseActivationCount: Int
  public let analyzedObservationCount: Int
  public let analyzedCaptureCount: Int
  public let controlledTestCount: Int
  public let behaviorShape: CandidateBehaviorShape
  public let algorithmID: String
  public let algorithmVersion: String

  private enum CodingKeys: String, CodingKey {
    case correlation, repeatability, falseActivationCount, analyzedObservationCount
    case analyzedCaptureCount, controlledTestCount, behaviorShape, algorithmVersion
    case algorithmID = "algorithmId"
  }

  public init(
    correlation: Double?,
    repeatability: Double?,
    falseActivationCount: Int,
    analyzedObservationCount: Int,
    analyzedCaptureCount: Int,
    controlledTestCount: Int,
    behaviorShape: CandidateBehaviorShape,
    algorithmID: String,
    algorithmVersion: String
  ) throws {
    guard correlation.map({ $0.isFinite && (-1...1).contains($0) }) ?? true,
      repeatability.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
      falseActivationCount >= 0, analyzedObservationCount > 0, analyzedCaptureCount > 0,
      controlledTestCount >= 0, controlledTestCount <= analyzedCaptureCount,
      DiscoveryContractValidation.isSemanticID(algorithmID),
      DiscoveryContractValidation.isSemanticVersion(algorithmVersion)
    else { throw DiscoveryContractError.invalidCandidateSignal }
    self.correlation = correlation
    self.repeatability = repeatability
    self.falseActivationCount = falseActivationCount
    self.analyzedObservationCount = analyzedObservationCount
    self.analyzedCaptureCount = analyzedCaptureCount
    self.controlledTestCount = controlledTestCount
    self.behaviorShape = behaviorShape
    self.algorithmID = algorithmID
    self.algorithmVersion = algorithmVersion
  }
}

public struct CandidateSignal: Codable, Equatable, Sendable, Identifiable {
  public let contract: String
  public let contractVersion: String
  public let id: String
  public let createdAt: String
  public let candidateSemantic: String
  public let proposedCanonicalSignalID: String?
  public let field: CandidateFieldDefinition
  public let metrics: CandidateSignalMetrics
  public let reviewState: CandidateReviewState
  public let captureIDs: [String]
  public let testTemplateIDs: [String]
  public let eventMarkerIDs: [String]
  public let independentEvidenceReferences: [String]
  public let sourceReferences: [String]
  public let authority: DiscoveryAuthorityStatus

  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion, id, createdAt, candidateSemantic, field, metrics, reviewState
    case independentEvidenceReferences, sourceReferences, authority
    case proposedCanonicalSignalID = "proposedCanonicalSignalId"
    case captureIDs = "captureIds"
    case testTemplateIDs = "testTemplateIds"
    case eventMarkerIDs = "eventMarkerIds"
  }

  public init(
    id: String,
    createdAt: String,
    candidateSemantic: String,
    proposedCanonicalSignalID: String?,
    field: CandidateFieldDefinition,
    metrics: CandidateSignalMetrics,
    reviewState: CandidateReviewState,
    captureIDs: [String],
    testTemplateIDs: [String],
    eventMarkerIDs: [String],
    independentEvidenceReferences: [String],
    sourceReferences: [String]
  ) throws {
    guard DiscoveryContractValidation.isDomainID(id, prefix: "candidate"),
      DiscoveryContractValidation.isWallTime(createdAt),
      DiscoveryContractValidation.isSemanticID(candidateSemantic),
      proposedCanonicalSignalID.map(DiscoveryContractValidation.isSemanticID) ?? true,
      !captureIDs.isEmpty,
      captureIDs.allSatisfy({ DiscoveryContractValidation.isDomainID($0, prefix: "capture") }),
      testTemplateIDs.allSatisfy(DiscoveryContractValidation.isSemanticID),
      eventMarkerIDs.allSatisfy({
        DiscoveryContractValidation.isDomainID($0, prefix: "marker")
      }), !sourceReferences.isEmpty,
      sourceReferences.allSatisfy({
        DiscoveryContractValidation.isBoundedText($0, maximum: 240)
      })
    else { throw DiscoveryContractError.invalidCandidateSignal }
    _ = try CandidateFieldDefinition(
      protocolID: field.protocolID, identifier: field.identifier, extended: field.extended,
      byteOffset: field.byteOffset, bitOffset: field.bitOffset, bitLength: field.bitLength,
      byteOrder: field.byteOrder, signed: field.signed)
    _ = try CandidateSignalMetrics(
      correlation: metrics.correlation, repeatability: metrics.repeatability,
      falseActivationCount: metrics.falseActivationCount,
      analyzedObservationCount: metrics.analyzedObservationCount,
      analyzedCaptureCount: metrics.analyzedCaptureCount,
      controlledTestCount: metrics.controlledTestCount,
      behaviorShape: metrics.behaviorShape, algorithmID: metrics.algorithmID,
      algorithmVersion: metrics.algorithmVersion)
    contract = "vhos.discovery.candidate-signal"
    contractVersion = "1.0.0"
    self.id = id
    self.createdAt = createdAt
    self.candidateSemantic = candidateSemantic
    self.proposedCanonicalSignalID = proposedCanonicalSignalID
    self.field = field
    self.metrics = metrics
    self.reviewState = reviewState
    self.captureIDs = Array(Set(captureIDs)).sorted()
    self.testTemplateIDs = Array(Set(testTemplateIDs)).sorted()
    self.eventMarkerIDs = Array(Set(eventMarkerIDs)).sorted()
    self.independentEvidenceReferences = Array(Set(independentEvidenceReferences)).sorted()
    self.sourceReferences = Array(Set(sourceReferences)).sorted()
    authority = .candidate
  }

  public func validateContract() throws {
    guard contract == "vhos.discovery.candidate-signal", contractVersion == "1.0.0",
      authority == .candidate
    else { throw DiscoveryContractError.unsupportedContract }
    _ = try CandidateSignal(
      id: id, createdAt: createdAt, candidateSemantic: candidateSemantic,
      proposedCanonicalSignalID: proposedCanonicalSignalID, field: field,
      metrics: metrics, reviewState: reviewState, captureIDs: captureIDs,
      testTemplateIDs: testTemplateIDs, eventMarkerIDs: eventMarkerIDs,
      independentEvidenceReferences: independentEvidenceReferences,
      sourceReferences: sourceReferences)
  }
}

public struct SignalValidationItem: Codable, Equatable, Sendable, Identifiable {
  public var id: String { requirement.rawValue }
  public let requirement: SignalValidationRequirement
  public let status: SignalValidationItemStatus
  public let evidenceReferences: [String]
  public let rationale: String

  public init(
    requirement: SignalValidationRequirement,
    status: SignalValidationItemStatus,
    evidenceReferences: [String],
    rationale: String
  ) throws {
    guard DiscoveryContractValidation.isBoundedText(rationale, maximum: 1_000),
      evidenceReferences.allSatisfy({
        DiscoveryContractValidation.isBoundedText($0, maximum: 240)
      }), status != .satisfied || !evidenceReferences.isEmpty
    else { throw DiscoveryContractError.invalidValidationChecklist }
    self.requirement = requirement
    self.status = status
    self.evidenceReferences = Array(Set(evidenceReferences)).sorted()
    self.rationale = rationale
  }
}

public struct SignalValidationApproval: Codable, Equatable, Sendable {
  public let reviewerID: String
  public let reviewedAt: String
  public let decision: SignalValidationApprovalDecision
  public let evidenceReference: String
  public let note: String
  public let authority: DiscoveryAuthorityStatus

  private enum CodingKeys: String, CodingKey {
    case reviewedAt, decision, evidenceReference, note, authority
    case reviewerID = "reviewerId"
  }

  public init(
    reviewerID: String,
    reviewedAt: String,
    decision: SignalValidationApprovalDecision,
    evidenceReference: String,
    note: String
  ) throws {
    guard DiscoveryContractValidation.isDomainID(reviewerID, prefix: "reviewer"),
      DiscoveryContractValidation.isWallTime(reviewedAt),
      DiscoveryContractValidation.isBoundedText(evidenceReference, maximum: 240),
      DiscoveryContractValidation.isBoundedText(note, maximum: 1_000)
    else { throw DiscoveryContractError.invalidValidationChecklist }
    self.reviewerID = reviewerID
    self.reviewedAt = reviewedAt
    self.decision = decision
    self.evidenceReference = evidenceReference
    self.note = note
    authority = .observed
  }
}

public struct SignalValidationChecklist: Codable, Equatable, Sendable {
  public let contract: String
  public let contractVersion: String
  public let candidateID: String
  public let evaluatedAt: String
  public let items: [SignalValidationItem]
  public let approval: SignalValidationApproval?
  public let authority: DiscoveryAuthorityStatus

  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion, evaluatedAt, items, approval, authority
    case candidateID = "candidateId"
  }

  public init(
    candidateID: String,
    evaluatedAt: String,
    items: [SignalValidationItem],
    approval: SignalValidationApproval? = nil
  ) throws {
    guard DiscoveryContractValidation.isDomainID(candidateID, prefix: "candidate"),
      DiscoveryContractValidation.isWallTime(evaluatedAt), !items.isEmpty,
      Set(items.map(\.requirement)).count == items.count
    else { throw DiscoveryContractError.invalidValidationChecklist }
    for item in items {
      _ = try SignalValidationItem(
        requirement: item.requirement, status: item.status,
        evidenceReferences: item.evidenceReferences, rationale: item.rationale)
    }
    if let approval {
      guard approval.authority == .observed else {
        throw DiscoveryContractError.invalidValidationChecklist
      }
      _ = try SignalValidationApproval(
        reviewerID: approval.reviewerID, reviewedAt: approval.reviewedAt,
        decision: approval.decision, evidenceReference: approval.evidenceReference,
        note: approval.note)
    }
    contract = "vhos.discovery.signal-validation-checklist"
    contractVersion = "1.0.0"
    self.candidateID = candidateID
    self.evaluatedAt = evaluatedAt
    self.items = items.sorted { $0.requirement.rawValue < $1.requirement.rawValue }
    self.approval = approval
    let complete = Set(items.map(\.requirement)) == Set(SignalValidationRequirement.allCases)
    authority =
      complete && items.allSatisfy({ $0.status == .satisfied })
        && approval?.decision == .approve
      ? .validated : .candidate
  }

  public func validateContract() throws {
    let expectedAuthority: DiscoveryAuthorityStatus =
      Set(items.map(\.requirement)) == Set(SignalValidationRequirement.allCases)
        && items.allSatisfy({ $0.status == .satisfied })
        && approval?.decision == .approve
      ? .validated : .candidate
    guard contract == "vhos.discovery.signal-validation-checklist",
      contractVersion == "1.0.0", authority == expectedAuthority
    else { throw DiscoveryContractError.unsupportedContract }
    _ = try SignalValidationChecklist(
      candidateID: candidateID, evaluatedAt: evaluatedAt, items: items, approval: approval)
  }
}

public struct SignalPromotionPolicy: Codable, Equatable, Sendable {
  public let policyID: String
  public let policyVersion: String
  public let requiredRequirements: [SignalValidationRequirement]
  public let minimumCorrelation: Double?
  public let minimumRepeatability: Double?

  private enum CodingKeys: String, CodingKey {
    case policyVersion, requiredRequirements, minimumCorrelation, minimumRepeatability
    case policyID = "policyId"
  }

  public init(
    policyID: String,
    policyVersion: String,
    requiredRequirements: [SignalValidationRequirement],
    minimumCorrelation: Double? = nil,
    minimumRepeatability: Double? = nil
  ) throws {
    guard DiscoveryContractValidation.isSemanticID(policyID),
      DiscoveryContractValidation.isSemanticVersion(policyVersion),
      Set(requiredRequirements) == Set(SignalValidationRequirement.allCases),
      minimumCorrelation.map({ $0.isFinite && (-1...1).contains($0) }) ?? true,
      minimumRepeatability.map({ $0.isFinite && (0...1).contains($0) }) ?? true
    else { throw DiscoveryContractError.invalidPromotionPolicy }
    self.policyID = policyID
    self.policyVersion = policyVersion
    self.requiredRequirements = Array(Set(requiredRequirements)).sorted {
      $0.rawValue < $1.rawValue
    }
    self.minimumCorrelation = minimumCorrelation
    self.minimumRepeatability = minimumRepeatability
  }

  public static var prdSignalDefinitionOfDone: SignalPromotionPolicy {
    // The PRD defines these evidence gates but does not define a universal numeric confidence
    // threshold, so the default policy intentionally leaves both thresholds unset.
    try! SignalPromotionPolicy(
      policyID: "discovery.signal-promotion.definition-of-done",
      policyVersion: "1.0.0",
      requiredRequirements: SignalValidationRequirement.allCases)
  }
}

public struct SignalPromotionDecision: Codable, Equatable, Sendable {
  public let contract: String
  public let contractVersion: String
  public let candidateID: String
  public let evaluatedAt: String
  public let policyID: String
  public let policyVersion: String
  public let promotionAllowed: Bool
  public let blockers: [String]
  public let satisfiedEvidenceReferences: [String]
  public let authority: DiscoveryAuthorityStatus

  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion, evaluatedAt, policyVersion, promotionAllowed, blockers
    case satisfiedEvidenceReferences, authority
    case candidateID = "candidateId"
    case policyID = "policyId"
  }
}

public struct RecommendedDiscoveryTest: Codable, Equatable, Sendable, Identifiable {
  public let contract: String
  public let contractVersion: String
  public let id: String
  public let candidateID: String
  public let templateID: String
  public let templateVersion: String
  public let generatedAt: String
  public let recommendationAlgorithmID: String
  public let recommendationAlgorithmVersion: String
  public let reason: String
  public let addressedRequirements: [SignalValidationRequirement]
  public let competingTemplateIDs: [String]
  public let sourceEvidenceReferences: [String]
  public let authority: DiscoveryAuthorityStatus

  private enum CodingKeys: String, CodingKey {
    case contract, contractVersion, id, templateVersion, generatedAt
    case recommendationAlgorithmVersion, reason, addressedRequirements
    case competingTemplateIDs = "competingTemplateIds"
    case sourceEvidenceReferences, authority
    case candidateID = "candidateId"
    case templateID = "templateId"
    case recommendationAlgorithmID = "recommendationAlgorithmId"
  }
}

public enum DiscoveryContractError: Error, Equatable, LocalizedError {
  case unsupportedContract
  case invalidTestStep
  case invalidTestTemplate
  case invalidEventMarker
  case invalidPhysicalMeasurement
  case invalidCaptureSession
  case invalidCapabilitySnapshot
  case invalidCandidateSignal
  case invalidValidationChecklist
  case invalidPromotionPolicy
  case evidenceDoesNotMatchCapture
  case emptyEvidence
  case noApplicableTestTemplate

  public var errorDescription: String? {
    switch self {
    case .unsupportedContract: "The Discovery contract name, version, or authority is unsupported."
    case .invalidTestStep: "The Discovery test step is invalid."
    case .invalidTestTemplate: "The Discovery test template is invalid."
    case .invalidEventMarker: "The Discovery event marker is invalid."
    case .invalidPhysicalMeasurement: "The synchronized physical measurement is invalid."
    case .invalidCaptureSession: "The finalized Discovery capture session is invalid."
    case .invalidCapabilitySnapshot: "The vehicle capability snapshot is invalid."
    case .invalidCandidateSignal: "The candidate signal contract is invalid."
    case .invalidValidationChecklist: "The signal validation checklist is invalid."
    case .invalidPromotionPolicy: "The signal promotion policy is invalid."
    case .evidenceDoesNotMatchCapture:
      "The retained evidence does not match the declared capture session."
    case .emptyEvidence: "Discovery analysis requires retained evidence."
    case .noApplicableTestTemplate:
      "No supplied test template addresses an unresolved validation requirement."
    }
  }
}

enum DiscoveryContractValidation {
  static func isDomainID(_ value: String, prefix: String) -> Bool {
    value.range(
      of: "^\(NSRegularExpression.escapedPattern(for: prefix))_[0-9A-HJKMNP-TV-Z]{26}$",
      options: .regularExpression) != nil
  }

  static func isSemanticID(_ value: String) -> Bool {
    value.range(
      of: "^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)+$", options: .regularExpression) != nil
      && (3...160).contains(value.count)
  }

  static func isSemanticVersion(_ value: String) -> Bool {
    value.range(
      of:
        "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?(?:\\+[0-9A-Za-z.-]+)?$",
      options: .regularExpression) != nil
  }

  static func isSHA256(_ value: String) -> Bool {
    value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
  }

  static func wallDate(_ value: String) -> Date? {
    let plain = ISO8601DateFormatter()
    if let date = plain.date(from: value) { return date }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value)
  }

  static func isWallTime(_ value: String) -> Bool {
    wallDate(value) != nil
  }

  static func isUnit(_ value: String) -> Bool {
    value.range(of: "^[A-Za-z0-9%/.*_^-]{1,32}$", options: .regularExpression) != nil
  }

  static func isBoundedText(_ value: String, maximum: Int) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed.count <= maximum
  }
}

enum DiscoveryOrdering {
  static func marker(_ left: EventMarker, _ right: EventMarker) -> Bool {
    if left.gatewayMonotonicMicroseconds != right.gatewayMonotonicMicroseconds {
      return left.gatewayMonotonicMicroseconds < right.gatewayMonotonicMicroseconds
    }
    return left.id < right.id
  }

  static func measurement(_ left: PhysicalMeasurement, _ right: PhysicalMeasurement) -> Bool {
    if left.gatewayMonotonicMicroseconds != right.gatewayMonotonicMicroseconds {
      return left.gatewayMonotonicMicroseconds < right.gatewayMonotonicMicroseconds
    }
    return left.id < right.id
  }
}
