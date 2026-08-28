import Foundation
import VHOSCore
import XCTest

@testable import Vehicle_Health_OS

/// Regression coverage for the 2026-08-24 incident: the phone's append-only
/// marker ledger holds records whose gatewaySessionId is a wrapped 64-bit
/// value (2^64 − 279,472) written by a build predating the 32-bit session
/// type. Those records must decode (one corrupt row may never take down the
/// whole evidence view), must be quarantined from selection and correlation,
/// and must re-encode their original value byte-for-byte.
final class StoredDiscoveryMarkerLegacySessionTests: XCTestCase {

  private func legacyRecordJSON(sessionValue: String) throws -> Data {
    let marker = try EventMarker(
      id: try DiscoveryIDGenerator.make(prefix: "marker"),
      captureID: try DiscoveryIDGenerator.make(prefix: "capture"),
      gatewaySessionID: nil,
      gatewayMonotonicMicroseconds: 2_396_750,
      recordedAt: "2026-08-24T15:01:00Z",
      kind: .brakePressed,
      label: "BRAKE PRESSED",
      source: .iPhone,
      nearestCANSequence: 1_553,
      note: "legacy record regression")
    let markerJSON = String(
      data: try VHOSJSON.encoder().encode(marker), encoding: .utf8)!
    return Data(
      """
      {"contract":"vhos.ios.discovery-marker-ledger-record",\
      "contractVersion":"1.0.0",\
      "templateId":"discovery.brakes.pulse",\
      "testRunId":null,\
      "gatewayId":"esp32-9454c5b08d14",\
      "gatewaySessionId":\(sessionValue),\
      "marker":\(markerJSON)}
      """.utf8)
  }

  func testLegacyOutOfRangeSessionDecodesQuarantinedNotFatal() throws {
    // The exact value from the phone's ledger: 2^64 − 279,472.
    let record = try VHOSJSON.decoder().decode(
      StoredDiscoveryMarker.self,
      from: legacyRecordJSON(sessionValue: "18446744073709272144"))

    XCTAssertEqual(record.legacyOutOfRangeSessionValue, 18_446_744_073_709_272_144)
    XCTAssertEqual(record.gatewaySessionID, 0)
    XCTAssertFalse(record.hasPlausibleSession)
  }

  func testLegacyRecordReencodesItsOriginalValueVerbatim() throws {
    let record = try VHOSJSON.decoder().decode(
      StoredDiscoveryMarker.self,
      from: legacyRecordJSON(sessionValue: "18446744073709272144"))

    let reencoded = try VHOSJSON.encoder().encode(record)
    let json = String(data: reencoded, encoding: .utf8)!
    XCTAssertTrue(
      json.contains("18446744073709272144"),
      "a quarantined record must round-trip its raw historical session value, never a repaired one"
    )
    XCTAssertFalse(json.contains("legacyOutOfRangeSessionValue"))

    let redecoded = try VHOSJSON.decoder().decode(
      StoredDiscoveryMarker.self, from: reencoded)
    XCTAssertEqual(redecoded, record)
  }

  func testPlausibleSessionDecodesUnchanged() throws {
    let record = try VHOSJSON.decoder().decode(
      StoredDiscoveryMarker.self,
      from: legacyRecordJSON(sessionValue: "1494406896"))

    XCTAssertEqual(record.gatewaySessionID, 1_494_406_896)
    XCTAssertNil(record.legacyOutOfRangeSessionValue)
    XCTAssertTrue(record.hasPlausibleSession)
  }

  func testZeroSessionIsQuarantinedNotTrusted() throws {
    let record = try VHOSJSON.decoder().decode(
      StoredDiscoveryMarker.self,
      from: legacyRecordJSON(sessionValue: "0"))

    XCTAssertFalse(record.hasPlausibleSession)
    XCTAssertEqual(record.legacyOutOfRangeSessionValue, 0)
  }
}
