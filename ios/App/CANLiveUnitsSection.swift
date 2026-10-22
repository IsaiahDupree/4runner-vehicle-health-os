import SwiftUI
import VHOSCore

/// Live pinned engineering candidates and exact raw CAN identifiers from the
/// passive stream.
///
/// Deliberately styled apart from the retained sections: a live number and
/// an archived number must never be mistaken for one another. The value
/// keeps its authority coloring (a pinned-but-unvalidated transform stays
/// blue whether it is live or retained) and a quiet bus is shown as STALE,
/// never as a frozen current reading.
struct CANLiveUnitsSection: View {
  @Environment(AppModel.self) private var model
  @Binding var selectedChannelID: String?

  private var fields: [CANLiveFieldDescriptor] { model.liveCANFields }
  private var rawIdentifiers: [CANLiveRawIdentifierDescriptor] {
    model.liveRawCANIdentifiers.sorted {
      if $0.extended != $1.extended { return !$0.extended }
      return $0.identifier < $1.identifier
    }
  }

  private var options: [CANLiveSelectionOption] {
    fields.map { CANLiveSelectionOption(kind: .field($0)) }
      + rawIdentifiers.map { CANLiveSelectionOption(kind: .rawIdentifier($0)) }
  }

  private var selection: CANLiveSelectionOption? {
    if let selectedChannelID, let match = options.first(where: { $0.id == selectedChannelID }) {
      return match
    }
    return options.first
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Live CAN Values").font(.title3.bold())
        Text("Pinned candidate units plus exact raw-only identifiers from the connected gateway")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if options.isEmpty {
        CANLiveUnavailable(
          title: "No live CAN identifiers yet",
          detail: emptyStateDetail)
      } else {
        picker
        if let selection {
          switch selection.kind {
          case .field(let field):
            if let channel = model.liveCANChannel(for: field.id) {
              liveCard(channel: channel, field: field)
            }
          case .rawIdentifier(let descriptor):
            if let channel = model.liveRawCANChannel(for: descriptor.id) {
              rawCard(channel: channel)
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var picker: some View {
    Picker("Live CAN channel", selection: Binding(
      get: { selection?.id ?? "" },
      set: { selectedChannelID = $0 }
    )) {
      if !fields.isEmpty {
        Section("Pinned candidate fields") {
          ForEach(fields) { field in
            Text(field.label).tag(field.id)
          }
        }
      }
      if !rawIdentifiers.isEmpty {
        Section("Raw frame inventory · \(rawIdentifiers.count)") {
          ForEach(rawIdentifiers) { descriptor in
            Text("\(descriptor.label) · RAW FRAME").tag(descriptor.id)
          }
        }
      }
    }
    .pickerStyle(.menu)
    .tint(.blue)
  }

  private var emptyStateDetail: String {
    var details = ["Gateway: \(gatewayStateLabel)."]
    if let observation = model.gateway.latestCANObservation {
      let age = model.gateway.latestCANObservationReceivedAt.map {
        max(0, model.canLiveUnitsClock.timeIntervalSince($0))
      }
      let ageText = age.map { $0 < 1 ? "<1s ago" : "\(Int($0))s ago" } ?? "age unavailable"
      details.append(
        "Latest accepted raw frame: 0x\(observation.identifierHex), \(ageText).")
    } else {
      details.append("No current-session raw CAN frame has passed the gateway evidence gates.")
    }
    let identifiers = recentPinnedIdentifiers
      .map { "0x" + String(format: "%03X", $0) }
      .joined(separator: ", ")
    details.append(
      identifiers.isEmpty
        ? "Pinned IDs seen in the recent accepted window: none."
        : "Pinned IDs seen in the recent accepted window: \(identifiers).")
    if model.gateway.state != .vhosConnected {
      details.append("Connect the VHOS gateway over Bluetooth to stream live values.")
    } else {
      details.append(
        "Waiting for a current-session listen-only BLE frame that passes the evidence contract.")
    }
    return details.joined(separator: " ")
  }

  private var recentPinnedIdentifiers: [UInt32] {
    guard let gatewayID = model.gateway.handshake?.gatewayID,
      let sessionID = model.gateway.health?.captureSessionID
    else { return [] }
    let pinned = Set(CANUnitsAnalyzer.candidateFields.map(\.identifier))
    return Set(
      model.gateway.recentCANObservations.lazy.filter {
        $0.gatewayID == gatewayID && $0.sessionID == sessionID && $0.listenOnly
          && $0.evidenceSource == "ble-live" && pinned.contains($0.identifier)
      }.map(\.identifier)
    ).sorted()
  }

  private var gatewayStateLabel: String {
    switch model.gateway.state {
    case .disconnected: "disconnected"
    case .scanning: "scanning"
    case .connecting: "connecting"
    case .factoryCompatible: "factory-compatible firmware"
    case .vhosConnected: "VHOS connected"
    case .degraded: "degraded"
    case .updating: "updating"
    case .failed: "failed"
    }
  }

  @ViewBuilder
  private func liveCard(channel: CANLiveChannel, field: CANLiveFieldDescriptor) -> some View {
    let tone = freshnessTone(channel.freshness)
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text(field.label).font(.headline)
          Text(field.source)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 3) {
          Text(valueText(channel: channel, field: field))
            .font(.title.bold().monospacedDigit())
            .foregroundStyle(tone)
            .contentTransition(.numericText())
            .animation(.easeOut(duration: 0.18), value: channel.latest?.displayValue)
          Text(freshnessLabel(channel.freshness, ageSeconds: channel.ageSeconds))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tone)
        }
      }

      CANLiveSparkline(values: channel.window, tone: tone)
        .frame(height: 54)

      if let statistics = channel.statistics {
        HStack(alignment: .top) {
          liveStat("MIN", statistics.minimum, field)
          Spacer()
          liveStat("MAX", statistics.maximum, field)
          Spacer()
          liveStat("MEAN", statistics.mean, field)
          Spacer()
          VStack(alignment: .trailing, spacing: 1) {
            Text("WINDOW").font(.caption2).foregroundStyle(.secondary)
            Text("\(channel.sampleCount) samples")
              .font(.footnote.monospacedDigit())
          }
        }
      }

      HStack(spacing: 7) {
        CANLiveBadge(
          text: field.authority == .rawOnlyCandidate ? "RAW / DERIVED" : "UNVERIFIED UNIT",
          color: field.authority == .rawOnlyCandidate ? .orange : .blue)
        if let latest = channel.latest {
          Text("session \(latest.sessionID) · seq \(latest.sourceSequence)")
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
        }
      }

      Text(
        field.authority == .rawOnlyCandidate
          ? "Raw counts only: no validated engineering unit exists for this field. It cannot drive owner health."
          : "Live values apply a pinned formula whose scale is not yet validated on this vehicle. Being current does not make it verified; it cannot drive owner health."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
    .padding()
    .background(tone.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
    .overlay(
      RoundedRectangle(cornerRadius: 18)
        .strokeBorder(tone.opacity(channel.freshness == .live ? 0.35 : 0.18), lineWidth: 1))
  }

  private func rawCard(channel: CANLiveRawChannel) -> some View {
    let tone = freshnessTone(channel.freshness)
    let latest = channel.latest
    return VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text(channel.descriptor.label).font(.headline.monospaced())
          Text(
            channel.descriptor.extended
              ? "29-bit extended identifier" : "11-bit standard identifier"
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 3) {
          CANLiveBadge(text: "RAW ONLY", color: .orange)
          Text(freshnessLabel(channel.freshness, ageSeconds: channel.ageSeconds))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tone)
        }
      }

      CANLiveRawByteStrip(
        data: latest.data,
        changedByteIndices: Set(channel.changedByteIndices))

      Text(rawPayloadText(latest))
        .font(.footnote.monospaced())
        .textSelection(.enabled)

      HStack(alignment: .top, spacing: 18) {
        rawMetric("DLC", latest.dataLength.formatted())
        rawMetric("BITRATE", "\(latest.bitrateBps / 1_000) kbit/s")
        rawMetric("WINDOW", "\(channel.sampleCount) updates")
      }

      Text(rawChangeSummary(channel))
        .font(.caption2)
        .foregroundStyle(channel.changedByteIndices.isEmpty ? Color.secondary : Color.orange)

      VStack(alignment: .leading, spacing: 3) {
        Text("session \(latest.sessionID) · seq \(latest.sourceSequence)")
          .font(.caption2.monospaced())
        Text("observed \(latest.observedAt)")
          .font(.caption2.monospaced())
      }
      .foregroundStyle(.secondary)

      Text(
        "No signal meaning, formula, or physical unit is inferred for this identifier. Exact raw evidence cannot drive owner health."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
    .padding()
    .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
    .overlay(
      RoundedRectangle(cornerRadius: 18)
        .strokeBorder(tone.opacity(channel.freshness == .live ? 0.35 : 0.18), lineWidth: 1))
  }

  private func rawMetric(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).font(.caption2).foregroundStyle(.secondary)
      Text(value).font(.footnote.weight(.semibold).monospacedDigit())
    }
  }

  private func rawPayloadText(_ reading: CANLiveRawReading) -> String {
    if reading.remoteRequest {
      return "Payload: — · RTR carries no payload"
    }
    return reading.data.isEmpty ? "Payload: — · DLC 0" : "Payload: \(reading.dataHex)"
  }

  private func rawChangeSummary(_ channel: CANLiveRawChannel) -> String {
    guard channel.sampleCount > 1 else { return "First observed payload; no prior update to compare." }
    let bytes = channel.changedByteIndices.map { "B\($0)" }.joined(separator: ", ")
    if bytes.isEmpty {
      return channel.dataLengthChanged
        ? "DLC changed; no current payload byte differs in the shared range."
        : "No payload byte changed since the previous update."
    }
    return "Changed since previous update: \(bytes)"
      + (channel.dataLengthChanged ? " · DLC also changed" : "")
  }

  private func liveStat(
    _ label: String, _ value: Double, _ field: CANLiveFieldDescriptor
  ) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(label).font(.caption2).foregroundStyle(.secondary)
      Text(value.formatted(.number.precision(.fractionLength(0...2))))
        .font(.footnote.monospacedDigit())
      Text(field.unit ?? "counts").font(.caption2).foregroundStyle(.secondary)
    }
  }

  private func valueText(channel: CANLiveChannel, field: CANLiveFieldDescriptor) -> String {
    guard let latest = channel.latest else { return "—" }
    let number = latest.displayValue.formatted(.number.precision(.fractionLength(0...2)))
    return "\(number) \(field.unit ?? "counts")"
  }

  private func freshnessLabel(
    _ freshness: CANLiveUnits.Freshness,
    ageSeconds: TimeInterval?
  ) -> String {
    switch freshness {
    case .live: "LIVE"
    case .stale:
      ageSeconds.map { "STALE · \(Int($0))s since last frame" } ?? "STALE"
    case .expired: "NO RECENT FRAMES"
    }
  }

  private func freshnessTone(_ freshness: CANLiveUnits.Freshness) -> Color {
    switch freshness {
    case .live: .blue
    case .stale: .orange
    case .expired: .secondary
    }
  }
}

