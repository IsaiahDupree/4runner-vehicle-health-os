import Charts
import SwiftUI
import VHOSCore

struct PassiveCANPlaybackLab: View {
  let report: PassiveCANResearchReport
  @Binding var selectedSeriesID: String

  @Environment(\.scenePhase) private var scenePhase
  @State private var transport: PassiveCANPlaybackTransport?
  @State private var frame: PassiveCANPlaybackFrame?
  @State private var playbackError: String?
  @State private var loopEnabled = false
  @State private var resumeAfterScrub = false
  @State private var speed = 1.0

  private static let speeds = [0.25, 0.5, 1, 2, 5, 10, 20]

  private var selectedSeries: PassiveCANResearchSeries? {
    report.series.first(where: { $0.id == selectedSeriesID }) ?? report.series.first
  }

  private var playbackIdentity: String {
    "\(report.generatedFromSHA256):\(selectedSeries?.id ?? "none")"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("HISTORICAL RETAINED EVIDENCE • NOT LIVE", systemImage: "play.rectangle.on.rectangle")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.blue)

      Picker("Candidate field", selection: $selectedSeriesID) {
        ForEach(report.series) { series in
          Text("\(series.identifierHex) · \(series.label)").tag(series.id)
        }
      }
      .pickerStyle(.menu)

      if let series = selectedSeries, let transport, let frame {
        playbackControls(transport: transport, frame: frame)
        playbackScrubber(frame: frame)
        playbackChart(series: series, transport: transport, frame: frame)
        playbackReadout(series: series, frame: frame)

        Text(
          "Playback uses the retained monotonic timeline and exact plotted points. Dashed markers separate capture sessions; the one-second separator is synthetic and is never presented as continuous vehicle time."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        Text(
          "The chart contains at most 480 transient-preserving points. The canonical retained NDJSON archive remains the complete evidence source."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      } else if let playbackError {
        VStack(alignment: .leading, spacing: 8) {
          Label(playbackError, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
          Button("Reset retained evidence playback") {
            configurePlayback()
          }
        }
      } else {
        ProgressView("Preparing retained evidence playback…")
      }
    }
    .task(id: playbackIdentity) {
      configurePlayback()
    }
    .task {
      await runPlaybackClock()
    }
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase != .active { pausePlayback() }
    }
  }

