public enum CaptureSyncMode: Equatable, Sendable {
    case otaPaused
    case inventoryOnlyWhileRecording
    case transferHistory
}

public enum CaptureSyncPolicy {
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
