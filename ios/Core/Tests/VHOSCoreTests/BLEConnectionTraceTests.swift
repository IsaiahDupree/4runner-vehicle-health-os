import Foundation
import Testing

@testable import VHOSCore

@Test func bleConnectionTracePersistsStructuredEventsAndExportsAllSegments() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "vhos-ble-trace-tests-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let recorder = try BLEConnectionTraceRecorder(
    directory: root, maximumFileBytes: 260, maximumFiles: 8)

  let first = try recorder.append(
    recordedAt: "2026-08-18T12:00:00.000Z",
    monotonicMicroseconds: 100,
    processInstance: "A1B2C3D4",
    message: "client=A1B2C3D4 CONNECT_REQUEST link_session=1"
  )
  let second = try recorder.append(
    recordedAt: "2026-08-18T12:00:00.100Z",
    monotonicMicroseconds: 200,
    processInstance: "A1B2C3D4",
    message: "HANDSHAKE_VERIFIED firmware=0.1.0-dev.29"
  )

  #expect(first.event == "CONNECT_REQUEST")
  #expect(second.event == "HANDSHAKE_VERIFIED")
  #expect(recorder.summary().recordCount == 2)
  #expect(recorder.summary().fileCount == 2)

  let exportDirectory = root.appendingPathComponent("export", isDirectory: true)
  let export = try recorder.export(to: exportDirectory)
  let lines = try String(contentsOf: export, encoding: .utf8)
    .split(separator: "\n")
  #expect(lines.count == 2)
  let decoded = try lines.map {
    try VHOSJSON.decoder().decode(BLEConnectionTraceRecord.self, from: Data($0.utf8))
  }
  #expect(decoded.map(\.sequence) == [1, 2])
  #expect(decoded.map(\.event) == ["CONNECT_REQUEST", "HANDSHAKE_VERIFIED"])
  #expect(decoded.allSatisfy { $0.contract == BLEConnectionTraceRecord.currentContract })

  let relaunchedRecorder = try BLEConnectionTraceRecorder(
    directory: root, maximumFileBytes: 260, maximumFiles: 8)
  let afterRelaunch = try relaunchedRecorder.append(
    recordedAt: "2026-08-18T12:01:00.000Z",
    monotonicMicroseconds: 300,
    processInstance: "E5F6A7B8",
    message: "CLIENT_INITIALIZED app_version=0.3.4 app_build=10"
  )
  #expect(afterRelaunch.sequence == 3)
}

@Test func bleConnectionTraceRetentionIsBoundedByFileCount() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "vhos-ble-trace-retention-tests-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let recorder = try BLEConnectionTraceRecorder(
    directory: root, maximumFileBytes: 190, maximumFiles: 2)

  for sequence in 1...5 {
    try recorder.append(
      recordedAt: "2026-08-18T12:00:0\(sequence).000Z",
      monotonicMicroseconds: UInt64(sequence * 100),
      processInstance: "TEST",
      message: "LINK_EVENT sequence=\(sequence) detail=retention-check"
    )
  }

  let summary = recorder.summary()
  #expect(summary.fileCount == 2)
  #expect(summary.recordCount == 2)
  #expect(summary.byteCount > 0)
}
