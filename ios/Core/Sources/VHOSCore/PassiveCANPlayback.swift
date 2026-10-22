import Foundation

public enum PassiveCANPlaybackPhase: String, Equatable, Sendable {
  case paused
  case playing
  case ended
}

public enum PassiveCANPlaybackEndBehavior: String, Equatable, Sendable {
  case stopAtEnd
  case loop
}

public struct PassiveCANPlaybackSessionBoundary: Identifiable, Equatable, Sendable {
  public let gatewayID: String
  public let sessionID: UInt32
  public let sessionOrdinal: Int
  public let startSeconds: Double
  public let endSeconds: Double
  public let pointCount: Int

  public var id: String { "\(gatewayID):\(sessionID):\(sessionOrdinal)" }
  public var label: String { "Session \(sessionOrdinal)" }

  public func contains(_ elapsedSeconds: Double) -> Bool {
    elapsedSeconds >= startSeconds && elapsedSeconds <= endSeconds
  }
}

public struct PassiveCANPlaybackFrame: Equatable, Sendable {
  public let phase: PassiveCANPlaybackPhase
  public let cursorSeconds: Double
  public let startSeconds: Double
  public let endSeconds: Double
  public let durationSeconds: Double
  public let progress: Double
  public let speed: Double
  public let completedLoops: Int
  public let visiblePoints: [PassiveCANResearchPoint]
  public let currentPoint: PassiveCANResearchPoint?
  public let nextPoint: PassiveCANResearchPoint?
  public let activeSession: PassiveCANPlaybackSessionBoundary?
  public let lastObservedSession: PassiveCANPlaybackSessionBoundary?
  public let nextSession: PassiveCANPlaybackSessionBoundary?
  public let isBetweenSessions: Bool
}

/// A deterministic chart timeline built exclusively from retained research points.
///
/// The timeline never interpolates or invents vehicle values. A frame contains the exact
/// retained prefix at or before its cursor and, separately, the next retained point.
public struct PassiveCANPlaybackTimeline: Equatable, Sendable {
  public let seriesID: String
  public let points: [PassiveCANResearchPoint]
  public let sessions: [PassiveCANPlaybackSessionBoundary]
  public let startSeconds: Double
  public let endSeconds: Double

  public var durationSeconds: Double { endSeconds - startSeconds }

  public init(series: PassiveCANResearchSeries) throws {
    guard !series.points.isEmpty else { throw PassiveCANPlaybackError.emptySeries }

    var identities = Set<String>()
    for point in series.points {
      guard point.elapsedSeconds.isFinite, point.elapsedSeconds >= 0,
        point.rawValue.isFinite, point.displayValue.isFinite
      else { throw PassiveCANPlaybackError.invalidPoint(point.id) }
      guard identities.insert(point.id).inserted else {
        throw PassiveCANPlaybackError.duplicatePoint(point.id)
      }
    }

    let ordered = series.points.sorted(by: Self.pointOrder)
    guard !series.sessionBounds.isEmpty else {
      throw PassiveCANPlaybackError.invalidSessionBounds(series.id)
    }
    var boundaryIdentities = Set<String>()
    let boundaries = try series.sessionBounds.map { bounds in
      guard bounds.captureStartSeconds.isFinite, bounds.captureEndSeconds.isFinite,
        bounds.firstPointSeconds.isFinite, bounds.lastPointSeconds.isFinite,
        bounds.captureStartSeconds >= 0,
        bounds.captureStartSeconds <= bounds.firstPointSeconds,
        bounds.firstPointSeconds <= bounds.lastPointSeconds,
        bounds.lastPointSeconds <= bounds.captureEndSeconds,
        bounds.pointCount > 0, boundaryIdentities.insert(bounds.id).inserted
      else { throw PassiveCANPlaybackError.invalidSessionBounds(bounds.id) }
      let plotted = ordered.filter {
        $0.gatewayID == bounds.gatewayID && $0.sessionID == bounds.sessionID
          && $0.sessionOrdinal == bounds.sessionOrdinal
      }
      guard plotted.first?.elapsedSeconds == bounds.firstPointSeconds,
        plotted.last?.elapsedSeconds == bounds.lastPointSeconds
      else { throw PassiveCANPlaybackError.missingSessionBoundaryPoint(bounds.id) }
      return PassiveCANPlaybackSessionBoundary(
        gatewayID: bounds.gatewayID,
        sessionID: bounds.sessionID,
        sessionOrdinal: bounds.sessionOrdinal,
        startSeconds: bounds.captureStartSeconds,
        endSeconds: bounds.captureEndSeconds,
        pointCount: bounds.pointCount
      )
    }.sorted {
      if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
      if $0.sessionOrdinal != $1.sessionOrdinal { return $0.sessionOrdinal < $1.sessionOrdinal }
      if $0.gatewayID != $1.gatewayID { return $0.gatewayID < $1.gatewayID }
      return $0.sessionID < $1.sessionID
    }

    seriesID = series.id
    points = ordered
    sessions = boundaries
    startSeconds = boundaries.map(\.startSeconds).min()!
    endSeconds = boundaries.map(\.endSeconds).max()!
  }

