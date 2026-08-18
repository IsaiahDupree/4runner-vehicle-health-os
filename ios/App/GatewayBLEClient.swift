@preconcurrency import CoreBluetooth
import Foundation
import Observation
import OSLog
import VHOSCore

@MainActor
@Observable
final class GatewayBLEClient: NSObject, @preconcurrency CBCentralManagerDelegate
{
  @MainActor
  private final class LinkScopedPeripheralDelegate: NSObject,
    @preconcurrency CBPeripheralDelegate
  {
    weak var owner: GatewayBLEClient?
    let linkSession: UInt64

    init(owner: GatewayBLEClient, linkSession: UInt64) {
      self.owner = owner
      self.linkSession = linkSession
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
      owner?.handleServicesDiscovered(peripheral, error: error, callbackSession: linkSession)
    }

    func peripheral(
      _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
      error: Error?
    ) {
      owner?.handleCharacteristicsDiscovered(
        peripheral, service: service, error: error, callbackSession: linkSession)
    }

    func peripheral(
      _ peripheral: CBPeripheral,
      didUpdateNotificationStateFor characteristic: CBCharacteristic,
      error: Error?
    ) {
      owner?.handleNotificationStateUpdated(
        peripheral, characteristic: characteristic, error: error,
        callbackSession: linkSession)
    }

    func peripheral(
      _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
      error: Error?
    ) {
      owner?.handleValueUpdated(
        peripheral, characteristic: characteristic, error: error,
        callbackSession: linkSession)
    }

    func peripheral(
      _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
      error: Error?
    ) {
      owner?.handleValueWritten(
        peripheral, characteristic: characteristic, error: error,
        callbackSession: linkSession)
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
      owner?.handleRSSIRead(
        peripheral, rssi: RSSI, error: error, callbackSession: linkSession)
    }
  }

  static let shared = GatewayBLEClient()

