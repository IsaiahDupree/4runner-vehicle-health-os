import Foundation
import Observation
import VHOSCore

private final class LightingRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

actor LightingControllerClient {
  private let session: URLSession
  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil; configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    session = URLSession(configuration: configuration, delegate: LightingRedirectGuard(), delegateQueue: nil)
  }
  func perform(_ operation: LightingControllerOperation, key: String) async throws -> Data {
    let request = try operation.request(key: key)
    let data = try await send(request, expected: {
      switch operation { case .manual, .off: 204; case .configure, .calibrate: 202; default: 200 }
    }(), maximumBytes: { if case .presets = operation { 262_144 } else { 65_536 } }())
    switch operation {
    case .state, .loadPreset, .savePreset, .deletePreset:
      guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            reply["error"] == nil, reply["success"] as? Bool != false else {
        throw LightingControlError.effectRejected
      }
    default: break
    }
    return data
  }
  func relay(_ command: LightingRelayCommand, session id: Int, key: String) async throws {
    guard let request = command.request(session: id, key: key) else { throw LightingControlError.invalidKey }
    _ = try await send(request, expected: 204)
  }
  private func send(_ request: URLRequest, expected: Int, maximumBytes: Int = 65_536) async throws -> Data {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, http.url?.host == "192.168.88.1",
          http.url?.scheme == "http", http.url?.port == nil || http.url?.port == 80 else {
      throw LightingControlError.redirected
    }
    guard http.statusCode == expected else { throw LightingControlError.rejected(http.statusCode) }
    guard data.count <= maximumBytes else { throw LightingControlError.responseTooLarge }
    return data
  }
}

@MainActor @Observable
final class LightingCANRelay {
  private(set) var running = false
  private(set) var message = "Relay stopped"
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()

  func start(signal: LightingRelaySignal, ecu: String, key: String,
             gateway: GatewayBLEClient, client: LightingControllerClient) {
    guard !running else { return }
    generation = UUID()
    let epoch = generation
    running = true; message = "Starting relay…"
    task = Task { [weak self] in
      guard let self else { return }
      let id = Int.random(in: 1...Int(Int32.max))
      let target = ecu.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      var started = false, sequence = 0
      var lastIdentity: String?
      let formatter = ISO8601DateFormatter()
      do {
        try await client.relay(.start(signal), session: id, key: key); started = true
        while !Task.isCancelled {
          let now = Date()
          let sample: (String, Int)?
          if signal == .activity {
            if let observation = gateway.latestCANObservation, gateway.hasCurrentGatewayHealth,
               let gatewayID = gateway.handshake?.gatewayID, let capture = gateway.health?.captureSessionID,
               observation.matchesRecorderContext(gatewayID: gatewayID, captureSessionID: capture),
               let at = gateway.latestCANObservationReceivedAt, (0...2).contains(now.timeIntervalSince(at)) {
              sample = (observation.id, 100)
            } else { sample = nil; message = "Waiting for verified live CAN frames" }
          } else {
            let current = gateway.standardOBDSamples.filter { reading in
              gateway.isCurrentStandardOBDSample(reading)
                && formatter.date(from: reading.observedAt).map({ (0...2).contains(now.timeIntervalSince($0)) }) == true
                && (target.isEmpty || reading.ecuAddress.lowercased() == target)
            }
            let candidates = signal.latestPerECU(current)
            if candidates.count == 1, let reading = candidates.first, let value = signal.centiUnits(reading) {
              sample = (reading.id, value)
            } else {
              sample = nil
              message = candidates.isEmpty ? "Waiting for fresh supported CAN data" : "Select an ECU address"
            }
          }
          if let sample {
            if sample.0 != lastIdentity {
              sequence += 1
              try await client.relay(.sample(signal, centiUnits: sample.1, sequence: sequence), session: id, key: key)
              lastIdentity = sample.0
            }
            message = "Relaying \(signal.label.lowercased())"
          }
          try await Task.sleep(for: .milliseconds(250))
        }
      } catch { message = Task.isCancelled ? "Relay stopped" : error.localizedDescription }
      if started {
        // Independent cancellation context lets the matching-session Stop reach the controller.
        await Task { try? await client.relay(.stop, session: id, key: key) }.value
      }
      if generation == epoch { running = false; task = nil }
    }
  }
  func stop() async {
    let epoch = generation, pending = task
    pending?.cancel()
    await pending?.value
    if generation == epoch { task = nil; running = false }
  }
}

