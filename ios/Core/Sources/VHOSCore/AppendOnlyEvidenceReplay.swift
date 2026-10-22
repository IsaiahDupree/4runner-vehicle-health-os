import Foundation

/// Fail-closed errors produced while replaying identity-bearing append-only evidence records.
///
/// Record positions are one-based so they can be correlated directly with NDJSON line numbers.
public enum AppendOnlyEvidenceReplayError: Error, Equatable, LocalizedError {
  case duplicateIdentity(
    recordKind: String, identity: String, firstRecord: Int, repeatedRecord: Int)
  case conflictingBinding(
    bindingKind: String, identity: String, firstRecord: Int, conflictingRecord: Int)
  case missingInitialState(recordKind: String, identity: String, record: Int)
  case immutableLineageChanged(recordKind: String, identity: String, record: Int)
  case invalidStateTransition(
    recordKind: String, identity: String, from: String, to: String, record: Int)
  case terminalHistoryExtended(
    recordKind: String, identity: String, terminalState: String, record: Int)
  case evidenceOutsideLifecycleBounds(
    recordKind: String, identity: String, violatedBound: String)
  case invalidLifecycleWallClock(recordKind: String, identity: String)

  public var errorDescription: String? {
    switch self {
    case .duplicateIdentity(
      let recordKind, let identity, let firstRecord, let repeatedRecord):
      "The append-only \(recordKind) identity \(identity) is duplicated at records "
        + "\(firstRecord) and \(repeatedRecord)."
    case .conflictingBinding(
      let bindingKind, let identity, let firstRecord, let conflictingRecord):
      "The append-only \(bindingKind) identity \(identity) has conflicting bindings at records "
        + "\(firstRecord) and \(conflictingRecord)."
    case .missingInitialState(let recordKind, let identity, let record):
      "The append-only \(recordKind) history \(identity) does not begin in its initial state at "
        + "record \(record)."
    case .immutableLineageChanged(let recordKind, let identity, let record):
      "The immutable lineage of append-only \(recordKind) history \(identity) changes at record "
        + "\(record)."
    case .invalidStateTransition(let recordKind, let identity, let from, let to, let record):
      "The append-only \(recordKind) history \(identity) has an invalid \(from) -> \(to) "
        + "transition at record \(record)."
    case .terminalHistoryExtended(let recordKind, let identity, let terminalState, let record):
      "The append-only \(recordKind) history \(identity) extends terminal state "
        + "\(terminalState) at record \(record)."
    case .evidenceOutsideLifecycleBounds(let recordKind, let identity, let violatedBound):
      "The append-only \(recordKind) evidence \(identity) violates its lifecycle "
        + "\(violatedBound) bound."
    case .invalidLifecycleWallClock(let recordKind, let identity):
      "The append-only \(recordKind) history \(identity) has an invalid wall-clock interval."
    }
  }
}

/// States whether an evidence record has an exact source-sequence binding.
public enum AppendOnlyEvidenceSequenceBinding: Equatable, Sendable {
  case bounded
  /// Legacy records without a source sequence remain readable, but are not sequence-bounded and
  /// must never be described as having passed a sequence-continuity check.
  case legacyUnsequenced
}

/// Deterministic, fail-closed reducers for append-only evidence ledgers.
///
/// These helpers deliberately reject ambiguous histories instead of applying first-wins or
/// last-wins dictionary semantics. Reading the same valid ledger repeatedly remains idempotent;
/// duplicate records inside the ledger are not treated as repeated reads.
public enum AppendOnlyEvidenceReplay {
  public static func hasValidWallClockInterval(startedAt: String, endedAt: String?) -> Bool {
    let wallClock = ISO8601DateFormatter()
    guard let startDate = wallClock.date(from: startedAt) else { return false }
    guard let endedAt else { return true }
    guard let endDate = wallClock.date(from: endedAt) else { return false }
    return endDate >= startDate
  }

