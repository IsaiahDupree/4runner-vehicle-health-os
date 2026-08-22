import Testing

@testable import VHOSCore

private struct ReplayBindingFixture: Equatable {
  let captureID: String
  let gatewaySession: String
}

private struct ReplayMarkerFixture: Equatable {
  let id: String
}

private enum ReplayLifecycleState: String, Equatable {
  case active = "ACTIVE"
  case ended = "ENDED"
  case aborted = "ABORTED"
}

private struct ReplayLifecycleFixture: Equatable {
  let id: String
  let captureID: String
  let templateVersion: String
  let state: ReplayLifecycleState
}

@Test func appendOnlyReplayRejectsExactDuplicateBindingRecords() throws {
  let records = [
    ReplayBindingFixture(captureID: "capture-a", gatewaySession: "gateway-a:1"),
    ReplayBindingFixture(captureID: "capture-a", gatewaySession: "gateway-a:1"),
  ]

  #expect(throws: AppendOnlyEvidenceReplayError.self) {
    try requireCaptureBindingBijection(records)
  }
}

@Test func appendOnlyReplayRejectsCaptureIdentityRebinding() throws {
  let records = [
    ReplayBindingFixture(captureID: "capture-a", gatewaySession: "gateway-a:1"),
    ReplayBindingFixture(captureID: "capture-a", gatewaySession: "gateway-a:2"),
  ]

  do {
    try requireCaptureBindingBijection(records)
    Issue.record("Expected a capture identity rebind to fail closed")
  } catch let error as AppendOnlyEvidenceReplayError {
    #expect(
      error
        == .conflictingBinding(
          bindingKind: "capture binding", identity: "capture-a", firstRecord: 1,
          conflictingRecord: 2))
  }
}

@Test func appendOnlyReplayRejectsGatewaySessionRebinding() throws {
  let records = [
    ReplayBindingFixture(captureID: "capture-a", gatewaySession: "gateway-a:1"),
    ReplayBindingFixture(captureID: "capture-b", gatewaySession: "gateway-a:1"),
  ]

  do {
    try requireCaptureBindingBijection(records)
    Issue.record("Expected a gateway-session rebind to fail closed")
  } catch let error as AppendOnlyEvidenceReplayError {
    #expect(
      error
        == .conflictingBinding(
          bindingKind: "gateway session", identity: "gateway-a:1", firstRecord: 1,
          conflictingRecord: 2))
  }
}

@Test func appendOnlyReplayRejectsDuplicateMarkerIdentity() throws {
  let records = [ReplayMarkerFixture(id: "marker-a"), ReplayMarkerFixture(id: "marker-a")]

  do {
    try AppendOnlyEvidenceReplay.requireUniqueIdentity(
      in: records,
      recordKind: "Discovery marker",
      identity: \.id,
      describeIdentity: { $0 })
    Issue.record("Expected a duplicate marker identity to fail closed")
  } catch let error as AppendOnlyEvidenceReplayError {
    #expect(
      error
        == .duplicateIdentity(
          recordKind: "Discovery marker", identity: "marker-a", firstRecord: 1,
          repeatedRecord: 2))
  }
}

@Test func appendOnlyReplayAcceptsInclusiveMarkerBounds() throws {
  let atStart = try markerSequenceBinding(monotonic: 1_000, sequence: 20)
  let atEnd = try markerSequenceBinding(monotonic: 2_000, sequence: 40)

  #expect(atStart == .bounded)
  #expect(atEnd == .bounded)
}

@Test func appendOnlyReplayRejectsMarkerBeforeRunStart() throws {
  #expect(
    throws: AppendOnlyEvidenceReplayError.evidenceOutsideLifecycleBounds(
      recordKind: "Discovery marker", identity: "marker-a",
      violatedBound: "monotonic-start")
  ) {
    _ = try markerSequenceBinding(monotonic: 999, sequence: 20)
  }

  #expect(
    throws: AppendOnlyEvidenceReplayError.evidenceOutsideLifecycleBounds(
      recordKind: "Discovery marker", identity: "marker-a",
      violatedBound: "source-sequence-start")
  ) {
    _ = try markerSequenceBinding(monotonic: 1_000, sequence: 19)
  }
}