  public func clampedCursor(_ elapsedSeconds: Double) throws -> Double {
    guard elapsedSeconds.isFinite else { throw PassiveCANPlaybackError.invalidCursor }
    return min(max(elapsedSeconds, startSeconds), endSeconds)
  }

  public func frame(
    at elapsedSeconds: Double,
    phase: PassiveCANPlaybackPhase,
    speed: Double,
    completedLoops: Int = 0
  ) throws -> PassiveCANPlaybackFrame {
    guard speed.isFinite, speed > 0 else { throw PassiveCANPlaybackError.invalidSpeed }
    let cursor = try clampedCursor(elapsedSeconds)
    let visibleCount = upperBound(for: cursor)
    let visible = Array(points.prefix(visibleCount))
    let current = visible.last
    let next = visibleCount < points.count ? points[visibleCount] : nil
    let active = sessions.first { $0.contains(cursor) }
    let lastSession = current.flatMap(session(for:))
    let upcoming = next.flatMap(session(for:))
    let between = active == nil && lastSession != nil && upcoming != nil

    return PassiveCANPlaybackFrame(
      phase: phase,
      cursorSeconds: cursor,
      startSeconds: startSeconds,
      endSeconds: endSeconds,
      durationSeconds: durationSeconds,
      progress: durationSeconds > 0 ? (cursor - startSeconds) / durationSeconds : 1,
      speed: speed,
      completedLoops: completedLoops,
      visiblePoints: visible,
      currentPoint: current,
      nextPoint: next,
      activeSession: active,
      lastObservedSession: lastSession,
      nextSession: upcoming,
      isBetweenSessions: between
    )
  }

  private struct SessionKey: Hashable {
    let gatewayID: String
    let sessionID: UInt32
    let sessionOrdinal: Int
  }

  private static func pointOrder(
    _ left: PassiveCANResearchPoint,
    _ right: PassiveCANResearchPoint
  ) -> Bool {
    if left.elapsedSeconds != right.elapsedSeconds {
      return left.elapsedSeconds < right.elapsedSeconds
    }
    if left.sessionOrdinal != right.sessionOrdinal {
      return left.sessionOrdinal < right.sessionOrdinal
    }
    if left.gatewayID != right.gatewayID { return left.gatewayID < right.gatewayID }
    if left.sessionID != right.sessionID { return left.sessionID < right.sessionID }
    return left.sourceSequence < right.sourceSequence
  }

  private func upperBound(for cursor: Double) -> Int {
    var lower = 0
    var upper = points.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if points[middle].elapsedSeconds <= cursor {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    return lower
  }

  private func session(
    for point: PassiveCANResearchPoint
  ) -> PassiveCANPlaybackSessionBoundary? {
    sessions.first {
      $0.gatewayID == point.gatewayID && $0.sessionID == point.sessionID
        && $0.sessionOrdinal == point.sessionOrdinal
    }
  }
}

/// A portable playback transport whose only clock input is an explicit monotonic host time.
/// This makes the same command sequence deterministic in the app and in tests.
public struct PassiveCANPlaybackTransport: Equatable, Sendable {
  public let timeline: PassiveCANPlaybackTimeline
  public private(set) var phase: PassiveCANPlaybackPhase
  public private(set) var cursorSeconds: Double
  public private(set) var speed: Double
  public private(set) var endBehavior: PassiveCANPlaybackEndBehavior
  public private(set) var completedLoops: Int

