import Foundation
import Testing

@testable import VHOSCore

@Test func protocolStatusStartsExplicitlyUntested() {
  let summary = ProtocolEvidenceSummary(results: [])

  #expect(summary.tests.count == DiscoveryProtocol.allCases.count)
  #expect(summary.tests.allSatisfy { $0.state == .notTested })
  #expect(summary.latestNetworkConfirmation == nil)
  #expect(summary.latestOBDConfirmation == nil)
}

@Test func protocolStatusSeparatesNetworkDetectionFromOBDConfirmation() {
  let passive = protocolResult(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
    protocolID: .can11Bit500K,
    phase: .passiveListen,
    outcome: .passiveLock,
    endedAt: "2026-08-16T12:00:10Z"
  )
  let diagnostic = protocolResult(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
    protocolID: .iso9141,
    phase: .interpreterRead,
    outcome: .readConfirmed,
    endedAt: "2026-08-16T12:01:10Z"
  )

  let networkOnly = ProtocolEvidenceSummary(results: [passive])
  #expect(networkOnly.latestNetworkConfirmation == passive)
  #expect(networkOnly.latestOBDConfirmation == nil)
  #expect(
    networkOnly.tests.first { $0.protocolID == .can11Bit500K }?.state == .networkDetected)

  let confirmed = ProtocolEvidenceSummary(results: [passive, diagnostic])
  #expect(confirmed.latestNetworkConfirmation == diagnostic)
  #expect(confirmed.latestOBDConfirmation == diagnostic)
  #expect(confirmed.tests.first { $0.protocolID == .iso9141 }?.state == .obdConfirmed)
}

@Test func protocolStatusReportsFailedAndInconclusiveOutcomesWithoutPromotingThem() {
  let noLock = protocolResult(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
    protocolID: .can29Bit500K,
    phase: .passiveListen,
    outcome: .noLock,
    endedAt: "2026-08-16T12:02:10Z"
  )
  let rejected = protocolResult(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
    protocolID: .j1850VPW,
    phase: .interpreterRead,
    outcome: .rejectedError,
    endedAt: "2026-08-16T12:03:10Z"
  )

  let summary = ProtocolEvidenceSummary(results: [noLock, rejected])
  #expect(summary.latestNetworkConfirmation == nil)
  #expect(summary.latestOBDConfirmation == nil)
  #expect(summary.tests.first { $0.protocolID == .can29Bit500K }?.state == .noLock)
  #expect(summary.tests.first { $0.protocolID == .j1850VPW }?.state == .rejected)
}

private func protocolResult(
  id: UUID,
  protocolID: DiscoveryProtocol,
  phase: DiscoveryPhase,
  outcome: DiscoveryOutcome,
  endedAt: String
) -> ProtocolExperimentResult {
  ProtocolExperimentResult(
    experimentID: id,
    captureID: "capture-\(id.uuidString.lowercased())",
    candidate: DiscoveryCandidate(
      id: id,
      protocolID: protocolID,
      phase: phase,
      boundedWindowSeconds: 10,
      allowlistEntryID: phase == .interpreterRead ? "obd.standard.supported-pids" : nil
    ),
    outcome: outcome,
    startedAt: "2026-08-16T12:00:00Z",
    endedAt: endedAt,
    receivedRecords: outcome == .noLock ? 0 : 12,
    droppedRecords: 0,
    errorCount: outcome == .rejectedError ? 1 : 0,
    stableIdentifierCount: outcome == .passiveLock ? 3 : 0,
    evidenceReferences: ["evidence://capture/\(id.uuidString.lowercased())"],
    manifestSHA256: String(repeating: "a", count: 64)
  )
}