@Test func appendOnlyReplayRejectsMarkerAfterTerminalRunEnd() throws {
  #expect(
    throws: AppendOnlyEvidenceReplayError.evidenceOutsideLifecycleBounds(
      recordKind: "Discovery marker", identity: "marker-a",
      violatedBound: "monotonic-end")
  ) {
    _ = try markerSequenceBinding(monotonic: 2_001, sequence: 40)
  }

  #expect(
    throws: AppendOnlyEvidenceReplayError.evidenceOutsideLifecycleBounds(
      recordKind: "Discovery marker", identity: "marker-a",
      violatedBound: "source-sequence-end")
  ) {
    _ = try markerSequenceBinding(monotonic: 2_000, sequence: 41)
  }
}

@Test func appendOnlyReplayKeepsLegacyNilSequenceExplicitAndStillChecksMonotonicBounds() throws {
  let binding = try markerSequenceBinding(monotonic: 1_500, sequence: nil)
  #expect(binding == .legacyUnsequenced)

  #expect(throws: AppendOnlyEvidenceReplayError.self) {
    _ = try markerSequenceBinding(monotonic: 2_001, sequence: nil)
  }
}

@Test func appendOnlyReplayRejectsMarkerRecordedAfterAbortWithoutPhysicalEndEvidence() throws {
  #expect(
    throws: AppendOnlyEvidenceReplayError.evidenceOutsideLifecycleBounds(
      recordKind: "Discovery marker", identity: "marker-a",
      violatedBound: "wall-clock-end")
  ) {
    _ = try markerSequenceBinding(
      recordedAt: "2026-08-22T12:00:11Z",
      monotonic: 1_500,
      sequence: nil,
      endedAt: "2026-08-22T12:00:10Z",
      endMonotonic: nil,
      lastSequence: nil)
  }
}

@Test func appendOnlyReplayRejectsBackwardTerminalWallClockInterval() {
  #expect(
    !AppendOnlyEvidenceReplay.hasValidWallClockInterval(
      startedAt: "2026-08-22T12:00:10Z",
      endedAt: "2026-08-22T12:00:09Z"))
  #expect(
    AppendOnlyEvidenceReplay.hasValidWallClockInterval(
      startedAt: "2026-08-22T12:00:10Z",
      endedAt: "2026-08-22T12:00:10Z"))
}

@Test func appendOnlyReplayPreservesValidInterleavedLifecycleTransitionsAndRepeatedReads() throws {
  let records = [
    lifecycle("run-a", capture: "capture-a", state: .active),
    lifecycle("run-b", capture: "capture-b", state: .active),
    lifecycle("run-a", capture: "capture-a", state: .ended),
    lifecycle("run-b", capture: "capture-b", state: .aborted),
  ]

  let firstRead = try reduceTestRunHistory(records)
  let secondRead = try reduceTestRunHistory(records)

  #expect(firstRead == secondRead)
  #expect(firstRead.map(\.id) == ["run-a", "run-b"])
  #expect(firstRead.map(\.state) == [.ended, .aborted])
}

@Test func appendOnlyReplayRejectsLifecycleLineageRewrite() throws {
  let records = [
    lifecycle("run-a", capture: "capture-a", state: .active),
    lifecycle("run-a", capture: "capture-b", state: .ended),
  ]

  do {
    _ = try reduceTestRunHistory(records)
    Issue.record("Expected immutable run lineage changes to fail closed")
  } catch let error as AppendOnlyEvidenceReplayError {
    #expect(
      error
        == .immutableLineageChanged(
          recordKind: "Discovery test run", identity: "run-a", record: 2))
  }
}