  private var lastHostTimeSeconds: Double?

  public init(
    series: PassiveCANResearchSeries,
    speed: Double = 1,
    endBehavior: PassiveCANPlaybackEndBehavior = .stopAtEnd
  ) throws {
    try Self.validateSpeed(speed)
    let timeline = try PassiveCANPlaybackTimeline(series: series)
    self.timeline = timeline
    phase = .paused
    cursorSeconds = timeline.startSeconds
    self.speed = speed
    self.endBehavior = endBehavior
    completedLoops = 0
    lastHostTimeSeconds = nil
  }

  public var currentFrame: PassiveCANPlaybackFrame {
    // Construction validation guarantees that these values remain valid.
    try! timeline.frame(
      at: cursorSeconds,
      phase: phase,
      speed: speed,
      completedLoops: completedLoops)
  }

  @discardableResult
  public mutating func play(
    atHostTime hostTimeSeconds: Double
  ) throws -> PassiveCANPlaybackFrame {
    try Self.validateHostTime(hostTimeSeconds)
    if phase == .playing {
      return try advance(toHostTime: hostTimeSeconds)
    }
    if phase == .ended {
      cursorSeconds = timeline.startSeconds
      completedLoops = 0
    }
    if timeline.durationSeconds == 0 {
      phase = .ended
      lastHostTimeSeconds = nil
    } else {
      phase = .playing
      lastHostTimeSeconds = hostTimeSeconds
    }
    return currentFrame
  }

  @discardableResult
  public mutating func pause(
    atHostTime hostTimeSeconds: Double
  ) throws -> PassiveCANPlaybackFrame {
    _ = try advance(toHostTime: hostTimeSeconds)
    if phase == .playing { phase = .paused }
    lastHostTimeSeconds = nil
    return currentFrame
  }

  @discardableResult
  public mutating func scrub(
    to elapsedSeconds: Double,
    atHostTime hostTimeSeconds: Double
  ) throws -> PassiveCANPlaybackFrame {
    try Self.validateHostTime(hostTimeSeconds)
    if phase == .playing { _ = try advance(toHostTime: hostTimeSeconds) }
    cursorSeconds = try timeline.clampedCursor(elapsedSeconds)
    if endBehavior == .stopAtEnd && cursorSeconds == timeline.endSeconds {
      phase = .ended
      lastHostTimeSeconds = nil
    } else if phase == .ended {
      phase = .paused
    } else if phase == .playing {
      lastHostTimeSeconds = hostTimeSeconds
    }
    return currentFrame
  }

  @discardableResult
  public mutating func setSpeed(
    _ newSpeed: Double,
    atHostTime hostTimeSeconds: Double
  ) throws -> PassiveCANPlaybackFrame {
    try Self.validateSpeed(newSpeed)
    try Self.validateHostTime(hostTimeSeconds)
    if phase == .playing { _ = try advance(toHostTime: hostTimeSeconds) }
    speed = newSpeed
    if phase == .playing { lastHostTimeSeconds = hostTimeSeconds }
    return currentFrame
  }

  @discardableResult
  public mutating func setEndBehavior(
    _ behavior: PassiveCANPlaybackEndBehavior,
    atHostTime hostTimeSeconds: Double
  ) throws -> PassiveCANPlaybackFrame {
    try Self.validateHostTime(hostTimeSeconds)
    if phase == .playing { _ = try advance(toHostTime: hostTimeSeconds) }
    endBehavior = behavior
    if phase == .playing { lastHostTimeSeconds = hostTimeSeconds }
    return currentFrame
  }

  @discardableResult
  public mutating func restart(
    atHostTime hostTimeSeconds: Double,
    playing: Bool = false
  ) throws -> PassiveCANPlaybackFrame {
    try Self.validateHostTime(hostTimeSeconds)
    cursorSeconds = timeline.startSeconds
    completedLoops = 0
    if playing && timeline.durationSeconds > 0 {
      phase = .playing
      lastHostTimeSeconds = hostTimeSeconds
    } else {
      phase = timeline.durationSeconds > 0 ? .paused : .ended
      lastHostTimeSeconds = nil
    }
    return currentFrame
  }

