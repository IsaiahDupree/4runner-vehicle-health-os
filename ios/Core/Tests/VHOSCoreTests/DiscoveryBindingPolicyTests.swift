import Foundation
import Testing

@testable import VHOSCore

// Regression suite for the 2026-08-24 marker-binding incident: selection by
// "largest sessionID" let a wrapped legacy session value win forever, and
// fifteen markers were appended sharing one frozen evidence coordinate
// (sequence 1,553) while the readiness card promised a different session.

private func bindingObservation(
  gatewayID: String = "esp32-9454c5b08d14",
  sessionID: UInt32,
  sourceSequence: UInt64,
  monotonicMicroseconds: UInt64
) -> PassiveCANObservation {
  PassiveCANObservation(
    gatewayID: gatewayID,
    sessionID: sessionID,
    sourceSequence: sourceSequence,
    monotonicMicroseconds: monotonicMicroseconds,
    bitrateBps: 500_000,
    identifier: 0x20,
    extended: false,
    remoteRequest: false,
    listenOnly: true,
    dataLength: 3,
    data: [0, 0, 7, 0, 0, 0, 0, 0],
    evidenceSource: "gateway-flash",
    ingestedAt: "2026-08-24T15:00:00Z")
}

@Test func freshestObservationWinsRegardlessOfSessionMagnitude() throws {
  // The incident shape: an older capture with a numerically huge session
  // versus a fresh capture with a small session. Recency must win.
  let staleHugeSession = bindingObservation(
    sessionID: 4_294_687_824,  // truncated legacy wrap — large, old
    sourceSequence: 1_553,
    monotonicMicroseconds: 90_000)
  let freshSmallSession = bindingObservation(
    sessionID: 1_494_406_896,
    sourceSequence: 113_995,
    monotonicMicroseconds: 224_072_523)

  let result = DiscoveryBindingPolicy.selectBindingObservation(
    from: [staleHugeSession, freshSmallSession])

  #expect(try result.get().sessionID == 1_494_406_896)
  #expect(try result.get().sourceSequence == 113_995)
}

@Test func presentationOrderIsFreshestFirstNeverSessionMagnitude() {
  let old = bindingObservation(
    sessionID: 4_000_000_000, sourceSequence: 1, monotonicMicroseconds: 10)
  let mid = bindingObservation(
    sessionID: 7, sourceSequence: 2, monotonicMicroseconds: 20)
  let new = bindingObservation(
    sessionID: 42, sourceSequence: 3, monotonicMicroseconds: 30)

  let ordered = DiscoveryBindingPolicy.presentationOrder([old, new, mid])

  #expect(ordered.map(\.sessionID) == [42, 7, 4_000_000_000])
}

@Test func implausibleSessionValuesNeverWinSelection() {
  // sessionID 0 is the quarantine sentinel for legacy out-of-range records.
  let quarantined = bindingObservation(
    sessionID: 0, sourceSequence: 1_553, monotonicMicroseconds: 999_999_999)
  let real = bindingObservation(
    sessionID: 1_494_406_896, sourceSequence: 5, monotonicMicroseconds: 100)

  let result = DiscoveryBindingPolicy.selectBindingObservation(
    from: [quarantined, real])

  #expect(try! result.get().sessionID == 1_494_406_896)

  let onlyQuarantined = DiscoveryBindingPolicy.selectBindingObservation(
    from: [quarantined])
  #expect(onlyQuarantined == .failure(.noPlausibleObservation))
}

@Test func sessionValuePlausibilityMatchesTheGatewayContract() {
  #expect(!DiscoveryBindingPolicy.sessionValueIsPlausible(UInt64(0)))
  #expect(DiscoveryBindingPolicy.sessionValueIsPlausible(UInt64(1)))
  #expect(DiscoveryBindingPolicy.sessionValueIsPlausible(UInt64(UInt32.max)))
  // The exact value from the phone's ledger: 2^64 − 279,472.
  #expect(!DiscoveryBindingPolicy.sessionValueIsPlausible(UInt64.max - 279_471))
  #expect(!DiscoveryBindingPolicy.sessionValueIsPlausible(UInt64(UInt32.max) + 1))
}

