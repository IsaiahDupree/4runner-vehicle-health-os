import Foundation
import Testing
@testable import VHOSCore

@Test func lightingColorAndRequestRejectOutOfRangeChannels() throws {
  let key = "contract-test-key-012345"
  let color = LightingColor(red: 0, green: 255, blue: 127, white: 255, brightness: 0)
  #expect(color.isValid && color.hex == "#00FF7F")
  let request = try LightingControllerOperation.manual(color).request(key: key)
  #expect(request.url?.absoluteString == "http://192.168.88.1/vhos/manual")
  #expect(request.httpMethod == "POST")
  #expect(request.value(forHTTPHeaderField: "X-VHOS-Key") == key)
  #expect(request.timeoutInterval == 3)
  let body = try #require(request.httpBody)
  let form = try #require(String(data: body, encoding: .utf8))
  let items = URLComponents(string: "?" + form)?.queryItems ?? []
  #expect(Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") }) == [
    "action": "set", "red": "0", "green": "255", "blue": "127", "white": "255", "brightness": "0"])
  for invalid in [-1, 256, Int.max, Int.min] {
    let bad = LightingColor(red: invalid, green: 0, blue: 0)
    #expect(!bad.isValid)
    #expect(throws: LightingControlError.self) { try LightingControllerOperation.manual(bad).request(key: key) }
  }
}

@Test func lightingCredentialsAndRoutesNeverAllowArbitraryRemoteOrigins() throws {
  for key in ["", "short", String(repeating: "x", count: 65), "a key with spaces 12345", "test-key-with\nnew-line"] {
    #expect(throws: LightingControlError.self) { try LightingControllerOperation.status.request(key: key) }
  }
  let key = String(repeating: "x", count: 64)
  let operations: [LightingControllerOperation] = [.status, .effects, .wledState, .off,
    .state(.init(effectID: 0, speed: 255, intensity: 0, colors: [.init(red: 0, green: 0, blue: 0)]))]
  for op in operations {
    let request = try op.request(key: key)
    #expect(request.url?.host == "192.168.88.1")
    #expect(request.url?.scheme == "http" && request.url?.user == nil)
    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    #expect(request.url?.query == nil)
  }
  #expect(String(data: try #require(LightingControllerOperation.off.request(key: key).httpBody), encoding: .utf8) == "action=off")
}

@Test func lightingEffectJSONUsesOneSegmentAndValidatedChannels() throws {
  let key = "contract-test-key-012345"
  let operation = LightingControllerOperation.state(.init(effectID: 7, speed: 80, intensity: 200,
    colors: [.init(red: 1, green: 2, blue: 3, white: 4, brightness: 5)]))
  let request = try operation.request(key: key)
  let body = try #require(request.httpBody)
  let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
  #expect(request.url?.path == "/json/state")
  #expect(json["bri"] as? Int == 5 && json["on"] as? Bool == true)
  let segments = try #require(json["seg"] as? [[String: Any]])
  #expect(segments.count == 1 && segments[0]["id"] as? Int == 0)
  #expect(segments[0]["fx"] as? Int == 7)
  #expect(segments[0]["col"] as? [[Int]] == [[1, 2, 3, 4]])
  #expect(throws: LightingControlError.self) {
    try LightingControllerOperation.state(.init(effectID: 256, speed: 0, intensity: 0, colors: [.init(red: 0, green: 0, blue: 0)])).request(key: key)
  }
}

@Test func lightingThresholdsPreserveCentiUnitsAndRejectAmbiguousInput() throws {
  #expect(try LightingRelaySignal.rpm.threshold("16383.75") == 1_638_375)
  #expect(try LightingRelaySignal.coolant.threshold("-40") == -4000)
  #expect(try LightingRelaySignal.load.threshold("1.01") == 101)
  #expect(try LightingRelaySignal.activity.threshold("1") == 100)
  for text in ["nan", "inf", "1e2", "1,01", "1.001", "", " 1", "1\n", "9999999999999999999999999999999999999"] {
    #expect(throws: LightingControlError.self) { try LightingRelaySignal.rpm.threshold(text) }
  }
  #expect(throws: LightingControlError.self) { try LightingRelaySignal.activity.threshold("1.01") }
  #expect(throws: LightingControlError.self) { try LightingRelaySignal.speed.threshold("-1") }
}