  @discardableResult
  public mutating func frame(
    atHostTime hostTimeSeconds: Double
  ) throws -> PassiveCANPlaybackFrame {
    try advance(toHostTime: hostTimeSeconds)
  }

  private mutating func advance(
    toHostTime hostTimeSeconds: Double
  ) throws -> PassiveCANPlaybackFrame {
    try Self.validateHostTime(hostTimeSeconds)
    guard phase == .playing, let lastHostTimeSeconds else { return currentFrame }
    guard hostTimeSeconds >= lastHostTimeSeconds else {
      throw PassiveCANPlaybackError.hostTimeMovedBackward
    }

    let hostDelta = hostTimeSeconds - lastHostTimeSeconds
    guard hostDelta > 0 else { return currentFrame }
    let playbackDelta = hostDelta * speed
    guard hostDelta.isFinite, playbackDelta.isFinite else {
      throw PassiveCANPlaybackError.playbackClockOverflow
    }

    switch endBehavior {
    case .stopAtEnd:
      cursorSeconds += playbackDelta
      if cursorSeconds >= timeline.endSeconds {
        cursorSeconds = timeline.endSeconds
        phase = .ended
        self.lastHostTimeSeconds = nil
      } else {
        self.lastHostTimeSeconds = hostTimeSeconds
      }
    case .loop:
      let duration = timeline.durationSeconds
      guard duration > 0 else {
        cursorSeconds = timeline.endSeconds
        phase = .ended
        self.lastHostTimeSeconds = nil
        return currentFrame
      }
      let travel = (cursorSeconds - timeline.startSeconds) + playbackDelta
      let loopValue = floor(travel / duration)
      guard travel.isFinite, loopValue.isFinite, loopValue >= 0,
        loopValue < Double(Int.max)
      else { throw PassiveCANPlaybackError.playbackClockOverflow }
      let loops = Int(loopValue)
      guard loops <= Int.max - completedLoops else {
        throw PassiveCANPlaybackError.playbackClockOverflow
      }
      completedLoops += loops
      cursorSeconds = timeline.startSeconds + travel.truncatingRemainder(dividingBy: duration)
      self.lastHostTimeSeconds = hostTimeSeconds
    }
    return currentFrame
  }

  private static func validateSpeed(_ speed: Double) throws {
    guard speed.isFinite, speed > 0 else { throw PassiveCANPlaybackError.invalidSpeed }
  }

  private static func validateHostTime(_ hostTimeSeconds: Double) throws {
    guard hostTimeSeconds.isFinite else { throw PassiveCANPlaybackError.invalidHostTime }
  }
}

public enum PassiveCANPlaybackError: Error, Equatable, LocalizedError {
  case emptySeries
  case invalidPoint(String)
  case duplicatePoint(String)
  case invalidCursor
  case invalidSpeed
  case invalidHostTime
  case hostTimeMovedBackward
  case invalidSessionBounds(String)
  case missingSessionBoundaryPoint(String)
  case playbackClockOverflow

  public var errorDescription: String? {
    switch self {
    case .emptySeries: "Playback requires at least one retained CAN research point."
    case .invalidPoint(let identity): "Retained CAN research point \(identity) is invalid."
    case .duplicatePoint(let identity): "Playback repeats retained point \(identity)."
    case .invalidCursor: "The playback cursor must be finite."
    case .invalidSpeed: "Playback speed must be finite and greater than zero."
    case .invalidHostTime: "The monotonic host timestamp must be finite."
    case .hostTimeMovedBackward: "The monotonic host clock moved backward."
    case .invalidSessionBounds(let identity):
      "Playback session bounds \(identity) are invalid."
    case .missingSessionBoundaryPoint(let identity):
      "Playback is missing a plotted endpoint for session \(identity)."
    case .playbackClockOverflow: "Playback clock arithmetic exceeded its finite range."
    }
  }
}
