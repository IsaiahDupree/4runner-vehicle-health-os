import Foundation
import Testing

@testable import VHOSCore

@Test func playbackFrameIsAnExactVisiblePrefixOfRetainedEvidence() throws {
  let series = try realPlaybackSeries()
  let timeline = try PassiveCANPlaybackTimeline(series: series)
  let pairIndex = try #require(
    timeline.points.indices.dropLast().first {
      timeline.points[$0].elapsedSeconds < timeline.points[$0 + 1].elapsedSeconds
    })
  let cursor =
    (timeline.points[pairIndex].elapsedSeconds + timeline.points[pairIndex + 1].elapsedSeconds) / 2
  let frame = try timeline.frame(at: cursor, phase: .paused, speed: 1)
  let retainedByID = Dictionary(uniqueKeysWithValues: timeline.points.map { ($0.id, $0) })

  #expect(frame.visiblePoints == Array(timeline.points.prefix(pairIndex + 1)))
  #expect(frame.currentPoint == timeline.points[pairIndex])
  #expect(frame.nextPoint == timeline.points[pairIndex + 1])
  #expect(frame.visiblePoints.allSatisfy { retainedByID[$0.id] == $0 })
  #expect(frame.visiblePoints.allSatisfy { $0.elapsedSeconds <= cursor })
  #expect(frame.nextPoint!.elapsedSeconds > cursor)
}

@Test func playbackTransportPreservesSpeedPauseAndScrubMath() throws {
  let series = try realPlaybackSeries()
  var transport = try PassiveCANPlaybackTransport(series: series, speed: 2)
  let start = transport.timeline.startSeconds

  let initial = try transport.play(atHostTime: 1_000)
  #expect(initial.phase == .playing)
  #expect(initial.cursorSeconds == start)

  let twoX = try transport.frame(atHostTime: 1_000.5)
  #expect(abs(twoX.cursorSeconds - (start + 1)) < 0.000_000_001)

  let repeatedPlay = try transport.play(atHostTime: 1_000.75)
  #expect(abs(repeatedPlay.cursorSeconds - (start + 1.5)) < 0.000_000_001)

  let paused = try transport.pause(atHostTime: 1_001)
  #expect(paused.phase == .paused)
  #expect(abs(paused.cursorSeconds - (start + 2)) < 0.000_000_001)
  let stillPaused = try transport.frame(atHostTime: 9_000)
  #expect(stillPaused.cursorSeconds == paused.cursorSeconds)
  #expect(stillPaused.currentPoint == paused.currentPoint)

  let target = start + transport.timeline.durationSeconds * 0.25
  let scrubbed = try transport.scrub(to: target, atHostTime: 9_001)
  #expect(abs(scrubbed.cursorSeconds - target) < 0.000_000_001)
  #expect(scrubbed.currentPoint?.elapsedSeconds ?? .infinity <= target)
  #expect(scrubbed.nextPoint?.elapsedSeconds ?? .infinity > target)

  _ = try transport.setSpeed(0.5, atHostTime: 9_001)
  _ = try transport.play(atHostTime: 9_001)
  let halfX = try transport.frame(atHostTime: 9_003)
  #expect(abs(halfX.cursorSeconds - (target + 1)) < 0.000_000_001)
  #expect(halfX.speed == 0.5)
}

@Test func stopAtEndHoldsAllRealPointsAndPlayRestarts() throws {
  let series = try realPlaybackSeries()
  var transport = try PassiveCANPlaybackTransport(
    series: series,
    speed: 1,
    endBehavior: .stopAtEnd)
  _ = try transport.play(atHostTime: 10)
  let ended = try transport.frame(
    atHostTime: 10 + transport.timeline.durationSeconds + 5)

  #expect(ended.phase == .ended)
  #expect(ended.cursorSeconds == transport.timeline.endSeconds)
  #expect(ended.progress == 1)
  #expect(ended.visiblePoints == transport.timeline.points)
  #expect(ended.currentPoint == transport.timeline.points.last)
  #expect(ended.nextPoint == nil)

  let replayed = try transport.play(atHostTime: 100)
  #expect(replayed.phase == .playing)
  #expect(replayed.cursorSeconds == transport.timeline.startSeconds)
  #expect(
    replayed.visiblePoints.allSatisfy {
      $0.elapsedSeconds == transport.timeline.startSeconds
    })
}