@Test func appendOnlyReplayRejectsTerminalRunResurrection() throws {
  let records = [
    lifecycle("run-a", capture: "capture-a", state: .active),
    lifecycle("run-a", capture: "capture-a", state: .ended),
    lifecycle("run-a", capture: "capture-a", state: .active),
  ]

  do {
    _ = try reduceTestRunHistory(records)
    Issue.record("Expected a terminal test run resurrection to fail closed")
  } catch let error as AppendOnlyEvidenceReplayError {
    #expect(
      error
        == .terminalHistoryExtended(
          recordKind: "Discovery test run", identity: "run-a", terminalState: "ENDED",
          record: 3))
  }
}

@Test func appendOnlyReplayRejectsHistoryThatStartsTerminal() throws {
  let records = [lifecycle("run-a", capture: "capture-a", state: .ended)]

  do {
    _ = try reduceTestRunHistory(records)
    Issue.record("Expected a history without an ACTIVE snapshot to fail closed")
  } catch let error as AppendOnlyEvidenceReplayError {
    #expect(
      error
        == .missingInitialState(
          recordKind: "Discovery test run", identity: "run-a", record: 1))
  }
}

private func requireCaptureBindingBijection(_ records: [ReplayBindingFixture]) throws {
  try AppendOnlyEvidenceReplay.requireBijection(
    in: records,
    leftKind: "capture binding",
    rightKind: "gateway session",
    left: \.captureID,
    right: \.gatewaySession,
    describeLeft: { $0 },
    describeRight: { $0 })
}

private func markerSequenceBinding(
  recordedAt: String = "2026-08-22T12:00:05Z",
  monotonic: UInt64,
  sequence: UInt64?,
  endedAt: String? = "2026-08-22T12:00:10Z",
  endMonotonic: UInt64? = 2_000,
  lastSequence: UInt64? = 40
) throws -> AppendOnlyEvidenceSequenceBinding {
  try AppendOnlyEvidenceReplay.requireEvidenceWithinLifecycleBounds(
    recordKind: "Discovery marker",
    identity: "marker-a",
    evidenceRecordedAt: recordedAt,
    evidenceMonotonicMicroseconds: monotonic,
    evidenceSourceSequence: sequence,
    startedAt: "2026-08-22T12:00:00Z",
    startMonotonicMicroseconds: 1_000,
    firstSourceSequence: 20,
    endedAt: endedAt,
    endMonotonicMicroseconds: endMonotonic,
    lastSourceSequence: lastSequence)
}

private func lifecycle(
  _ id: String,
  capture: String,
  state: ReplayLifecycleState
) -> ReplayLifecycleFixture {
  ReplayLifecycleFixture(
    id: id,
    captureID: capture,
    templateVersion: "1.0.0",
    state: state)
}

private func reduceTestRunHistory(
  _ records: [ReplayLifecycleFixture]
) throws -> [ReplayLifecycleFixture] {
  let identity: (ReplayLifecycleFixture) -> String = { $0.id }
  let state: (ReplayLifecycleFixture) -> ReplayLifecycleState = { $0.state }
  let sameLineage: (ReplayLifecycleFixture, ReplayLifecycleFixture) -> Bool = {
    $0.id == $1.id && $0.captureID == $1.captureID
      && $0.templateVersion == $1.templateVersion
  }
  let transition: (ReplayLifecycleState, ReplayLifecycleState) -> Bool = {
    $0 == .active && ($1 == .ended || $1 == .aborted)
  }
  return try AppendOnlyEvidenceReplay.reduceLifecycle(
    records,
    recordKind: "Discovery test run",
    identity: identity,
    describeIdentity: { $0 },
    state: state,
    describeState: { $0.rawValue },
    isInitial: { $0 == .active },
    isTerminal: { $0 != .active },
    hasSameImmutableLineage: sameLineage,
    canTransition: transition)
}
