import Foundation

public enum LightingControlError: Error, LocalizedError {
  case invalidKey, invalidColor, invalidConfiguration, invalidCalibration, incompatibleStatus
  case rejected(Int), redirected, responseTooLarge, effectRejected

  public var errorDescription: String? {
    switch self {
    case .invalidKey: "Use the controller’s 16–64 character relay key."
    case .invalidColor: "RGB, white and brightness must be between 0 and 255."
    case .invalidConfiguration: "Check the signal range, thresholds and measured input calibration."
    case .invalidCalibration: "Use two separated meter readings within the Rev I monitor’s range."
    case .incompatibleStatus: "Unsupported controller response. Install the matching Rev I lighting firmware."
    case .rejected(403): "Check the relay key and controller configuration."
    case .rejected(409): "The controller is not ready. Check output arming, private Wi-Fi and the RGBW bus."
    case .rejected(let code): "The controller rejected the request (HTTP \(code))."
    case .redirected: "A controller request attempted to leave the local device."
    case .responseTooLarge: "The controller response exceeds the supported size."
    case .effectRejected: "WLED reported that the effect command failed."
    }
  }
}

public struct LightingColor: Codable, Equatable, Sendable {
  public var red, green, blue, white, brightness: Int
  public init(red: Int, green: Int, blue: Int, white: Int = 0, brightness: Int = 96) {
    self.red = red; self.green = green; self.blue = blue; self.white = white; self.brightness = brightness
  }
  public var isValid: Bool { [red, green, blue, white, brightness].allSatisfy { (0...255).contains($0) } }
  public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
  public var form: [String: Int] {
    ["red": red, "green": green, "blue": blue, "white": white, "brightness": brightness]
  }
}

public struct LightingConfiguration: Codable, Equatable, Sendable {
  public var signal, onCenti, offCenti, red, green, blue, white, brightness: Int
  public var tailEnabled, tailOnMv, tailOffMv, dimEnabled, dimMinMv, dimMaxMv: Int
  public var dimAtMinPercent, dimAtMaxPercent: Int

  enum CodingKeys: String, CodingKey {
    case signal, red, green, blue, white, brightness
    case onCenti = "on-centi", offCenti = "off-centi"
    case tailEnabled = "tail-enabled", tailOnMv = "tail-on-mv", tailOffMv = "tail-off-mv"
    case dimEnabled = "dim-enabled", dimMinMv = "dim-min-mv", dimMaxMv = "dim-max-mv"
    case dimAtMinPercent = "dim-at-min-percent", dimAtMaxPercent = "dim-at-max-percent"
  }

  public var color: LightingColor {
    get { LightingColor(red: red, green: green, blue: blue, white: white, brightness: brightness) }
    set { red = newValue.red; green = newValue.green; blue = newValue.blue
      white = newValue.white; brightness = newValue.brightness }
  }

  public var isValid: Bool {
    guard let chosen = LightingRelaySignal(rawValue: signal), color.isValid, brightness > 0,
          chosen.controlRange.contains(onCenti), chosen.controlRange.contains(offCenti), offCenti <= onCenti,
          [tailEnabled, dimEnabled].allSatisfy({ (0...1).contains($0) }),
          [tailOnMv, tailOffMv, dimMinMv, dimMaxMv].allSatisfy({ (0...3300).contains($0) }),
          [dimAtMinPercent, dimAtMaxPercent].allSatisfy({ (0...100).contains($0) }) else { return false }
    return (tailEnabled == 0 || abs(tailOnMv - tailOffMv) >= 50)
      && (dimEnabled == 0 || dimMaxMv - dimMinMv >= 100)
  }

  public func form() throws -> [String: Int] {
    guard isValid else { throw LightingControlError.invalidConfiguration }
    return ["signal": signal, "on-centi": onCenti, "off-centi": offCenti,
      "red": red, "green": green, "blue": blue, "white": white, "brightness": brightness,
      "tail-enabled": tailEnabled, "tail-on-mv": tailOnMv, "tail-off-mv": tailOffMv,
      "dim-enabled": dimEnabled, "dim-min-mv": dimMinMv, "dim-max-mv": dimMaxMv,
      "dim-at-min-percent": dimAtMinPercent, "dim-at-max-percent": dimAtMaxPercent]
  }
}