@Test func loopingPlaybackWrapsWithExactSpeedAndNeverInterpolatesValues() throws {
  let series = try realPlaybackSeries()
  var transport = try PassiveCANPlaybackTransport(
    series: series,
    speed: 4,
    endBehavior: .loop)
  let duration = transport.timeline.durationSeconds
  _ = try transport.play(atHostTime: 50)
  let frame = try transport.frame(atHostTime: 50 + (duration * 2.5 / 4))
  let expectedCursor = transport.timeline.startSeconds + duration * 0.5
  let retainedIdentities = Set(transport.timeline.points.map(\.id))

  #expect(frame.phase == .playing)
  #expect(frame.completedLoops == 2)
  #expect(abs(frame.cursorSeconds - expectedCursor) < 0.000_000_001)
  #expect(frame.visiblePoints.allSatisfy { retainedIdentities.contains($0.id) })
  #expect(frame.currentPoint.map { retainedIdentities.contains($0.id) } ?? false)
  #expect(frame.nextPoint.map { retainedIdentities.contains($0.id) } ?? true)
}

@Test func realMultiSessionPlaybackExposesBoundariesAndEvidenceGap() throws {
  let series = try realMultiSessionPlaybackSeries()
  let timeline = try PassiveCANPlaybackTimeline(series: series)
  let adjacent = try #require(
    timeline.sessions.indices.dropLast().first {
      timeline.sessions[$0].endSeconds < timeline.sessions[$0 + 1].startSeconds
    })
  let first = timeline.sessions[adjacent]
  let second = timeline.sessions[adjacent + 1]
  let gapCursor = (first.endSeconds + second.startSeconds) / 2
  let gap = try timeline.frame(at: gapCursor, phase: .paused, speed: 1)
  let secondStart = try timeline.frame(at: second.startSeconds, phase: .paused, speed: 1)

  #expect(timeline.sessions.count == 2)
  #expect(first.sessionID != second.sessionID)
  #expect(first.pointCount > 0)
  #expect(second.pointCount > 0)
  #expect(gap.activeSession == nil)
  #expect(gap.isBetweenSessions)
  #expect(gap.lastObservedSession == first)
  #expect(gap.nextSession == second)
  #expect(secondStart.activeSession == second)
  #expect(secondStart.currentPoint?.sessionID == first.sessionID)
  #expect(secondStart.nextPoint?.sessionID == second.sessionID)
  let secondPointStart = try #require(
    series.sessionBounds.first { $0.sessionID == second.sessionID }?.firstPointSeconds)
  let firstObservedPoint = try timeline.frame(
    at: secondPointStart,
    phase: .paused,
    speed: 1)
  #expect(firstObservedPoint.currentPoint?.sessionID == second.sessionID)
}

@Test func overCapRealCorpusPreservesExactCaptureAndPlottedSessionBoundaries() throws {
  let observations = try loadRealMultiSessionObservations(allSessions: true)
  let report = try PassiveCANResearchAnalyzer.analyze(
    observations,
    maximumPointsPerSeries: 16)
  let series = try #require(
    report.series.first { $0.id == "toyota.2c4.engine-speed.be16" })
  let timeline = try PassiveCANPlaybackTimeline(series: series)

  #expect(series.recordCount > series.points.count)
  #expect(series.points.count <= 16)
  #expect(series.sessionBounds.count == 8)
  #expect(series.sessionBounds.map(\.pointCount).reduce(0, +) == series.recordCount)
  #expect(
    series.sessionBounds.contains {
      $0.captureStartSeconds < $0.firstPointSeconds
        || $0.captureEndSeconds > $0.lastPointSeconds
    })

  for bounds in series.sessionBounds {
    let plotted = series.points.filter {
      $0.gatewayID == bounds.gatewayID && $0.sessionID == bounds.sessionID
    }
    #expect(plotted.first?.elapsedSeconds == bounds.firstPointSeconds)
    #expect(plotted.last?.elapsedSeconds == bounds.lastPointSeconds)
    let playbackBounds = try #require(timeline.sessions.first { $0.id == bounds.id })
    #expect(playbackBounds.startSeconds == bounds.captureStartSeconds)
    #expect(playbackBounds.endSeconds == bounds.captureEndSeconds)
    #expect(playbackBounds.pointCount == bounds.pointCount)
  }

  for index in series.sessionBounds.indices.dropLast() {
    let left = series.sessionBounds[index]
    let right = series.sessionBounds[index + 1]
    #expect(abs(right.captureStartSeconds - left.captureEndSeconds - 1) < 0.000_000_001)
    let frame = try timeline.frame(
      at: (left.captureEndSeconds + right.captureStartSeconds) / 2,
      phase: .paused,
      speed: 1)
    #expect(frame.isBetweenSessions)
    #expect(frame.lastObservedSession?.sessionID == left.sessionID)
    #expect(frame.nextSession?.sessionID == right.sessionID)
  }
}

