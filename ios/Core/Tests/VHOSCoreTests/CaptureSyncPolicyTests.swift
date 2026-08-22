import Testing
@testable import VHOSCore

@Test func activeRecorderAllowsInventoryButDefersHistoryTransfer() {
    #expect(
        CaptureSyncPolicy.mode(recorderIsLogging: true, suspendedForOTA: false)
            == .inventoryOnlyWhileRecording
    )
}

@Test func stoppedRecorderAllowsHistoryTransfer() {
    #expect(
        CaptureSyncPolicy.mode(recorderIsLogging: false, suspendedForOTA: false)
            == .transferHistory
    )
}

@Test func otaPauseWinsAfterRecorderFlushes() {
    #expect(
        CaptureSyncPolicy.mode(recorderIsLogging: false, suspendedForOTA: true)
            == .otaPaused
    )
}
