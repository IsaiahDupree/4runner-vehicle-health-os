@preconcurrency import CoreBluetooth
import Foundation
import Observation
import VHOSCore

@MainActor
@Observable
final class GatewayBLEClient: NSObject, @preconcurrency CBCentralManagerDelegate,
  @preconcurrency CBPeripheralDelegate
{
  static let vhosService = CBUUID(string: "33613EB3-FFCA-42D1-83FA-A18F12B3F123")
  static let commandCharacteristic = CBUUID(string: "B3D3279B-0244-4D54-A2AB-A1AB47A5FC0A")
  static let streamCharacteristic = CBUUID(string: "265B90C0-A600-4659-BBBD-5CDA411C49CC")
  static let statusCharacteristic = CBUUID(string: "BCB5699A-A9B4-49B8-B69B-D2DFF19B41A9")
  static let otaStatusCharacteristic = CBUUID(string: "18D21F8E-D190-4DB3-923C-27BBFC355874")
  static let factoryService = CBUUID(string: "FEE0")
  static let factoryCharacteristic = CBUUID(string: "FEE1")

  private var central: CBCentralManager!
  private var peripheral: CBPeripheral?
  private var command: CBCharacteristic?
  private var streamDecoder = GatewayFrameStreamDecoder()
  private var sequence: UInt64 = 1
  private var scanRequested = false
  private var pendingCommandChunks: [Data] = []

  var state: GatewayConnectionState = .disconnected
  var discoveredName: String?
  var factoryBanner: String?
  var handshake: GatewayHandshake?
  var health: GatewayHealth?
  var experimentResults: [ProtocolExperimentResult] = []
  var transportMessage: String?

  override init() {
    super.init()
    central = CBCentralManager(
      delegate: self,
      queue: .main,
      options: [
        CBCentralManagerOptionRestoreIdentifierKey: "com.isaiahdupree.VehicleHealthOS.central"
      ]
    )
  }

  func startScan() {
    scanRequested = true
    guard central.state == .poweredOn else {
      transportMessage = "Bluetooth is not powered on."
      return
    }
    state = .scanning
    central.scanForPeripherals(
      withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
  }

  func disconnect() {
    scanRequested = false
    central.stopScan()
    if let peripheral { central.cancelPeripheralConnection(peripheral) }
    resetConnection()
  }

  func sendSignedExperimentPlan(_ envelope: SignedExperimentPlanEnvelope) throws {
    guard state == .vhosConnected else { throw GatewayBLEError.vhosFirmwareRequired }
    try writeFrame(type: .experimentPlan, payload: envelope.encoded())
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if central.state == .poweredOn, scanRequested { startScan() }
    if central.state != .poweredOn {
      state = .disconnected
      transportMessage = "Bluetooth state: \(central.state.description)"
    }
  }

  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    guard
      let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first
    else { return }
    peripheral = restored
    restored.delegate = self
    state = .connecting
    central.connect(restored)
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi: NSNumber
  ) {
    let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
    let name =
      (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
    let normalizedName = name.lowercased()
    let supported =
      advertised.contains(Self.vhosService)
      || advertised.contains(Self.factoryService)
      || normalizedName.contains("wican")
      || normalizedName.contains("vhos")
    guard supported else { return }
    central.stopScan()
    self.peripheral = peripheral
    peripheral.delegate = self
    discoveredName = name.isEmpty ? peripheral.identifier.uuidString : name
    state = .connecting
    central.connect(peripheral)
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    transportMessage = "Connected; negotiating gateway contract…"
    peripheral.discoverServices([Self.vhosService, Self.factoryService])
  }

  func centralManager(
    _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
  ) {
    state = .failed
    transportMessage = error?.localizedDescription ?? "Gateway connection failed."
  }

  func centralManager(
    _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
  ) {
    resetConnection()
    transportMessage = error?.localizedDescription ?? "Gateway disconnected."
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    if let error {
      state = .failed
      transportMessage = error.localizedDescription
      return
    }
    for service in peripheral.services ?? [] {
      if service.uuid == Self.vhosService {
        peripheral.discoverCharacteristics(
          [
            Self.commandCharacteristic, Self.streamCharacteristic, Self.statusCharacteristic,
            Self.otaStatusCharacteristic,
          ],
          for: service
        )
      } else if service.uuid == Self.factoryService {
        peripheral.discoverCharacteristics([Self.factoryCharacteristic], for: service)
      }
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
      case Self.streamCharacteristic, Self.statusCharacteristic, Self.otaStatusCharacteristic:
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
    if service.uuid == Self.vhosService, command != nil {
      requestHandshake()
    }
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
      for frame in try streamDecoder.append(value) { try consume(frame) }
    } catch {
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
      state = .degraded
      transportMessage = error.localizedDescription
      return
    }
    if !pendingCommandChunks.isEmpty { pendingCommandChunks.removeFirst() }
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

  private func consume(_ frame: GatewayFrame) throws {
    switch frame.messageType {
    case .handshake:
      let value = try VHOSJSON.decoder().decode(GatewayHandshake.self, from: frame.payload)
      handshake = value
      state = .vhosConnected
      transportMessage = "VHOS gateway contract active."
    case .gatewayHealth:
      health = try VHOSJSON.decoder().decode(GatewayHealth.self, from: frame.payload)
    case .experimentResult:
      let result = try VHOSJSON.decoder().decode(ProtocolExperimentResult.self, from: frame.payload)
      experimentResults.append(result)
    case .otaControl:
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
    if pendingCommandChunks.count == Int(ceil(Double(bytes.count) / Double(maximum))) {
      sendNextCommandChunk()
    }
  }

  private func sendNextCommandChunk() {
    guard let peripheral, let command, let next = pendingCommandChunks.first else { return }
    peripheral.writeValue(next, for: command, type: .withResponse)
  }

  private func resetConnection() {
    central.stopScan()
    peripheral = nil
    command = nil
    streamDecoder = GatewayFrameStreamDecoder()
    pendingCommandChunks.removeAll()
    state = .disconnected
    handshake = nil
    health = nil
  }
}

private struct HandshakeRequest: Codable {
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
