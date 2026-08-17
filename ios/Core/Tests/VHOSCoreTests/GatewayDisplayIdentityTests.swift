import Testing
@testable import VHOSCore

@Test func legacyOBDAdvertisementNormalizesToCanonicalName() {
  #expect(
    GatewayDisplayIdentity.obdName(advertisedName: "VHOS-MRDIY-B08D14")
      == "VHOS-4R-OBD-B08D14")
}

@Test func immutableGatewayIDWinsAfterHandshake() {
  #expect(
    GatewayDisplayIdentity.obdName(
      advertisedName: "VHOS-MRDIY-000000", gatewayID: "esp32-aabbccb08d14")
      == "VHOS-4R-OBD-B08D14")
}

@Test func transportUUIDNeverBecomesADeviceName() {
  #expect(
    GatewayDisplayIdentity.obdName(
      advertisedName: "54F7616F-F2E1-B2F1-47EC-763783505DEB")
      == "VHOS-4R-OBD")
}

@Test func acNodeUsesItsOwnStableRoleName() {
  #expect(
    GatewayDisplayIdentity.acName(advertisedName: "VHOS-AC-12ABEF")
      == "VHOS-4R-AC-12ABEF")
}