  /// Requires an evidence wall clock, monotonic timestamp, and optional source sequence to fall
  /// within its referenced lifecycle snapshot. Bounds are inclusive. A missing source sequence is
  /// retained only as explicit legacy-unsequenced evidence; it does not bypass either time bound.
  @discardableResult
  public static func requireEvidenceWithinLifecycleBounds(
    recordKind: String,
    identity: String,
    evidenceRecordedAt: String,
    evidenceMonotonicMicroseconds: UInt64,
    evidenceSourceSequence: UInt64?,
    startedAt: String,
    startMonotonicMicroseconds: UInt64,
    firstSourceSequence: UInt64,
    endedAt: String?,
    endMonotonicMicroseconds: UInt64?,
    lastSourceSequence: UInt64?
  ) throws -> AppendOnlyEvidenceSequenceBinding {
    let wallClock = ISO8601DateFormatter()
    guard hasValidWallClockInterval(startedAt: startedAt, endedAt: endedAt) else {
      throw AppendOnlyEvidenceReplayError.invalidLifecycleWallClock(
        recordKind: recordKind, identity: identity)
    }
    guard let evidenceDate = wallClock.date(from: evidenceRecordedAt),
      let startDate = wallClock.date(from: startedAt), evidenceDate >= startDate
    else {
      throw AppendOnlyEvidenceReplayError.evidenceOutsideLifecycleBounds(
        recordKind: recordKind, identity: identity, violatedBound: "wall-clock-start")
    }
    if let endedAt {
      guard let endDate = wallClock.date(from: endedAt), evidenceDate <= endDate else {
        throw AppendOnlyEvidenceReplayError.evidenceOutsideLifecycleBounds(
          recordKind: recordKind, identity: identity, violatedBound: "wall-clock-end")
      }
    }

    guard evidenceMonotonicMicroseconds >= startMonotonicMicroseconds else {
      throw AppendOnlyEvidenceReplayError.evidenceOutsideLifecycleBounds(
        recordKind: recordKind, identity: identity, violatedBound: "monotonic-start")
    }
    if let endMonotonicMicroseconds,
      evidenceMonotonicMicroseconds > endMonotonicMicroseconds
    {
      throw AppendOnlyEvidenceReplayError.evidenceOutsideLifecycleBounds(
        recordKind: recordKind, identity: identity, violatedBound: "monotonic-end")
    }

    guard let evidenceSourceSequence else { return .legacyUnsequenced }
    guard evidenceSourceSequence >= firstSourceSequence else {
      throw AppendOnlyEvidenceReplayError.evidenceOutsideLifecycleBounds(
        recordKind: recordKind, identity: identity, violatedBound: "source-sequence-start")
    }
    if let lastSourceSequence, evidenceSourceSequence > lastSourceSequence {
      throw AppendOnlyEvidenceReplayError.evidenceOutsideLifecycleBounds(
        recordKind: recordKind, identity: identity, violatedBound: "source-sequence-end")
    }
    return .bounded
  }

  public static func requireUniqueIdentity<Record, Identity: Hashable>(
    in records: [Record],
    recordKind: String,
    identity: (Record) -> Identity,
    describeIdentity: (Identity) -> String
  ) throws {
    var firstRecordByIdentity: [Identity: Int] = [:]
    for (offset, record) in records.enumerated() {
      let recordNumber = offset + 1
      let value = identity(record)
      if let firstRecord = firstRecordByIdentity[value] {
        throw AppendOnlyEvidenceReplayError.duplicateIdentity(
          recordKind: recordKind,
          identity: describeIdentity(value),
          firstRecord: firstRecord,
          repeatedRecord: recordNumber)
      }
      firstRecordByIdentity[value] = recordNumber
    }
  }