@Test func preferredContextBindsExactlyOrRefuses() throws {
  let boundSession = bindingObservation(
    sessionID: 1_007_674_331, sourceSequence: 9, monotonicMicroseconds: 50)
  let otherSession = bindingObservation(
    sessionID: 1_846_258_254, sourceSequence: 90, monotonicMicroseconds: 500)

  let match = DiscoveryBindingPolicy.selectBindingObservation(
    from: [boundSession, otherSession],
    preferredGatewayID: "esp32-9454c5b08d14",
    preferredSessionID: 1_007_674_331)
  #expect(try match.get().sessionID == 1_007_674_331)

  let missing = DiscoveryBindingPolicy.selectBindingObservation(
    from: [otherSession],
    preferredGatewayID: "esp32-9454c5b08d14",
    preferredSessionID: 1_007_674_331)
  #expect(missing == .failure(.preferredContextUnavailable))
}

@Test func twoMarkersMayNeverShareAnEvidenceCoordinate() {
  // A frozen archive: the freshest observation never advances. The second
  // marker must be refused, not silently appended at the same coordinate.
  let frozen = bindingObservation(
    sessionID: 1_007_674_331, sourceSequence: 1_553, monotonicMicroseconds: 2_396_750)

  let second = DiscoveryBindingPolicy.selectBindingObservation(
    from: [frozen],
    lastRecordedMarker: .init(
      gatewaySessionID: 1_007_674_331,
      gatewayMonotonicMicroseconds: 2_396_750))

  #expect(second == .failure(.timelineStalled(lastMonotonicMicroseconds: 2_396_750)))
}

@Test func aNewGatewaySessionRestartsTheMonotonicProgressGuard() throws {
  // Monotonic clocks reset across gateway power cycles: a later marker in
  // a DIFFERENT session may legitimately carry a smaller monotonic value.
  let newSession = bindingObservation(
    sessionID: 2_020_748_856, sourceSequence: 4, monotonicMicroseconds: 1_000)

  let result = DiscoveryBindingPolicy.selectBindingObservation(
    from: [newSession],
    lastRecordedMarker: .init(
      gatewaySessionID: 1_007_674_331,
      gatewayMonotonicMicroseconds: 2_396_750))

  #expect(try result.get().sessionID == 2_020_748_856)
}

@Test func progressWithinASessionSelectsTheAdvancedObservation() throws {
  let stalled = bindingObservation(
    sessionID: 1_007_674_331, sourceSequence: 1_553, monotonicMicroseconds: 2_396_750)
  let advanced = bindingObservation(
    sessionID: 1_007_674_331, sourceSequence: 1_601, monotonicMicroseconds: 2_500_000)

  let result = DiscoveryBindingPolicy.selectBindingObservation(
    from: [stalled, advanced],
    lastRecordedMarker: .init(
      gatewaySessionID: 1_007_674_331,
      gatewayMonotonicMicroseconds: 2_396_750))

  #expect(try result.get().sourceSequence == 1_601)
}

@Test func ignitionMarkerTaxonomyCoversAccessoryAndCrank() {
  // The Ignition Cycle template's five steps must each carry a typed kind;
  // ACCESSORY and CRANK were previously recorded as .custom, making them
  // indistinguishable from arbitrary user annotations downstream.
  #expect(DiscoveryMarkerKind(rawValue: "ACCESSORY") == .accessory)
  #expect(DiscoveryMarkerKind(rawValue: "CRANK") == .crank)
  #expect(Set(DiscoveryMarkerKind.allCases).isSuperset(of: [
    .ignitionOff, .accessory, .ignitionOn, .crank, .engineStarted,
  ]))
}