extension LightingRelaySignal {
  public var controlUnit: String {
    switch self { case .rpm: "rpm"; case .speed: "km/h"; case .coolant: "°C"; case .load: "%"; case .activity: "0 / 1" }
  }
  public var controlRange: ClosedRange<Int> {
    switch self {
    case .rpm: 0...1_638_375
    case .speed: 0...25_500
    case .coolant: -4_000...21_500
    case .load: 0...10_000
    case .activity: 0...100
    }
  }
  public func threshold(_ text: String) throws -> Int {
    guard text.range(of: #"^-?\d+(\.\d{1,2})?$"#, options: .regularExpression) != nil,
          let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
      throw LightingControlError.invalidConfiguration
    }
    let scaled = NSDecimalNumber(decimal: value * 100)
    guard scaled.compare(NSDecimalNumber(value: controlRange.lowerBound)) != .orderedAscending,
          scaled.compare(NSDecimalNumber(value: controlRange.upperBound)) != .orderedDescending else {
      throw LightingControlError.invalidConfiguration
    }
    return scaled.intValue
  }
}

public struct LightingVoltageCalibration: Codable, Equatable, Sendable {
  public var lowAdcMv, lowInputMv, highAdcMv, highInputMv: Int
  public init(lowAdcMv: Int, lowInputMv: Int, highAdcMv: Int, highInputMv: Int) {
    self.lowAdcMv = lowAdcMv; self.lowInputMv = lowInputMv
    self.highAdcMv = highAdcMv; self.highInputMv = highInputMv
  }
  enum CodingKeys: String, CodingKey {
    case lowAdcMv = "low-adc-mv", lowInputMv = "low-input-mv"
    case highAdcMv = "high-adc-mv", highInputMv = "high-input-mv"
  }
  public var isValid: Bool {
    guard (0...1200).contains(lowAdcMv), (0...1200).contains(highAdcMv),
          (6000...17000).contains(lowInputMv), (6000...17000).contains(highInputMv) else { return false }
    let a = highAdcMv - lowAdcMv, v = highInputMv - lowInputMv
    return a >= 100 && v >= 1000 && v >= 10*a && v <= 20*a
      && lowAdcMv*100 >= lowInputMv*5 && lowAdcMv*100 <= lowInputMv*9
      && highAdcMv*100 >= highInputMv*5 && highAdcMv*100 <= highInputMv*9
  }
  public func form() throws -> [String: Int] {
    guard isValid else { throw LightingControlError.invalidCalibration }
    return ["low-adc-mv": lowAdcMv, "low-input-mv": lowInputMv,
            "high-adc-mv": highAdcMv, "high-input-mv": highInputMv]
  }
}