  /// Requires a one-to-one relationship between both sides of an immutable binding ledger.
  /// Exact duplicate pairs are rejected as duplicate identities; either side being rebound is a
  /// conflict.
  public static func requireBijection<Record, Left: Hashable, Right: Hashable>(
    in records: [Record],
    leftKind: String,
    rightKind: String,
    left: (Record) -> Left,
    right: (Record) -> Right,
    describeLeft: (Left) -> String,
    describeRight: (Right) -> String
  ) throws {
    var rightByLeft: [Left: (value: Right, record: Int)] = [:]
    var leftByRight: [Right: (value: Left, record: Int)] = [:]

    for (offset, record) in records.enumerated() {
      let recordNumber = offset + 1
      let leftValue = left(record)
      let rightValue = right(record)

      if let existing = rightByLeft[leftValue] {
        if existing.value == rightValue {
          throw AppendOnlyEvidenceReplayError.duplicateIdentity(
            recordKind: leftKind,
            identity: describeLeft(leftValue),
            firstRecord: existing.record,
            repeatedRecord: recordNumber)
        }
        throw AppendOnlyEvidenceReplayError.conflictingBinding(
          bindingKind: leftKind,
          identity: describeLeft(leftValue),
          firstRecord: existing.record,
          conflictingRecord: recordNumber)
      }

      if let existing = leftByRight[rightValue] {
        throw AppendOnlyEvidenceReplayError.conflictingBinding(
          bindingKind: rightKind,
          identity: describeRight(rightValue),
          firstRecord: existing.record,
          conflictingRecord: recordNumber)
      }

      rightByLeft[leftValue] = (rightValue, recordNumber)
      leftByRight[rightValue] = (leftValue, recordNumber)
    }
  }

  /// Replays snapshot histories into their latest state without permitting lineage mutation,
  /// invalid transitions, or any record after a terminal snapshot.
  public static func reduceLifecycle<Record, Identity: Hashable, State: Equatable>(
    _ records: [Record],
    recordKind: String,
    identity: (Record) -> Identity,
    describeIdentity: (Identity) -> String,
    state: (Record) -> State,
    describeState: (State) -> String,
    isInitial: (State) -> Bool,
    isTerminal: (State) -> Bool,
    hasSameImmutableLineage: (Record, Record) -> Bool,
    canTransition: (State, State) -> Bool
  ) throws -> [Record] {
    var initialByIdentity: [Identity: Record] = [:]
    var latestByIdentity: [Identity: Record] = [:]
    var identityOrder: [Identity] = []

    for (offset, record) in records.enumerated() {
      let recordNumber = offset + 1
      let recordIdentity = identity(record)
      let recordState = state(record)

      guard let latest = latestByIdentity[recordIdentity] else {
        guard isInitial(recordState) else {
          throw AppendOnlyEvidenceReplayError.missingInitialState(
            recordKind: recordKind,
            identity: describeIdentity(recordIdentity),
            record: recordNumber)
        }
        initialByIdentity[recordIdentity] = record
        latestByIdentity[recordIdentity] = record
        identityOrder.append(recordIdentity)
        continue
      }

      let latestState = state(latest)
      if isTerminal(latestState) {
        throw AppendOnlyEvidenceReplayError.terminalHistoryExtended(
          recordKind: recordKind,
          identity: describeIdentity(recordIdentity),
          terminalState: describeState(latestState),
          record: recordNumber)
      }

      guard let initial = initialByIdentity[recordIdentity],
        hasSameImmutableLineage(initial, record)
      else {
        throw AppendOnlyEvidenceReplayError.immutableLineageChanged(
          recordKind: recordKind,
          identity: describeIdentity(recordIdentity),
          record: recordNumber)
      }

      guard canTransition(latestState, recordState) else {
        throw AppendOnlyEvidenceReplayError.invalidStateTransition(
          recordKind: recordKind,
          identity: describeIdentity(recordIdentity),
          from: describeState(latestState),
          to: describeState(recordState),
          record: recordNumber)
      }
      latestByIdentity[recordIdentity] = record
    }

    return identityOrder.compactMap { latestByIdentity[$0] }
  }
}