  private static let logger = Logger(
    subsystem: "com.isaiahdupree.VehicleHealthOS", category: "GatewayBLE")
  private static let connectionTraceRecorder: BLEConnectionTraceRecorder? = {
    do {
      return try BLEConnectionTraceRecorder(
        directory: BLEConnectionTraceRecorder.defaultDirectory())
    } catch {
      logger.error(
        "BLE flight recorder unavailable: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }()
  static let vhosService = CBUUID(string: "33613EB3-FFCA-42D1-83FA-A18F12B3F123")
  static let commandCharacteristic = CBUUID(string: "B3D3279B-0244-4D54-A2AB-A1AB47A5FC0A")
  static let streamCharacteristic = CBUUID(string: "265B90C0-A600-4659-BBBD-5CDA411C49CC")
  static let statusCharacteristic = CBUUID(string: "BCB5699A-A9B4-49B8-B69B-D2DFF19B41A9")
  static let otaStatusCharacteristic = CBUUID(string: "18D21F8E-D190-4DB3-923C-27BBFC355874")
  static let factoryService = CBUUID(string: "FEE0")
  static let factoryCharacteristic = CBUUID(string: "FEE1")
  private static let securityRetryLimit = 30
  private static let handshakeResponseAttemptLimit = 3
  private static let handshakeWriteAckTimeout: Duration = .seconds(2)
  private static let handshakeResponseTimeout: Duration = .seconds(2)
  private static let notificationEnableTimeout: Duration = .seconds(15)
  private static let restoredCleanupTimeout: Duration = .seconds(4)
  private static let captureInitialSyncDelay: Duration = .seconds(3)
  private static let captureChunkInterval: Duration = .milliseconds(500)
  private static let captureChunkResponseTimeout: Duration = .seconds(8)
  private static let autoScanArgument = "--vhos-auto-scan"
  private static let autoScanEnvironmentKey = "VHOS_AUTO_SCAN"
  private static let commissioningTraceEnvironmentKey = "VHOS_COMMISSIONING_TRACE"
  private static let centralRestoreIdentifier =
    "com.isaiahdupree.VehicleHealthOS.central.v3"
  private static let centralRestoreIdentifierKey =
    "vhos.currentCentralRestoreIdentifier.v1"
  private static let validatedPeripheralIdentifiersKey =
    "vhos.validatedGatewayPeripheralIdentifiers.v1"
  private static let handshakeVerifiedPeripheralIdentifierKey =
    "vhos.handshakeVerifiedGatewayPeripheralIdentifier.v1"

  private var central: CBCentralManager!
  private var currentCentralRestoreIdentifier = ""
  private let instanceID = String(UUID().uuidString.prefix(8))
  private var peripheral: CBPeripheral?
  private var command: CBCharacteristic?
  private var factoryReadCharacteristic: CBCharacteristic?
  private var streamDecoder = GatewayFrameStreamDecoder()
  private var sequence: UInt64 = 1
  private var scanRequested = false
  private var scanFallbackTask: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?
  private var serviceDiscoveryTask: Task<Void, Never>?
  private var restoredConnectionTask: Task<Void, Never>?
  private var restoredCleanupTask: Task<Void, Never>?
  private var restoredCleanupGeneration: UInt64 = 0
  private var centralCleanupRecoveryPending = false
  private var handshakeRetryTask: Task<Void, Never>?
  private var handshakeWriteAckTask: Task<Void, Never>?
  private var handshakeResponseTask: Task<Void, Never>?
  private var notificationEnableTask: Task<Void, Never>?
  private var freshCentralRecoveryAttempted = false
  private var reconnectIntentRequested = false
  private var automaticReconnectEnabled = false
  private var userRequestedDisconnect = false
  private var handshakeRequested = false
  private var handshakeSecurityRetryCount = 0
  private var handshakeResponseAttemptCount = 0
  private var handshakeWriteAttemptInFlight: Int?
  private var notificationCharacteristics: [CBUUID: CBCharacteristic] = [:]
  private var notificationSetupInFlight: CBUUID?
  private var notificationRequestSession: UInt64?
  private var notificationPairingPending = false
  private var linkSession: UInt64 = 0
  private var activePeripheralDelegate: LinkScopedPeripheralDelegate?
  private var retiredPeripheralDelegates: [UInt64: LinkScopedPeripheralDelegate] = [:]
  private var retiredRestoredPeripherals: [ObjectIdentifier: CBPeripheral] = [:]
  private var pendingRestoredPeripheral: CBPeripheral?
  private var scanAfterRestorationCleanup = false
  private var pendingCommandChunks: [Data] = []
  private var pendingStaleGATTRescan = false
  private var pendingStaleGATTReason: String?
  private var candidateNameSuggestsGateway = false
  private var candidateAdvertisedVHOSService = false
  private var candidateWasPreviouslyValidated = false
  private let captureStore = CaptureLogStore()
  private let portableFrameStore = PortableFrameStore()
  private var j1979Accumulator = J1979Accumulator()
  private var captureSyncTargets: [CaptureSyncTarget] = []
  private var captureSyncSuspendedForOTA = false
  private var captureSyncTask: Task<Void, Never>?
  private var captureChunkResponseTask: Task<Void, Never>?
  private var lastCaptureSyncFingerprint: String?

  var bluetoothStateDescription = "Initializing"
  var bluetoothReady = false
  var scanActive = false
  var scanMode = "Idle"
  var scanObservationCount: UInt64 = 0
  var lastObservedAdvertisement: String?
  var state: GatewayConnectionState = .disconnected
  var discoveredName: String?
  var discoveredIdentifier: String?
  var discoveredRSSI: Int?
  var peripheralConnected = false
  var gatewayIdentityValidated = false
  var connectedAt: Date?
  var vhosServiceDiscovered = false
  var factoryServiceDiscovered = false
  var commandChannelReady = false
  var streamChannelDiscovered = false
  var streamNotificationsEnabled = false
  var healthChannelDiscovered = false
  var healthNotificationsEnabled = false
  var otaStatusChannelDiscovered = false
  var otaStatusNotificationsEnabled = false
  var decodedFrameCount: UInt64 = 0
  var frameDecodeErrorCount: UInt64 = 0
  var sequenceDiscontinuityCount: UInt64 = 0
  var missingSequenceCount: UInt64 = 0
  var lastReceivedSequence: UInt64?
  var lastFrameReceivedAt: Date?
  var lastHandshakeReceivedAt: Date?
  var lastHealthReceivedAt: Date?
  var lastExperimentResultAt: Date?
  var lastOTAStatusAt: Date?
  var otaStatus: GatewayOTAStatus?
  var commandChunksPending = 0
  var currentSessionResultStartIndex = 0
  var factoryBanner: String?
  var handshake: GatewayHandshake?
  var health: GatewayHealth?
  var experimentResults: [ProtocolExperimentResult] = []
  var captureLogIndex: CaptureLogIndex?
  var latestCANObservation: PassiveCANObservation?
  var recentCANObservations: [PassiveCANObservation] = []
  var captureSessions: [CaptureSessionSummary] = []
  var captureSyncMessage = "Waiting for a gateway capture index."
  var captureDownloadedRecords: UInt64 = 0
  var captureSyncCompletionGeneration: UInt64 = 0
  var portableFrameCount = 0
  var lastEvidenceSyncMessage = "No Android/iPhone evidence sync has run."
  var j1979Availability: [J1979ECUAvailability] = []
  var standardOBDSamples: [J1979StandardSample] = []
  var transportMessage: String?
  var lastTransportFailureAt: Date?
  var lastTransportFailureEvidence: String?
  var verifiedSavedGatewayIdentifier: String?
  var connectionCleanupActive = false
  var automaticReconnectActive = false
  var reconnectAttemptCount = 0

  var bleConnectionTraceSummary: BLEConnectionTraceSummary {
    Self.connectionTraceRecorder?.summary()
      ?? BLEConnectionTraceSummary(recordCount: 0, fileCount: 0, byteCount: 0)
  }

  var canonicalDisplayName: String {
    GatewayDisplayIdentity.obdName(
      advertisedName: discoveredName,
      gatewayID: handshake?.gatewayID)
  }

  var currentSessionExperimentResults: [ProtocolExperimentResult] {
    Array(experimentResults.dropFirst(currentSessionResultStartIndex))
  }

  var hasVerifiedSavedGateway: Bool {
    verifiedSavedGatewayIdentifier != nil
  }

  var applicationSessionHealthy: Bool {
    peripheralConnected && gatewayIdentityValidated && state == .vhosConnected
      && handshake != nil && lastHandshakeReceivedAt != nil && decodedFrameCount > 0
  }

  private override init() {
    super.init()
    currentCentralRestoreIdentifier =
      UserDefaults.standard.string(forKey: Self.centralRestoreIdentifierKey)
      ?? Self.centralRestoreIdentifier
    verifiedSavedGatewayIdentifier = UserDefaults.standard.string(
      forKey: Self.handshakeVerifiedPeripheralIdentifierKey
    ).flatMap { UUID(uuidString: $0)?.uuidString.uppercased() }
    scanRequested = CommandLine.arguments.contains(Self.autoScanArgument)
      || ProcessInfo.processInfo.environment[Self.autoScanEnvironmentKey] == "1"
    reconnectIntentRequested = scanRequested
    // State restoration is required for a bonded gateway, but a physical link inherited from a
    // previous app process is retired before reuse. The saved peripheral identifier and iOS bond
    // survive; a fresh link establishes one current-process delegate, CCCD, and VHOS contract.
    central = CBCentralManager(
      delegate: self,
      queue: .main,
      options: [CBCentralManagerOptionRestoreIdentifierKey: currentCentralRestoreIdentifier]
    )
    portableFrameCount = portableFrameStore.count()
    if scanRequested {
      Self.logger.info("BLE auto-scan requested by commissioning launch")
      trace("AUTO_SCAN_REQUESTED")
    }
    let info = Bundle.main.infoDictionary
    let appVersion = info?["CFBundleShortVersionString"] as? String ?? "unknown"
    let appBuild = info?["CFBundleVersion"] as? String ?? "unknown"
    trace(
      "CLIENT_INITIALIZED restore_identifier=\(currentCentralRestoreIdentifier) app_version=\(appVersion) app_build=\(appBuild) os={\(ProcessInfo.processInfo.operatingSystemVersionString)}"
    )
  }

  func startScan(source: String = "user", skipConnectedRetrieval: Bool = false) {
    reconnectIntentRequested = true
    trace(
      "SCAN_REQUEST source=\(source) state=\(state.rawValue) peripheral=\(peripheral?.identifier.uuidString ?? "none") connected=\(peripheralConnected) active=\(scanActive)"
    )
    if state == .connecting, peripheral != nil {
      Self.commissioningTrace("SCAN_IGNORED reason=gateway-connection-in-progress")
      return
    }
    if pendingStaleGATTRescan {
      transportMessage =
        "Waiting for the stale BLE link to close before scanning for the gateway again…"
      Self.commissioningTrace("SCAN_IGNORED reason=stale-gatt-disconnect-pending")
      return
    }
    if !retiredRestoredPeripherals.isEmpty {
      scanRequested = true
      scanAfterRestorationCleanup = true
      transportMessage =
        "Closing an older restored BLE link before scanning for the gateway…"
      Self.commissioningTrace(
        "SCAN_DEFERRED reason=restoration-cleanup count=\(retiredRestoredPeripherals.count)"
      )
      return
    }
    reconnectTask?.cancel()
    automaticReconnectActive = false
    automaticReconnectEnabled = true
    userRequestedDisconnect = false
    reconnectAttemptCount = 0
    freshCentralRecoveryAttempted = false
    if scanActive, state == .scanning {
      Self.commissioningTrace("SCAN_REENTRY_IGNORED")
      return
    }
    guard !peripheralConnected else {
      transportMessage = "Disconnect the connected gateway before starting another scan."
      return
    }
    scanRequested = true
    guard central.state == .poweredOn else {
      scanActive = false
      transportMessage = "Bluetooth is not powered on."
      return
    }
    if !skipConnectedRetrieval,
      let savedIdentifier = verifiedSavedGatewayIdentifier,
      let savedUUID = UUID(uuidString: savedIdentifier),
      let known = central.retrievePeripherals(withIdentifiers: [savedUUID]).first
    {
      if known.state == .disconnecting {
        retireRestoredPeripheral(known, reason: "saved-gateway-still-disconnecting")
        scanAfterRestorationCleanup = true
        scanRequested = true
        transportMessage =
          "Waiting for the saved gateway link to close before reconnecting…"
        Self.commissioningTrace(
          "KNOWN_GATEWAY_RECONNECT_DEFERRED peripheral=\(peripheralEvidence(known))"
        )
        return
      }
      resetTransportSession()
      scanRequested = false
      scanActive = false
      scanMode = "Saved gateway"
      discoveredName = known.name
      discoveredIdentifier = known.identifier.uuidString
      candidateNameSuggestsGateway = GatewayBLEIdentityPolicy.nameSuggestsGateway(known.name)
      candidateAdvertisedVHOSService = false
      candidateWasPreviouslyValidated = true
      state = .connecting
      transportMessage = "Saved VHOS gateway found; reconnecting…"
      Self.commissioningTrace(
        "KNOWN_GATEWAY_RECONNECT peripheral=\(peripheralEvidence(known)) source=\(source)"
      )
      connect(known)
      return
    }
    if !skipConnectedRetrieval, verifiedSavedGatewayIdentifier != nil {
      Self.commissioningTrace(
        "KNOWN_GATEWAY_RETRIEVAL_EMPTY action=service-scan-fallback source=\(source)"
      )
    }
    let connectedCandidates = skipConnectedRetrieval
      ? []
      : central.retrieveConnectedPeripherals(withServices: [Self.vhosService])
        .filter { $0.state == .connected }
    if connectedCandidates.count > 1 {
      for extra in connectedCandidates {
        retireRestoredPeripheral(extra, reason: "retrieve-connected-ambiguous")
      }
      scanAfterRestorationCleanup = true
      scanRequested = true
      transportMessage =
        "Closing ambiguous system BLE links before selecting the gateway…"
      return
    }
    let connected = connectedCandidates.first(where: isHandshakeVerified)
      ?? (connectedCandidates.count == 1 ? connectedCandidates.first : nil)
    if let connected {
      resetTransportSession()
      scanRequested = false
      scanActive = false
      scanMode = "Existing connection"
      discoveredName = connected.name
      discoveredIdentifier = connected.identifier.uuidString
      candidateNameSuggestsGateway = GatewayBLEIdentityPolicy.nameSuggestsGateway(connected.name)
      candidateAdvertisedVHOSService = true
      candidateWasPreviouslyValidated = isPreviouslyValidated(connected)
      beginServiceDiscovery(connected, source: "retrieve-connected")
      return
    }
    resetTransportSession()
    scanRequested = true
    scanActive = true
    scanMode = "VHOS service filter"
    scanObservationCount = 0
    lastObservedAdvertisement = nil
    state = .scanning
    transportMessage = "Scanning for a WiCAN or VHOS gateway…"
    Self.logger.info("BLE scan started with VHOS service filter")
    Self.commissioningTrace("SCAN_START mode=service-filter")
    central.scanForPeripherals(
      withServices: [Self.vhosService],
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    scanFallbackTask?.cancel()
    scanFallbackTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(5))
      guard let self, !Task.isCancelled, self.scanActive, self.peripheral == nil else { return }
      self.central.stopScan()
      self.scanMode = "Service + name fallback"
      self.transportMessage = "No service match yet; scanning all nearby BLE advertisements…"
      Self.logger.info("BLE scan broadened to all advertisements")
      Self.commissioningTrace("SCAN_FALLBACK observations=\(self.scanObservationCount)")
      self.central.scanForPeripherals(
        withServices: nil,
        options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }
  }

  func disconnect() {
    Self.commissioningTrace(
      "USER_DISCONNECT_INTENT action=\(peripheralConnected ? "disconnect-active-link" : "cancel-connection-flow") state=\(state.rawValue) link_session=\(linkSession) scan_active=\(scanActive) peripheral_connected=\(peripheralConnected) reconnect_active=\(automaticReconnectActive) pairing_pending=\(notificationPairingPending) peripheral={\(activePeripheralEvidence)}"
    )
    pendingStaleGATTRescan = false
    pendingStaleGATTReason = nil
    pendingRestoredPeripheral = nil
    scanAfterRestorationCleanup = false
    userRequestedDisconnect = true
    reconnectIntentRequested = false
    automaticReconnectEnabled = false
    automaticReconnectActive = false
    reconnectTask?.cancel()
    scanRequested = false
    scanFallbackTask?.cancel()
    central.stopScan()
    if let peripheral {
      retireRestoredPeripheral(peripheral, reason: "user-disconnect-or-cancel")
    }
    resetConnection()
    transportMessage = connectionCleanupActive
      ? "Finishing the current BLE link before Reconnect becomes available…"
      : "Gateway disconnected by user."
  }

  func sendSignedExperimentPlan(_ envelope: SignedExperimentPlanEnvelope) throws {
    guard state == .vhosConnected else { throw GatewayBLEError.vhosFirmwareRequired }
    try writeFrame(type: .experimentPlan, payload: envelope.encoded())
  }

  func captureLogExportURL() throws -> URL {
    try captureStore.exportURL()
  }

  func bleConnectionTraceExportURL() throws -> URL {
    guard let recorder = Self.connectionTraceRecorder else {
      throw BLEConnectionTraceError.applicationSupportUnavailable
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "VehicleHealthOS-Evidence", isDirectory: true)
    return try recorder.export(to: directory)
  }

  func refreshCaptureLogIndex() {
    do {
      try writeFrame(type: .captureLogRequest, payload: CaptureLogRequest(operation: .index).encoded())
      captureSyncMessage = "Requesting the gateway capture index…"
    } catch {
      captureSyncMessage = error.localizedDescription
    }
  }

  func setCaptureLogging(_ enabled: Bool) throws {
    captureSyncSuspendedForOTA = !enabled
    if !enabled {
      captureSyncTask?.cancel()
      captureSyncTask = nil
      captureChunkResponseTask?.cancel()
      captureChunkResponseTask = nil
      captureSyncTargets.removeAll()
    }
    try writeFrame(
      type: .captureLogRequest,
      payload: CaptureLogRequest(operation: enabled ? .resume : .pause).encoded()
    )
    captureSyncMessage = enabled
      ? "Resuming the passive flight recorder…"
      : "Pausing and flushing the passive flight recorder for OTA…"
  }

  func activateTemporaryOTANetwork(for package: VerifiedFirmwarePackage) throws {
    otaStatus = nil
    let request = OTAControlRequest(
      packageID: package.manifest.packageID,
      firmwareVersion: package.manifest.firmwareVersion,
      firmwareSHA256: package.manifest.firmwareSHA256,
      firmwareSizeBytes: package.firmware.count,
      approvedAt: Self.timestamp()
    )
    try writeFrame(type: .otaControl, payload: request.encoded())
    transportMessage = "Opening the temporary authenticated OTA network…"
  }

  func cancelTemporaryOTANetwork(for package: VerifiedFirmwarePackage) {
    let request = OTAControlRequest(
      operation: .cancel,
      packageID: package.manifest.packageID,
      firmwareVersion: package.manifest.firmwareVersion,
      firmwareSHA256: package.manifest.firmwareSHA256,
      firmwareSizeBytes: package.firmware.count,
      approvedAt: Self.timestamp()
    )
    try? writeFrame(type: .otaControl, payload: request.encoded())
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard central === self.central else {
      Self.commissioningTrace(
        "STALE_CENTRAL_STATE_IGNORED candidate=\(ObjectIdentifier(central)) active=\(ObjectIdentifier(self.central))"
      )
      return
    }
    bluetoothStateDescription = central.state.description
    bluetoothReady = central.state == .poweredOn
    Self.commissioningTrace(
      "CENTRAL_STATE state=\(central.state.description) scan_requested=\(scanRequested) reconnect_intent=\(reconnectIntentRequested) reconnect_enabled=\(automaticReconnectEnabled) user_disconnected=\(userRequestedDisconnect) cleanup_active=\(connectionCleanupActive)"
    )
    if central.state == .poweredOn {
      if centralCleanupRecoveryPending {
        centralCleanupRecoveryPending = false
        connectionCleanupActive = false
        Self.commissioningTrace(
          "CLEANUP_CENTRAL_RECOVERY_READY reconnect_intent=\(scanRequested && !userRequestedDisconnect)"
        )
      }
      if scanRequested, !userRequestedDisconnect, retiredRestoredPeripherals.isEmpty {
        startScan(source: "bluetooth-powered-on")
      }
      return
    }

    let shouldReconnectWhenPoweredOn = reconnectIntentRequested && !userRequestedDisconnect
    reconnectTask?.cancel()
    scanFallbackTask?.cancel()
    central.stopScan()
    scanActive = false
    scanRequested = shouldReconnectWhenPoweredOn
    automaticReconnectActive = shouldReconnectWhenPoweredOn
    if !centralCleanupRecoveryPending {
      restoredCleanupTask?.cancel()
      restoredCleanupTask = nil
      retiredRestoredPeripherals.removeAll()
      pendingRestoredPeripheral = nil
      scanAfterRestorationCleanup = false
      connectionCleanupActive = false
    }
    resetTransportSession()
    state = shouldReconnectWhenPoweredOn ? .connecting : .disconnected
    transportMessage = shouldReconnectWhenPoweredOn
      ? "Bluetooth is \(central.state.description); reconnecting to the verified gateway when the radio is ready…"
      : "Bluetooth state: \(central.state.description)"
    Self.commissioningTrace(
      "BLUETOOTH_RECONNECT_INTENT preserved=\(shouldReconnectWhenPoweredOn) saved_id=\(verifiedSavedGatewayIdentifier ?? "none")"
    )
  }

  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    guard central === self.central else {
      Self.commissioningTrace(
        "STALE_CENTRAL_RESTORE_IGNORED candidate=\(ObjectIdentifier(central)) active=\(ObjectIdentifier(self.central))"
      )
      return
    }
    let restoredPeripherals =
      (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
    if userRequestedDisconnect {
      for restored in restoredPeripherals {
        retireRestoredPeripheral(restored, reason: "late-restore-after-user-disconnect")
      }
      Self.commissioningTrace(
        "RESTORE_REJECTED reason=user-disconnected count=\(restoredPeripherals.count)"
      )
      return
    }
    if !restoredPeripherals.isEmpty {
      reconnectIntentRequested = true
    }
    let eligible = restoredPeripherals.filter(isHandshakeVerified).sorted {
      restorationStateRank($0.state) < restorationStateRank($1.state)
    }
    let restored = eligible.first
    let extras = restoredPeripherals.filter { candidate in
      guard let restored else { return true }
      return candidate !== restored
    }

    if let active = peripheral {
      for extra in restoredPeripherals where extra !== active {
        retireRestoredPeripheral(extra, reason: "restore-arrived-after-active-selection")
      }
      Self.commissioningTrace(
        "RESTORE_IGNORED reason=active-peripheral-exists active=\(peripheralEvidence(active)) restored_count=\(restoredPeripherals.count)"
      )
      return
    }

    guard let restored else {
      for extra in extras {
        retireRestoredPeripheral(extra, reason: "restore-not-handshake-verified")
      }
      scanRequested = true
      scanAfterRestorationCleanup = !retiredRestoredPeripherals.isEmpty
      transportMessage =
        "Discarded an incomplete restored BLE session; scanning for the VHOS service…"
      Self.commissioningTrace(
        "RESTORE_REJECTED count=\(restoredPeripherals.count) reason=handshake-not-verified cleanup=\(retiredRestoredPeripherals.count)"
      )
      if central.state == .poweredOn, retiredRestoredPeripherals.isEmpty {
        startScan(source: "restore-rejection")
      }
      return
    }

    for extra in extras {
      retireRestoredPeripheral(extra, reason: "restore-extra")
    }
    if !retiredRestoredPeripherals.isEmpty {
      pendingRestoredPeripheral = restored
      scanRequested = false
      scanAfterRestorationCleanup = false
      transportMessage =
        "Closing older restored BLE links before resuming the verified gateway…"
      Self.commissioningTrace(
        "RESTORE_DEFERRED selected=\(peripheralEvidence(restored)) cleanup=\(retiredRestoredPeripherals.count)"
      )
      return
    }
    resumeRestoredPeripheral(restored)
  }

  private func resumeRestoredPeripheral(_ restored: CBPeripheral) {
    reconnectIntentRequested = true
    candidateNameSuggestsGateway = GatewayBLEIdentityPolicy.nameSuggestsGateway(restored.name)
    candidateAdvertisedVHOSService = false
    candidateWasPreviouslyValidated = true
    if restored.state == .connected {
      automaticReconnectEnabled = true
      userRequestedDisconnect = false
      scanRequested = true
      scanAfterRestorationCleanup = true
      discoveredName = restored.name
      discoveredIdentifier = restored.identifier.uuidString
      state = .connecting
      transportMessage =
        "Closing the link inherited from the previous app process before reconnecting…"
      Self.commissioningTrace(
        "RESTORE_CONNECTED_RETIRED peripheral=\(peripheralEvidence(restored)) action=fresh-physical-link-preserve-bond"
      )
      retireRestoredPeripheral(restored, reason: "restore-connected-from-previous-process")
      return
    }
    if restored.state == .connecting {
      automaticReconnectEnabled = true
      userRequestedDisconnect = false
      scanRequested = true
      scanAfterRestorationCleanup = true
      discoveredName = restored.name
      discoveredIdentifier = restored.identifier.uuidString
      state = .connecting
      transportMessage =
        "Closing the in-progress link inherited from the previous app process before reconnecting…"
      Self.commissioningTrace(
        "RESTORE_CONNECTING_RETIRED peripheral=\(peripheralEvidence(restored)) action=fresh-physical-link-preserve-bond"
      )
      retireRestoredPeripheral(restored, reason: "restore-connecting-from-previous-process")
      return
    }
    if restored.state == .disconnecting {
      scanRequested = true
      scanAfterRestorationCleanup = true
      transportMessage =
        "Waiting for the restored gateway link to close before reconnecting…"
      Self.commissioningTrace(
        "RESTORE_DISCONNECTING_DEFERRED peripheral=\(peripheralEvidence(restored))"
      )
      retireRestoredPeripheral(restored, reason: "restore-still-disconnecting")
      return
    }
    if scanRequested {
      Self.commissioningTrace(
        "RESTORE_SKIPPED_FOR_SCAN id=\(restored.identifier.uuidString) state=\(restored.state.rawValue)"
      )
      return
    }
    peripheral = restored
    automaticReconnectEnabled = true
    userRequestedDisconnect = false
    discoveredName = restored.name
    discoveredIdentifier = restored.identifier.uuidString
    state = .connecting
    transportMessage = "Restoring the paired gateway connection…"
    connect(restored)
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi: NSNumber
  ) {
    guard central === self.central else {
      Self.commissioningTrace(
        "STALE_CENTRAL_DISCOVERY_IGNORED candidate=\(ObjectIdentifier(central)) active=\(ObjectIdentifier(self.central))"
      )
      return
    }
    guard scanActive, scanRequested, state == .scanning, !userRequestedDisconnect,
      !connectionCleanupActive
    else {
      Self.commissioningTrace(
        "STALE_SCAN_DISCOVERY_IGNORED scan_active=\(scanActive) scan_requested=\(scanRequested) state=\(state.rawValue) user_disconnected=\(userRequestedDisconnect) cleanup=\(connectionCleanupActive) peripheral=\(peripheralEvidence(peripheral))"
      )
      return
    }
    let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
    let overflow = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
    let solicited = advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID] ?? []
    let visibleServices = advertised + overflow + solicited
    let name =
      (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
    scanObservationCount &+= 1
    let serviceDescription = visibleServices.map(\.uuidString).joined(separator: ",")
    lastObservedAdvertisement = name.isEmpty
      ? (serviceDescription.isEmpty ? peripheral.identifier.uuidString : serviceDescription)
      : name
    let supported = GatewayBLEIdentityPolicy.advertisementCanBeGatewayCandidate(
      localName: name, serviceUUIDs: visibleServices.map(\.uuidString))
    if supported || scanObservationCount.isMultiple(of: 25) {
      Self.logger.info(
        "BLE observation count=\(self.scanObservationCount) name=\(name, privacy: .public) services=\(serviceDescription, privacy: .public) supported=\(supported)"
      )
    }
    guard supported else { return }
    if retiredRestoredPeripherals[ObjectIdentifier(peripheral)] != nil {
      Self.commissioningTrace(
        "RETIRED_DISCOVERY_IGNORED peripheral=\(peripheralEvidence(peripheral))"
      )
      return
    }
    if let active = self.peripheral, active !== peripheral {
      Self.commissioningTrace(
        "PARALLEL_DISCOVERY_IGNORED active=\(peripheralEvidence(active)) candidate=\(peripheralEvidence(peripheral))"
      )
      return
    }
    central.stopScan()
    scanFallbackTask?.cancel()
    scanRequested = false
    scanActive = false
    scanMode = "Matched"
    self.peripheral = peripheral
    discoveredName = name.isEmpty ? nil : name
    discoveredIdentifier = peripheral.identifier.uuidString
    discoveredRSSI = rssi.intValue == 127 ? nil : rssi.intValue
    candidateNameSuggestsGateway = GatewayBLEIdentityPolicy.nameSuggestsGateway(name)
    candidateAdvertisedVHOSService = visibleServices.contains(Self.vhosService)
    candidateWasPreviouslyValidated = isPreviouslyValidated(peripheral)
    state = .connecting
    transportMessage = "Gateway found; opening BLE link…"
    Self.logger.info(
      "Supported gateway selected name=\(self.discoveredName ?? "unknown", privacy: .public) rssi=\(rssi.intValue)"
    )
    Self.commissioningTrace(
      "GATEWAY_MATCH name=\(self.discoveredName ?? "unknown") rssi=\(rssi.intValue == 127 ? "unavailable" : String(rssi.intValue))"
    )
    connect(peripheral)
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard central === self.central else {
      Self.commissioningTrace(
        "STALE_CENTRAL_CONNECT_IGNORED candidate=\(ObjectIdentifier(central)) active=\(ObjectIdentifier(self.central)) peripheral=\(peripheralEvidence(peripheral))"
      )
      central.cancelPeripheralConnection(peripheral)
      return
    }
    if retiredRestoredPeripherals[ObjectIdentifier(peripheral)] != nil {
      Self.commissioningTrace(
        "RETIRED_LINK_CONNECTED_CANCEL peripheral=\(peripheralEvidence(peripheral))"
      )
      central.cancelPeripheralConnection(peripheral)
      return
    }
    guard isActivePeripheral(peripheral) else {
      Self.commissioningTrace(
        "STALE_LINK_CONNECTED_IGNORED peripheral=\(peripheralEvidence(peripheral)) active=\(activePeripheralEvidence)"
      )
      central.cancelPeripheralConnection(peripheral)
      return
    }
    beginServiceDiscovery(peripheral, source: "did-connect")
  }

  func centralManager(
    _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
  ) {
    guard central === self.central else {
      Self.commissioningTrace(
        "STALE_CENTRAL_CONNECT_FAILURE_IGNORED candidate=\(ObjectIdentifier(central)) active=\(ObjectIdentifier(self.central)) peripheral=\(peripheralEvidence(peripheral))"
      )
      return
    }
    if peripheralConnected, isActivePeripheral(peripheral) {
      Self.commissioningTrace(
        "STALE_CONNECT_FAILURE_IGNORED reason=current-link-already-connected peripheral=\(peripheralEvidence(peripheral))"
      )
      return
    }
    if completeRetiredPeripheral(peripheral, event: "connect-failure", error: error) { return }
    guard isActivePeripheral(peripheral) else {
      Self.commissioningTrace(
        "STALE_LINK_FAILURE_IGNORED peripheral=\(peripheralEvidence(peripheral)) active=\(activePeripheralEvidence)"
      )
      return
    }
    if pendingStaleGATTRescan {
      completeStaleGATTRecovery(after: peripheral, event: "connect-failure")
      return
    }
    let failure = Self.errorEvidence(error)
    recordTransportFailure(error, event: "link-connect-failed")
    Self.commissioningTrace("LINK_FAILED_DETAIL error={\(failure)}")
    if isPeerPairingInformationRemoved(error), !freshCentralRecoveryAttempted {
      rebuildCentralForFreshPairing()
      return
    }
    if automaticReconnectEnabled, !userRequestedDisconnect {
      scheduleReconnect(to: peripheral, error: error)
      return
    }
    scanActive = false
    state = .failed
    transportMessage = connectionFailureMessage(error, fallback: "Gateway connection failed.")
    Self.logger.error("ESP32 BLE connection failed: \(self.transportMessage ?? "unknown", privacy: .public)")
    Self.commissioningTrace("LINK_FAILED reason=\(transportMessage ?? "unknown")")
  }

  func centralManager(
    _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
  ) {
    guard central === self.central else {
      Self.commissioningTrace(
        "STALE_CENTRAL_DISCONNECT_IGNORED candidate=\(ObjectIdentifier(central)) active=\(ObjectIdentifier(self.central)) peripheral=\(peripheralEvidence(peripheral))"
      )
      return
    }
    if completeRetiredPeripheral(peripheral, event: "disconnect", error: error) { return }
    if peripheralConnected, isActivePeripheral(peripheral), peripheral.state == .connected {
      Self.commissioningTrace(
        "STALE_LEGACY_DISCONNECT_IGNORED reason=current-link-still-connected link_session=\(linkSession)"
      )
      return
    }
    handleDisconnect(peripheral, isSystemReconnecting: false, error: error)
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    timestamp: CFAbsoluteTime,
    isReconnecting: Bool,
    error: Error?
  ) {
    guard central === self.central else {
      Self.commissioningTrace(
        "STALE_CENTRAL_DISCONNECT_IGNORED candidate=\(ObjectIdentifier(central)) active=\(ObjectIdentifier(self.central)) peripheral=\(peripheralEvidence(peripheral))"
      )
      return
    }
    if completeRetiredPeripheral(peripheral, event: "disconnect", error: error) { return }
    if let connectedAt,
      Date(timeIntervalSinceReferenceDate: timestamp) < connectedAt
    {
      Self.commissioningTrace(
        "STALE_TIMESTAMPED_DISCONNECT_IGNORED callback_timestamp=\(timestamp) connected_at=\(connectedAt.timeIntervalSinceReferenceDate) link_session=\(linkSession)"
      )
      return
    }
    handleDisconnect(peripheral, isSystemReconnecting: isReconnecting, error: error)
  }

  private func handleServicesDiscovered(
    _ peripheral: CBPeripheral, error: Error?, callbackSession: UInt64
  ) {
    guard acceptsPeripheralCallback(
      peripheral, callbackSession: callbackSession, event: "service-discovery")
    else { return }
    serviceDiscoveryTask?.cancel()
    if let error {
      recordTransportFailure(error, event: "service-discovery-failed")
      Self.commissioningTrace(
        "SERVICE_DISCOVERY_FAILED link_session=\(linkSession) error={\(Self.errorEvidence(error))}"
      )
      refreshStaleGATTCandidate(
        peripheral,
        reason: "Gateway services did not respond; scanning for its current BLE identity…")
      return
    }
    processDiscoveredServices(
      peripheral, services: peripheral.services ?? [], source: "callback",
      callbackSession: callbackSession)
  }

  private func processDiscoveredServices(
    _ peripheral: CBPeripheral, services: [CBService], source: String,
    callbackSession: UInt64
  ) {
    guard acceptsPeripheralCallback(
      peripheral, callbackSession: callbackSession, event: "process-services-\(source)")
    else { return }
    Self.commissioningTrace(
      "SERVICES_DISCOVERED source=\(source) uuids=\(services.map { $0.uuid.uuidString }.joined(separator: ","))"
    )
    let kind = GatewayBLEIdentityPolicy.provenGatewayKind(
      localName: discoveredName ?? peripheral.name,
      discoveredServiceUUIDs: services.map { $0.uuid.uuidString })
    guard let kind else {
      rejectCandidateAndResumeScanning(
        peripheral, reason: "Connected BLE device is not a verified VHOS/WiCAN gateway.")
      return
    }
    gatewayIdentityValidated = true
    rememberValidated(peripheral)
    for service in services {
      if kind == .vhos, service.uuid == Self.vhosService {
        vhosServiceDiscovered = true
        if let characteristics = service.characteristics, !characteristics.isEmpty {
          processDiscoveredCharacteristics(
            peripheral, service: service, characteristics: characteristics, source: "cache",
            callbackSession: callbackSession)
        } else {
          peripheral.discoverCharacteristics(
            [
              Self.commandCharacteristic, Self.streamCharacteristic, Self.statusCharacteristic,
              Self.otaStatusCharacteristic,
            ],
            for: service
          )
        }
      } else if kind == .factoryWiCAN, service.uuid == Self.factoryService {
        factoryServiceDiscovered = true
        if let characteristics = service.characteristics, !characteristics.isEmpty {
          processDiscoveredCharacteristics(
            peripheral, service: service, characteristics: characteristics, source: "cache",
            callbackSession: callbackSession)
        } else {
          peripheral.discoverCharacteristics([Self.factoryCharacteristic], for: service)
        }
      }
    }
    if vhosServiceDiscovered || factoryServiceDiscovered {
      armGATTDiscoveryTimeout(peripheral, phase: "characteristics")
    }
  }

  private func handleCharacteristicsDiscovered(
    _ peripheral: CBPeripheral, service: CBService, error: Error?,
    callbackSession: UInt64
  ) {
    guard acceptsPeripheralCallback(
      peripheral, callbackSession: callbackSession, event: "characteristic-discovery")
    else { return }
    serviceDiscoveryTask?.cancel()
    if let error {
      recordTransportFailure(error, event: "characteristic-discovery-failed")
      Self.commissioningTrace(
        "CHARACTERISTICS_FAILED service=\(service.uuid.uuidString) link_session=\(linkSession) error={\(Self.errorEvidence(error))}"
      )
      refreshStaleGATTCandidate(
        peripheral,
        reason: "Gateway characteristics did not respond; scanning for its current BLE identity…")
      return
    }
    processDiscoveredCharacteristics(
      peripheral, service: service, characteristics: service.characteristics ?? [], source: "callback",
      callbackSession: callbackSession)
  }

  private func processDiscoveredCharacteristics(
    _ peripheral: CBPeripheral, service: CBService, characteristics: [CBCharacteristic],
    source: String, callbackSession: UInt64
  ) {
    guard acceptsPeripheralCallback(
      peripheral, callbackSession: callbackSession, event: "process-characteristics-\(source)")
    else { return }
    for characteristic in characteristics {
      switch characteristic.uuid {
      case Self.commandCharacteristic:
        command = characteristic
        commandChannelReady = characteristic.properties.contains(.write)
      case Self.streamCharacteristic:
        streamChannelDiscovered = true
        streamNotificationsEnabled = false
        notificationCharacteristics[characteristic.uuid] = characteristic
      case Self.statusCharacteristic:
        healthChannelDiscovered = true
        healthNotificationsEnabled = streamNotificationsEnabled
      case Self.otaStatusCharacteristic:
        otaStatusChannelDiscovered = true
        otaStatusNotificationsEnabled = streamNotificationsEnabled
      case Self.factoryCharacteristic:
        factoryReadCharacteristic = characteristic
        state = .factoryCompatible
        factoryBanner =
          "Factory WiCAN BLE service detected. Install the VHOS firmware fork before vehicle experiments."
        if characteristic.properties.contains(.read) { peripheral.readValue(for: characteristic) }
      default:
        break
      }
    }
    Self.commissioningTrace(
      "CHARACTERISTICS_DISCOVERED source=\(source) service=\(service.uuid.uuidString) count=\(characteristics.count)"
    )
    if service.uuid == Self.vhosService {
      enableNextNotificationIfNeeded(on: peripheral, callbackSession: callbackSession)
    }
  }

  /// All framed outbound traffic is multiplexed over the evidence stream. A single encrypted CCCD
  /// avoids losing later notification requests while Just Works pairing is still in flight. Health
  /// and OTA remain distinct, CRC-protected message types within that shared transport.
  private func enableNextNotificationIfNeeded(
    on peripheral: CBPeripheral, callbackSession: UInt64
  ) {
    guard acceptsPeripheralCallback(
      peripheral, callbackSession: callbackSession, event: "notification-enable-next")
    else { return }
    guard notificationSetupInFlight == nil else { return }

    let orderedUUIDs = [Self.streamCharacteristic]
    for uuid in orderedUUIDs {
      guard let characteristic = notificationCharacteristics[uuid] else { return }
      guard notificationRequestSession != linkSession else {
        Self.commissioningTrace(
          "SUBSCRIBE_DUPLICATE_SUPPRESSED uuid=\(uuid.uuidString) link_session=\(linkSession)"
        )
        return
      }
      notificationSetupInFlight = uuid
      notificationRequestSession = linkSession
      notificationPairingPending = true
      Self.commissioningTrace(
        "SUBSCRIBE_REQUEST uuid=\(uuid.uuidString) link_session=\(linkSession) peripheral=\(peripheralEvidence(peripheral)) attempt=1"
      )
      peripheral.setNotifyValue(true, for: characteristic)
      armNotificationEnableWatchdog(
        on: peripheral, characteristic: characteristic, callbackSession: callbackSession)
      return
    }
    requestHandshakeIfReady()
  }

  private func armNotificationEnableWatchdog(
    on peripheral: CBPeripheral, characteristic: CBCharacteristic,
    callbackSession: UInt64
  ) {
    notificationEnableTask?.cancel()
    Self.commissioningTrace(
      "SUBSCRIBE_WATCHDOG_ARMED uuid=\(characteristic.uuid.uuidString) link_session=\(callbackSession) timeout_seconds=15"
    )
    notificationEnableTask = Task { [weak self, weak peripheral, weak characteristic] in
      try? await Task.sleep(for: Self.notificationEnableTimeout)
      guard !Task.isCancelled, let self, let peripheral, let characteristic,
        self.acceptsPeripheralCallback(
          peripheral, callbackSession: callbackSession, event: "notification-watchdog"),
        self.notificationRequestSession == callbackSession,
        self.notificationSetupInFlight == characteristic.uuid,
        self.notificationCharacteristics[characteristic.uuid] === characteristic,
        !self.streamNotificationsEnabled
      else { return }
      self.notificationEnableTask = nil
      self.notificationPairingPending = false
      self.notificationSetupInFlight = nil
      self.reconnectIntentRequested = true
      self.automaticReconnectEnabled = true
      self.automaticReconnectActive = false
      self.scanAfterRestorationCleanup = true
      self.lastTransportFailureAt = Date()
      self.lastTransportFailureEvidence =
        "notification-enable-timeout: uuid=\(characteristic.uuid.uuidString) link_session=\(callbackSession)"
      Self.commissioningTrace(
        "SUBSCRIBE_WATCHDOG_TIMEOUT uuid=\(characteristic.uuid.uuidString) link_session=\(callbackSession) action=retire-link-for-automatic-reconnect"
      )
      self.retireRestoredPeripheral(peripheral, reason: "notification-enable-timeout")
      self.resetTransportSession()
      self.state = .degraded
      self.transportMessage = self.connectionCleanupActive
        ? "The encrypted stream did not confirm. Closing this BLE link before reconnecting automatically…"
        : "The encrypted stream did not confirm. Reconnecting automatically…"
    }
  }

  private func failNotificationSetup(
    on peripheral: CBPeripheral, callbackSession: UInt64, reason: String,
    evidence: String
  ) {
    guard acceptsPeripheralCallback(
      peripheral, callbackSession: callbackSession, event: "notification-failure")
    else { return }
    notificationEnableTask?.cancel()
    notificationEnableTask = nil
    captureSyncTask?.cancel()
    captureSyncTask = nil
    captureChunkResponseTask?.cancel()
    captureChunkResponseTask = nil
    notificationPairingPending = false
    notificationSetupInFlight = nil
    reconnectIntentRequested = false
    automaticReconnectEnabled = false
    automaticReconnectActive = false
    lastTransportFailureAt = Date()
    lastTransportFailureEvidence = "\(evidence) link_session=\(callbackSession)"
    Self.commissioningTrace(
      "SUBSCRIBE_LINK_RETIRED link_session=\(callbackSession) reason=\(evidence) action=explicit-reconnect"
    )
    retireRestoredPeripheral(peripheral, reason: evidence)
    resetTransportSession()
    state = .degraded
    transportMessage = connectionCleanupActive
      ? "\(reason). Finishing this BLE link before Reconnect becomes available…"
      : "\(reason). Select Reconnect to start one clean session."
  }

  private func updateNotificationState(for characteristic: CBCharacteristic) {
    switch characteristic.uuid {
    case Self.streamCharacteristic:
      streamNotificationsEnabled = characteristic.isNotifying
      healthNotificationsEnabled = characteristic.isNotifying
      otaStatusNotificationsEnabled = characteristic.isNotifying
    case Self.statusCharacteristic:
      healthNotificationsEnabled = characteristic.isNotifying
    case Self.otaStatusCharacteristic:
      otaStatusNotificationsEnabled = characteristic.isNotifying
    default:
      break
    }
  }

  private func handleNotificationStateUpdated(
    _ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?,
    callbackSession: UInt64
  ) {
    guard acceptsPeripheralCallback(
      peripheral, callbackSession: callbackSession, event: "notification-state")
    else { return }
    if characteristic.uuid == Self.streamCharacteristic,
      let expected = notificationCharacteristics[characteristic.uuid], expected !== characteristic
    {
      Self.commissioningTrace(
        "STALE_SUBSCRIBE_CHARACTERISTIC_IGNORED uuid=\(characteristic.uuid.uuidString) link_session=\(linkSession)"
      )
      return
    }
    if characteristic.uuid == Self.streamCharacteristic,
      notificationRequestSession == callbackSession,
      notificationSetupInFlight == nil,
      streamNotificationsEnabled,
      error != nil || !characteristic.isNotifying
    {
      failNotificationSetup(
        on: peripheral, callbackSession: callbackSession,
        reason: "The encrypted stream stopped notifying",
        evidence: "notification-disabled-after-enable: \(Self.errorEvidence(error))")
      return
    }
    guard notificationRequestSession == callbackSession,
      notificationSetupInFlight == characteristic.uuid
    else {
      Self.commissioningTrace(
        "STALE_SUBSCRIBE_TOKEN_IGNORED uuid=\(characteristic.uuid.uuidString) callback_session=\(callbackSession) request_session=\(notificationRequestSession.map(String.init) ?? "none") in_flight=\(notificationSetupInFlight?.uuidString ?? "none")"
      )
      return
    }
    notificationEnableTask?.cancel()
    notificationEnableTask = nil
    if let error {
      notificationPairingPending = false
      if notificationSetupInFlight == characteristic.uuid {
        notificationSetupInFlight = nil
      }
      let evidence = Self.errorEvidence(error)
      recordTransportFailure(error, event: "stream-subscribe-failed")
      Self.commissioningTrace(
        "SUBSCRIBE_FAILED uuid=\(characteristic.uuid.uuidString) link_session=\(linkSession) error={\(evidence)}"
      )
      let reason = isSecurityNegotiationError(error)
        ? "Secure BLE setup did not complete"
        : "BLE notification setup failed (\(Self.errorSymbol(error))): \(error.localizedDescription)"
      failNotificationSetup(
        on: peripheral, callbackSession: callbackSession, reason: reason,
        evidence: "notification-enable-failed: \(evidence)")
      return
    }
    notificationPairingPending = false
    updateNotificationState(for: characteristic)
    if notificationSetupInFlight == characteristic.uuid {
      notificationSetupInFlight = nil
    }
    Self.commissioningTrace(
      "SUBSCRIBE_READY uuid=\(characteristic.uuid.uuidString) enabled=\(characteristic.isNotifying) link_session=\(linkSession)"
    )
    guard characteristic.isNotifying || characteristic.uuid != Self.streamCharacteristic else {
      transportMessage =
        "The encrypted stream did not enable. Reconnecting without duplicating the request…"
      Self.commissioningTrace(
        "SUBSCRIBE_DISABLED_UNEXPECTED action=cancel-link link_session=\(linkSession)"
      )
      failNotificationSetup(
        on: peripheral, callbackSession: callbackSession,
        reason: "The encrypted stream did not enable",
        evidence: "notification-enable-disabled")
      return
    }
    if characteristic.uuid == Self.streamCharacteristic, characteristic.isNotifying {
      requestHandshakeIfReady()
    } else {
      enableNextNotificationIfNeeded(on: peripheral, callbackSession: callbackSession)
    }
  }

  private func handleValueUpdated(
    _ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?,
    callbackSession: UInt64
  ) {
    guard acceptsPeripheralCallback(
      peripheral, callbackSession: callbackSession, event: "value-update")
    else { return }
    let isCurrentStream = characteristic.uuid == Self.streamCharacteristic
      && notificationCharacteristics[Self.streamCharacteristic] === characteristic
      && notificationRequestSession == callbackSession
      && streamNotificationsEnabled
    let isCurrentFactory = characteristic.uuid == Self.factoryCharacteristic
      && factoryServiceDiscovered && factoryReadCharacteristic === characteristic
    guard isCurrentStream || isCurrentFactory else {
      Self.commissioningTrace(
        "STALE_OR_UNEXPECTED_VALUE_IGNORED uuid=\(characteristic.uuid.uuidString) link_session=\(linkSession) stream_confirmed=\(streamNotificationsEnabled)"
      )
      return
    }
    if characteristic.uuid == Self.streamCharacteristic,
      let expected = notificationCharacteristics[characteristic.uuid], expected !== characteristic
    {
      Self.commissioningTrace(
        "STALE_VALUE_CHARACTERISTIC_IGNORED uuid=\(characteristic.uuid.uuidString) link_session=\(linkSession)"
      )
      return
    }
    if let error {
      recordTransportFailure(error, event: "notification-value-failed")
      transportMessage =
        "Gateway stream read failed (\(Self.errorSymbol(error))): \(error.localizedDescription)"
      Self.commissioningTrace(
        "VALUE_UPDATE_FAILED uuid=\(characteristic.uuid.uuidString) link_session=\(linkSession) error={\(Self.errorEvidence(error))}"
      )
      return
    }
    guard let value = characteristic.value else { return }
    if characteristic.uuid == Self.factoryCharacteristic {
      if let text = String(data: value, encoding: .utf8), !text.isEmpty { factoryBanner = text }
      return
    }
    do {
      for frame in try streamDecoder.append(value) {
        record(frame)
        try consume(frame)
      }
    } catch {
      frameDecodeErrorCount &+= 1
      state = .degraded
      transportMessage = error.localizedDescription
      Self.commissioningTrace(
        "FRAME_OR_CONTRACT_DECODE_FAILED characteristic=\(characteristic.uuid.uuidString) error=\(error.localizedDescription)"
      )
    }
  }

  private func handleValueWritten(
    _ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?,
    callbackSession: UInt64
  ) {
    guard acceptsPeripheralCallback(
      peripheral, callbackSession: callbackSession, event: "value-write"),
      characteristic.uuid == Self.commandCharacteristic,
      command === characteristic
    else {
      Self.commissioningTrace(
        "STALE_WRITE_RESULT_IGNORED peripheral=\(peripheralEvidence(peripheral)) uuid=\(characteristic.uuid.uuidString)"
      )
      return
    }
    handshakeRetryTask?.cancel()
    handshakeRetryTask = nil
    if let error {
      handshakeWriteAckTask?.cancel()
      handshakeWriteAckTask = nil
      handshakeResponseTask?.cancel()
      handshakeResponseTask = nil
      handshakeWriteAttemptInFlight = nil
      pendingCommandChunks.removeAll()
      commandChunksPending = 0
      if captureChunkResponseTask != nil, handshake != nil {
        captureChunkResponseTask?.cancel()
        captureChunkResponseTask = nil
        recordTransportFailure(error, event: "capture-sync-write-failed")
        captureSyncMessage =
          "Recent-log sync paused after a gateway write error; live health remains connected."
        Self.commissioningTrace(
          "CAPTURE_SYNC_PAUSED reason=write-error link_session=\(linkSession) error={\(Self.errorEvidence(error))}"
        )
        return
      }
      if isSecurityNegotiationError(error),
        handshakeSecurityRetryCount < Self.securityRetryLimit
      {
        handshakeSecurityRetryCount += 1
        handshakeRequested = false
        transportMessage =
          "Securing BLE link; handshake retry \(handshakeSecurityRetryCount)/\(Self.securityRetryLimit)…"
        Self.logger.info(
          "Waiting for BLE encryption before handshake retry \(self.handshakeSecurityRetryCount)"
        )
        let retrySession = linkSession
        handshakeRetryTask = Task { [weak self, weak peripheral] in
          try? await Task.sleep(for: .seconds(1))
          guard !Task.isCancelled, let self, let peripheral,
            self.linkSession == retrySession, self.isActivePeripheral(peripheral),
            self.peripheralConnected
          else { return }
          self.handshakeRetryTask = nil
          self.requestHandshakeIfReady()
        }
        return
      }
      recordTransportFailure(error, event: "command-write-failed")
      Self.commissioningTrace(
        "COMMAND_WRITE_FAILED link_session=\(linkSession) error={\(Self.errorEvidence(error))}"
      )
      state = .degraded
      transportMessage =
        "Gateway command failed (\(Self.errorSymbol(error))): \(error.localizedDescription)"
      return
    }
    if !pendingCommandChunks.isEmpty { pendingCommandChunks.removeFirst() }
    commandChunksPending = pendingCommandChunks.count
    if !pendingCommandChunks.isEmpty {
      sendNextCommandChunk()
      if let attempt = handshakeWriteAttemptInFlight {
        armHandshakeWriteAckWatchdog(on: peripheral, attempt: attempt)
      }
      return
    }
    if let attempt = handshakeWriteAttemptInFlight, handshakeRequested, handshake == nil {
      handshakeWriteAckTask?.cancel()
      handshakeWriteAckTask = nil
      handshakeWriteAttemptInFlight = nil
      handshakeResponseAttemptCount = attempt
      Self.commissioningTrace(
        "HANDSHAKE_REQUEST_WRITE_ACK link_session=\(linkSession) attempt=\(attempt)"
      )
      armHandshakeResponseWatchdog(on: peripheral, attempt: attempt)
    }
  }

  private func requestHandshake() {
    do {
      guard let peripheral, isActivePeripheral(peripheral), peripheralConnected else {
        throw GatewayBLEError.commandChannelUnavailable
      }
      guard pendingCommandChunks.isEmpty, handshakeWriteAttemptInFlight == nil,
        handshakeResponseTask == nil
      else {
        Self.commissioningTrace(
          "HANDSHAKE_REQUEST_SUPPRESSED reason=prior-attempt-unfinished link_session=\(linkSession) chunks=\(pendingCommandChunks.count) write_attempt=\(handshakeWriteAttemptInFlight.map(String.init) ?? "none") response_waiting=\(handshakeResponseTask != nil)"
        )
        return
      }
      let attempt = handshakeResponseAttemptCount + 1
      guard attempt <= Self.handshakeResponseAttemptLimit else { return }
      Self.commissioningTrace(
        "HANDSHAKE_REQUEST_WRITE_BEGIN link_session=\(linkSession) attempt=\(attempt)"
      )
      let payload = try VHOSJSON.encoder().encode(HandshakeRequest())
      handshakeWriteAttemptInFlight = attempt
      try writeFrame(type: .handshake, payload: payload)
      armHandshakeWriteAckWatchdog(on: peripheral, attempt: attempt)
    } catch {
      handshakeWriteAckTask?.cancel()
      handshakeWriteAckTask = nil
      handshakeWriteAttemptInFlight = nil
      handshakeRequested = false
      state = .failed
      transportMessage = error.localizedDescription
      Self.commissioningTrace(
        "HANDSHAKE_REQUEST_WRITE_SETUP_FAILED link_session=\(linkSession) error={\(Self.errorEvidence(error))}"
      )
    }
  }

  private func requestHandshakeIfReady() {
    guard
      handshake == nil,
      !handshakeRequested,
      handshakeWriteAttemptInFlight == nil,
      handshakeResponseTask == nil,
      pendingCommandChunks.isEmpty,
      command != nil,
      streamNotificationsEnabled,
      healthNotificationsEnabled,
      otaStatusNotificationsEnabled
    else { return }
    handshakeRequested = true
    requestHandshake()
  }

  private func armHandshakeWriteAckWatchdog(on peripheral: CBPeripheral, attempt: Int) {
    handshakeWriteAckTask?.cancel()
    let writeSession = linkSession
    Self.commissioningTrace(
      "HANDSHAKE_WRITE_ACK_WATCHDOG_ARMED link_session=\(writeSession) attempt=\(attempt) outstanding_chunks=\(pendingCommandChunks.count) timeout_seconds=2"
    )
    handshakeWriteAckTask = Task { [weak self, weak peripheral] in
      try? await Task.sleep(for: Self.handshakeWriteAckTimeout)
      guard !Task.isCancelled, let self, let peripheral,
        self.linkSession == writeSession, self.isActivePeripheral(peripheral),
        self.peripheralConnected, self.handshake == nil,
        self.handshakeWriteAttemptInFlight == attempt,
        !self.pendingCommandChunks.isEmpty
      else { return }
      self.handshakeWriteAckTask = nil
      let outstandingChunks = self.pendingCommandChunks.count
      self.pendingCommandChunks.removeAll()
      self.commandChunksPending = 0
      self.handshakeWriteAttemptInFlight = nil
      self.handshakeRequested = false
      Self.commissioningTrace(
        "HANDSHAKE_WRITE_ACK_TIMEOUT link_session=\(writeSession) attempt=\(attempt) outstanding_chunks=\(outstandingChunks) action=cancel-link-no-retry"
      )
      self.failHandshakeWriteAcknowledgement(on: peripheral, attempt: attempt)
    }
  }

  private func armHandshakeResponseWatchdog(on peripheral: CBPeripheral, attempt: Int) {
    handshakeResponseTask?.cancel()
    let responseSession = linkSession
    Self.commissioningTrace(
      "HANDSHAKE_REQUEST_QUEUED link_session=\(responseSession) attempt=\(attempt) limit=\(Self.handshakeResponseAttemptLimit) timeout_seconds=2"
    )
    handshakeResponseTask = Task { [weak self, weak peripheral] in
      try? await Task.sleep(for: Self.handshakeResponseTimeout)
      guard !Task.isCancelled, let self, let peripheral,
        self.linkSession == responseSession, self.isActivePeripheral(peripheral),
        self.peripheralConnected, self.handshake == nil,
        self.handshakeResponseAttemptCount == attempt
      else { return }
      self.handshakeResponseTask = nil
      Self.commissioningTrace(
        "HANDSHAKE_RESPONSE_TIMEOUT link_session=\(responseSession) attempt=\(attempt) limit=\(Self.handshakeResponseAttemptLimit) health_received=\(self.lastHealthReceivedAt != nil)"
      )
      if self.handshakeWriteAttemptInFlight != nil || !self.pendingCommandChunks.isEmpty {
        Self.commissioningTrace(
          "HANDSHAKE_RETRY_BLOCKED reason=prior-write-unfinished link_session=\(responseSession) attempt=\(attempt) chunks=\(self.pendingCommandChunks.count)"
        )
        self.failHandshakeWriteAcknowledgement(on: peripheral, attempt: attempt)
        return
      }
      if attempt < Self.handshakeResponseAttemptLimit {
        self.handshakeRequested = false
        self.transportMessage =
          "Gateway contract did not answer; retrying handshake \(attempt + 1)/\(Self.handshakeResponseAttemptLimit)…"
        self.requestHandshakeIfReady()
        return
      }
      self.failUnresponsiveHandshake(on: peripheral, attempts: attempt)
    }
  }

  private func failUnresponsiveHandshake(on peripheral: CBPeripheral, attempts: Int) {
    guard isActivePeripheral(peripheral), handshake == nil else { return }
    handshakeRetryTask?.cancel()
    handshakeRetryTask = nil
    handshakeWriteAckTask?.cancel()
    handshakeWriteAckTask = nil
    handshakeResponseTask?.cancel()
    handshakeResponseTask = nil
    handshakeWriteAttemptInFlight = nil
    handshakeRequested = false
    reconnectIntentRequested = false
    automaticReconnectEnabled = false
    automaticReconnectActive = false
    let message =
      "Physical BLE is available, but the VHOS contract did not answer after \(attempts) handshake attempts. Select Reconnect to start one clean session."
    lastTransportFailureAt = Date()
    lastTransportFailureEvidence =
      "handshake-response-timeout: attempts=\(attempts) link_session=\(linkSession)"
    Self.commissioningTrace(
      "HANDSHAKE_RESPONSE_EXHAUSTED link_session=\(linkSession) attempts=\(attempts) action=cancel-link-for-explicit-reconnect peripheral={\(peripheralEvidence(peripheral))}"
    )
    retireRestoredPeripheral(peripheral, reason: "handshake-response-timeout")
    resetTransportSession()
    state = .degraded
    transportMessage = connectionCleanupActive
      ? "\(message) Finishing the unresponsive link first…" : message
  }

  private func failHandshakeWriteAcknowledgement(on peripheral: CBPeripheral, attempt: Int) {
    guard isActivePeripheral(peripheral), handshake == nil else { return }
    handshakeRetryTask?.cancel()
    handshakeRetryTask = nil
    handshakeWriteAckTask?.cancel()
    handshakeWriteAckTask = nil
    handshakeResponseTask?.cancel()
    handshakeResponseTask = nil
    handshakeWriteAttemptInFlight = nil
    pendingCommandChunks.removeAll()
    commandChunksPending = 0
    handshakeRequested = false
    reconnectIntentRequested = false
    automaticReconnectEnabled = false
    automaticReconnectActive = false
    let message =
      "The saved BLE link did not acknowledge handshake write attempt \(attempt). Select Reconnect after this stale link closes."
    lastTransportFailureAt = Date()
    lastTransportFailureEvidence =
      "handshake-write-ack-timeout: attempt=\(attempt) link_session=\(linkSession)"
    Self.commissioningTrace(
      "HANDSHAKE_WRITE_FAILURE_LINK_CLOSE link_session=\(linkSession) attempt=\(attempt) peripheral={\(peripheralEvidence(peripheral))}"
    )
    retireRestoredPeripheral(peripheral, reason: "handshake-write-ack-timeout")
    resetTransportSession()
    state = .degraded
    transportMessage = connectionCleanupActive
      ? "\(message) Finishing the unresponsive link first…" : message
  }

  private func consume(_ frame: GatewayFrame) throws {
    if frame.messageType != .handshake, let handshake {
      _ = try portableFrameStore.append(
        frame: frame,
        sourceRole: .obdCAN,
        sourceID: handshake.gatewayID,
        ingestedAt: Self.timestamp()
      )
      portableFrameCount = portableFrameStore.count()
    }
    switch frame.messageType {
    case .handshake:
      guard handshakeRequested, handshakeWriteAttemptInFlight == nil,
        pendingCommandChunks.isEmpty, handshakeResponseTask != nil,
        notificationRequestSession == linkSession, streamNotificationsEnabled
      else {
        Self.commissioningTrace(
          "UNSOLICITED_OR_STALE_HANDSHAKE_IGNORED link_session=\(linkSession) requested=\(handshakeRequested) write_in_flight=\(handshakeWriteAttemptInFlight != nil) chunks=\(pendingCommandChunks.count) response_window=\(handshakeResponseTask != nil) stream_confirmed=\(streamNotificationsEnabled)"
        )
        return
      }
      let value = try VHOSJSON.decoder().decode(GatewayHandshake.self, from: frame.payload)
      handshakeRetryTask?.cancel()
      handshakeRetryTask = nil
      handshakeWriteAckTask?.cancel()
      handshakeWriteAckTask = nil
      handshakeResponseTask?.cancel()
      handshakeResponseTask = nil
      handshakeWriteAttemptInFlight = nil
      _ = try portableFrameStore.append(
        frame: frame,
        sourceRole: .obdCAN,
        sourceID: value.gatewayID,
        ingestedAt: Self.timestamp()
      )
      portableFrameCount = portableFrameStore.count()
      handshake = value
      lastHandshakeReceivedAt = Date()
      if let peripheral, isActivePeripheral(peripheral) {
        rememberHandshakeVerified(peripheral)
      }
      state = .vhosConnected
      reconnectAttemptCount = 0
      transportMessage = "VHOS gateway contract active."
      Self.logger.info("VHOS gateway handshake verified")
      Self.commissioningTrace("HANDSHAKE_VERIFIED firmware=\(value.firmwareVersion)")
      captureSessions = captureStore.summaries()
      if value.capabilities.contains(.persistentEvidenceLog) {
        refreshCaptureLogIndex()
      }
    case .gatewayHealth:
      let value = try VHOSJSON.decoder().decode(GatewayHealth.self, from: frame.payload)
      health = value
      lastHealthReceivedAt = Date()
      Self.commissioningTrace(
        "HEALTH_DECODED scan=\(value.canScanState?.rawValue ?? "unavailable") bitrate=\(value.canBitrateBps.map(String.init) ?? "unavailable") cycles=\(value.canScanCycles.map(String.init) ?? "unavailable") controller=\(value.canControllerRunning.map(String.init) ?? "unavailable") lock=\(value.canPassiveLock.map(String.init) ?? "unavailable") frames=\(value.receivedFrames) standard=\(value.canStandardFrames.map(String.init) ?? "unavailable") extended=\(value.canExtendedFrames.map(String.init) ?? "unavailable") dropped=\(value.droppedFrames) errors=\(value.busErrorCount) bus_off=\(value.busOffCount) candidate=\(value.passiveCanCandidate ?? "none")"
      )
    case .experimentResult:
      let result = try VHOSJSON.decoder().decode(ProtocolExperimentResult.self, from: frame.payload)
      experimentResults.append(result)
      lastExperimentResultAt = Date()
    case .diagnosticResponse:
      guard let gatewayID = handshake?.gatewayID else { return }
      let response =
        if frame.payload.count == 36, frame.payload.first == 1 {
          try J1979ResponseEvidence.decodePassiveWire(
            frame.payload, gatewayID: gatewayID, observedAt: Self.timestamp())
        } else {
          try VHOSJSON.decoder().decode(J1979ResponseEvidence.self, from: frame.payload)
        }
      _ = try j1979Accumulator.ingest(response)
      j1979Availability = j1979Accumulator.availability
      standardOBDSamples = j1979Accumulator.standardSamples
      Self.commissioningTrace(
        "J1979_RESPONSE ecu=\(response.ecuAddress) pid=0x\(String(format: "%02X", response.requestPID)) complete=\(j1979Availability.first(where: { $0.ecuAddress == response.ecuAddress })?.enumerationComplete ?? false) decoded_samples=\(standardOBDSamples.count)"
      )
    case .rawCANFrame:
      guard let gatewayID = handshake?.gatewayID else { return }
      let observation = try PassiveCANObservation.decodeLive(
        frame.payload,
        gatewayID: gatewayID,
        ingestedAt: Self.timestamp()
      )
      latestCANObservation = observation
      recentCANObservations.append(observation)
      if recentCANObservations.count > 100 {
        recentCANObservations.removeFirst(recentCANObservations.count - 100)
      }
    case .captureLogIndex:
      let index = try VHOSJSON.decoder().decode(CaptureLogIndex.self, from: frame.payload)
      captureLogIndex = index
      Self.commissioningTrace(
        "CAPTURE_INDEX current_session=\(index.currentSessionID) current_records=\(index.currentRecords) previous_session=\(index.previousSessionID) previous_records=\(index.previousRecords) retained=\(index.retainedRecords) queue_drops=\(index.queueDroppedRecords) write_failures=\(index.storageWriteFailures)"
      )
      if captureSyncSuspendedForOTA, !index.logging {
        captureSyncMessage = "Passive flight recorder is flushed and paused for OTA."
      } else {
        beginCaptureSync(index)
      }
    case .captureLogChunk:
      guard let gatewayID = handshake?.gatewayID else { return }
      let chunk = try CaptureLogChunk.decode(
        frame.payload,
        gatewayID: gatewayID,
        ingestedAt: Self.timestamp()
      )
      try consumeCaptureChunk(chunk)
    case .otaControl:
      let status = try VHOSJSON.decoder().decode(GatewayOTAStatus.self, from: frame.payload)
      otaStatus = status
      lastOTAStatusAt = Date()
      transportMessage = status.detail
      Self.commissioningTrace(
        "OTA_STATUS state=\(status.state) active=\(status.sessionActive) expires=\(status.expiresInSeconds)"
      )
    default:
      break
    }
  }

  private func writeFrame(type: GatewayMessageType, payload: Data) throws {
    guard let peripheral, let command else { throw GatewayBLEError.commandChannelUnavailable }
    let frame = GatewayFrame(
      messageType: type,
      sequence: sequence,
      monotonicMicroseconds: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000),
      payload: payload
    )
    sequence &+= 1
    guard command.properties.contains(.write) else { throw GatewayBLEError.reliableWriteRequired }
    let bytes = frame.encoded()
    let maximum = peripheral.maximumWriteValueLength(for: .withResponse)
    guard maximum > 0 else { throw GatewayBLEError.commandChannelUnavailable }
    pendingCommandChunks.append(
      contentsOf: stride(from: 0, to: bytes.count, by: maximum).map { offset in
        Data(bytes[offset..<min(offset + maximum, bytes.count)])
      })
    commandChunksPending = pendingCommandChunks.count
    if pendingCommandChunks.count == Int(ceil(Double(bytes.count) / Double(maximum))) {
      sendNextCommandChunk()
    }
  }

  func evidenceSyncExportURL(
    applicationID: String,
    applicationVersion: String,
    deviceModel: String
  ) throws -> URL {
    let url = try portableFrameStore.export(
      applicationID: applicationID,
      applicationVersion: applicationVersion,
      deviceModel: deviceModel
    )
    lastEvidenceSyncMessage = "Prepared \(portableFrameCount) validated logical frames for Android/iPhone sync."
    return url
  }

  func importEvidenceSync(from url: URL) throws -> EvidenceSyncImportSummary {
    let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
    let summary = try portableFrameStore.importBundle(bytes)
    portableFrameCount = portableFrameStore.count()
    lastEvidenceSyncMessage =
      "Verified \(summary.verifiedRecords) records; appended \(summary.appendedRecords) new logical frames."
    return summary
  }

  private func beginCaptureSync(_ index: CaptureLogIndex) {
    guard let gatewayID = handshake?.gatewayID else { return }
    captureSyncTask?.cancel()
    captureSyncTask = nil
    captureChunkResponseTask?.cancel()
    captureChunkResponseTask = nil
    captureSyncTargets.removeAll()
    let candidates: [(UInt8, UInt32, UInt32)] = [
      (1, index.previousSessionID, index.previousRecords),
      (0, index.currentSessionID, index.currentRecords),
    ]
    for (slot, sessionID, totalRecords) in candidates where sessionID != 0 && totalRecords > 0 {
      let localCount = captureStore.recordCount(gatewayID: gatewayID, sessionID: sessionID)
      let offset = localCount <= totalRecords ? localCount : 0
      captureSyncTargets.append(
        CaptureSyncTarget(
          slot: slot,
          sessionID: sessionID,
          totalRecords: totalRecords,
          recordOffset: offset
        ))
    }
    captureSessions = captureStore.summaries()
    scheduleNextCaptureChunk(after: Self.captureInitialSyncDelay)
  }

  private func scheduleNextCaptureChunk(after delay: Duration) {
    captureSyncTask?.cancel()
    let scheduledSession = linkSession
    captureSyncTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self, self.linkSession == scheduledSession,
        self.applicationSessionHealthy, !self.captureSyncSuspendedForOTA
      else { return }
      self.captureSyncTask = nil
      self.requestNextCaptureChunk()
    }
  }

  private func requestNextCaptureChunk() {
    guard applicationSessionHealthy, !captureSyncSuspendedForOTA,
      captureChunkResponseTask == nil
    else { return }
    while let target = captureSyncTargets.first,
      target.recordOffset >= target.totalRecords
    {
      captureSyncTargets.removeFirst()
    }
    guard let target = captureSyncTargets.first else {
      captureSessions = captureStore.summaries()
      captureSyncMessage = "Recent gateway logs are synchronized on this iPhone."
      let fingerprint = captureSessions
        .map { "\($0.gatewayID):\($0.sessionID):\($0.recordCount):\($0.byteCount)" }
        .joined(separator: "|")
      if !fingerprint.isEmpty, fingerprint != lastCaptureSyncFingerprint {
        lastCaptureSyncFingerprint = fingerprint
        captureSyncCompletionGeneration &+= 1
      }
      Self.commissioningTrace(
        "CAPTURE_SYNC_COMPLETE downloaded=\(captureDownloadedRecords) local_sessions=\(captureSessions.count) outbox_generation=\(captureSyncCompletionGeneration)"
      )
      return
    }
    do {
      try writeFrame(
        type: .captureLogRequest,
        payload: CaptureLogRequest(
          operation: .read,
          slot: target.slot,
          recordOffset: target.recordOffset
        ).encoded()
      )
      captureSyncMessage =
        "Syncing session \(target.sessionID): \(target.recordOffset)/\(target.totalRecords) records…"
      armCaptureChunkResponseTimeout(for: target)
    } catch {
      captureSyncMessage = error.localizedDescription
    }
  }

  private func armCaptureChunkResponseTimeout(for target: CaptureSyncTarget) {
    captureChunkResponseTask?.cancel()
    let requestSession = linkSession
    let requestSlot = target.slot
    let requestSessionID = target.sessionID
    let requestOffset = target.recordOffset
    captureChunkResponseTask = Task { [weak self] in
      try? await Task.sleep(for: Self.captureChunkResponseTimeout)
      guard !Task.isCancelled, let self, self.linkSession == requestSession,
        self.applicationSessionHealthy,
        let current = self.captureSyncTargets.first,
        current.slot == requestSlot,
        current.sessionID == requestSessionID,
        current.recordOffset == requestOffset
      else { return }
      self.captureChunkResponseTask = nil
      self.captureSyncMessage =
        "Recent-log sync paused at record \(requestOffset); the live vehicle session remains connected."
      Self.commissioningTrace(
        "CAPTURE_SYNC_PAUSED reason=chunk-timeout link_session=\(requestSession) slot=\(requestSlot) session=\(requestSessionID) offset=\(requestOffset) timeout_seconds=8"
      )
    }
  }

  private func consumeCaptureChunk(_ chunk: CaptureLogChunk) throws {
    guard var target = captureSyncTargets.first,
      chunk.slot == target.slot,
      chunk.sessionID == target.sessionID,
      chunk.recordOffset == target.recordOffset
    else {
      throw CaptureSyncError.unexpectedChunk
    }
    captureChunkResponseTask?.cancel()
    captureChunkResponseTask = nil
    guard let gatewayID = handshake?.gatewayID else { return }
    let appended = try captureStore.append(
      chunk.records,
      gatewayID: gatewayID,
      sessionID: chunk.sessionID
    )
    captureDownloadedRecords &+= UInt64(appended)
    Self.commissioningTrace(
      "CAPTURE_CHUNK session=\(chunk.sessionID) slot=\(chunk.slot) offset=\(chunk.recordOffset) received=\(chunk.records.count) appended=\(appended) end=\(chunk.endOfFile)"
    )
    target.recordOffset &+= UInt32(chunk.records.count)
    captureSyncTargets[0] = target
    captureSessions = captureStore.summaries()
    if chunk.endOfFile || target.recordOffset >= target.totalRecords {
      captureSyncTargets.removeFirst()
    } else if chunk.records.isEmpty {
      throw CaptureSyncError.emptyNonterminalChunk
    }
    scheduleNextCaptureChunk(after: Self.captureChunkInterval)
  }

  private func record(_ frame: GatewayFrame) {
    decodedFrameCount &+= 1
    lastFrameReceivedAt = Date()
    if let previous = lastReceivedSequence {
      let expected = previous &+ 1
      if frame.sequence != expected {
        sequenceDiscontinuityCount &+= 1
        if frame.sequence > expected { missingSequenceCount &+= frame.sequence - expected }
      }
    }
    lastReceivedSequence = frame.sequence
  }

  private func sendNextCommandChunk() {
    guard let peripheral, let command, let next = pendingCommandChunks.first else { return }
    peripheral.writeValue(next, for: command, type: .withResponse)
  }

  private func isSecurityNegotiationError(_ error: Error) -> Bool {
    let value = error as NSError
    return value.domain == CBATTErrorDomain
      && (value.code == CBATTError.insufficientEncryption.rawValue
        || value.code == CBATTError.insufficientAuthentication.rawValue)
  }

  private func isPeerPairingInformationRemoved(_ error: Error?) -> Bool {
    guard let error else { return false }
    let value = error as NSError
    return value.domain == CBErrorDomain
      && value.code == CBError.peerRemovedPairingInformation.rawValue
  }

  private func connect(_ peripheral: CBPeripheral) {
    if let active = self.peripheral, active !== peripheral {
      Self.commissioningTrace(
        "PARALLEL_CONNECT_REJECTED active=\(peripheralEvidence(active)) candidate=\(peripheralEvidence(peripheral))"
      )
      central.cancelPeripheralConnection(peripheral)
      return
    }
    self.peripheral = peripheral
    if peripheral.state == .connected {
      beginServiceDiscovery(peripheral, source: "already-connected")
      return
    }
    if peripheral.state == .connecting {
      state = .connecting
      transportMessage = "Waiting for the existing gateway connection…"
      Self.commissioningTrace("CONNECT_WAITING id=\(peripheral.identifier.uuidString)")
      armConnectionTimeout(peripheral, source: "existing-connect-request")
      return
    }
    if peripheral.state == .disconnecting {
      scanRequested = true
      scanAfterRestorationCleanup = true
      transportMessage = "Waiting for the previous gateway link to close before reconnecting…"
      Self.commissioningTrace(
        "CONNECT_DISCONNECTING_DEFERRED peripheral=\(peripheralEvidence(peripheral))"
      )
      retireRestoredPeripheral(peripheral, reason: "connect-called-while-disconnecting")
      return
    }
    guard peripheral.state == .disconnected else {
      Self.commissioningTrace(
        "CONNECT_STATE_REJECTED peripheral=\(peripheralEvidence(peripheral))"
      )
      return
    }
    Self.commissioningTrace(
      "CONNECT_REQUEST peripheral=\(peripheralEvidence(peripheral)) reconnect_attempt=\(reconnectAttemptCount)"
    )
    central.connect(
      peripheral,
      options: [
        CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
      ])
    armConnectionTimeout(peripheral, source: "new-connect-request")
  }

  private func handleDisconnect(
    _ peripheral: CBPeripheral, isSystemReconnecting: Bool, error: Error?
  ) {
    if completeRetiredPeripheral(peripheral, event: "disconnect", error: error) { return }
    guard isActivePeripheral(peripheral) else {
      Self.commissioningTrace(
        "STALE_DISCONNECT_IGNORED peripheral=\(peripheralEvidence(peripheral)) "
          + "active=\(activePeripheralEvidence)"
      )
      return
    }
    if pendingStaleGATTRescan {
      completeStaleGATTRecovery(after: peripheral, event: "disconnect")
      return
    }
    let failure = Self.errorEvidence(error)
    recordTransportFailure(error, event: "link-disconnected")
    Self.commissioningTrace(
      "LINK_DISCONNECTED link_session=\(linkSession) pairing_pending=\(notificationPairingPending) system_reconnecting=\(isSystemReconnecting) error={\(failure)}"
    )
    if userRequestedDisconnect || !automaticReconnectEnabled {
      resetConnection()
      transportMessage = "Gateway disconnected by user."
      return
    }
    if isSystemReconnecting {
      resetTransportSession(preservingSelection: true)
      automaticReconnectActive = true
      state = .connecting
      transportMessage = "Connection interrupted; iPhone is automatically reconnecting…"
      Self.commissioningTrace("SYSTEM_RECONNECT_ACTIVE")
      return
    }
    scheduleReconnect(to: peripheral, error: error)
  }

  private func beginServiceDiscovery(_ peripheral: CBPeripheral, source: String) {
    if isActivePeripheral(peripheral), peripheralConnected {
      Self.commissioningTrace(
        "LINK_CONNECTED_DUPLICATE_IGNORED link_session=\(linkSession) source=\(source) peripheral=\(peripheralEvidence(peripheral))"
      )
      return
    }
    if let active = self.peripheral, active !== peripheral {
      Self.commissioningTrace(
        "PARALLEL_LINK_ADOPTION_REJECTED source=\(source) active=\(peripheralEvidence(active)) candidate=\(peripheralEvidence(peripheral))"
      )
      central.cancelPeripheralConnection(peripheral)
      return
    }
    restoredConnectionTask?.cancel()
    reconnectTask?.cancel()
    central.stopScan()
    scanFallbackTask?.cancel()
    scanRequested = false
    scanActive = false
    automaticReconnectActive = false
    automaticReconnectEnabled = true
    userRequestedDisconnect = false
    self.peripheral = peripheral
    peripheralConnected = true
    gatewayIdentityValidated = false
    connectedAt = Date()
    currentSessionResultStartIndex = experimentResults.count
    linkSession &+= 1
    installPeripheralDelegate(on: peripheral, for: linkSession)
    notificationRequestSession = nil
    notificationPairingPending = false
    state = .connecting
    transportMessage = "Connected; negotiating gateway contract…"
    Self.logger.info("ESP32 BLE connection established via \(source, privacy: .public)")
    Self.commissioningTrace(
      "LINK_CONNECTED link_session=\(linkSession) peripheral=\(peripheralEvidence(peripheral)) source=\(source) state=\(peripheral.state.rawValue)"
    )
    Self.commissioningTrace("LINK_RSSI_REQUEST link_session=\(linkSession) reason=connected")
    peripheral.readRSSI()
    if let services = peripheral.services, !services.isEmpty {
      Self.commissioningTrace(
        "GATT_CACHE_ADOPTED id=\(peripheral.identifier.uuidString) service_count=\(services.count)"
      )
      processDiscoveredServices(
        peripheral, services: services, source: "cache", callbackSession: linkSession)
    } else {
      peripheral.discoverServices([Self.vhosService, Self.factoryService])
      armGATTDiscoveryTimeout(peripheral, phase: "services")
    }
  }

  private func armGATTDiscoveryTimeout(_ peripheral: CBPeripheral, phase: String) {
    serviceDiscoveryTask?.cancel()
    let discoverySession = linkSession
    serviceDiscoveryTask = Task { [weak self, weak peripheral] in
      try? await Task.sleep(for: .seconds(12))
      guard !Task.isCancelled, let self, let peripheral,
        self.acceptsPeripheralCallback(
          peripheral, callbackSession: discoverySession, event: "gatt-watchdog-\(phase)")
      else { return }
      let complete = phase == "services"
        ? (self.vhosServiceDiscovered || self.factoryServiceDiscovered)
        : ((self.factoryServiceDiscovered && self.state == .factoryCompatible)
          || (self.commandChannelReady && self.streamChannelDiscovered
            && self.healthChannelDiscovered && self.otaStatusChannelDiscovered))
      guard !complete else { return }
      if phase == "services", !self.gatewayIdentityValidated {
        if self.candidateAdvertisedVHOSService || self.candidateWasPreviouslyValidated {
          Self.commissioningTrace(
            "TRUSTED_GATT_TIMEOUT id=\(peripheral.identifier.uuidString)"
          )
          self.refreshStaleGATTCandidate(
            peripheral,
            reason:
              "The saved gateway database is stale; scanning for the current gateway identity…"
          )
        } else {
          self.rejectCandidateAndResumeScanning(
            peripheral, reason: "BLE candidate did not prove a VHOS/WiCAN service identity.")
        }
        return
      }
      self.transportMessage =
        "Verified gateway GATT is not responding; refreshing it automatically…"
      Self.commissioningTrace(
        "GATT_DISCOVERY_TIMEOUT phase=\(phase) id=\(peripheral.identifier.uuidString) state=\(peripheral.state.rawValue)"
      )
      self.refreshStaleGATTCandidate(
        peripheral,
        reason: "Gateway contract discovery timed out; scanning for the current gateway identity…")
    }
  }

  private func armConnectionTimeout(_ peripheral: CBPeripheral, source: String) {
    restoredConnectionTask?.cancel()
    restoredConnectionTask = Task { [weak self, weak peripheral] in
      try? await Task.sleep(for: .seconds(12))
      guard !Task.isCancelled, let self, let peripheral,
        self.isActivePeripheral(peripheral),
        !self.peripheralConnected
      else { return }
      if peripheral.state == .connected {
        Self.commissioningTrace(
          "RESTORED_CONNECT_ADOPT id=\(peripheral.identifier.uuidString) recovery=service-discovery"
        )
        self.beginServiceDiscovery(peripheral, source: "restored-timeout-adopted")
        return
      }
      Self.commissioningTrace(
        "CONNECT_TIMEOUT id=\(peripheral.identifier.uuidString) state=\(peripheral.state.rawValue) source=\(source) recovery=cancel-and-service-scan"
      )
      self.transportMessage =
        "The restored BLE connection stopped responding; scanning again automatically…"
      self.retireRestoredPeripheral(peripheral, reason: "restored-connection-timeout")
      self.resetTransportSession()
      self.scanRequested = true
      self.scanAfterRestorationCleanup = true
      if self.retiredRestoredPeripherals.isEmpty {
        self.scanAfterRestorationCleanup = false
        self.startScan(source: "connection-timeout-fallback", skipConnectedRetrieval: true)
      }
    }
  }

  private func scheduleReconnect(to peripheral: CBPeripheral, error: Error?) {
    reconnectTask?.cancel()
    let wasPairingPending = notificationPairingPending
    let reason = connectionFailureMessage(
      error,
      fallback: "BLE link interrupted.",
      pairingWasPending: wasPairingPending
    )
    resetTransportSession(preservingSelection: true)
    self.peripheral = peripheral
    reconnectAttemptCount += 1
    automaticReconnectActive = true
    state = .connecting
    let delays = [1, 2, 4, 8, 15, 30]
    let delay = delays[min(reconnectAttemptCount - 1, delays.count - 1)]
    transportMessage =
      "\(reason) Reconnecting automatically in \(delay) second\(delay == 1 ? "" : "s")…"
    Self.commissioningTrace(
      "RECONNECT_SCHEDULED attempt=\(reconnectAttemptCount) delay=\(delay) previous_pairing_pending=\(wasPairingPending) error={\(Self.errorEvidence(error))}"
    )
    reconnectTask = Task { [weak self, weak peripheral] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, let self, let peripheral,
        self.automaticReconnectEnabled, !self.userRequestedDisconnect,
        self.central.state == .poweredOn, self.isActivePeripheral(peripheral)
      else { return }
      self.transportMessage =
        "Reconnecting to \(self.canonicalDisplayName)…"
      self.connect(peripheral)
    }
  }

  private func rebuildCentralForFreshPairing() {
    freshCentralRecoveryAttempted = true
    Self.logger.info("Discarding restored CoreBluetooth state after peer removed pairing data")
    Self.commissioningTrace("CENTRAL_REBUILD reason=peer-removed-pairing-information")
    central.stopScan()
    central.delegate = nil
    restoredCleanupTask?.cancel()
    restoredCleanupTask = nil
    retiredRestoredPeripherals.removeAll()
    pendingRestoredPeripheral = nil
    scanAfterRestorationCleanup = false
    connectionCleanupActive = false
    centralCleanupRecoveryPending = false
    resetTransportSession()
    scanRequested = true
    reconnectIntentRequested = true
    automaticReconnectEnabled = true
    userRequestedDisconnect = false
    state = .scanning
    transportMessage = "Resetting the Bluetooth session for fresh pairing…"
    replaceCentralManager(reason: "peer-removed-pairing-information")
  }

  private func replaceCentralManager(reason: String) {
    let previousIdentifier = currentCentralRestoreIdentifier
    central.stopScan()
    central.delegate = nil
    let replacementIdentifier =
      "\(Self.centralRestoreIdentifier).\(UUID().uuidString.lowercased())"
    currentCentralRestoreIdentifier = replacementIdentifier
    UserDefaults.standard.set(
      replacementIdentifier, forKey: Self.centralRestoreIdentifierKey)
    Self.commissioningTrace(
      "CENTRAL_MANAGER_REPLACED reason=\(reason) previous_restore_id=\(previousIdentifier) replacement_restore_id=\(replacementIdentifier)"
    )
    central = CBCentralManager(
      delegate: self,
      queue: .main,
      options: [CBCentralManagerOptionRestoreIdentifierKey: replacementIdentifier]
    )
  }

  private func isActivePeripheral(_ candidate: CBPeripheral) -> Bool {
    guard let peripheral else { return false }
    return peripheral === candidate
  }

  private func installPeripheralDelegate(on peripheral: CBPeripheral, for session: UInt64) {
    retireActivePeripheralDelegate()
    let delegate = LinkScopedPeripheralDelegate(owner: self, linkSession: session)
    activePeripheralDelegate = delegate
    peripheral.delegate = delegate
    if retiredPeripheralDelegates.count > 8,
      let oldest = retiredPeripheralDelegates.keys.min()
    {
      retiredPeripheralDelegates.removeValue(forKey: oldest)
    }
    Self.commissioningTrace(
      "PERIPHERAL_DELEGATE_INSTALLED link_session=\(session) peripheral=\(peripheralEvidence(peripheral))"
    )
  }

  private func retireActivePeripheralDelegate() {
    guard let delegate = activePeripheralDelegate else { return }
    retiredPeripheralDelegates[delegate.linkSession] = delegate
    activePeripheralDelegate = nil
  }

  private func acceptsPeripheralCallback(
    _ candidate: CBPeripheral, callbackSession: UInt64, event: String
  ) -> Bool {
    guard callbackSession == linkSession, peripheralConnected,
      isActivePeripheral(candidate),
      activePeripheralDelegate?.linkSession == callbackSession
    else {
      Self.commissioningTrace(
        "STALE_PERIPHERAL_CALLBACK_IGNORED event=\(event) callback_session=\(callbackSession) active_session=\(linkSession) connected=\(peripheralConnected) candidate={\(peripheralEvidence(candidate))} active={\(activePeripheralEvidence)}"
      )
      return false
    }
    return true
  }

  private func handleRSSIRead(
    _ peripheral: CBPeripheral, rssi: NSNumber, error: Error?, callbackSession: UInt64
  ) {
    guard acceptsPeripheralCallback(
      peripheral, callbackSession: callbackSession, event: "rssi-read")
    else { return }
    if let error {
      Self.commissioningTrace(
        "LINK_RSSI_FAILED link_session=\(callbackSession) error={\(Self.errorEvidence(error))}"
      )
      return
    }
    let value = rssi.intValue
    guard value != 127 else {
      Self.commissioningTrace(
        "LINK_RSSI_FAILED link_session=\(callbackSession) error={unavailable-sentinel}"
      )
      return
    }
    discoveredRSSI = value
    Self.commissioningTrace("LINK_RSSI link_session=\(callbackSession) rssi=\(value)")
  }

  private var activePeripheralEvidence: String {
    peripheral.map(peripheralEvidence) ?? "none"
  }

  private func peripheralEvidence(_ peripheral: CBPeripheral) -> String {
    "id=\(peripheral.identifier.uuidString),object=\(ObjectIdentifier(peripheral)),state=\(peripheral.state.rawValue)"
  }

  private func restorationStateRank(_ state: CBPeripheralState) -> Int {
    switch state {
    case .connected: 0
    case .connecting: 1
    case .disconnected: 2
    case .disconnecting: 3
    @unknown default: 4
    }
  }

  private func retireRestoredPeripheral(_ peripheral: CBPeripheral, reason: String) {
    let key = ObjectIdentifier(peripheral)
    guard retiredRestoredPeripherals[key] == nil else { return }
    guard
      peripheral.state == .connected || peripheral.state == .connecting
        || peripheral.state == .disconnecting
    else {
      Self.commissioningTrace(
        "RESTORED_PERIPHERAL_ALREADY_IDLE reason=\(reason) peripheral=\(peripheralEvidence(peripheral))"
      )
      return
    }
    if isActivePeripheral(peripheral) {
      retireActivePeripheralDelegate()
    }
    peripheral.delegate = nil
    retiredRestoredPeripherals[key] = peripheral
    connectionCleanupActive = true
    Self.commissioningTrace(
      "RESTORED_PERIPHERAL_RETIRING reason=\(reason) peripheral=\(peripheralEvidence(peripheral))"
    )
    if peripheral.state != .disconnecting {
      central.cancelPeripheralConnection(peripheral)
    }
    armRetiredPeripheralCleanupWatchdog()
  }

  @discardableResult
  private func completeRetiredPeripheral(
    _ peripheral: CBPeripheral, event: String, error: Error?
  ) -> Bool {
    let key = ObjectIdentifier(peripheral)
    guard retiredRestoredPeripherals.removeValue(forKey: key) != nil else { return false }
    Self.commissioningTrace(
      "RESTORED_PERIPHERAL_RETIRED event=\(event) peripheral=\(peripheralEvidence(peripheral)) error={\(Self.errorEvidence(error))} remaining=\(retiredRestoredPeripherals.count)"
    )
    guard retiredRestoredPeripherals.isEmpty else {
      armRetiredPeripheralCleanupWatchdog()
      return true
    }
    finishRetiredPeripheralCleanup(source: event)
    return true
  }

  private func finishRetiredPeripheralCleanup(source: String) {
    restoredCleanupTask?.cancel()
    restoredCleanupTask = nil
    connectionCleanupActive = false
    Self.commissioningTrace(
      "RESTORED_CLEANUP_COMPLETE source=\(source) user_disconnected=\(userRequestedDisconnect) pending_restore=\(pendingRestoredPeripheral != nil) scan_after=\(scanAfterRestorationCleanup)"
    )
    if userRequestedDisconnect {
      pendingRestoredPeripheral = nil
      scanAfterRestorationCleanup = false
      transportMessage = "Gateway disconnected by user."
      return
    }
    if let restored = pendingRestoredPeripheral {
      pendingRestoredPeripheral = nil
      resumeRestoredPeripheral(restored)
      return
    }
    if scanAfterRestorationCleanup {
      scanAfterRestorationCleanup = false
      startScan(source: "restoration-cleanup-complete", skipConnectedRetrieval: true)
      return
    }
    if state == .degraded {
      transportMessage =
        "The previous BLE link is closed. Select Reconnect to start one clean session."
    }
  }

  private func armRetiredPeripheralCleanupWatchdog() {
    restoredCleanupTask?.cancel()
    restoredCleanupGeneration &+= 1
    let cleanupGeneration = restoredCleanupGeneration
    guard !retiredRestoredPeripherals.isEmpty else {
      connectionCleanupActive = false
      return
    }
    connectionCleanupActive = true
    Self.commissioningTrace(
      "RESTORED_CLEANUP_WATCHDOG_ARMED generation=\(cleanupGeneration) count=\(retiredRestoredPeripherals.count) timeout_seconds=4"
    )
    restoredCleanupTask = Task { [weak self] in
      try? await Task.sleep(for: Self.restoredCleanupTimeout)
      guard !Task.isCancelled, let self,
        self.restoredCleanupGeneration == cleanupGeneration,
        !self.retiredRestoredPeripherals.isEmpty
      else { return }
      self.restoredCleanupTask = nil
      let stillActive = self.retiredRestoredPeripherals.values.filter {
        $0.state != .disconnected
      }
      Self.commissioningTrace(
        "RESTORED_CLEANUP_WATCHDOG_FIRED generation=\(cleanupGeneration) retained=\(self.retiredRestoredPeripherals.count) still_active=\(stillActive.count)"
      )
      if stillActive.isEmpty {
        self.retiredRestoredPeripherals.removeAll()
        self.finishRetiredPeripheralCleanup(source: "watchdog-observed-disconnected")
        return
      }
      self.rebuildCentralAfterCleanupTimeout(stillActive, generation: cleanupGeneration)
    }
  }

  private func rebuildCentralAfterCleanupTimeout(
    _ stillActive: [CBPeripheral], generation: UInt64
  ) {
    let shouldReconnect = reconnectIntentRequested && !userRequestedDisconnect
    Self.commissioningTrace(
      "RESTORED_CLEANUP_CENTRAL_RECOVERY generation=\(generation) active=\(stillActive.count) reconnect_intent=\(shouldReconnect) action=cancel-old-central-before-rebuild"
    )
    for stale in stillActive {
      stale.delegate = nil
      if stale.state != .disconnecting {
        central.cancelPeripheralConnection(stale)
      }
    }
    central.stopScan()
    central.delegate = nil
    restoredCleanupTask?.cancel()
    restoredCleanupTask = nil
    retiredRestoredPeripherals.removeAll()
    pendingRestoredPeripheral = nil
    scanAfterRestorationCleanup = false
    resetTransportSession()
    scanRequested = shouldReconnect
    automaticReconnectActive = shouldReconnect
    state = shouldReconnect ? .connecting : .disconnected
    transportMessage = shouldReconnect
      ? "Refreshing Core Bluetooth before reconnecting to the verified gateway…"
      : "Finishing the previous BLE link…"
    connectionCleanupActive = true
    centralCleanupRecoveryPending = true
    replaceCentralManager(reason: "retired-peripheral-cleanup-timeout")
  }

  private var validatedPeripheralIdentifiers: Set<String> {
    Set(
      (UserDefaults.standard.stringArray(forKey: Self.validatedPeripheralIdentifiersKey) ?? [])
        .map { $0.uppercased() })
  }

  private func isPreviouslyValidated(_ peripheral: CBPeripheral) -> Bool {
    GatewayBLEIdentityPolicy.restorationIsAllowed(
      identifier: peripheral.identifier.uuidString,
      validatedIdentifiers: validatedPeripheralIdentifiers)
  }

  private func isHandshakeVerified(_ peripheral: CBPeripheral) -> Bool {
    guard let identifier = verifiedSavedGatewayIdentifier else { return false }
    return identifier.caseInsensitiveCompare(peripheral.identifier.uuidString) == .orderedSame
  }

  private func rememberHandshakeVerified(_ peripheral: CBPeripheral) {
    let identifier = peripheral.identifier.uuidString.uppercased()
    verifiedSavedGatewayIdentifier = identifier
    UserDefaults.standard.set(
      identifier,
      forKey: Self.handshakeVerifiedPeripheralIdentifierKey
    )
    Self.commissioningTrace(
      "RESTORATION_TRUST_PROMOTED peripheral=\(peripheralEvidence(peripheral)) link_session=\(linkSession) basis=verified-handshake"
    )
  }

  private func rememberValidated(_ peripheral: CBPeripheral) {
    var identifiers = validatedPeripheralIdentifiers
    identifiers.insert(peripheral.identifier.uuidString.uppercased())
    UserDefaults.standard.set(
      identifiers.sorted(), forKey: Self.validatedPeripheralIdentifiersKey)
    candidateWasPreviouslyValidated = true
  }

  private func forgetValidated(_ peripheral: CBPeripheral) {
    var identifiers = validatedPeripheralIdentifiers
    identifiers.remove(peripheral.identifier.uuidString.uppercased())
    UserDefaults.standard.set(
      identifiers.sorted(), forKey: Self.validatedPeripheralIdentifiersKey)
    if isHandshakeVerified(peripheral) {
      verifiedSavedGatewayIdentifier = nil
      UserDefaults.standard.removeObject(
        forKey: Self.handshakeVerifiedPeripheralIdentifierKey)
    }
    candidateWasPreviouslyValidated = false
  }

  private func rejectCandidateAndResumeScanning(_ peripheral: CBPeripheral, reason: String) {
    forgetValidated(peripheral)
    automaticReconnectEnabled = false
    gatewayIdentityValidated = false
    transportMessage = "\(reason) Resuming the service-filtered scan…"
    Self.commissioningTrace(
      "GATEWAY_REJECTED id=\(peripheral.identifier.uuidString) name=\(peripheral.name ?? "unknown")"
    )
    central.cancelPeripheralConnection(peripheral)
    resetConnection()
    startScan(source: "candidate-rejection")
  }

  private func refreshStaleGATTCandidate(_ peripheral: CBPeripheral, reason: String) {
    guard isActivePeripheral(peripheral) else { return }
    Self.commissioningTrace(
      "STALE_GATT_CANDIDATE_RETIRED id=\(peripheral.identifier.uuidString)"
    )
    automaticReconnectEnabled = false
    automaticReconnectActive = false
    reconnectTask?.cancel()
    serviceDiscoveryTask?.cancel()
    central.stopScan()
    scanActive = false
    scanRequested = false
    pendingStaleGATTRescan = true
    pendingStaleGATTReason = reason
    state = .connecting
    transportMessage =
      "\(reason) Waiting for the stale BLE link to close; no Settings cleanup is required."
    central.cancelPeripheralConnection(peripheral)
  }

  private func completeStaleGATTRecovery(after peripheral: CBPeripheral, event: String) {
    guard pendingStaleGATTRescan, isActivePeripheral(peripheral) else {
      return
    }
    let reason = pendingStaleGATTReason
      ?? "The saved gateway database is stale; scanning for the current gateway identity…"
    pendingStaleGATTRescan = false
    pendingStaleGATTReason = nil
    Self.commissioningTrace(
      "STALE_GATT_DISCONNECT_CONFIRMED id=\(peripheral.identifier.uuidString) event=\(event)"
    )
    resetTransportSession()
    state = .disconnected
    transportMessage = "\(reason) Starting a fresh service-filtered scan…"
    startScan(source: "stale-gatt-disconnect-confirmed", skipConnectedRetrieval: true)
  }

  private func recordTransportFailure(_ error: Error?, event: String) {
    guard let error else { return }
    lastTransportFailureAt = Date()
    lastTransportFailureEvidence = "\(event): \(Self.errorEvidence(error))"
  }

  private func connectionFailureMessage(
    _ error: Error?, fallback: String, pairingWasPending: Bool = false
  ) -> String {
    guard let error else { return fallback }
    let value = error as NSError
    if value.domain == CBErrorDomain, value.code == 6, pairingWasPending {
      return
        "Secure BLE pairing timed out (CBError.connectionTimeout, code 6)."
    }
    if value.domain == CBErrorDomain,
      value.code == CBError.encryptionTimedOut.rawValue
    {
      if let discoveredRSSI, discoveredRSSI <= -80 {
        return "BLE timed out at \(discoveredRSSI) dBm; move the iPhone closer."
      }
      return "BLE encryption timed out."
    }
    if value.domain == CBErrorDomain,
      value.code == CBError.peerRemovedPairingInformation.rawValue
    {
      return
        "iPhone still has stale gateway pairing state. Toggle Bluetooth off and on, then scan again."
    }
    return "\(error.localizedDescription) [\(Self.errorSymbol(error)), code \(value.code)]"
  }

  private static func errorSymbol(_ error: Error) -> String {
    let value = error as NSError
    if value.domain == CBErrorDomain {
      switch value.code {
      case 0: return "CBError.unknown"
      case 1: return "CBError.invalidParameters"
      case 2: return "CBError.invalidHandle"
      case 3: return "CBError.notConnected"
      case 4: return "CBError.outOfSpace"
      case 5: return "CBError.operationCancelled"
      case 6: return "CBError.connectionTimeout"
      case 7: return "CBError.peripheralDisconnected"
      case 8: return "CBError.uuidNotAllowed"
      case 9: return "CBError.alreadyAdvertising"
      case 10: return "CBError.connectionFailed"
      case 11: return "CBError.connectionLimitReached"
      case 12: return "CBError.unknownDevice"
      case 13: return "CBError.operationNotSupported"
      case 14: return "CBError.peerRemovedPairingInformation"
      case 15: return "CBError.encryptionTimedOut"
      case 16: return "CBError.tooManyLEPairedDevices"
      default: return "CBError.unknownCode"
      }
    }
    if value.domain == CBATTErrorDomain {
      switch value.code {
      case CBATTError.insufficientAuthentication.rawValue:
        return "CBATTError.insufficientAuthentication"
      case CBATTError.insufficientAuthorization.rawValue:
        return "CBATTError.insufficientAuthorization"
      case CBATTError.insufficientEncryption.rawValue:
        return "CBATTError.insufficientEncryption"
      default:
        return "CBATTError.code\(value.code)"
      }
    }
    return "\(value.domain).code\(value.code)"
  }

  private static func errorEvidence(_ error: Error?) -> String {
    guard let error else { return "none" }
    let value = error as NSError
    let message = value.localizedDescription
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
    return
      "domain=\(value.domain) code=\(value.code) symbol=\(errorSymbol(error)) message=\(message)"
  }

  private static func commissioningTrace(_ message: String) {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let wallClock = formatter.string(from: Date())
    let monotonicMicroseconds = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000)
    let processInstance = message.split(whereSeparator: { $0.isWhitespace }).first.flatMap {
      token -> String? in
      let value = String(token)
      guard value.hasPrefix("client=") else { return nil }
      return String(value.dropFirst("client=".count))
    }
    do {
      try connectionTraceRecorder?.append(
        recordedAt: wallClock,
        monotonicMicroseconds: monotonicMicroseconds,
        processInstance: processInstance,
        message: message
      )
    } catch {
      logger.error("BLE flight-recorder append failed: \(error.localizedDescription, privacy: .public)")
    }
    if ProcessInfo.processInfo.environment[commissioningTraceEnvironmentKey] == "1" {
      FileHandle.standardError.write(
        Data(
          "VHOS_COMMISSIONING timestamp=\(wallClock) monotonic_us=\(monotonicMicroseconds) \(message)\n"
            .utf8
        )
      )
    }
  }

