import SwiftUI
import VHOSCore

/// Live engineering values from the passive CAN stream.
///
/// Deliberately styled apart from the retained sections: a live number and
/// an archived number must never be mistaken for one another. The value
/// keeps its authority coloring (a pinned-but-unvalidated transform stays
/// blue whether it is live or retained) and a quiet bus is shown as STALE,
/// never as a frozen current reading.
struct CANLiveUnitsSection: View {
  @Environment(AppModel.self) private var model
  @Binding var selectedFieldID: String?

  private var fields: [CANLiveFieldDescriptor] { model.liveCANFields }

  private var selection: CANLiveFieldDescriptor? {
    if let selectedFieldID, let match = fields.first(where: { $0.id == selectedFieldID }) {
      return match
    }
    return fields.first
  }

  private var channel: CANLiveChannel? {
    selection.flatMap { model.liveCANChannel(for: $0.id) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Live Engineering Units").font(.title3.bold())
        Text("Streaming from the connected gateway · pinned formulas, unvalidated scale")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if fields.isEmpty {
        CANLiveUnavailable(
          title: "No live candidate fields yet",
          detail: model.gateway.state == .vhosConnected
            ? "Connected, but no passive frame has matched a pinned candidate field yet. Values appear as the vehicle's modules transmit."
            : "Connect the VHOS gateway over Bluetooth to stream live passive CAN values.")
      } else {
        picker
        if let channel, let selection {
          liveCard(channel: channel, field: selection)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var picker: some View {
    Picker("Live field", selection: Binding(
      get: { selection?.id ?? "" },
      set: { selectedFieldID = $0 }
    )) {
      ForEach(fields) { field in
        Text(field.label).tag(field.id)
      }
    }
    .pickerStyle(.menu)
    .tint(.blue)
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
          Text(freshnessLabel(channel))
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

  private func freshnessLabel(_ channel: CANLiveChannel) -> String {
    switch channel.freshness {
    case .live: "LIVE"
    case .stale:
      channel.ageSeconds.map { "STALE · \(Int($0))s since last frame" } ?? "STALE"
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
