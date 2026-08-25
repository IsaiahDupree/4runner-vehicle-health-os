import Foundation
import Testing

@testable import VHOSCore

@Test func supportedPIDChainGatesStandardValues() throws {
  var accumulator = J1979Accumulator()
  let supported = try J1979Accumulator.decodeBitmap(
    basePID: 0, bitmap: Data([0x18, 0x18, 0x80, 0x01]))
  #expect(supported.contains(0x04))
  #expect(supported.contains(0x05))
  #expect(supported.contains(0x0C))
  #expect(supported.contains(0x0D))
  #expect(supported.contains(0x11))
  #expect(supported.contains(0x20))

  try accumulator.ingest(response(pid: 0x00, payload: "410018188001", time: 1))
  #expect(accumulator.availability.first?.enumerationComplete == false)
  #expect(try accumulator.ingest(response(pid: 0x0C, payload: "410C156C", time: 2)) == nil)

  try accumulator.ingest(response(pid: 0x20, payload: "412000000000", time: 3))
  #expect(accumulator.availability.first?.enumerationComplete == true)
  let rpm = try accumulator.ingest(response(pid: 0x0C, payload: "410C156C", time: 4))
  #expect(rpm?.signalID == "obd.engine.speed")
  #expect(rpm?.value == 1371)
  #expect(rpm?.unit == "rpm")
  #expect(rpm?.definitionRevision == J1979Accumulator.definitionRevision)
}

@Test func mismatchedPositiveResponseIsRejected() {
  var accumulator = J1979Accumulator()
  #expect(throws: J1979DecodeError.invalidResponse) {
    try accumulator.ingest(response(pid: 0x0C, payload: "410D00", time: 1))
  }
}

@Test func newCaptureCannotReusePriorSupportedPIDEnumeration() throws {
  var accumulator = J1979Accumulator()
  try accumulator.ingest(
    response(pid: 0x00, payload: "410000180000", time: 1, captureID: "capture-one"))
  #expect(accumulator.availability.first?.enumerationComplete == true)

  let newCaptureRPM = try accumulator.ingest(
    response(pid: 0x0C, payload: "410C156C", time: 2, captureID: "capture-two"))

  #expect(newCaptureRPM == nil)
  #expect(accumulator.availability.isEmpty)
  #expect(accumulator.standardSamples.isEmpty)
}

@Test func finalBitmapDoesNotOverflowPastPID255() throws {
  #expect(
    try J1979Accumulator.decodeBitmap(basePID: 0xE0, bitmap: Data([0, 0, 0, 1])).isEmpty)
}

@Test func passiveFirmwareWireResponseBecomesDurableJ1979Evidence() throws {
  var wire = Data(repeating: 0, count: 36)
  wire[0] = 1
  wire[1] = 1
  wire[2] = 4
  wire.replaceSubrange(4..<8, with: [0xE8, 0x07, 0x00, 0x00])
  wire.replaceSubrange(8..<16, with: [0xD2, 0x04, 0, 0, 0, 0, 0, 0])
  wire.replaceSubrange(16..<24, with: [0x40, 0xE2, 0x01, 0, 0, 0, 0, 0])
  wire.replaceSubrange(24..<28, with: [0x2A, 0, 0, 0])
  wire.replaceSubrange(28..<32, with: [0x41, 0x0C, 0x15, 0x6C])

  let response = try J1979ResponseEvidence.decodePassiveWire(
    wire,
    gatewayID: "esp32-9454c5b08d14",
    observedAt: "2026-08-18T12:00:00Z"
  )

  #expect(response.captureID == "capture-42")
  #expect(response.sourceSequence == 1_234)
  #expect(response.gatewayMonotonicMicroseconds == 123_456)
  #expect(response.ecuAddress == "0x7E8")
  #expect(response.requestPID == 0x0C)
  #expect(response.responsePayloadHex == "410C156C")
  _ = try response.validatedPayload()
}

@Test func recorderContextRejectsLateDiagnosticResponseFromPreviousSession() {
  let currentGatewayID = "esp32-9454c5b08d14"
  let old = response(
    pid: 0x00, payload: "410000180000", time: 1, captureID: "capture-41")
  let current = response(
    pid: 0x00, payload: "410000180000", time: 2, captureID: "capture-42")

  #expect(!old.matchesRecorderContext(gatewayID: currentGatewayID, captureSessionID: 42))
  #expect(current.matchesRecorderContext(gatewayID: currentGatewayID, captureSessionID: 42))
  #expect(!current.matchesRecorderContext(gatewayID: "esp32-different", captureSessionID: 42))
}

private func response(
  pid: UInt8,
  payload: String,
  time: UInt64,
  captureID: String = "capture-test"
) -> J1979ResponseEvidence {
  J1979ResponseEvidence(
    gatewayID: "esp32-9454c5b08d14",
    captureID: captureID,
    observedAt: "2026-08-18T12:00:00Z",
    gatewayMonotonicMicroseconds: time,
    sourceSequence: time,
    transport: "ISO_15765_11_500",
    ecuAddress: "0x7E8",
    requestPID: pid,
    responsePayloadHex: payload
  )
}