  private func trace(_ message: String) {
    Self.commissioningTrace("client=\(instanceID) \(message)")
  }

  private func resetConnection() {
    reconnectTask?.cancel()
    automaticReconnectActive = false
    central.stopScan()
    scanFallbackTask?.cancel()
    scanActive = false
    scanRequested = false
    resetTransportSession()
    state = .disconnected
  }

  private func resetTransportSession(preservingSelection: Bool = false) {
    let selectedPeripheral = peripheral
    let selectedName = discoveredName
    let selectedIdentifier = discoveredIdentifier
    let selectedRSSI = discoveredRSSI
    let selectedNameEvidence = candidateNameSuggestsGateway
    let selectedVHOSAdvertisementEvidence = candidateAdvertisedVHOSService
    scanFallbackTask?.cancel()
    serviceDiscoveryTask?.cancel()
    restoredConnectionTask?.cancel()
    handshakeRetryTask?.cancel()
    handshakeRetryTask = nil
    handshakeWriteAckTask?.cancel()
    handshakeWriteAckTask = nil
    handshakeResponseTask?.cancel()
    handshakeResponseTask = nil
    notificationEnableTask?.cancel()
    notificationEnableTask = nil
    captureSyncTask?.cancel()
    captureSyncTask = nil
    captureChunkResponseTask?.cancel()
    captureChunkResponseTask = nil
    handshakeWriteAttemptInFlight = nil
    selectedPeripheral?.delegate = nil
    retireActivePeripheralDelegate()
    peripheral = nil
    command = nil
    factoryReadCharacteristic = nil
    streamDecoder = GatewayFrameStreamDecoder()
    pendingCommandChunks.removeAll()
    commandChunksPending = 0
    handshakeRequested = false
    handshakeSecurityRetryCount = 0
    handshakeResponseAttemptCount = 0
    notificationCharacteristics.removeAll()
    notificationSetupInFlight = nil
    notificationRequestSession = nil
    notificationPairingPending = false
    peripheralConnected = false
    gatewayIdentityValidated = false
    connectedAt = nil
    vhosServiceDiscovered = false
    factoryServiceDiscovered = false
    commandChannelReady = false
    streamChannelDiscovered = false
    streamNotificationsEnabled = false
    healthChannelDiscovered = false
    healthNotificationsEnabled = false
    otaStatusChannelDiscovered = false
    otaStatusNotificationsEnabled = false
    decodedFrameCount = 0
    frameDecodeErrorCount = 0
    sequenceDiscontinuityCount = 0
    missingSequenceCount = 0
    lastReceivedSequence = nil
    lastFrameReceivedAt = nil
    lastHandshakeReceivedAt = nil
    lastHealthReceivedAt = nil
    lastOTAStatusAt = nil
    otaStatus = nil
    discoveredName = nil
    discoveredIdentifier = nil
    discoveredRSSI = nil
    candidateNameSuggestsGateway = false
    candidateAdvertisedVHOSService = false
    candidateWasPreviouslyValidated = false
    factoryBanner = nil
    handshake = nil
    health = nil
    j1979Accumulator = J1979Accumulator()
    j1979Availability = []
    standardOBDSamples = []
    captureLogIndex = nil
    captureSyncTargets.removeAll()
    captureSyncMessage = "Waiting for a gateway capture index."
    currentSessionResultStartIndex = experimentResults.count
    if preservingSelection {
      peripheral = selectedPeripheral
      discoveredName = selectedName
      discoveredIdentifier = selectedIdentifier
      discoveredRSSI = selectedRSSI
      candidateNameSuggestsGateway = selectedNameEvidence
      candidateAdvertisedVHOSService = selectedVHOSAdvertisementEvidence
      candidateWasPreviouslyValidated = selectedPeripheral.map(isPreviouslyValidated) ?? false
    }
  }
}