@Test func overCapShuffledRealEvidenceProducesIdenticalResearchSeries() throws {
  let observations = try loadRealMultiSessionObservations(allSessions: true)
  let shuffled = observations.enumerated().sorted { left, right in
    let leftBucket = (left.offset * 73) % observations.count
    let rightBucket = (right.offset * 73) % observations.count
    return leftBucket < rightBucket
  }.map(\.element)

  let canonical = try PassiveCANResearchAnalyzer.analyze(
    observations,
    maximumPointsPerSeries: 480)
  let permuted = try PassiveCANResearchAnalyzer.analyze(
    shuffled,
    maximumPointsPerSeries: 480)
  let engine = try #require(
    canonical.series.first { $0.id == "toyota.2c4.engine-speed.be16" })

  #expect(engine.recordCount > 480)
  #expect(engine.points.count <= 480)
  #expect(permuted == canonical)
}

@Test func playbackRejectsInvalidClockAndSpeedInputs() throws {
  let series = try realPlaybackSeries()
  #expect(throws: PassiveCANPlaybackError.invalidSpeed) {
    try PassiveCANPlaybackTransport(series: series, speed: 0)
  }

  var transport = try PassiveCANPlaybackTransport(series: series)
  _ = try transport.play(atHostTime: 20)
  _ = try transport.frame(atHostTime: 21)
  #expect(throws: PassiveCANPlaybackError.hostTimeMovedBackward) {
    try transport.frame(atHostTime: 20.5)
  }

  var overflowing = try PassiveCANPlaybackTransport(
    series: series,
    speed: Double.greatestFiniteMagnitude / 4,
    endBehavior: .loop)
  _ = try overflowing.play(atHostTime: 0)
  #expect(throws: PassiveCANPlaybackError.playbackClockOverflow) {
    try overflowing.frame(atHostTime: 1)
  }
}

private func realPlaybackSeries() throws -> PassiveCANResearchSeries {
  let url = try #require(
    Bundle.module.url(
      forResource: "real-can-2026-08-18-627753796-256",
      withExtension: "ndjson",
      subdirectory: "Fixtures"))
  let observations = try PassiveCANEvidenceArchive.decodeNDJSON(Data(contentsOf: url))
  let report = try PassiveCANResearchAnalyzer.analyze(observations)
  return try #require(report.series.first { $0.id == "toyota.2c4.engine-speed.be16" })
}

private func realMultiSessionPlaybackSeries() throws -> PassiveCANResearchSeries {
  let observations = try loadRealMultiSessionObservations(allSessions: false)
  let report = try PassiveCANResearchAnalyzer.analyze(observations)
  return try #require(report.series.first { $0.id == "toyota.2c4.engine-speed.be16" })
}

private func loadRealMultiSessionObservations(
  allSessions: Bool
) throws -> [PassiveCANObservation] {
  let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let directory = repositoryRoot.appendingPathComponent(
    "test-replay/real-can-2026-08-18/sessions")
  let sessionFiles =
    allSessions
    ? [
      "1007674331.ndjson", "1846258254.ndjson", "2020748856.ndjson",
      "2175731012.ndjson", "4020849719.ndjson", "627753796.ndjson",
      "628897492.ndjson", "740616386.ndjson",
    ]
    : ["1007674331.ndjson", "628897492.ndjson"]
  return try sessionFiles.flatMap { name in
    try PassiveCANEvidenceArchive.decodeNDJSON(
      Data(contentsOf: directory.appendingPathComponent(name)))
  }
}
