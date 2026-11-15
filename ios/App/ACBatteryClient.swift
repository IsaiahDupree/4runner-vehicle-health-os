@preconcurrency import CoreBluetooth
import Foundation
import Observation
import VHOSCore

@MainActor
@Observable
final class ACBatteryClient: NSObject, @preconcurrency CBCentralManagerDelegate,
  @preconcurrency CBPeripheralDelegate
{
  private static let service = CBUUID(string: "CB09443D-4F7E-4529-A8E6-E84391864ACE")
  private static let identityCharacteristic = CBUUID(string: "A81A38E3-C36C-4EC7-80CC-9199C922E624")
  private static let sampleCharacteristic = CBUUID(string: "9686641E-3831-428A-891F-BCFE4846B0D9")

  private(set) var message = "Connect to the A/C logger with its switch in RUN."
  private(set) var reading: ACBatteryReading?
  private(set) var active = false
  private(set) var observedAt: Date?

  @ObservationIgnored private var central: CBCentralManager?
  @ObservationIgnored private var node: CBPeripheral?
  @ObservationIgnored private var sampleCharacteristic: CBCharacteristic?
  @ObservationIgnored private var identity: ACBatteryIdentity?
  @ObservationIgnored private var sessionFile: URL?
  @ObservationIgnored private var sequence: UInt64 = 0
  @ObservationIgnored private var sampledAt: UInt64 = 0
  @ObservationIgnored private var poll: Task<Void, Never>?
  @ObservationIgnored private var deadline: Task<Void, Never>?

  func connect() {
    guard !active else { return }
    active = true
    if let central {
      centralManagerDidUpdateState(central)
    } else {
      central = CBCentralManager(delegate: self, queue: .main)
    }
    armDeadline("No A/C battery telemetry. Check the logger power and Bluetooth pairing.", seconds: 25)
  }

  func disconnect() { close("A/C battery disconnected.") }

  private func close(_ reason: String) {
    active = false
    deadline?.cancel()
    deadline = nil
    poll?.cancel()
    poll = nil
    central?.stopScan()
    if let node, node.state != .disconnected { central?.cancelPeripheralConnection(node) }
    node?.delegate = nil
    node = nil
    identity = nil
    sessionFile = nil
    sampleCharacteristic = nil
    sequence = 0
    sampledAt = 0
    reading = nil
    observedAt = nil
    message = reason
  }

  private func armDeadline(_ reason: String, seconds: Int) {
    deadline?.cancel()
    deadline = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
      self?.close(reason)
    }
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard active else { return }
    switch central.state {
    case .poweredOn:
      message = "Looking for the A/C logger."
      if node == nil { central.scanForPeripherals(withServices: [Self.service]) }
    case .unknown, .resetting:
      message = "Waiting for Bluetooth."
    default:
      close("Bluetooth must be available to connect.")
    }
  }

  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any], rssi RSSI: NSNumber)
  {
    guard active, node == nil else { return }
    central.stopScan()
    node = peripheral
    peripheral.delegate = self
    central.connect(peripheral)
    message = "Connecting to the A/C logger."
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard active, node === peripheral else { return }
    peripheral.discoverServices([Self.service])
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
    error: (any Error)?)
  {
    if node === peripheral { close("Could not connect to the A/C logger.") }
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
    error: (any Error)?)
  {
    if node === peripheral { close("A/C battery disconnected.") }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
    guard active, node === peripheral else { return }
    guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service })
    else { return close("A/C battery service unavailable.") }
    peripheral.discoverCharacteristics([Self.identityCharacteristic, Self.sampleCharacteristic], for: service)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
    error: (any Error)?)
  {
    guard active, node === peripheral else { return }
    guard error == nil,
      let claim = service.characteristics?.first(where: { $0.uuid == Self.identityCharacteristic }),
      let sample = service.characteristics?.first(where: { $0.uuid == Self.sampleCharacteristic }),
      claim.properties.contains(.read), sample.properties.contains(.read)
    else { return close("A/C battery read characteristics unavailable.") }
    sampleCharacteristic = sample
    peripheral.readValue(for: claim)
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
    error: (any Error)?)
  {
    guard active, node === peripheral else { return }
    defer {
      if active, identity != nil { scheduleRead() }
    }
    guard error == nil, let raw = characteristic.value else {
      message = "Waiting for an encrypted battery reading."
      return
    }
    do {
      switch characteristic.uuid {
      case Self.identityCharacteristic:
        let frame = try ACBatteryReading.frame(raw, expected: .handshake)
        guard identity == nil, frame.sequence == 1, let sampleCharacteristic else { throw ACBatteryError.identity }
        let claim = try JSONDecoder().decode(ACBatteryIdentity.self, from: frame.payload)
        let bindingKey = "vhos.ac-battery.identity.\(peripheral.identifier.uuidString)"
        let defaults = UserDefaults.standard
        if let known = defaults.string(forKey: bindingKey), known != claim.sourceID {
          throw ACBatteryError.identity
        }
        try openEvidence(for: claim)
        try retain(raw, now: Date())
        defaults.set(claim.sourceID, forKey: bindingKey)
        identity = claim
        sequence = frame.sequence
        sampledAt = frame.monotonicMicroseconds
        message = "A/C battery connected."
        peripheral.readValue(for: sampleCharacteristic)
      case Self.sampleCharacteristic:
        guard identity != nil else { throw ACBatteryError.identity }
        let frame = try ACBatteryReading.frame(raw, expected: .acBattery)
        guard frame.sequence > sequence, frame.monotonicMicroseconds > sampledAt else { return }
        let now = Date()
        try retain(raw, now: now)
        reading = try ACBatteryReading(frame: frame)
        observedAt = now
        sequence = frame.sequence
        sampledAt = frame.monotonicMicroseconds
        message = "A/C battery connected."
        armDeadline("A/C battery readings expired.", seconds: 18)
      default:
        throw ACBatteryError.frame
      }
    } catch {
      close("Could not verify or save the A/C battery frame.")
    }
  }

  private func scheduleRead() {
    poll?.cancel()
    poll = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      if let self, let sampleCharacteristic, let node, active { node.readValue(for: sampleCharacteristic) }
    }
  }

  private func openEvidence(for claim: ACBatteryIdentity) throws {
    let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true).appending(path: "ACBattery", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appending(path: "\(claim.sourceID)-\(claim.bootID)-\(UUID().uuidString).ndjson")
    try Data().write(to: file, options: .completeFileProtectionUntilFirstUserAuthentication)
    sessionFile = file
  }

  private func retain(_ bytes: Data, now: Date) throws {
    guard let sessionFile else { throw ACBatteryError.identity }
    let line = try JSONEncoder().encode(BatteryEvidence(receivedAt: now.timeIntervalSince1970, frame: bytes))
    let handle = try FileHandle(forWritingTo: sessionFile)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line + Data([10]))
    try handle.synchronize()
  }

  private struct BatteryEvidence: Encodable {
    let receivedAt: Double
    let frame: Data
  }
}