private struct CaptureSyncTarget {
  let slot: UInt8
  let sessionID: UInt32
  let totalRecords: UInt32
  var recordOffset: UInt32
}

struct CaptureSessionSummary: Identifiable {
  let gatewayID: String
  let sessionID: UInt32
  let recordCount: UInt32
  let byteCount: Int64
  let updatedAt: Date
  let url: URL

  var id: String { "\(gatewayID):\(sessionID)" }
}

private final class CaptureLogStore {
  private let fileManager = FileManager.default
  private let root: URL
  private var sequenceCache: [String: Set<UInt64>] = [:]

  init() {
    let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? fileManager.temporaryDirectory
    root = applicationSupport.appendingPathComponent("VHOS/PassiveCAN", isDirectory: true)
    try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func recordCount(gatewayID: String, sessionID: UInt32) -> UInt32 {
    UInt32(sequences(gatewayID: gatewayID, sessionID: sessionID).count)
  }

  func append(
    _ observations: [PassiveCANObservation],
    gatewayID: String,
    sessionID: UInt32
  ) throws -> Int {
    guard !observations.isEmpty else { return 0 }
    let url = fileURL(gatewayID: gatewayID, sessionID: sessionID)
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    var known = sequences(gatewayID: gatewayID, sessionID: sessionID)
    let fresh = observations.filter { known.insert($0.sourceSequence).inserted }
    guard !fresh.isEmpty else { return 0 }
    var bytes = Data()
    for observation in fresh {
      bytes.append(try VHOSJSON.encoder().encode(observation))
      bytes.append(0x0A)
    }
    if !fileManager.fileExists(atPath: url.path) {
      try Data().write(to: url, options: .atomic)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: bytes)
    sequenceCache[cacheKey(gatewayID: gatewayID, sessionID: sessionID)] = known
    return fresh.count
  }

  func summaries() -> [CaptureSessionSummary] {
    guard let gatewayDirectories = try? fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else { return [] }
    var summaries: [CaptureSessionSummary] = []
    for directory in gatewayDirectories {
      guard let files = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
      ) else { continue }
      for file in files where file.pathExtension == "ndjson" {
        guard let sessionID = UInt32(file.deletingPathExtension().lastPathComponent) else { continue }
        let gatewayID = directory.lastPathComponent
        let resources = try? file.resourceValues(
          forKeys: [.fileSizeKey, .contentModificationDateKey])
        let count = recordCount(gatewayID: gatewayID, sessionID: sessionID)
        summaries.append(
          CaptureSessionSummary(
            gatewayID: gatewayID,
            sessionID: sessionID,
            recordCount: count,
            byteCount: Int64(resources?.fileSize ?? 0),
            updatedAt: resources?.contentModificationDate ?? .distantPast,
            url: file
          ))
      }
    }
    return summaries.sorted { $0.updatedAt > $1.updatedAt }
  }