@Test func lightingConfigurationSharesFirmwareCalibrationAndHysteresisBounds() throws {
  // Deliberate parser inputs, not a recorded vehicle status or meter observation.
  var config = LightingConfiguration(signal: 0, onCenti: 150_000, offCenti: 140_000,
    red: 255, green: 128, blue: 0, white: 0, brightness: 96,
    tailEnabled: 0, tailOnMv: 0, tailOffMv: 0, dimEnabled: 0,
    dimMinMv: 0, dimMaxMv: 0, dimAtMinPercent: 100, dimAtMaxPercent: 100)
  let configFields = try config.form()
  #expect(config.isValid && configFields.count == 16)
  let encoded = try JSONEncoder().encode(config)
  #expect(try JSONDecoder().decode(LightingConfiguration.self, from: encoded) == config)
  config.tailEnabled = 1; config.tailOnMv = 900; config.tailOffMv = 851
  #expect(!config.isValid)
  config.tailOffMv = 850; #expect(config.isValid)
  config.tailOnMv = 850; config.tailOffMv = 900; #expect(config.isValid)
  config.dimEnabled = 1; config.dimMinMv = 500; config.dimMaxMv = 599; #expect(!config.isValid)
  config.dimMaxMv = 600; config.dimAtMinPercent = 100; config.dimAtMaxPercent = 0; #expect(config.isValid)
  config.offCenti = config.onCenti + 1; #expect(!config.isValid)
  #expect(throws: LightingControlError.self) { try config.form() }
}

@Test func lightingVoltageCalibrationRejectsBadTransferAndOverflowInputs() throws {
  let calibration = LightingVoltageCalibration(lowAdcMv: 616, lowInputMv: 9000, highAdcMv: 986, highInputMv: 14400)
  let calibrationFields = try calibration.form()
  #expect(calibration.isValid && calibrationFields.count == 4)
  for bad in [
    LightingVoltageCalibration(lowAdcMv: 0, lowInputMv: 9000, highAdcMv: 986, highInputMv: 14400),
    LightingVoltageCalibration(lowAdcMv: 616, lowInputMv: 9000, highAdcMv: 700, highInputMv: 14400),
    LightingVoltageCalibration(lowAdcMv: Int.min, lowInputMv: Int.max, highAdcMv: 986, highInputMv: 14400),
    LightingVoltageCalibration(lowAdcMv: 616, lowInputMv: 9000, highAdcMv: 1201, highInputMv: 17000)] {
    #expect(!bad.isValid)
    #expect(throws: LightingControlError.self) { try bad.form() }
  }
}

@Test func lightingPresetsUseTheActualWLEDFileAndRequestFormat() throws {
  // Protocol parser inputs, never a claimed observation from a vehicle/controller.
  let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let path = folder.appending(path: "presets.json")
  let data = try JSONSerialization.data(withJSONObject: ["0": [:], "16": ["n": "Bench preset"], "251": ["n": "Outside WLED range"]])
  try data.write(to: path, options: .atomic)
  let presets = try LightingWLEDPreset.decode(Data(contentsOf: path))
  #expect(presets.count == 1 && presets.first?.id == 16 && presets.first?.name == "Bench preset")
  let key = "contract-test-key-012345"
  let request = try LightingControllerOperation.savePreset(id: 16, name: " Bench preset ").request(key: key)
  let body = try #require(request.httpBody)
  let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
  #expect(json["psave"] as? Int == 16 && json["n"] as? String == "Bench preset")
  #expect(json["ib"] as? Bool == true && json["sb"] as? Bool == false)
  #expect(request.url?.path == "/json/state")
  for id in [0,251,Int.max] {
    #expect(throws: LightingControlError.self) { try LightingControllerOperation.loadPreset(id).request(key: key) }
  }
}

@Test func lightingWheelHasCorrectHueSaturationAndPreservesWhiteAndBrightness() {
  let current = LightingColor(red: 255, green: 0, blue: 0, white: 73, brightness: 99)
  let center = LightingColorWheel.color(x: 100, y: 100, diameter: 200, preserving: current)
  #expect(center.red == 255 && center.green == 255 && center.blue == 255)
  let red = LightingColorWheel.color(x: 200, y: 100, diameter: 200, preserving: current)
  #expect(red.red == 255 && red.green == 0 && red.blue == 0)
  let cyan = LightingColorWheel.color(x: 0, y: 100, diameter: 200, preserving: current)
  #expect(cyan.red == 0 && cyan.green == 255 && cyan.blue == 255)
  #expect(cyan.white == 73 && cyan.brightness == 99)
  #expect(LightingColorWheel.color(x: .nan, y: 0, diameter: 200, preserving: current) == current)
  for i in 0...360 {
    let angle = Double(i) * .pi/180
    let color = LightingColorWheel.color(x: 100+cos(angle)*100, y: 100+sin(angle)*100, diameter: 200, preserving: current)
    #expect(color.isValid)
    let point = LightingColorWheel.position(for: color, diameter: 200)
    #expect(abs(point.x-(100+cos(angle)*100)) < 1 && abs(point.y-(100+sin(angle)*100)) < 1)
  }
}

@Test func lightingStatusRejectsMissingContractAndOversizedResponses() {
  #expect(throws: (any Error).self) { try LightingControllerStatus.decode(Data("{}".utf8)) }
  #expect(throws: LightingControlError.self) { try LightingControllerStatus.decode(Data(repeating: 32, count: 65_537)) }
}
