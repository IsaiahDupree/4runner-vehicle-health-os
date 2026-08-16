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

  private var central: CBCentralManager!
  private var peripheral: CBPeripheral?
  private var command: CBCharacteristic?
  private var scanAfterPendingCancellation = false
  private var streamDecoder = GatewayFrameStreamDecoder()
  private var sequence: UInt64 = 1
  private var scanRequested = false
  private var scanFallbackTask: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?
  private var freshCentralRecoveryAttempted = false
  private var automaticReconnectEnabled = false
  private var userRequestedDisconnect = false
  private var handshakeRequested = false
  private var handshakeSecurityRetryCount = 0
  private var notificationSecurityRetryCounts: [CBUUID: Int] = [:]
  private var pendingCommandChunks: [Data] = []

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
  var transportMessage: String?
  var automaticReconnectActive = false
  var reconnectAttemptCount = 0

  var currentSessionExperimentResults: [ProtocolExperimentResult] {
    Array(experimentResults.dropFirst(currentSessionResultStartIndex))
  }

  override init() {
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
      Self.commissioningTrace("AUTO_SCAN_REQUESTED")
    }
  }

  func startScan() {
    reconnectTask?.cancel()
    automaticReconnectActive = false
    automaticReconnectEnabled = true
    userRequestedDisconnect = false
    reconnectAttemptCount = 0
    freshCentralRecoveryAttempted = false
    guard !peripheralConnected else {
      transportMessage = "Disconnect the connected gateway before starting another scan."
      return
    }
    if state == .connecting, let peripheral {
      Self.commissioningTrace("STALE_CONNECTION_CANCEL id=\(peripheral.identifier.uuidString)")
      scanAfterPendingCancellation = true
      scanRequested = true
      transportMessage = "Cancelling a stale gateway connection before scanning…"
      central.cancelPeripheralConnection(peripheral)
      return
    }
    scanRequested = true
    guard central.state == .poweredOn else {
      scanActive = false
      transportMessage = "Bluetooth is not powered on."
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
    scanAfterPendingCancellation = false
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

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    bluetoothStateDescription = central.state.description
    bluetoothReady = central.state == .poweredOn
    Self.commissioningTrace(
      "CENTRAL_STATE state=\(central.state.description) scan_requested=\(scanRequested)"
    )
    if central.state == .poweredOn, scanRequested { startScan() }
    if central.state != .poweredOn {
      scanActive = false
      resetTransportSession()
      state = .disconnected
      transportMessage = "Bluetooth state: \(central.state.description)"
    }
  }

  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    guard
      let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first
    else { return }
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
    let normalizedName = name.lowercased()
    let supported =
      visibleServices.contains(Self.vhosService)
      || visibleServices.contains(Self.factoryService)
      || normalizedName.contains("wican")
      || normalizedName.contains("vhos")
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
    discoveredRSSI = rssi.intValue
    state = .connecting
    transportMessage = "Gateway found; opening BLE link…"
    Self.logger.info(
      "Supported gateway selected name=\(self.discoveredName ?? "unknown", privacy: .public) rssi=\(rssi.intValue)"
    )
    Self.commissioningTrace(
      "GATEWAY_MATCH name=\(self.discoveredName ?? "unknown") rssi=\(rssi.intValue)"
    )
    connect(peripheral)
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    reconnectTask?.cancel()
    reconnectAttemptCount = 0
    automaticReconnectActive = false
    automaticReconnectEnabled = true
    userRequestedDisconnect = false
    peripheralConnected = true
    connectedAt = Date()
    currentSessionResultStartIndex = experimentResults.count
    transportMessage = "Connected; negotiating gateway contract…"
    Self.logger.info("ESP32 BLE connection established")
    Self.commissioningTrace("LINK_CONNECTED id=\(peripheral.identifier.uuidString)")
    peripheral.discoverServices([Self.vhosService, Self.factoryService])
  }

  func centralManager(
    _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
  ) {
    if scanAfterPendingCancellation {
      scanAfterPendingCancellation = false
      resetConnection()
      startScan()
      return
    }
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
    if let error {
      state = .failed
      transportMessage = error.localizedDescription
      return
    }
    let services = peripheral.services ?? []
    for service in services {
      if service.uuid == Self.vhosService {
        vhosServiceDiscovered = true
        peripheral.discoverCharacteristics(
          [
            Self.commandCharacteristic, Self.streamCharacteristic, Self.statusCharacteristic,
            Self.otaStatusCharacteristic,
          ],
          for: service
        )
      } else if service.uuid == Self.factoryService {
        factoryServiceDiscovered = true
        peripheral.discoverCharacteristics([Self.factoryCharacteristic], for: service)
      }
    }
    if !vhosServiceDiscovered, !factoryServiceDiscovered {
      state = .failed
      transportMessage = "Connected device does not advertise a supported gateway service."
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
  ) {
    if let error {
      state = .failed
      transportMessage = error.localizedDescription
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
      transportMessage = "VHOS gateway contract active."
      Self.logger.info("VHOS gateway handshake verified")
      Self.commissioningTrace("HANDSHAKE_VERIFIED firmware=\(value.firmwareVersion)")
    case .gatewayHealth:
      health = try VHOSJSON.decoder().decode(GatewayHealth.self, from: frame.payload)
      lastHealthReceivedAt = Date()
    case .experimentResult:
      let result = try VHOSJSON.decoder().decode(ProtocolExperimentResult.self, from: frame.payload)
      experimentResults.append(result)
      lastExperimentResultAt = Date()
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
    central.connect(
      peripheral,
      options: [
        CBConnectPeripheralOptionEnableAutoReconnect: true,
        CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
      ])
  }

  private func handleDisconnect(
    _ peripheral: CBPeripheral, isSystemReconnecting: Bool, error: Error?
  ) {
    if scanAfterPendingCancellation {
      scanAfterPendingCancellation = false
      resetConnection()
      startScan()
      return
    }
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

  private func resetConnection() {
    reconnectTask?.cancel()
    automaticReconnectActive = false
    scanAfterPendingCancellation = false
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
    scanFallbackTask?.cancel()
    peripheral = nil
    command = nil
    streamDecoder = GatewayFrameStreamDecoder()
    pendingCommandChunks.removeAll()
    commandChunksPending = 0
    handshakeRequested = false
    handshakeSecurityRetryCount = 0
    notificationSecurityRetryCounts.removeAll()
    peripheralConnected = false
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
    factoryBanner = nil
    handshake = nil
    health = nil
    currentSessionResultStartIndex = experimentResults.count
    if preservingSelection {
      peripheral = selectedPeripheral
      discoveredName = selectedName
      discoveredIdentifier = selectedIdentifier
      discoveredRSSI = selectedRSSI
    }
  }
}

private struct HandshakeRequest: Encodable {
  let contract = "gateway.handshake.request"
  let contractVersion = "1.0.0"
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