  func exportURL() throws -> URL {
    let sessions = summaries()
    guard !sessions.isEmpty else { throw CaptureSyncError.noStoredLogs }
    let directory = fileManager.temporaryDirectory.appendingPathComponent(
      "VehicleHealthOS-Evidence", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let output = directory.appendingPathComponent("passive-can-recent-logs.ndjson")
    var combined = Data()
    for session in sessions {
      combined.append(try Data(contentsOf: session.url))
    }
    try combined.write(to: output, options: .atomic)
    return output
  }

  private func sequences(gatewayID: String, sessionID: UInt32) -> Set<UInt64> {
    let key = cacheKey(gatewayID: gatewayID, sessionID: sessionID)
    if let cached = sequenceCache[key] { return cached }
    let url = fileURL(gatewayID: gatewayID, sessionID: sessionID)
    guard let bytes = try? Data(contentsOf: url), !bytes.isEmpty else {
      sequenceCache[key] = []
      return []
    }
    var found: Set<UInt64> = []
    for line in bytes.split(separator: 0x0A) {
      if let observation = try? VHOSJSON.decoder().decode(
        PassiveCANObservation.self,
        from: Data(line)
      ) {
        found.insert(observation.sourceSequence)
      }
    }
    sequenceCache[key] = found
    return found
  }

  private func fileURL(gatewayID: String, sessionID: UInt32) -> URL {
    root.appendingPathComponent(sanitized(gatewayID), isDirectory: true)
      .appendingPathComponent("\(sessionID).ndjson")
  }

  private func cacheKey(gatewayID: String, sessionID: UInt32) -> String {
    "\(sanitized(gatewayID)):\(sessionID)"
  }

  private func sanitized(_ value: String) -> String {
    String(value.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
  }
}

private enum CaptureSyncError: Error, LocalizedError {
  case unexpectedChunk
  case emptyNonterminalChunk
  case noStoredLogs

  var errorDescription: String? {
    switch self {
    case .unexpectedChunk: "The gateway returned a capture chunk outside the requested session or offset."
    case .emptyNonterminalChunk: "The gateway returned an empty nonterminal capture chunk."
    case .noStoredLogs: "No synchronized passive CAN logs are stored on this iPhone yet."
    }
  }
}

private struct HandshakeRequest: Encodable {
  let contract = "gateway.handshake.request"
  let contractVersion = "1.0.0"
}

private extension GatewayBLEClient {
  static func timestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
  }
}

enum GatewayBLEError: Error, LocalizedError {
  case commandChannelUnavailable
  case vhosFirmwareRequired
  case reliableWriteRequired

  var errorDescription: String? {
    switch self {
    case .commandChannelUnavailable: "The VHOS BLE command characteristic is unavailable."
    case .vhosFirmwareRequired:
      "Signed experiments require the VHOS gateway firmware, not factory compatibility mode."
    case .reliableWriteRequired: "The VHOS command characteristic must support reliable writes."
    }
  }
}

extension CBManagerState {
  fileprivate var description: String {
    switch self {
    case .unknown: "unknown"
    case .resetting: "resetting"
    case .unsupported: "unsupported"
    case .unauthorized: "unauthorized"
    case .poweredOff: "powered off"
    case .poweredOn: "powered on"
    @unknown default: "unrecognized"
    }
  }
}