public struct LightingControllerStatus: Decodable, Sendable {
  public struct Inputs: Decodable, Sendable { public let tailAdcMv, dimAdcMv, supplyAdcMv: Int }
  public struct Sample: Decodable, Sendable { public let signal: Int; public let centiUnits, receiptAgeMs: Int? }
  public struct Voltage: Decodable, Sendable {
    public let fitted, calibrated: Bool
    public let source, quality: String
    public let inputMv: Int?
  }
  public let contract, board, mode, reason: String
  public let ready, armed, canFresh, tailAllowed, configurationPendingSave, stripQualified: Bool
  public let requestedBrightness, effectiveBrightness, maximumChannelMa, maximumCombinedMa: Int
  public let inputs: Inputs
  public let sample: Sample
  public let voltage: Voltage
  public let config: LightingConfiguration
  public let voltageCalibration: LightingVoltageCalibration

  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= 65_536 else { throw LightingControlError.responseTooLarge }
    let value = try JSONDecoder().decode(Self.self, from: data)
    guard value.contract == "vhos.lighting.status@1.0.0", value.config.isValid,
          ["can", "manual", "off"].contains(value.mode),
          (0...255).contains(value.requestedBrightness), (0...255).contains(value.effectiveBrightness),
          [value.inputs.tailAdcMv, value.inputs.dimAdcMv, value.inputs.supplyAdcMv].allSatisfy({ (-1...3300).contains($0) }),
          value.maximumChannelMa > 0, value.maximumCombinedMa > 0,
          (!value.ready || value.armed), value.effectiveBrightness <= value.requestedBrightness,
          (value.ready || value.effectiveBrightness == 0),
          value.voltage.source == "ACC_FUSED",
          ["unavailable", "over-range", "calibrated", "estimate"].contains(value.voltage.quality),
          value.voltage.inputMv.map({ (0...25_000).contains($0) }) ?? true else {
      throw LightingControlError.incompatibleStatus
    }
    if value.canFresh {
      guard value.mode == "can", value.sample.signal == value.config.signal,
            let signal = LightingRelaySignal(rawValue: value.sample.signal),
            let sample = value.sample.centiUnits, signal.controlRange.contains(sample),
            let age = value.sample.receiptAgeMs, (0..<2500).contains(age) else {
        throw LightingControlError.incompatibleStatus
      }
    } else if value.sample.centiUnits != nil || value.sample.receiptAgeMs != nil {
      throw LightingControlError.incompatibleStatus
    }
    if (!value.voltage.fitted || ["unavailable", "over-range"].contains(value.voltage.quality)) && value.voltage.inputMv != nil {
      throw LightingControlError.incompatibleStatus
    }
    if value.voltage.calibrated && !value.voltageCalibration.isValid { throw LightingControlError.incompatibleStatus }
    return value
  }
}

public struct LightingWLEDState: Decodable, Sendable {
  public struct Segment: Decodable, Sendable {
    public let id, fx, sx, ix: Int
    public let col: [[Int]]
    public let start, stop, len, pal: Int?
    public let n: String?
  }
  public let on: Bool
  public let bri: Int
  public let seg: [Segment]
}

public enum LightingControllerOperation: Sendable {
  case status, effects, palettes, wledState, presets
  case manual(LightingColor), off, configure(LightingConfiguration), calibrate(LightingVoltageCalibration)
  case state(LightingWLEDSelection)
  case loadPreset(Int), savePreset(id: Int, name: String), deletePreset(Int)

