import Foundation
import Testing

@testable import VHOSCore

@Test func simulatorACMetricsKeepEvidenceAndRefuseDiagnosis() throws {
  let snapshot = ACTelemetrySnapshot(
    captureID: "capture_simulator",
    source: .simulator,
    observedAt: "2026-08-16T16:02:00Z",
    highPressureAbsolute: measurement(
      signalID: "sim.ac.pressure.high.absolute", value: 1_600, unit: "kPa", evidence: "sample_high"),
    lowPressureAbsolute: measurement(
      signalID: "sim.ac.pressure.low.absolute", value: 260, unit: "kPa", evidence: "sample_low"),
    cabinReturnTemperature: measurement(
      signalID: "sim.ac.temperature.cabin-return", value: 25, unit: "Cel", evidence: "sample_cabin"),
    centerVentTemperature: measurement(
      signalID: "sim.ac.temperature.center-vent", value: 10, unit: "Cel", evidence: "sample_vent")
  )

  let report = try ACPerformanceCalculator.calculate(
    snapshot,
    confidence: 0,
    confidenceFactors: ["source_quality": 0],
    qualityNotes: ["SIMULATOR-only; not vehicle evidence or diagnosis."]
  )
  let results = Dictionary(uniqueKeysWithValues: report.calculations.map { ($0.metricID, $0) })

  #expect(Set(results.keys) == ["ac.pressure.delta", "ac.pressure.ratio", "ac.vent.delta"])
  #expect(results["ac.pressure.delta"]?.value == 1_340)
  #expect(results["ac.pressure.ratio"]?.value == 1_600.0 / 260.0)
  #expect(results["ac.vent.delta"]?.value == 15)
  #expect(
    results["ac.pressure.delta"]?.inputs.map(\.evidenceReference) == [
      "sample_high", "sample_low",
    ])
  #expect(report.unavailable["ac.superheat"] != nil)
  #expect(report.unavailable["ac.subcooling"] != nil)
  #expect(report.unavailable["ac.diagnostic.hypotheses"] != nil)
}

@Test func realTelemetryRequiresValidatedCalibration() throws {
  let uncalibrated = ACTelemetrySnapshot(
    captureID: "capture_vehicle",
    source: .addedSensor,
    observedAt: "2026-08-16T16:02:00Z",
    highPressureAbsolute: measurement(
      signalID: "ac.pressure.high.absolute", value: 1_200, unit: "kPa", evidence: "sample_high"),
    lowPressureAbsolute: measurement(
      signalID: "ac.pressure.low.absolute", value: 300, unit: "kPa", evidence: "sample_low"),
    cabinReturnTemperature: nil,
    centerVentTemperature: nil
  )

  let report = try ACPerformanceCalculator.calculate(
    uncalibrated,
    confidence: 0,
    confidenceFactors: ["calibration_quality": 0],
    qualityNotes: ["Calibration is not configured."]
  )
  #expect(report.calculations.isEmpty)
  #expect(report.unavailable["ac.pressure.delta"] != nil)
}

@Test func realTelemetryCannotMixObservations() throws {
  let high = calibratedMeasurement(
    signalID: "ac.pressure.high.absolute",
    value: 1_200,
    unit: "kPa",
    evidence: "sample_high",
    observationID: "obs_one"
  )
  let low = calibratedMeasurement(
    signalID: "ac.pressure.low.absolute",
    value: 300,
    unit: "kPa",
    evidence: "sample_low",
    observationID: "obs_two"
  )
  let snapshot = ACTelemetrySnapshot(
    captureID: "capture_vehicle",
    source: .addedSensor,
    observedAt: "2026-08-16T16:02:00Z",
    highPressureAbsolute: high,
    lowPressureAbsolute: low,
    cabinReturnTemperature: nil,
    centerVentTemperature: nil
  )

  let report = try ACPerformanceCalculator.calculate(
    snapshot,
    confidence: 0,
    confidenceFactors: ["source_quality": 0],
    qualityNotes: []
  )
  #expect(report.calculations.isEmpty)
  #expect(report.unavailable["ac.pressure.ratio"] != nil)
}

@Test func simulatorCannotReceiveVehicleConfidence() {
  let snapshot = ACTelemetrySnapshot(
    captureID: "capture_simulator",
    source: .simulator,
    observedAt: "2026-08-16T16:02:00Z",
    highPressureAbsolute: nil,
    lowPressureAbsolute: nil,
    cabinReturnTemperature: nil,
    centerVentTemperature: nil
  )

  #expect(throws: ACPerformanceError.simulatorConfidenceMustBeZero) {
    try ACPerformanceCalculator.calculate(
      snapshot,
      confidence: 0.5,
      confidenceFactors: ["source_quality": 0.5],
      qualityNotes: []
    )
  }
}

private func measurement(
  signalID: String,
  value: Double,
  unit: String,
  evidence: String
) -> ACMeasurement {
  ACMeasurement(
    signalID: signalID,
    value: value,
    unit: unit,
    quality: .good,
    evidenceReference: evidence,
    observationID: "obs_shared"
  )
}

private func calibratedMeasurement(
  signalID: String,
  value: Double,
  unit: String,
  evidence: String,
  observationID: String
) -> ACMeasurement {
  ACMeasurement(
    signalID: signalID,
    value: value,
    unit: unit,
    quality: .good,
    evidenceReference: evidence,
    observationID: observationID,
    calibrationID: "ac.sensor.calibration",
    calibrationRevision: "1.0.0",
    calibrationValidationStatus: .benchValidated
  )
}
