import Foundation

public enum ACTelemetrySourceKind: String, Codable, Sendable {
  case addedSensor = "ADDED_SENSOR"
  case simulator = "SIMULATOR"
}

public enum SensorSampleQuality: String, Codable, Sendable {
  case good = "GOOD"
  case stale = "STALE"
  case missing = "MISSING"
  case outOfRange = "OUT_OF_RANGE"
  case decoderUncertain = "DECODER_UNCERTAIN"
  case transportGap = "TRANSPORT_GAP"
  case sensorUnverified = "SENSOR_UNVERIFIED"
  case manuallyEntered = "MANUALLY_ENTERED"
}

public enum CalibrationValidationStatus: String, Codable, Sendable {
  case experimental = "EXPERIMENTAL"
  case benchValidated = "BENCH_VALIDATED"
  case vehicleValidated = "VEHICLE_VALIDATED"
  case calibrated = "CALIBRATED"

  fileprivate var supportsVehicleCalculation: Bool {
    switch self {
    case .experimental: false
    case .benchValidated, .vehicleValidated, .calibrated: true
    }
  }
}

public struct ACMeasurement: Codable, Equatable, Sendable {
  public let signalID: String
  public let value: Double
  public let unit: String
  public let quality: SensorSampleQuality
  public let evidenceReference: String
  public let observationID: String
  public let calibrationID: String?
  public let calibrationRevision: String?
  public let calibrationValidationStatus: CalibrationValidationStatus?

  public init(
    signalID: String,
    value: Double,
    unit: String,
    quality: SensorSampleQuality,
    evidenceReference: String,
    observationID: String,
    calibrationID: String? = nil,
    calibrationRevision: String? = nil,
    calibrationValidationStatus: CalibrationValidationStatus? = nil
  ) {
    self.signalID = signalID
    self.value = value
    self.unit = unit
    self.quality = quality
    self.evidenceReference = evidenceReference
    self.observationID = observationID
    self.calibrationID = calibrationID
    self.calibrationRevision = calibrationRevision
    self.calibrationValidationStatus = calibrationValidationStatus
  }

  fileprivate func isUsable(for source: ACTelemetrySourceKind) -> Bool {
    guard quality == .good else { return false }
    if source == .simulator { return signalID.hasPrefix("sim.") }
    return calibrationID?.isEmpty == false
      && calibrationRevision?.isEmpty == false
      && calibrationValidationStatus?.supportsVehicleCalculation == true
  }
}

public struct ACTelemetrySnapshot: Codable, Equatable, Sendable {
  public let captureID: String
  public let source: ACTelemetrySourceKind
  public let observedAt: String
  public let highPressureAbsolute: ACMeasurement?
  public let lowPressureAbsolute: ACMeasurement?
  public let cabinReturnTemperature: ACMeasurement?
  public let centerVentTemperature: ACMeasurement?

  public init(
    captureID: String,
    source: ACTelemetrySourceKind,
    observedAt: String,
    highPressureAbsolute: ACMeasurement?,
    lowPressureAbsolute: ACMeasurement?,
    cabinReturnTemperature: ACMeasurement?,
    centerVentTemperature: ACMeasurement?
  ) {
    self.captureID = captureID
    self.source = source
    self.observedAt = observedAt
    self.highPressureAbsolute = highPressureAbsolute
    self.lowPressureAbsolute = lowPressureAbsolute
    self.cabinReturnTemperature = cabinReturnTemperature
    self.centerVentTemperature = centerVentTemperature
  }
}

public struct ACCalculationInput: Codable, Equatable, Sendable {
  public let name: String
  public let value: Double
  public let unit: String
  public let evidenceReference: String
  public let quality: SensorSampleQuality
}

public struct ACCalculationResult: Codable, Equatable, Sendable {
  public let metricID: String
  public let equationID: String
  public let equationVersion: String
  public let value: Double
  public let unit: String
  public let truthBoundary: String
  public let confidence: Double
  public let confidenceFactors: [String: Double]
  public let inputs: [ACCalculationInput]
  public let qualityNotes: [String]
  public let executedAt: String
}

public struct ACMetricsReport: Equatable, Sendable {
  public let calculations: [ACCalculationResult]
  public let unavailable: [String: String]
}

public enum ACPerformanceCalculator {
  private static let blockedMetrics = [
    "ac.r134a.saturation":
      "Unavailable until a validated, versioned R134a property table/interpolator is installed.",
    "ac.superheat":
      "Unavailable until validated saturation data and calibrated low-line temperature exist.",
    "ac.subcooling":
      "Unavailable until validated saturation data and calibrated high-line temperature exist.",
    "ac.condenser.approach":
      "Unavailable until validated saturation data and ambient temperature evidence exist.",
    "ac.stabilization.time":
      "Unavailable until versioned slope/window criteria are validated.",
    "ac.baseline.delta":
      "Unavailable until matched-condition vehicle baseline captures exist.",
    "ac.diagnostic.hypotheses":
      "Unavailable: pressure-only or simulator evidence cannot declare charge or component faults.",
  ]

