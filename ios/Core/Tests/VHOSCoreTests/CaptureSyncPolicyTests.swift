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

@Test func interruptedHistoryRecoveryRequiresExplicitOwnerAction() {
  #expect(CaptureSyncPolicy.permitsAutomaticHistoryRecovery == false)
}

@Test func ownerTriggeredHistoryTransferRequiresConnectedParkedIdleGateway() {
  #expect(
    CaptureSyncPolicy.permitsOwnerTriggeredHistoryTransfer(
      gatewayConnected: true,
      hasCurrentParkedAuthority: true,
      transferActive: false))
  #expect(
    !CaptureSyncPolicy.permitsOwnerTriggeredHistoryTransfer(
      gatewayConnected: false,
      hasCurrentParkedAuthority: true,
      transferActive: false))
  #expect(
    !CaptureSyncPolicy.permitsOwnerTriggeredHistoryTransfer(
      gatewayConnected: true,
      hasCurrentParkedAuthority: false,
      transferActive: false))
  #expect(
    !CaptureSyncPolicy.permitsOwnerTriggeredHistoryTransfer(
      gatewayConnected: true,
      hasCurrentParkedAuthority: true,
      transferActive: true))
}
