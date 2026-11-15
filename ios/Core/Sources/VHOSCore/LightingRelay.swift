import Foundation

public enum LightingRelaySignal: Int, CaseIterable, Identifiable, Sendable {
  case rpm, speed, coolant, load, activity

  public var id: Int { rawValue }

  public var signalID: String {
    switch self {
    case .rpm: "obd.engine.speed"
    case .speed: "obd.vehicle.speed"
    case .coolant: "obd.engine.coolant_temperature"
    case .load: "obd.engine.calculated_load"
    case .activity: "gateway.can.activity"
    }
  }

  public var label: String {
    switch self {
    case .rpm: "Engine speed"
    case .speed: "Vehicle speed"
    case .coolant: "Coolant temperature"
    case .load: "Calculated engine load"
    case .activity: "CAN activity"
    }
  }

  private var unit: String {
    switch self {
    case .rpm: "rpm"
    case .speed: "km/h"
    case .coolant: "degC"
    case .load: "%"
    case .activity: ""
    }
  }

  private var range: ClosedRange<Double> {
    switch self {
    case .rpm: 0...16383.75
    case .speed: 0...255
    case .coolant: -40...215
    case .load: 0...100
    case .activity: 0...1
    }
  }

  public func centiUnits(_ sample: J1979StandardSample) -> Int? {
    guard self != .activity, sample.signalID == signalID, sample.unit == unit, range.contains(sample.value),
          sample.definitionRevision == J1979Accumulator.definitionRevision
    else { return nil }
    return Int((sample.value * 100).rounded())
  }

  public func latestPerECU(_ samples: [J1979StandardSample]) -> [J1979StandardSample] {
    Dictionary(grouping: samples.filter { centiUnits($0) != nil }, by: { $0.ecuAddress.lowercased() })
      .values.compactMap { history in
        history.max { ($0.gatewayMonotonicMicroseconds, $0.sourceSequence) <
          ($1.gatewayMonotonicMicroseconds, $1.sourceSequence) }
      }
  }
}

public enum LightingRelayCommand: Sendable {
  case start(LightingRelaySignal)
  case sample(LightingRelaySignal, centiUnits: Int, sequence: Int)
  case stop

  public static let controller = URL(string: "http://192.168.88.1")!

  public func request(session: Int, key: String) -> URLRequest? {
    guard (1...Int(Int32.max)).contains(session), (16...64).contains(key.utf8.count),
          key.utf8.allSatisfy({ (33...126).contains($0) })
    else { return nil }
    var form = "session=\(session)"
    switch self {
    case .start(let signal):
      form += "&action=start&signal=\(signal.rawValue)"
    case .sample(let signal, let value, let seq):
      guard (1...Int(Int32.max)).contains(seq) else { return nil }
      form += "&action=sample&signal=\(signal.rawValue)&centi=\(value)&seq=\(seq)"
    case .stop:
      form += "&action=stop"
    }
    var req = URLRequest(url: Self.controller.appending(path: "vhos/lighting"), timeoutInterval: 1.5)
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.setValue(key, forHTTPHeaderField: "X-VHOS-Key")
    req.httpBody = Data(form.utf8)
    return req
  }
}