  public static func calculate(
    _ snapshot: ACTelemetrySnapshot,
    confidence: Double,
    confidenceFactors: [String: Double],
    qualityNotes: [String]
  ) throws -> ACMetricsReport {
    guard (0...1).contains(confidence) else {
      throw ACPerformanceError.invalidConfidence
    }
    guard !confidenceFactors.isEmpty,
      confidenceFactors.values.allSatisfy({ (0...1).contains($0) })
    else {
      throw ACPerformanceError.invalidConfidenceFactors
    }
    guard snapshot.source != .simulator || confidence == 0 else {
      throw ACPerformanceError.simulatorConfidenceMustBeZero
    }

    var unavailable = blockedMetrics
    var calculations: [ACCalculationResult] = []

    if let high = snapshot.highPressureAbsolute,
      let low = snapshot.lowPressureAbsolute,
      validPair(high, low, source: snapshot.source, unit: "kPa")
    {
      calculations.append(
        result(
          metricID: "ac.pressure.delta",
          equationID: "ac.pressure.delta",
          value: high.value - low.value,
          unit: "kPa",
          measurements: [
            ("high_pressure_absolute", high),
            ("low_pressure_absolute", low),
          ],
          snapshot: snapshot,
          confidence: confidence,
          confidenceFactors: confidenceFactors,
          qualityNotes: qualityNotes + [
            "Atmospheric pressure cancels when high and low pressure are subtracted."
          ]
        ))
      if low.value > 0 {
        calculations.append(
          result(
            metricID: "ac.pressure.ratio",
            equationID: "ac.pressure.ratio",
            value: high.value / low.value,
            unit: "1",
            measurements: [
              ("high_pressure_absolute", high),
              ("low_pressure_absolute", low),
            ],
            snapshot: snapshot,
            confidence: confidence,
            confidenceFactors: confidenceFactors,
            qualityNotes: qualityNotes
          ))
      } else {
        unavailable["ac.pressure.ratio"] =
          "Low-side absolute pressure must be greater than zero."
      }
    } else {
      unavailable["ac.pressure.delta"] =
        "A matched, calibrated high/low absolute-pressure observation is unavailable."
      unavailable["ac.pressure.ratio"] =
        "A matched, calibrated high/low absolute-pressure observation is unavailable."
    }

    if let cabin = snapshot.cabinReturnTemperature,
      let vent = snapshot.centerVentTemperature,
      validPair(cabin, vent, source: snapshot.source, unit: "Cel")
    {
      calculations.append(
        result(
          metricID: "ac.vent.delta",
          equationID: "ac.vent.delta",
          value: cabin.value - vent.value,
          unit: "Cel",
          measurements: [
            ("cabin_return_temperature", cabin),
            ("center_vent_temperature", vent),
          ],
          snapshot: snapshot,
          confidence: confidence,
          confidenceFactors: confidenceFactors,
          qualityNotes: qualityNotes
        ))
    } else {
      unavailable["ac.vent.delta"] =
        "A matched, calibrated cabin-return/center-vent observation is unavailable."
    }

    return ACMetricsReport(calculations: calculations, unavailable: unavailable)
  }

  private static func validPair(
    _ first: ACMeasurement,
    _ second: ACMeasurement,
    source: ACTelemetrySourceKind,
    unit: String
  ) -> Bool {
    first.observationID == second.observationID
      && first.unit == unit
      && second.unit == unit
      && first.isUsable(for: source)
      && second.isUsable(for: source)
  }

  private static func result(
    metricID: String,
    equationID: String,
    value: Double,
    unit: String,
    measurements: [(String, ACMeasurement)],
    snapshot: ACTelemetrySnapshot,
    confidence: Double,
    confidenceFactors: [String: Double],
    qualityNotes: [String]
  ) -> ACCalculationResult {
    ACCalculationResult(
      metricID: metricID,
      equationID: equationID,
      equationVersion: "1.0.0",
      value: value,
      unit: unit,
      truthBoundary: "ESTIMATED",
      confidence: confidence,
      confidenceFactors: confidenceFactors,
      inputs: measurements.map { name, measurement in
        ACCalculationInput(
          name: name,
          value: measurement.value,
          unit: measurement.unit,
          evidenceReference: measurement.evidenceReference,
          quality: measurement.quality
        )
      },
      qualityNotes: qualityNotes,
      executedAt: snapshot.observedAt
    )
  }
}

public enum ACPerformanceError: Error, Equatable, Sendable {
  case invalidConfidence
  case invalidConfidenceFactors
  case simulatorConfidenceMustBeZero
}