private struct CANLiveSelectionOption: Identifiable {
  enum Kind {
    case field(CANLiveFieldDescriptor)
    case rawIdentifier(CANLiveRawIdentifierDescriptor)
  }

  let kind: Kind

  var id: String {
    switch kind {
    case .field(let field): field.id
    case .rawIdentifier(let descriptor): descriptor.id
    }
  }

  var label: String {
    switch kind {
    case .field(let field): field.label
    case .rawIdentifier(let descriptor): "\(descriptor.label) · RAW FRAME"
    }
  }
}

/// Minimal rolling sparkline. Oldest-first values, endpoint emphasized.
private struct CANLiveSparkline: View {
  let values: [Double]
  let tone: Color

  var body: some View {
    GeometryReader { geometry in
      let points = normalizedPoints(in: geometry.size)
      ZStack {
        if points.count > 1 {
          Path { path in
            path.move(to: CGPoint(x: points[0].x, y: geometry.size.height))
            for point in points { path.addLine(to: point) }
            path.addLine(to: CGPoint(x: points[points.count - 1].x, y: geometry.size.height))
            path.closeSubpath()
          }
          .fill(
            LinearGradient(
              colors: [tone.opacity(0.28), tone.opacity(0.02)],
              startPoint: .top, endPoint: .bottom))

          Path { path in
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
          }
          .stroke(tone, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

          if let last = points.last {
            Circle()
              .fill(tone)
              .frame(width: 6, height: 6)
              .position(last)
          }
        } else {
          Text("Collecting samples…")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
      }
    }
    .accessibilityLabel("Rolling window of the selected live value")
  }

  private func normalizedPoints(in size: CGSize) -> [CGPoint] {
    guard values.count > 1 else { return [] }
    let minimum = values.min() ?? 0
    let maximum = values.max() ?? 0
    let span = maximum - minimum
    let stepX = size.width / CGFloat(values.count - 1)
    return values.enumerated().map { index, value in
      // A flat series draws through the middle rather than pinned to an
      // edge, so "not moving" reads as not moving.
      let ratio = span == 0 ? 0.5 : (value - minimum) / span
      let inset = size.height * 0.08
      let usable = size.height - inset * 2
      return CGPoint(
        x: CGFloat(index) * stepX,
        y: size.height - inset - CGFloat(ratio) * usable)
    }
  }
}

/// Exact payload bytes with only direct byte-to-byte change highlighted.
/// No endianness, scalar, scale, or semantic meaning is inferred.
private struct CANLiveRawByteStrip: View {
  let data: [UInt8]
  let changedByteIndices: Set<Int>

  var body: some View {
    if data.isEmpty {
      Text("— no payload bytes —")
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    } else {
      HStack(spacing: 4) {
        ForEach(data.indices, id: \.self) { index in
          let changed = changedByteIndices.contains(index)
          VStack(spacing: 2) {
            Text("B\(index)")
              .font(.system(size: 8, weight: .medium, design: .monospaced))
              .foregroundStyle(.secondary)
            Text(String(format: "%02X", data[index]))
              .font(.system(size: 12, weight: .bold, design: .monospaced))
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 6)
          .background(
            changed ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 7))
          .overlay(
            RoundedRectangle(cornerRadius: 7)
              .strokeBorder(changed ? Color.orange.opacity(0.55) : .clear, lineWidth: 1))
        }
      }
      .accessibilityLabel(
        "Raw payload bytes "
          + data.enumerated().map { "byte \($0.offset) \(String(format: "%02X", $0.element))" }
            .joined(separator: ", "))
    }
  }
}

private struct CANLiveBadge: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(color.opacity(0.14), in: Capsule())
      .foregroundStyle(color)
  }
}

private struct CANLiveUnavailable: View {
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Label(title, systemImage: "antenna.radiowaves.left.and.right.slash")
        .font(.subheadline.weight(.semibold))
      Text(detail).font(.caption).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
    .background(.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
  }
}