  public func request(key: String) throws -> URLRequest {
    guard (16...64).contains(key.utf8.count), key.utf8.allSatisfy({ (33...126).contains($0) }) else {
      throw LightingControlError.invalidKey
    }
    var path: String, form: [String: String]?, json: Data?
    switch self {
    case .status: path = "vhos/status"
    case .effects: path = "json/eff"
    case .palettes: path = "json/pal"
    case .presets: path = "presets.json"
    case .wledState: path = "json/state"
    case .off: path = "vhos/manual"; form = ["action": "off"]
    case .manual(let color):
      guard color.isValid else { throw LightingControlError.invalidColor }
      path = "vhos/manual"; form = color.form.mapValues(String.init); form?["action"] = "set"
    case .configure(let config): path = "vhos/config"; form = try config.form().mapValues(String.init)
    case .calibrate(let calibration): path = "vhos/voltage"; form = try calibration.form().mapValues(String.init)
    case .state(let selection):
      path = "json/state"; json = try selection.encoded()
    case .loadPreset(let id), .deletePreset(let id):
      guard (1...250).contains(id) else { throw LightingControlError.invalidConfiguration }
      path = "json/state"
      let field: String
      if case .loadPreset = self { field = "ps" } else { field = "pdel" }
      json = try JSONSerialization.data(withJSONObject: [field: id])
    case .savePreset(let id, let name):
      let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard (1...250).contains(id), !clean.isEmpty, clean.count <= 32 else { throw LightingControlError.invalidConfiguration }
      path = "json/state"
      json = try JSONSerialization.data(withJSONObject: ["psave": id, "n": clean, "ib": true, "sb": false])
    }
    var request = URLRequest(url: LightingRelayCommand.controller.appending(path: path), timeoutInterval: 3)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue(key, forHTTPHeaderField: "X-VHOS-Key")
    if let form {
      var body = URLComponents()
      body.queryItems = form.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
      request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
      request.httpMethod = "POST"
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    } else if let json {
      request.httpBody = json; request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return request
  }
}


/// One physical analog RGBW output; the three colors are WLED effect color slots.
public struct LightingWLEDSelection: Sendable {
  public let effectID, speed, intensity, paletteID: Int
  public let colors: [LightingColor]
  public init(effectID: Int, speed: Int, intensity: Int, paletteID: Int = 0, colors: [LightingColor]) {
    self.effectID = effectID; self.speed = speed; self.intensity = intensity
    self.paletteID = paletteID; self.colors = colors
  }
  public func encoded() throws -> Data {
    guard [effectID, speed, intensity, paletteID].allSatisfy({ (0...255).contains($0) }),
          (1...3).contains(colors.count), colors.allSatisfy(\.isValid), let primary = colors.first else {
      throw LightingControlError.invalidColor
    }
    return try JSONSerialization.data(withJSONObject: ["on": primary.brightness > 0, "bri": primary.brightness,
      "seg": [["id": 0, "fx": effectID, "sx": speed, "ix": intensity, "pal": paletteID,
               "col": colors.map { [$0.red, $0.green, $0.blue, $0.white] }]]])
  }
}

public struct LightingWLEDPreset: Equatable, Identifiable, Sendable {
  public let id: Int
  public let name: String
  public static func decode(_ data: Data) throws -> [Self] {
    guard data.count <= 262_144 else { throw LightingControlError.responseTooLarge }
    guard let objects = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw LightingControlError.incompatibleStatus
    }
    return try objects.compactMap { key, value in
      guard let id = Int(key), (1...250).contains(id) else { return nil }
      guard let preset = value as? [String: Any] else { throw LightingControlError.incompatibleStatus }
      let name = preset["n"] as? String
      return Self(id: id, name: name?.isEmpty == false ? String(name!.prefix(100)) : "Preset \(id)")
    }.sorted { $0.id < $1.id }
  }
}

/// Shared deterministic math for the native WLED-style hue/saturation wheel.
public enum LightingColorWheel {
  public static func color(x: Double, y: Double, diameter: Double, preserving current: LightingColor) -> LightingColor {
    guard x.isFinite, y.isFinite, diameter.isFinite, diameter > 0 else { return current }
    let radius = diameter/2, dx = (x-radius)/radius, dy = (y-radius)/radius
    let saturation = min(hypot(dx,dy),1)
    var hue = atan2(dy,dx)/(2 * .pi)
    if hue < 0 { hue += 1 }
    let h = hue*6, chroma = saturation, second = chroma*(1-abs(h.truncatingRemainder(dividingBy:2)-1))
    let rgb: (Double,Double,Double)
    switch Int(h) % 6 {
    case 0: rgb = (chroma,second,0)
    case 1: rgb = (second,chroma,0)
    case 2: rgb = (0,chroma,second)
    case 3: rgb = (0,second,chroma)
    case 4: rgb = (second,0,chroma)
    default: rgb = (chroma,0,second)
    }
    let base = 1-chroma
    return LightingColor(red:Int(((rgb.0+base)*255).rounded()),green:Int(((rgb.1+base)*255).rounded()),
      blue:Int(((rgb.2+base)*255).rounded()),white:current.white,brightness:current.brightness)
  }
  public static func position(for color: LightingColor, diameter: Double) -> (x: Double,y: Double) {
    let r=Double(color.red)/255, g=Double(color.green)/255, b=Double(color.blue)/255
    let maximum=max(r,g,b), minimum=min(r,g,b), delta=maximum-minimum
    var hue: Double = 0
    if delta > 0 {
      if maximum == r { hue=((g-b)/delta).truncatingRemainder(dividingBy:6) }
      else if maximum == g { hue=(b-r)/delta+2 }
      else { hue=(r-g)/delta+4 }
      hue /= 6; if hue < 0 { hue += 1 }
    }
    let saturation=maximum == 0 ? 0 : delta/maximum, radius=diameter/2
    return (radius+cos(hue*2 * .pi)*saturation*radius, radius+sin(hue*2 * .pi)*saturation*radius)
  }
}
