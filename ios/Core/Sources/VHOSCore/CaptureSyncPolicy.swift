public enum CaptureSyncMode: Equatable, Sendable {
  case otaPaused
  case inventoryOnlyWhileRecording
  case transferHistory
}

public enum CaptureSyncPolicy {
  /// Bulk history recovery is deliberately owner-triggered. Automatically restarting a partial
  /// transfer during BLE restoration competes with service discovery and live evidence, and a
  /// field trace demonstrated that it can leave the gateway GATT server unavailable until a
  /// power cycle. The saved record offset still makes a later manual retry resumable.
  public static let permitsAutomaticHistoryRecovery = false

  /// An explicit retained-history transfer pauses the live recorder and therefore remains a
  /// parked-only gateway control in every build configuration. Debug evidence authority applies
  /// only to app-local import, replay, annotation, and analysis.
  public static func permitsOwnerTriggeredHistoryTransfer(
    gatewayConnected: Bool,
    hasCurrentParkedAuthority: Bool,
    transferActive: Bool
  ) -> Bool {
    gatewayConnected && hasCurrentParkedAuthority && !transferActive
  }

  public static func mode(
    recorderIsLogging: Bool,
    suspendedForOTA: Bool
  ) -> CaptureSyncMode {
    if suspendedForOTA, !recorderIsLogging {
      return .otaPaused
    }
    if recorderIsLogging {
      return .inventoryOnlyWhileRecording
    }
    return .transferHistory
  }
}
