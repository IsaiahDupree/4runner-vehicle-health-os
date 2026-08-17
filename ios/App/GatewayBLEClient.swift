@preconcurrency import CoreBluetooth
import Foundation
import Observation
import OSLog
import VHOSCore

@MainActor
@Observable
final class GatewayBLEClient: NSObject, @preconcurrency CBCentralManagerDelegate,
  @preconcurrency CBPeripheralDelegate
{
  static let shared = GatewayBLEClient()

  private static let logger = Logger(
    subsystem: "com.isaiahdupree.VehicleHealthOS", category: "GatewayBLE")
  static let vhosService = CBUUID(string: "33613EB3-FFCA-42D1-83FA-A18F12B3F123")
  static let commandCharacteristic = CBUUID(string: "B3D3279B-0244-4D54-A2AB-A1AB47A5FC0A")
  static let streamCharacteristic = CBUUID(string: "265B90C0-A600-4659-BBBD-5CDA411C49CC")
  static let statusCharacteristic = CBUUID(string: "BCB5699A-A9B4-49B8-B69B-D2DFF19B41A9")
  static let otaStatusCharacteristic = CBUUID(string: "18D21F8E-D190-4DB3-923C-27BBFC355874")
  static let factoryService = CBUUID(string: "FEE0")
  static let factoryCharacteristic = CBUUID(string: "FEE1")
  private static let securityRetryLimit = 30
  private static let autoScanArgument = "--vhos-auto-scan"
  private static let autoScanEnvironmentKey = "VHOS_AUTO_SCAN"
  private static let commissioningTraceEnvironmentKey = "VHOS_COMMISSIONING_TRACE"
  private static let centralRestoreIdentifier =
    "com.isaiahdupree.VehicleHealthOS.central.v2"
  private static let validatedPeripheralIdentifiersKey =
    "vhos.validatedGatewayPeripheralIdentifiers.v1"

  private var central: CBCentralManager!
  private let instanceID = String(UUID().uuidString.prefix(8))
  private var peripheral: CBPeripheral?
  private var command: CBCharacteristic?
  private var streamDecoder = GatewayFrameStreamDecoder()
  private var sequence: UInt64 = 1
  private var scanRequested = false
  private var scanFallbackTask: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?
  private var serviceDiscoveryTask: Task<Void, Never>?
  private var restoredConnectionTask: Task<Void, Never>?
  private var freshCentralRecoveryAttempted = false
  private var automaticReconnectEnabled = false
  private var userRequestedDisconnect = false
  private var handshakeRequested = false
  private var handshakeSecurityRetryCount = 0
  private var notificationSecurityRetryCounts: [CBUUID: Int] = [:]
  private var pendingCommandChunks: [Data] = []
  private var candidateNameSuggestsGateway = false
  private var candidateAdvertisedVHOSService = false
  private var candidateWasPreviouslyValidated = false
  private let captureStore = CaptureLogStore()
  private var captureSyncTargets: [CaptureSyncTarget] = []

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
  var transportMessage: String?
  var automaticReconnectActive = false
  var reconnectAttemptCount = 0

  var currentSessionExperimentResults: [ProtocolExperimentResult] {
    Array(experimentResults.dropFirst(currentSessionResultStartIndex))
  }

  private override init() {
    super.init()
    scanRequested = CommandLine.arguments.contains(Self.autoScanArgument)
      || ProcessInfo.processInfo.environment[Self.autoScanEnvironmentKey] == "1"
    central = CBCentralManager(
      delegate: self,
      queue: .main,
      options: [
        CBCentralManagerOptionRestoreIdentifierKey: Self.centralRestoreIdentifier
      ]
    )
    if scanRequested {
      Self.logger.info("BLE auto-scan requested by commissioning launch")
      trace("AUTO_SCAN_REQUESTED")
    }
    trace("CLIENT_INITIALIZED")
  }

  func startScan(source: String = "user") {
    trace(
      "SCAN_REQUEST source=\(source) state=\(state.rawValue) peripheral=\(peripheral?.identifier.uuidString ?? "none") connected=\(peripheralConnected) active=\(scanActive)"
    )
    if state == .connecting, peripheral != nil {
      Self.commissioningTrace("SCAN_IGNORED reason=gateway-connection-in-progress")
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
    let connected = central.retrieveConnectedPeripherals(withServices: [Self.vhosService]).first
    if let connected {
      resetTransportSession()
      scanRequested = false
      scanActive = false
      scanMode = "Restored connection"
      discoveredName = connected.name ?? connected.identifier.uuidString
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
    userRequestedDisconnect = true
    automaticReconnectEnabled = false
    automaticReconnectActive = false
    reconnectTask?.cancel()
    scanRequested = false
    scanFallbackTask?.cancel()
    central.stopScan()
    if let peripheral { central.cancelPeripheralConnection(peripheral) }
    resetConnection()
    transportMessage = "Gateway disconnected by user."
  }

  func sendSignedExperimentPlan(_ envelope: SignedExperimentPlanEnvelope) throws {
    guard state == .vhosConnected else { throw GatewayBLEError.vhosFirmwareRequired }
    try writeFrame(type: .experimentPlan, payload: envelope.encoded())
  }

  func captureLogExportURL() throws -> URL {
    try captureStore.exportURL()
  }

  func refreshCaptureLogIndex() {
    do {
      try writeFrame(type: .captureLogRequest, payload: CaptureLogRequest(operation: .index).encoded())
      captureSyncMessage = "Requesting the gateway capture index…"
    } catch {
      captureSyncMessage = error.localizedDescription
    }
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    bluetoothStateDescription = central.state.description
    bluetoothReady = central.state == .poweredOn
    Self.commissioningTrace(
      "CENTRAL_STATE state=\(central.state.description) scan_requested=\(scanRequested)"
    )
    if central.state == .poweredOn, scanRequested { startScan(source: "central-state") }
    if central.state != .poweredOn {
      scanActive = false
      resetTransportSession()
      state = .disconnected
      transportMessage = "Bluetooth state: \(central.state.description)"
    }
  }

  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    let restoredPeripherals =
      (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
    guard
      let restored = restoredPeripherals.first(where: { isPreviouslyValidated($0) })
    else {
      for peripheral in restoredPeripherals
      where peripheral.state == .connected || peripheral.state == .connecting {
        central.cancelPeripheralConnection(peripheral)
      }
      scanRequested = true
      transportMessage =
        "Discarded an unverified restored BLE device; scanning for the VHOS service…"
      Self.commissioningTrace(
        "RESTORE_REJECTED count=\(restoredPeripherals.count) reason=not-previously-validated"
      )
      if central.state == .poweredOn { startScan(source: "restore-rejection") }
      return
    }
    candidateNameSuggestsGateway = GatewayBLEIdentityPolicy.nameSuggestsGateway(restored.name)
    candidateAdvertisedVHOSService = false
    candidateWasPreviouslyValidated = true
    if restored.state == .connected {
      scanRequested = false
      scanActive = false
      scanMode = "Restored connection"
      discoveredName = restored.name ?? restored.identifier.uuidString
      discoveredIdentifier = restored.identifier.uuidString
      beginServiceDiscovery(restored, source: "state-restoration")
      return
    }
    if restored.state == .connecting {
      peripheral = restored
      restored.delegate = self
      automaticReconnectEnabled = true
      userRequestedDisconnect = false
      discoveredName = restored.name ?? restored.identifier.uuidString
      discoveredIdentifier = restored.identifier.uuidString
      state = .connecting
      transportMessage = "Restoring the in-progress gateway connection…"
      Self.commissioningTrace(
        "RESTORE_WAITING id=\(restored.identifier.uuidString) state=\(restored.state.rawValue)"
      )
      armRestoredConnectionTimeout(restored)
      return
    }
    if scanRequested {
      Self.commissioningTrace(
        "RESTORE_SKIPPED_FOR_SCAN id=\(restored.identifier.uuidString) state=\(restored.state.rawValue)"
      )
      return
    }
    peripheral = restored
    restored.delegate = self
    automaticReconnectEnabled = true
    userRequestedDisconnect = false
    discoveredName = restored.name ?? restored.identifier.uuidString
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
    central.stopScan()
    scanFallbackTask?.cancel()
    scanRequested = false
    scanActive = false
    scanMode = "Matched"
    self.peripheral = peripheral
    peripheral.delegate = self
    discoveredName = name.isEmpty ? peripheral.identifier.uuidString : name
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
    guard self.peripheral?.identifier == peripheral.identifier else {
      Self.commissioningTrace(
        "STALE_LINK_CONNECTED_IGNORED id=\(peripheral.identifier.uuidString)"
      )
      central.cancelPeripheralConnection(peripheral)
      return
    }
    beginServiceDiscovery(peripheral, source: "did-connect")
  }

  func centralManager(
    _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
  ) {
    guard self.peripheral?.identifier == peripheral.identifier else {
      Self.commissioningTrace(
        "STALE_LINK_FAILURE_IGNORED id=\(peripheral.identifier.uuidString)"
      )
      return
    }
    let failure = error.map {
      let value = $0 as NSError
      return "domain=\(value.domain) code=\(value.code) message=\(value.localizedDescription)"
    } ?? "none"
    Self.commissioningTrace("LINK_FAILED_DETAIL \(failure)")
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
    handleDisconnect(peripheral, isSystemReconnecting: false, error: error)
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    timestamp: CFAbsoluteTime,
    isReconnecting: Bool,
    error: Error?
  ) {
    handleDisconnect(peripheral, isSystemReconnecting: isReconnecting, error: error)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard self.peripheral?.identifier == peripheral.identifier else {
      Self.commissioningTrace(
        "STALE_SERVICE_RESULT_IGNORED id=\(peripheral.identifier.uuidString)"
      )
      return
    }
    serviceDiscoveryTask?.cancel()
    if let error {
      let value = error as NSError
      Self.commissioningTrace(
        "SERVICE_DISCOVERY_FAILED domain=\(value.domain) code=\(value.code) message=\(value.localizedDescription)"
      )
      transportMessage = "Gateway services did not respond; refreshing the BLE link automatically…"
      central.cancelPeripheralConnection(peripheral)
      return
    }
    let services = peripheral.services ?? []
    Self.commissioningTrace(
      "SERVICES_DISCOVERED uuids=\(services.map { $0.uuid.uuidString }.joined(separator: ","))"
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
        peripheral.discoverCharacteristics(
          [
            Self.commandCharacteristic, Self.streamCharacteristic, Self.statusCharacteristic,
            Self.otaStatusCharacteristic,
          ],
          for: service
        )
      } else if kind == .factoryWiCAN, service.uuid == Self.factoryService {
        factoryServiceDiscovered = true
        peripheral.discoverCharacteristics([Self.factoryCharacteristic], for: service)
      }
    }
    if vhosServiceDiscovered || factoryServiceDiscovered {
      armGATTDiscoveryTimeout(peripheral, phase: "characteristics")
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
  ) {
    serviceDiscoveryTask?.cancel()
    if let error {
      let value = error as NSError
      Self.commissioningTrace(
        "CHARACTERISTICS_FAILED service=\(service.uuid.uuidString) domain=\(value.domain) code=\(value.code)"
      )
      transportMessage = "Gateway characteristics did not respond; refreshing the BLE link automatically…"
      central.cancelPeripheralConnection(peripheral)
      return
    }
    for characteristic in service.characteristics ?? [] {
      switch characteristic.uuid {
      case Self.commandCharacteristic:
        command = characteristic
        commandChannelReady = characteristic.properties.contains(.write)
      case Self.streamCharacteristic:
        streamChannelDiscovered = true
        peripheral.setNotifyValue(true, for: characteristic)
      case Self.statusCharacteristic:
        healthChannelDiscovered = true
        peripheral.setNotifyValue(true, for: characteristic)
      case Self.otaStatusCharacteristic:
        otaStatusChannelDiscovered = true
        peripheral.setNotifyValue(true, for: characteristic)
      case Self.factoryCharacteristic:
        state = .factoryCompatible
        factoryBanner =
          "Factory WiCAN BLE service detected. Install the VHOS firmware fork before vehicle experiments."
        if characteristic.properties.contains(.read) { peripheral.readValue(for: characteristic) }
        if characteristic.properties.contains(.notify) {
          peripheral.setNotifyValue(true, for: characteristic)
        }
      default:
        break
      }
    }
    Self.commissioningTrace(
      "CHARACTERISTICS_DISCOVERED service=\(service.uuid.uuidString) count=\(service.characteristics?.count ?? 0)"
    )
    if service.uuid == Self.vhosService { requestHandshakeIfReady() }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    if let error {
      let retryCount = notificationSecurityRetryCounts[characteristic.uuid, default: 0]
      if isSecurityNegotiationError(error), retryCount < Self.securityRetryLimit {
        let nextRetry = retryCount + 1
        notificationSecurityRetryCounts[characteristic.uuid] = nextRetry
        transportMessage =
          "Pairing with ESP32; secure notification retry \(nextRetry)/\(Self.securityRetryLimit)…"
        Self.logger.info(
          "Waiting for BLE pairing before notification retry uuid=\(characteristic.uuid.uuidString, privacy: .public) attempt=\(nextRetry)"
        )
        Task { [weak self, weak peripheral] in
          try? await Task.sleep(for: .seconds(1))
          guard !Task.isCancelled, let self, let peripheral, self.peripheralConnected else {
            return
          }
          peripheral.setNotifyValue(true, for: characteristic)
        }
        return
      }
      state = .degraded
      transportMessage = error.localizedDescription
      return
    }
    notificationSecurityRetryCounts[characteristic.uuid] = 0
    switch characteristic.uuid {
    case Self.streamCharacteristic:
      streamNotificationsEnabled = characteristic.isNotifying
    case Self.statusCharacteristic:
      healthNotificationsEnabled = characteristic.isNotifying
    case Self.otaStatusCharacteristic:
      otaStatusNotificationsEnabled = characteristic.isNotifying
    default:
      break
    }
    requestHandshakeIfReady()
  }

  func peripheral(
    _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
  ) {
    if let error {
      transportMessage = error.localizedDescription
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

  func peripheral(
    _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?
  ) {
    guard characteristic.uuid == Self.commandCharacteristic else { return }
    if let error {
      pendingCommandChunks.removeAll()
      commandChunksPending = 0
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
        Task { [weak self] in
          try? await Task.sleep(for: .seconds(1))
          guard !Task.isCancelled else { return }
          self?.requestHandshakeIfReady()
        }
        return
      }
      state = .degraded
      transportMessage = error.localizedDescription
      return
    }
    if !pendingCommandChunks.isEmpty { pendingCommandChunks.removeFirst() }
    commandChunksPending = pendingCommandChunks.count
    sendNextCommandChunk()
  }

  private func requestHandshake() {
    do {
      let payload = try VHOSJSON.encoder().encode(HandshakeRequest())
      try writeFrame(type: .handshake, payload: payload)
    } catch {
      state = .failed
      transportMessage = error.localizedDescription
    }
  }

  private func requestHandshakeIfReady() {
    guard
      !handshakeRequested,
      command != nil,
      streamNotificationsEnabled,
      healthNotificationsEnabled
    else { return }
    handshakeRequested = true
    requestHandshake()
  }

  private func consume(_ frame: GatewayFrame) throws {
    switch frame.messageType {
    case .handshake:
      let value = try VHOSJSON.decoder().decode(GatewayHandshake.self, from: frame.payload)
      handshake = value
      lastHandshakeReceivedAt = Date()
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
      beginCaptureSync(index)
    case .captureLogChunk:
      guard let gatewayID = handshake?.gatewayID else { return }
      let chunk = try CaptureLogChunk.decode(
        frame.payload,
        gatewayID: gatewayID,
        ingestedAt: Self.timestamp()
      )
      try consumeCaptureChunk(chunk)
    case .otaControl:
      lastOTAStatusAt = Date()
      transportMessage = String(data: frame.payload, encoding: .utf8) ?? "OTA status received."
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

  private func beginCaptureSync(_ index: CaptureLogIndex) {
    guard let gatewayID = handshake?.gatewayID else { return }
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
    requestNextCaptureChunk()
  }

  private func requestNextCaptureChunk() {
    while let target = captureSyncTargets.first,
      target.recordOffset >= target.totalRecords
    {
      captureSyncTargets.removeFirst()
    }
    guard let target = captureSyncTargets.first else {
      captureSessions = captureStore.summaries()
      captureSyncMessage = "Recent gateway logs are synchronized on this iPhone."
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
    } catch {
      captureSyncMessage = error.localizedDescription
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
    guard let gatewayID = handshake?.gatewayID else { return }
    let appended = try captureStore.append(
      chunk.records,
      gatewayID: gatewayID,
      sessionID: chunk.sessionID
    )
    captureDownloadedRecords &+= UInt64(appended)
    target.recordOffset &+= UInt32(chunk.records.count)
    captureSyncTargets[0] = target
    captureSessions = captureStore.summaries()
    if chunk.endOfFile || target.recordOffset >= target.totalRecords {
      captureSyncTargets.removeFirst()
    } else if chunk.records.isEmpty {
      throw CaptureSyncError.emptyNonterminalChunk
    }
    requestNextCaptureChunk()
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
    self.peripheral = peripheral
    peripheral.delegate = self
    if peripheral.state == .connected {
      beginServiceDiscovery(peripheral, source: "already-connected")
      return
    }
    if peripheral.state == .connecting {
      state = .connecting
      transportMessage = "Waiting for the existing gateway connection…"
      Self.commissioningTrace("CONNECT_WAITING id=\(peripheral.identifier.uuidString)")
      armRestoredConnectionTimeout(peripheral)
      return
    }
    central.connect(
      peripheral,
      options: [
        CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
      ])
  }

  private func handleDisconnect(
    _ peripheral: CBPeripheral, isSystemReconnecting: Bool, error: Error?
  ) {
    guard self.peripheral?.identifier == peripheral.identifier else {
      Self.commissioningTrace(
        "STALE_DISCONNECT_IGNORED id=\(peripheral.identifier.uuidString)"
      )
      return
    }
    let failure = error.map {
      let value = $0 as NSError
      return "domain=\(value.domain) code=\(value.code) message=\(value.localizedDescription)"
    } ?? "none"
    Self.commissioningTrace(
      "LINK_DISCONNECTED system_reconnecting=\(isSystemReconnecting) \(failure)"
    )
    if userRequestedDisconnect || !automaticReconnectEnabled {
      resetConnection()
      transportMessage = "Gateway disconnected by user."
      return
    }
    resetTransportSession(preservingSelection: true)
    if isSystemReconnecting {
      automaticReconnectActive = true
      state = .connecting
      transportMessage = "Connection interrupted; iPhone is automatically reconnecting…"
      Self.commissioningTrace("SYSTEM_RECONNECT_ACTIVE")
      return
    }
    scheduleReconnect(to: peripheral, error: error)
  }

  private func beginServiceDiscovery(_ peripheral: CBPeripheral, source: String) {
    restoredConnectionTask?.cancel()
    reconnectTask?.cancel()
    automaticReconnectActive = false
    automaticReconnectEnabled = true
    userRequestedDisconnect = false
    self.peripheral = peripheral
    peripheral.delegate = self
    peripheralConnected = true
    gatewayIdentityValidated = false
    connectedAt = Date()
    currentSessionResultStartIndex = experimentResults.count
    state = .connecting
    transportMessage = "Connected; negotiating gateway contract…"
    Self.logger.info("ESP32 BLE connection established via \(source, privacy: .public)")
    Self.commissioningTrace(
      "LINK_CONNECTED id=\(peripheral.identifier.uuidString) source=\(source) state=\(peripheral.state.rawValue)"
    )
    peripheral.discoverServices([Self.vhosService, Self.factoryService])
    armGATTDiscoveryTimeout(peripheral, phase: "services")
  }

  private func armGATTDiscoveryTimeout(_ peripheral: CBPeripheral, phase: String) {
    serviceDiscoveryTask?.cancel()
    serviceDiscoveryTask = Task { [weak self, weak peripheral] in
      try? await Task.sleep(for: .seconds(12))
      guard !Task.isCancelled, let self, let peripheral,
        self.peripheral?.identifier == peripheral.identifier, self.peripheralConnected
      else { return }
      let complete = phase == "services"
        ? (self.vhosServiceDiscovered || self.factoryServiceDiscovered)
        : ((self.factoryServiceDiscovered && self.state == .factoryCompatible)
          || (self.commandChannelReady && self.streamChannelDiscovered
            && self.healthChannelDiscovered && self.otaStatusChannelDiscovered))
      guard !complete else { return }
      if phase == "services", !self.gatewayIdentityValidated {
        if self.candidateAdvertisedVHOSService || self.candidateWasPreviouslyValidated {
          self.transportMessage =
            "VHOS gateway service discovery timed out; refreshing the trusted link…"
          Self.commissioningTrace(
            "TRUSTED_GATT_TIMEOUT id=\(peripheral.identifier.uuidString)"
          )
          self.central.cancelPeripheralConnection(peripheral)
        } else {
          self.rejectCandidateAndResumeScanning(
            peripheral, reason: "BLE candidate did not prove a VHOS/WiCAN service identity.")
        }
        return
      }
      self.transportMessage = "Verified gateway GATT is not responding; refreshing it automatically…"
      Self.commissioningTrace(
        "GATT_DISCOVERY_TIMEOUT phase=\(phase) id=\(peripheral.identifier.uuidString) state=\(peripheral.state.rawValue)"
      )
      self.central.cancelPeripheralConnection(peripheral)
    }
  }

  private func armRestoredConnectionTimeout(_ peripheral: CBPeripheral) {
    restoredConnectionTask?.cancel()
    restoredConnectionTask = Task { [weak self, weak peripheral] in
      try? await Task.sleep(for: .seconds(12))
      guard !Task.isCancelled, let self, let peripheral,
        self.peripheral?.identifier == peripheral.identifier,
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
        "RESTORED_CONNECT_TIMEOUT id=\(peripheral.identifier.uuidString) state=\(peripheral.state.rawValue) recovery=cancel-and-scan"
      )
      self.transportMessage =
        "The restored BLE connection stopped responding; scanning again automatically…"
      self.central.cancelPeripheralConnection(peripheral)
      self.resetTransportSession()
      self.startScan(source: "restored-connection-timeout")
    }
  }

  private func scheduleReconnect(to peripheral: CBPeripheral, error: Error?) {
    reconnectTask?.cancel()
    resetTransportSession(preservingSelection: true)
    self.peripheral = peripheral
    peripheral.delegate = self
    reconnectAttemptCount += 1
    automaticReconnectActive = true
    state = .connecting
    let delays = [1, 2, 4, 8, 15, 30]
    let delay = delays[min(reconnectAttemptCount - 1, delays.count - 1)]
    let reason = connectionFailureMessage(error, fallback: "BLE link interrupted.")
    transportMessage =
      "\(reason) Reconnecting automatically in \(delay) second\(delay == 1 ? "" : "s")…"
    Self.commissioningTrace(
      "RECONNECT_SCHEDULED attempt=\(reconnectAttemptCount) delay=\(delay)"
    )
    reconnectTask = Task { [weak self, weak peripheral] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, let self, let peripheral,
        self.automaticReconnectEnabled, !self.userRequestedDisconnect,
        self.central.state == .poweredOn
      else { return }
      self.transportMessage =
        "Reconnecting to \(self.discoveredName ?? "the saved gateway")…"
      self.connect(peripheral)
    }
  }

  private func rebuildCentralForFreshPairing() {
    freshCentralRecoveryAttempted = true
    Self.logger.info("Discarding restored CoreBluetooth state after peer removed pairing data")
    Self.commissioningTrace("CENTRAL_REBUILD reason=peer-removed-pairing-information")
    central.stopScan()
    central.delegate = nil
    resetTransportSession()
    scanRequested = true
    automaticReconnectEnabled = true
    userRequestedDisconnect = false
    state = .scanning
    transportMessage = "Resetting the Bluetooth session for fresh pairing…"
    central = CBCentralManager(delegate: self, queue: .main, options: nil)
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

  private func connectionFailureMessage(_ error: Error?, fallback: String) -> String {
    guard let error else { return fallback }
    let value = error as NSError
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
    return error.localizedDescription
  }

  private static func commissioningTrace(_ message: String) {
    guard ProcessInfo.processInfo.environment[commissioningTraceEnvironmentKey] == "1" else {
      return
    }
    FileHandle.standardError.write(Data("VHOS_COMMISSIONING \(message)\n".utf8))
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
    peripheral = nil
    command = nil
    streamDecoder = GatewayFrameStreamDecoder()
    pendingCommandChunks.removeAll()
    commandChunksPending = 0
    handshakeRequested = false
    handshakeSecurityRetryCount = 0
    notificationSecurityRetryCounts.removeAll()
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
    discoveredName = nil
    discoveredIdentifier = nil
    discoveredRSSI = nil
    candidateNameSuggestsGateway = false
    candidateAdvertisedVHOSService = false
    candidateWasPreviouslyValidated = false
    factoryBanner = nil
    handshake = nil
    health = nil
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
