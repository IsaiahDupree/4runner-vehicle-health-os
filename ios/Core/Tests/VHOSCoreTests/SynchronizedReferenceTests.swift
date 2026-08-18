import Foundation
import Testing

@testable import VHOSCore

@Test func synchronizedReferenceCSVPreservesGatewayTimeAndEscapesNotes() throws {
  let sample = try SynchronizedReferenceSample(
    id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
    gatewayMonotonicMicroseconds: 1_234_567,
    signalID: "reference.engine.speed",
    value: 1371,
    unit: "rpm",
    source: "TECHSTREAM",
    recordedAt: "2026-08-18T12:00:00Z",
    nearestCANSequence: 42,
    evidenceNote: "Engine & ECT, Data List"
  )
  let csv = String(decoding: SynchronizedReferenceCSV.encode([sample]), as: UTF8.self)
  #expect(csv.contains("1234567,reference.engine.speed,1371,rpm,TECHSTREAM"))
  #expect(csv.contains("42,\"Engine & ECT, Data List\""))
}

@Test func synchronizedReferenceRejectsNonSemanticIdentity() {
  #expect(throws: SynchronizedReferenceError.invalidSample) {
    try SynchronizedReferenceSample(
      gatewayMonotonicMicroseconds: 1,
      signalID: "RPM",
      value: 1,
      unit: "rpm",
      source: "TECHSTREAM",
      recordedAt: "2026-08-18T12:00:00Z",
      nearestCANSequence: nil,
      evidenceNote: ""
    )
  }
}
