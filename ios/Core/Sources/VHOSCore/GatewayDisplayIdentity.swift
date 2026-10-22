import Foundation

/// User-facing names are stable aliases. They never replace the immutable gateway ID in evidence.
public enum GatewayDisplayIdentity {
  public static let obdBaseName = "VHOS-4R-OBD"
  public static let acBaseName = "VHOS-4R-AC"

  public static func obdName(advertisedName: String?, gatewayID: String? = nil) -> String {
    let suffix = hardwareSuffix(fromGatewayID: gatewayID)
      ?? hardwareSuffix(fromAdvertisedName: advertisedName, acceptedPrefixes: [
        "VHOS-4R-OBD-", "VHOS-MRDIY-",
      ])
    return suffix.map { "\(obdBaseName)-\($0)" } ?? obdBaseName
  }

  public static func acName(advertisedName: String?, sourceID: String? = nil) -> String {
    let suffix = hardwareSuffix(fromGatewayID: sourceID)
      ?? hardwareSuffix(fromAdvertisedName: advertisedName, acceptedPrefixes: [
        "VHOS-4R-AC-", "VHOS-AC-",
      ])
    return suffix.map { "\(acBaseName)-\($0)" } ?? acBaseName
  }

  private static func hardwareSuffix(fromGatewayID gatewayID: String?) -> String? {
    guard let gatewayID else { return nil }
    let compact = gatewayID.uppercased().filter { $0.isHexDigit }
    guard compact.count >= 6 else { return nil }
    return String(compact.suffix(6))
  }

  private static func hardwareSuffix(
    fromAdvertisedName advertisedName: String?, acceptedPrefixes: [String]
  ) -> String? {
    guard let advertisedName else { return nil }
    let uppercased = advertisedName.uppercased()
    guard let prefix = acceptedPrefixes.first(where: { uppercased.hasPrefix($0) }) else {
      return nil
    }
    let suffix = String(uppercased.dropFirst(prefix.count))
    guard suffix.count == 6, suffix.allSatisfy(\.isHexDigit) else { return nil }
    return suffix
  }
}
