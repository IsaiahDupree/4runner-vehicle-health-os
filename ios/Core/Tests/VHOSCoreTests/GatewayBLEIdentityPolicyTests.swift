import Testing
@testable import VHOSCore

@Suite("BLE gateway identity policy")
struct GatewayBLEIdentityPolicyTests {
  @Test func connectionAttemptWaitsAtFringeRange() {
    #expect(GatewayBLEIdentityPolicy.connectionAttemptIsReliable(observedRSSI: nil))
    #expect(GatewayBLEIdentityPolicy.connectionAttemptIsReliable(observedRSSI: -84))
    #expect(!GatewayBLEIdentityPolicy.connectionAttemptIsReliable(observedRSSI: -85))
    #expect(!GatewayBLEIdentityPolicy.connectionAttemptIsReliable(observedRSSI: -96))
  }

  @Test("A generic FEE0 peripheral is not a gateway candidate")
  func genericFEE0AdvertisementIsRejected() {
    #expect(
      !GatewayBLEIdentityPolicy.advertisementCanBeGatewayCandidate(
        localName: "Battery Monitor", serviceUUIDs: ["FEE0"]))
    #expect(
      GatewayBLEIdentityPolicy.provenGatewayKind(
        localName: "Battery Monitor", discoveredServiceUUIDs: ["FEE0"]) == nil)
  }

  @Test("The versioned VHOS service proves gateway identity")
  func vhosServiceIsAuthoritative() {
    #expect(
      GatewayBLEIdentityPolicy.advertisementCanBeGatewayCandidate(
        localName: "Unknown", serviceUUIDs: [GatewayBLEIdentityPolicy.vhosServiceUUID]))
    #expect(
      GatewayBLEIdentityPolicy.provenGatewayKind(
        localName: "Unknown",
        discoveredServiceUUIDs: [GatewayBLEIdentityPolicy.vhosServiceUUID]) == .vhos)
  }

  @Test("Factory compatibility requires WiCAN or VHOS name evidence")
  func factoryServiceNeedsNameEvidence() {
    #expect(
      GatewayBLEIdentityPolicy.provenGatewayKind(
        localName: "WiCAN_1234", discoveredServiceUUIDs: ["fee0"]) == .factoryWiCAN)
    #expect(
      GatewayBLEIdentityPolicy.provenGatewayKind(
        localName: "Battery Monitor", discoveredServiceUUIDs: ["fee0"]) == nil)
  }

  @Test("Only a previously validated CoreBluetooth identifier may be restored")
  func restorationUsesAnAllowlist() {
    let allowed = "C274A374-812C-45D4-CDBD-BC93BDC9A697"
    #expect(
      GatewayBLEIdentityPolicy.restorationIsAllowed(
        identifier: allowed.lowercased(), validatedIdentifiers: [allowed]))
    #expect(
      !GatewayBLEIdentityPolicy.restorationIsAllowed(
        identifier: "00000000-0000-0000-0000-000000000000",
        validatedIdentifiers: [allowed]))
  }
}