  @ViewBuilder
  private func playbackControls(
    transport: PassiveCANPlaybackTransport,
    frame: PassiveCANPlaybackFrame
  ) -> some View {
    HStack(spacing: 12) {
      Button {
        restartPlayback(playing: frame.phase == .playing)
      } label: {
        Image(systemName: "backward.end.fill")
          .frame(minWidth: 30, minHeight: 30)
      }
      .buttonStyle(.bordered)
      .accessibilityLabel("Restart retained evidence playback")

      Button {
        togglePlayback()
      } label: {
        Label(
          frame.phase == .playing ? "Pause" : (frame.phase == .ended ? "Replay" : "Play"),
          systemImage: frame.phase == .playing ? "pause.fill" : "play.fill"
        )
        .frame(minHeight: 30)
      }
      .buttonStyle(.borderedProminent)
      .disabled(frame.durationSeconds <= 0 || transport.timeline.points.count < 2)
      .accessibilityHint("Plays only the retained CAN points on this iPhone")

      Menu {
        ForEach(Self.speeds, id: \.self) { candidate in
          Button {
            setSpeed(candidate)
          } label: {
            if speed == candidate {
              Label(speedLabel(candidate), systemImage: "checkmark")
            } else {
              Text(speedLabel(candidate))
            }
          }
        }
      } label: {
        Label(speedLabel(speed), systemImage: "gauge.with.dots.needle.50percent")
          .frame(minHeight: 30)
      }
      .buttonStyle(.bordered)
      .accessibilityLabel("Playback speed \(speedLabel(speed))")

      Toggle(
        isOn: Binding(
          get: { loopEnabled },
          set: { setLoopEnabled($0) }
        )
      ) {
        Image(systemName: "repeat")
          .frame(minWidth: 30, minHeight: 30)
      }
      .toggleStyle(.button)
      .accessibilityLabel("Loop retained evidence playback")
      .accessibilityValue(loopEnabled ? "On" : "Off")
    }

    HStack {
      Label(phaseLabel(frame), systemImage: phaseSymbol(frame.phase))
        .font(.caption.weight(.semibold))
        .foregroundStyle(frame.phase == .playing ? .blue : .secondary)
      Spacer()
      if frame.completedLoops > 0 {
        Text("\(frame.completedLoops) completed loops")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func playbackScrubber(frame: PassiveCANPlaybackFrame) -> some View {
    VStack(spacing: 4) {
      Slider(
        value: Binding(
          get: { frame.cursorSeconds },
          set: { scrubPlayback(to: $0) }
        ),
        in: playbackRange(frame),
        onEditingChanged: handleScrubbing
      )
      .disabled(frame.durationSeconds <= 0)
      .accessibilityLabel("Retained evidence playback position")
      .accessibilityValue(
        "\(timeLabel(frame.cursorSeconds - frame.startSeconds)) of \(timeLabel(frame.durationSeconds))"
      )

      HStack {
        Text(timeLabel(frame.cursorSeconds - frame.startSeconds))
        Spacer()
        Text("\((frame.progress).formatted(.percent.precision(.fractionLength(0))))")
        Spacer()
        Text(timeLabel(frame.durationSeconds))
      }
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
    }
  }

  private func playbackChart(
    series: PassiveCANResearchSeries,
    transport: PassiveCANPlaybackTransport,
    frame: PassiveCANPlaybackFrame
  ) -> some View {
    Chart {
      ForEach(series.points) { point in
        LineMark(
          x: .value("Capture timeline (s)", point.elapsedSeconds),
          y: .value(series.displayUnit, point.displayValue),
          series: .value("Context session", "context-\(point.sessionOrdinal)")
        )
        .foregroundStyle(Color.secondary.opacity(0.18))
        .lineStyle(StrokeStyle(lineWidth: 1))
        .interpolationMethod(.stepEnd)
      }

      ForEach(frame.visiblePoints) { point in
        LineMark(
          x: .value("Capture timeline (s)", point.elapsedSeconds),
          y: .value(series.displayUnit, point.displayValue),
          series: .value("Played session", "played-\(point.sessionOrdinal)")
        )
        .foregroundStyle(Color.accentColor)
        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        .interpolationMethod(.stepEnd)
      }

      ForEach(transport.timeline.sessions) { session in
        RuleMark(x: .value("Session boundary", session.startSeconds))
          .foregroundStyle(Color.secondary.opacity(0.5))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
          .annotation(position: .top, alignment: .leading) {
            Text("S\(session.sessionOrdinal)")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
          }
      }

      RuleMark(x: .value("Playback cursor", frame.cursorSeconds))
        .foregroundStyle(.orange)
        .lineStyle(StrokeStyle(lineWidth: 2))

      if let point = frame.currentPoint {
        PointMark(
          x: .value("Current retained point", point.elapsedSeconds),
          y: .value(series.displayUnit, point.displayValue)
        )
        .foregroundStyle(.orange)
        .symbolSize(70)
      }
    }
    .chartXScale(domain: frame.startSeconds...safeChartEnd(frame))
    .chartXAxisLabel("Retained capture timeline (seconds)")
    .chartYAxisLabel(
      series.usesCandidateTransform
        ? "Candidate \(series.displayUnit) — unverified" : series.displayUnit
    )
    .chartLegend(.hidden)
    .frame(minHeight: 260)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Retained CAN playback chart for \(series.label)")
    .accessibilityValue(chartAccessibilityValue(series: series, frame: frame))
  }

  private func playbackReadout(
    series: PassiveCANResearchSeries,
    frame: PassiveCANPlaybackFrame
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      if frame.isBetweenSessions {
        Label(
          "SESSION GAP • next \(frame.nextSession?.label ?? "capture session")",
          systemImage: "arrow.right.to.line.compact"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(.orange)
      }

      if let activeSession = frame.activeSession,
        frame.currentPoint.map({
          $0.gatewayID != activeSession.gatewayID || $0.sessionID != activeSession.sessionID
            || $0.sessionOrdinal != activeSession.sessionOrdinal
        }) ?? true
      {
        Label(
          "AWAITING FIRST SELECTED SAMPLE • \(activeSession.label)",
          systemImage: "clock.badge.questionmark"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(.orange)

        if frame.currentPoint != nil {
          Text("The value below remains the previous session's last exact retained point.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if let point = frame.currentPoint {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 125), alignment: .leading)],
          alignment: .leading,
          spacing: 10
        ) {
          playbackMetric(
            series.usesCandidateTransform ? "Candidate value" : "Graph value",
            "\(numberLabel(point.displayValue)) \(series.displayUnit)",
            emphasized: true)
          playbackMetric("Raw field", "\(numberLabel(point.rawValue)) counts")
          playbackMetric("Retained point capture", point.sessionLabel)
          if let activeSession = frame.activeSession {
            playbackMetric("Cursor capture", activeSession.label)
          }
          playbackMetric("Source sequence", point.sourceSequence.formatted())
          playbackMetric(
            "Retained point time", timeLabel(point.elapsedSeconds - frame.startSeconds))
          if let next = frame.nextPoint {
            playbackMetric(
              "Next retained point",
              "+\(numberLabel(max(0, next.elapsedSeconds - frame.cursorSeconds))) s")
          }
        }
      } else {
        Text("No retained point exists at this playback position.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      if series.usesCandidateTransform {
        Label(
          "Candidate engineering units are cross-model research and remain unverified for this 4Runner.",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(.orange)
      }
    }
  }

  private func playbackMetric(
    _ label: String,
    _ value: String,
    emphasized: Bool = false
  ) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(emphasized ? .headline.monospacedDigit() : .subheadline.monospacedDigit())
    }
  }

  private func configurePlayback() {
    guard let series = selectedSeries else {
      transport = nil
      frame = nil
      playbackError = "No retained CAN series is available for playback."
      return
    }
    if selectedSeriesID != series.id { selectedSeriesID = series.id }
    do {
      let candidate = try PassiveCANPlaybackTransport(
        series: series,
        speed: speed,
        endBehavior: loopEnabled ? .loop : .stopAtEnd)
      transport = candidate
      frame = candidate.currentFrame
      playbackError = nil
      resumeAfterScrub = false
    } catch {
      transport = nil
      frame = nil
      playbackError = error.localizedDescription
    }
  }

  private func runPlaybackClock() async {
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: .milliseconds(50))
      } catch {
        return
      }
      guard transport?.phase == .playing else { continue }
      updateTransport { candidate in
        try candidate.frame(atHostTime: hostTime)
      }
    }
  }

  private func togglePlayback() {
    if frame?.phase == .playing {
      pausePlayback()
    } else {
      updateTransport { candidate in
        try candidate.play(atHostTime: hostTime)
      }
    }
  }

  private func pausePlayback() {
    guard transport?.phase == .playing else { return }
    updateTransport { candidate in
      try candidate.pause(atHostTime: hostTime)
    }
  }

  private func restartPlayback(playing: Bool) {
    updateTransport { candidate in
      try candidate.restart(atHostTime: hostTime, playing: playing)
    }
  }

  private func scrubPlayback(to elapsedSeconds: Double) {
    updateTransport { candidate in
      try candidate.scrub(to: elapsedSeconds, atHostTime: hostTime)
    }
  }

  private func handleScrubbing(_ editing: Bool) {
    if editing {
      resumeAfterScrub = frame?.phase == .playing
      pausePlayback()
      return
    }
    guard resumeAfterScrub else { return }
    resumeAfterScrub = false
    guard let frame, frame.cursorSeconds < frame.endSeconds else { return }
    updateTransport { candidate in
      try candidate.play(atHostTime: hostTime)
    }
  }

  private func setSpeed(_ candidateSpeed: Double) {
    updateTransport { candidate in
      try candidate.setSpeed(candidateSpeed, atHostTime: hostTime)
    }
    speed = candidateSpeed
  }

  private func setLoopEnabled(_ enabled: Bool) {
    updateTransport { candidate in
      try candidate.setEndBehavior(enabled ? .loop : .stopAtEnd, atHostTime: hostTime)
    }
    loopEnabled = enabled
  }

  private func updateTransport(
    _ operation: (inout PassiveCANPlaybackTransport) throws -> PassiveCANPlaybackFrame
  ) {
    guard var candidate = transport else { return }
    do {
      let nextFrame = try operation(&candidate)
      transport = candidate
      frame = nextFrame
      playbackError = nil
    } catch {
      transport = nil
      frame = nil
      playbackError = error.localizedDescription
    }
  }

  private var hostTime: Double { ProcessInfo.processInfo.systemUptime }

  private func playbackRange(_ frame: PassiveCANPlaybackFrame) -> ClosedRange<Double> {
    frame.startSeconds...(frame.durationSeconds > 0 ? frame.endSeconds : frame.startSeconds + 1)
  }

  private func safeChartEnd(_ frame: PassiveCANPlaybackFrame) -> Double {
    frame.durationSeconds > 0 ? frame.endSeconds : frame.startSeconds + 1
  }

  private func phaseLabel(_ frame: PassiveCANPlaybackFrame) -> String {
    switch frame.phase {
    case .paused: frame.isBetweenSessions ? "PAUSED IN SESSION GAP" : "PAUSED"
    case .playing: frame.isBetweenSessions ? "PLAYING SESSION GAP" : "PLAYING RETAINED EVIDENCE"
    case .ended: "END OF RETAINED EVIDENCE"
    }
  }

  private func phaseSymbol(_ phase: PassiveCANPlaybackPhase) -> String {
    switch phase {
    case .paused: "pause.circle.fill"
    case .playing: "play.circle.fill"
    case .ended: "checkmark.circle.fill"
    }
  }

  private func chartAccessibilityValue(
    series: PassiveCANResearchSeries,
    frame: PassiveCANPlaybackFrame
  ) -> String {
    guard let point = frame.currentPoint else {
      return "No retained point at \(timeLabel(frame.cursorSeconds - frame.startSeconds))."
    }
    return
      "\(phaseLabel(frame)). \(point.sessionLabel), source sequence \(point.sourceSequence), raw value \(numberLabel(point.rawValue)) counts, graph value \(numberLabel(point.displayValue)) \(series.displayUnit), at \(timeLabel(frame.cursorSeconds - frame.startSeconds))."
  }

  private func numberLabel(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...3)))
  }

  private func speedLabel(_ value: Double) -> String {
    "\(value.formatted(.number.precision(.fractionLength(0...2))))×"
  }

  private func timeLabel(_ seconds: Double) -> String {
    let clamped = max(0, seconds)
    let minutes = Int(clamped) / 60
    let remainder = clamped - Double(minutes * 60)
    return String(format: "%02d:%04.1f", minutes, remainder)
  }
}