@MainActor @Observable
final class LightingStudioModel {
  var keyText = ""
  var rememberKey = false
  var color = LightingColor(red: 255, green: 128, blue: 0)
  var secondary = LightingColor(red: 0, green: 0, blue: 0)
  var tertiary = LightingColor(red: 0, green: 0, blue: 0)
  var colorSlot = 0
  var selectedPalette = 0
  var selectedEffect = 0
  var effectSpeed = 128
  var effectIntensity = 128
  var ecu = ""
  private(set) var wantsConnection = false
  private(set) var status: LightingControllerStatus?
  private(set) var effects: [String] = []
  private(set) var palettes: [String] = []
  private(set) var presets: [LightingWLEDPreset] = []
  private(set) var presetsAvailable = false
  private(set) var segments: [LightingWLEDState.Segment] = []
  private(set) var wledAvailable = false
  private(set) var busy = false
  private(set) var notice: String?
  private(set) var connectionMessage = "Connect to your controller"
  let relay = LightingCANRelay()
  let gateway = GatewayBLEClient.shared
  @ObservationIgnored private let client = LightingControllerClient()
  @ObservationIgnored private let credentials = KeyStore(service: (Bundle.main.bundleIdentifier ?? "VHOS") + ".lighting")
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let rememberKeyPreference = "lighting.remember-key.v1"
  private(set) var connectionGeneration = UUID()
  @ObservationIgnored private var activeKey = ""
  @ObservationIgnored private var receivedAt: Date?
  @ObservationIgnored private var loaded = false
  @ObservationIgnored private var mutationRevision: UInt64 = 0
  @ObservationIgnored private var pendingApply = false

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    do {
      if defaults.bool(forKey: rememberKeyPreference),
         let data = try credentials.data(for: .lightingControllerKey), let text = String(data: data, encoding: .utf8) {
        keyText = text; rememberKey = true
      }
    } catch { notice = "The saved relay key could not be read: \(error.localizedDescription)" }

  }
  var connected: Bool { status != nil && receivedAt.map { Date().timeIntervalSince($0) < 4 } == true }
  var outputReady: Bool { connected && status?.ready == true && !busy }
  var validKey: Bool { (try? LightingControllerOperation.status.request(key: keyText)) != nil }

  func connect() {
    guard validKey else { notice = LightingControlError.invalidKey.localizedDescription; return }
    do {
      if rememberKey { try credentials.set(Data(keyText.utf8), for: .lightingControllerKey) }
      else if defaults.bool(forKey: rememberKeyPreference) { try credentials.remove(.lightingControllerKey) }
      defaults.set(rememberKey, forKey: rememberKeyPreference)
      loaded = false; activeKey = keyText; connectionGeneration = UUID(); wantsConnection = true
      connectionMessage = "Connecting on 4Runner-Lighting Wi-Fi…"
    } catch { notice = error.localizedDescription }
  }
  func disconnect() async {
    wantsConnection = false; connectionGeneration = UUID(); status = nil; receivedAt = nil; effects = []; palettes = []; presets = []; presetsAvailable = false; segments = []; wledAvailable = false
    await relay.stop(); connectionMessage = "Controller disconnected"
  }
  func suspend() async { status = nil; receivedAt = nil; await relay.stop() }

  func poll() async {
    let epoch = connectionGeneration
    defer { if connectionGeneration == epoch { status = nil; receivedAt = nil } }
    while !Task.isCancelled && wantsConnection && connectionGeneration == epoch {
      if busy {
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        continue
      }
      let revision = mutationRevision
      do {
        let data = try await client.perform(.status, key: activeKey)
        try Task.checkCancellation()
        guard connectionGeneration == epoch else { return }
        if revision != mutationRevision { continue }
        let report = try LightingControllerStatus.decode(data)
        status = report; receivedAt = Date()
        connectionMessage = report.ready ? "Controller ready" : "Connected · output disarmed"
        if !loaded {
          color = report.config.color; loaded = true
          do {
            let catalog = try await client.perform(.effects, key: activeKey)
            try Task.checkCancellation()
            guard connectionGeneration == epoch else { return }
            let list = try JSONDecoder().decode([String].self, from: catalog)
            if (1...256).contains(list.count), list.allSatisfy({ !$0.isEmpty && $0.count <= 100 }) { effects = list }
            let paletteData = try await client.perform(.palettes, key: activeKey)
            let paletteList = try JSONDecoder().decode([String].self, from: paletteData)
            if paletteList.count <= 256 { palettes = paletteList }
            try await refreshWLED(updateDraft: true)
            await refreshPresets()

          } catch {
            if Task.isCancelled { return }
            notice = "Color control is connected. WLED effects are unavailable: \(error.localizedDescription)"
          }
        }
      } catch {
        if Task.isCancelled { return }
        status = nil; receivedAt = nil; connectionMessage = "Controller unavailable"
        notice = error.localizedDescription
        await relay.stop()
      }
      do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
    }
  }

  private func command(_ operation: LightingControllerOperation, message: String, takeover: Bool = true) async {
    guard connected, !busy else { return }
    busy = true
    mutationRevision &+= 1
    let epoch = connectionGeneration
    defer { busy = false }
    if takeover { await relay.stop() }
    do {
      _ = try await client.perform(operation, key: activeKey)
      let refreshed = try LightingControllerStatus.decode(await client.perform(.status, key: activeKey))
      guard epoch == connectionGeneration else { return }
      status = refreshed; receivedAt = Date(); notice = message
    }
    catch { notice = error.localizedDescription }
  }
  var editingColor: LightingColor {
    get { colorSlot == 1 ? secondary : colorSlot == 2 ? tertiary : color }
    set {
      switch colorSlot { case 1: secondary = newValue; case 2: tertiary = newValue; default: color = newValue }
    }
  }
  var effectName: String { effects.indices.contains(selectedEffect) ? effects[selectedEffect] : selectedEffect == 0 ? "Solid" : "Effect \(selectedEffect)" }
  var segmentName: String {
    let name = segments.first?.n?.trimmingCharacters(in: .whitespacesAndNewlines)
    return name?.isEmpty == false ? name! : "Whole strip"
  }
  var paletteName: String { palettes.indices.contains(selectedPalette) ? palettes[selectedPalette] : "Palette \(selectedPalette)" }
  func applyColor() async {
    if busy { pendingApply = true; return }
    guard connected, status?.ready == true else { return }
    repeat {
      pendingApply = false
      if wledAvailable {
        let selection = LightingWLEDSelection(effectID: selectedEffect, speed: effectSpeed,
          intensity: effectIntensity, paletteID: selectedPalette, colors: [color, secondary, tertiary])
        await command(.state(selection), message: "Applied")
      } else if colorSlot == 0 && selectedEffect == 0 {
        await command(.manual(color), message: "Applied")
      } else { notice = "Reconnect to load WLED’s color slots and effect controls."; return }
    } while pendingApply && connected && status?.ready == true
  }
  func off() async { pendingApply = false; await command(.off, message: "Off") }
  func power() async {
    guard connected, !busy else { return }
    if let mode = status?.mode, mode != "off" { await off() }
    else { if color.brightness == 0 { color.brightness = 96 }; await applyColor() }
  }
  private func refreshWLED(updateDraft: Bool) async throws {
    let epoch = connectionGeneration
    let data = try await client.perform(.wledState, key: activeKey)
    let state = try JSONDecoder().decode(LightingWLEDState.self, from: data)
    try Task.checkCancellation()
    guard (0...255).contains(state.bri), state.seg.count == 1,
          let seg = state.seg.first, seg.id == 0,
          [seg.fx,seg.sx,seg.ix,seg.pal ?? 0].allSatisfy({ (0...255).contains($0) }),
          (1...3).contains(seg.col.count), seg.col.allSatisfy({ $0.count >= 3 && $0.prefix(4).allSatisfy({ (0...255).contains($0) }) }) else {
      throw LightingControlError.incompatibleStatus
    }
    guard epoch == connectionGeneration else { throw CancellationError() }
    segments = state.seg; wledAvailable = true
    if updateDraft {
      selectedEffect = seg.fx; effectSpeed = seg.sx; effectIntensity = seg.ix; selectedPalette = seg.pal ?? 0
      func decoded(_ values: [Int]) -> LightingColor {
        LightingColor(red: values[0], green: values[1], blue: values[2],
          white: values.count >= 4 ? values[3] : 0, brightness: state.bri)
      }
      color = decoded(seg.col[0])
      if seg.col.count > 1 { secondary = decoded(seg.col[1]) }
      if seg.col.count > 2 { tertiary = decoded(seg.col[2]) }
    }
  }
  func refreshPresets() async {
    guard connected else { return }
    let epoch = connectionGeneration
    do {
      let data = try await client.perform(.presets, key: activeKey)
      let list = try LightingWLEDPreset.decode(data)
      try Task.checkCancellation()
      guard epoch == connectionGeneration else { return }
      presets = list; presetsAvailable = true
    } catch { presetsAvailable = false; if !Task.isCancelled { notice = "Presets unavailable: \(error.localizedDescription)" } }
  }
  func loadPreset(_ preset: LightingWLEDPreset) async {
    guard outputReady else { return }
    await command(.loadPreset(preset.id), message: "Preset \(preset.id) requested")
    do { try await refreshWLED(updateDraft: true) } catch { notice = error.localizedDescription }
  }
  func savePreset(id: Int, name: String) async {
    guard connected, wledAvailable else { return }
    await command(.savePreset(id: id, name: name), message: "Preset save requested", takeover: false)
    await refreshPresets()
  }
  func deletePreset(_ preset: LightingWLEDPreset) async {
    await command(.deletePreset(preset.id), message: "Preset delete requested", takeover: false)
    await refreshPresets()
  }
  func saveRule(signal: LightingRelaySignal, on: String, off: String) async {
    guard var config = status?.config, connected else { return }
    do {
      config.signal = signal.rawValue; config.onCenti = try signal.threshold(on); config.offCenti = try signal.threshold(off)
      config.color = color
      _ = try config.form()
      await command(.configure(config), message: "Rule applied in RAM; controller flash save scheduled. Start the relay when ready.")
    } catch { notice = error.localizedDescription }
  }
  func saveInputs(tail: Bool, tailOn: String, tailOff: String, dim: Bool, dimMin: String,
                  dimMax: String, dimLow: String, dimHigh: String) async {
    guard var config = status?.config, connected else { return }
    guard let tOn = Int(tailOn), let tOff = Int(tailOff), let dMin = Int(dimMin), let dMax = Int(dimMax),
          let dLow = Int(dimLow), let dHigh = Int(dimHigh) else { notice = "Enter measured whole-number ADC millivolts and percentages."; return }
    config.tailEnabled = tail ? 1 : 0; config.tailOnMv = tOn; config.tailOffMv = tOff
    config.dimEnabled = dim ? 1 : 0; config.dimMinMv = dMin; config.dimMaxMv = dMax
    config.dimAtMinPercent = dLow; config.dimAtMaxPercent = dHigh
    guard config.isValid else { notice = LightingControlError.invalidConfiguration.localizedDescription; return }
    await command(.configure(config), message: "Vehicle-input settings applied in RAM; flash save scheduled. Relay stopped.")
  }
  func calibrate(_ values: [String]) async {
    guard values.count == 4, let a = Int(values[0]), let v = Int(values[1]), let b = Int(values[2]), let w = Int(values[3]) else {
      notice = "Enter all four measured values in millivolts."; return
    }
    let cal = LightingVoltageCalibration(lowAdcMv: a, lowInputMv: v, highAdcMv: b, highInputMv: w)
    guard cal.isValid else { notice = LightingControlError.invalidCalibration.localizedDescription; return }
    await command(.calibrate(cal), message: "Calibration applied in RAM; controller flash save scheduled.")
  }
  func startRelay() {
    guard connected, status?.ready == true, let raw = status?.config.signal,
          let signal = LightingRelaySignal(rawValue: raw), gateway.applicationSessionHealthy else {
      notice = "Connect the verified CAN gateway and ready lighting controller first."; return
    }
    relay.start(signal: signal, ecu: ecu, key: activeKey, gateway: gateway, client: client)
  }
  func dismissNotice() { notice = nil }
}
