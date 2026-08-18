import Foundation

public enum GatewayBLEIdentityKind: Equatable, Sendable {
  case vhos
  case factoryWiCAN
}

public enum GatewayBLEIdentityPolicy {
  public static let vhosServiceUUID = "33613EB3-FFCA-42D1-83FA-A18F12B3F123"
  public static let factoryServiceUUID = "FEE0"
  public static let minimumReliableConnectionRSSI = -84

  public static func nameSuggestsGateway(_ localName: String?) -> Bool {
    guard let localName else { return false }
    let normalized = localName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.contains("vhos") || normalized.contains("wican")
  }

  public static func advertisementCanBeGatewayCandidate(
    localName: String?, serviceUUIDs: [String]
  ) -> Bool {
    normalized(serviceUUIDs).contains(vhosServiceUUID) || nameSuggestsGateway(localName)
  }

  public static func provenGatewayKind(
    localName: String?, discoveredServiceUUIDs: [String]
  ) -> GatewayBLEIdentityKind? {
    let services = normalized(discoveredServiceUUIDs)
    if services.contains(vhosServiceUUID) {
      return .vhos
    }
    if services.contains(factoryServiceUUID), nameSuggestsGateway(localName) {
      return .factoryWiCAN
    }
    return nil
  }

  public static func restorationIsAllowed(
    identifier: String, validatedIdentifiers: Set<String>
  ) -> Bool {
    validatedIdentifiers.contains(identifier.uppercased())
  }

  public static func connectionAttemptIsReliable(observedRSSI: Int?) -> Bool {
    guard let observedRSSI else { return true }
    return observedRSSI >= minimumReliableConnectionRSSI
  }

  private static func normalized(_ serviceUUIDs: [String]) -> Set<String> {
    Set(serviceUUIDs.map { $0.uppercased() })
  }
}
