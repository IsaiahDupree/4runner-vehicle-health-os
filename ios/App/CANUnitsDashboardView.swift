import SwiftUI
import VHOSCore

struct CANUnitsDashboardView: View {
  @Environment(AppModel.self) private var model
  @State private var selectedReplaySeriesID = "toyota.2c4.engine-speed.be16"
  @State private var selectedLiveChannelID: String?
  /// One-second tick so freshness decays visibly without new frames.
  private let liveClock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  private var report: CANUnitsReport? { model.canUnitsReport }

  private var latestStandardSamples: [J1979StandardSample] {
    Dictionary(
      grouping: model.gateway.standardOBDSamples.filter(model.gateway.isCurrentStandardOBDSample),
      by: \.signalID
    ).values.compactMap {
      $0.max { $0.gatewayMonotonicMicroseconds < $1.gatewayMonotonicMicroseconds }
    }.sorted { $0.name < $1.name }
  }

  private var unitSignals: [CANUnitsSignal] {
    report?.signals.filter {
      $0.authority.exposesEngineeringUnit && $0.authority != .observedStandard
    } ?? []
  }

  private var rawSignals: [CANUnitsSignal] {
    report?.signals.filter { !$0.authority.exposesEngineeringUnit } ?? []
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        boundaryCard
        CANLiveUnitsSection(selectedChannelID: $selectedLiveChannelID)
        standardValues
        engineeringValues
        derivedValues
        replayLab
        rawValues
        evidenceSnapshot
      }
      .padding()
    }
    .navigationTitle("CAN Data & Units")
    .navigationBarTitleDisplayMode(.inline)
    // Drain the bounded recent window rather than only the last rendered
    // value. SwiftUI may coalesce several high-rate frame changes.
    .onChange(of: model.gateway.latestCANObservation?.id) { _, _ in
      model.ingestLiveCANObservations(model.gateway.recentCANObservations)
    }
    .onChange(of: model.gateway.health?.captureSessionID) { _, _ in
      model.ingestLiveCANObservations(model.gateway.recentCANObservations)
    }
    .onChange(of: model.gateway.state) { _, _ in
      model.ingestLiveCANObservations(model.gateway.recentCANObservations)
    }
    // Freshness must decay on its own: a bus that goes quiet has to show
    // STALE rather than sit frozen at its last value.
    .onReceive(liveClock) { _ in model.tickLiveCANClock() }
    .onAppear { model.ingestLiveCANObservations(model.gateway.recentCANObservations) }
  }

}

extension CANUnitsDashboardView {
  private var boundaryCard: some View {
    VStack(alignment: .leading, spacing: 9) {
      Label("REAL EVIDENCE ONLY", systemImage: "checkmark.shield.fill")
        .font(.caption.bold())
        .foregroundStyle(.blue)
      Text("Physical units and derived evidence").font(.title2.bold())
      Text(
        "Green values are current SAE J1979 observations. Blue values use pinned transforms awaiting target-vehicle validation. Orange values remain raw or derived and cannot drive owner health."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      HStack(spacing: 7) {
        CANUnitsBadge(text: "OBSERVED", color: .green)
        CANUnitsBadge(text: "UNVERIFIED UNIT", color: .blue)
        CANUnitsBadge(text: "RAW / DERIVED", color: .orange)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
    .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
  }

  private var standardValues: some View {
    CANUnitsSection(title: "Current Standard OBD", subtitle: "Validated SAE J1979 decoding") {
      if latestStandardSamples.isEmpty {
        CANUnitsUnavailable(
          title: "Standard OBD values unavailable",
          detail:
            "The gateway is listen-only: it never requests a PID, so SAE J1979 values appear here only while another tool on the bus is polling. Without that traffic this lane stays empty by design — see Live Engineering Units above for values derived from passive frames. Missing evidence is never shown as zero.")
      } else {
        ForEach(latestStandardSamples) { sample in
          NavigationLink {
            CANStandardDetail(sample: sample)
          } label: {
            CANStandardCard(sample: sample)
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private var engineeringValues: some View {
    CANUnitsSection(
      title: "Experimental Engineering Units",
      subtitle: "Pinned formulas · scale not yet validated on this vehicle"
    ) {
      if unitSignals.isEmpty {
        CANUnitsUnavailable(title: "No unit-bearing passive fields", detail: model.canUnitsMessage)
      } else {
        ForEach(unitSignals) { signal in
          NavigationLink {
            CANSignalDetail(signal: signal)
          } label: {
            CANEngineeringCard(signal: signal)
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private var derivedValues: some View {
    CANUnitsSection(
      title: "Relevant Derived Evidence",
      subtitle: "Full-projection statistics and bounded same-session relationships"
    ) {
      if let report, !report.relationships.isEmpty {
        ForEach(report.relationships) { relationship in
          NavigationLink {
            CANRelationshipDetail(relationship: relationship)
          } label: {
            CANRelationshipSummary(relationship: relationship)
          }
          .buttonStyle(.plain)
        }
      } else {
        CANUnitsUnavailable(
          title: "Derived relationship unavailable",
          detail:
            "The relationship requires enough bounded pairs from the same gateway and session. Cross-session interpolation is prohibited.")
      }
    }
  }

  private var rawValues: some View {
    CANUnitsSection(
      title: "Raw-Only Channels",
      subtitle: "Observed counts with no defensible physical-unit scale"
    ) {
      if rawSignals.isEmpty {
        CANUnitsUnavailable(
          title: "Raw channel evidence unavailable",
          detail: "Synchronize or import retained listen-only evidence to populate this section.")
      } else {
        ForEach(rawSignals) { signal in
          NavigationLink {
            CANSignalDetail(signal: signal)
          } label: {
            CANRawCard(signal: signal)
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private var evidenceSnapshot: some View {
    CANUnitsSection(title: "Evidence Snapshot", subtitle: "Source and decoder identity") {
      if let report {
        CANReportLineage(report: report)
      } else {
        CANUnitsUnavailable(title: "Snapshot unavailable", detail: model.canUnitsMessage)
      }
    }
  }

  private var replayLab: some View {
    CANUnitsSection(
      title: "Retained Evidence Playback",
      subtitle: "Move historical evidence through the graph without a vehicle connection"
    ) {
      if let retained = model.canResearchReport, !retained.series.isEmpty {
        PassiveCANPlaybackLab(
          report: retained,
          selectedSeriesID: $selectedReplaySeriesID
        )
        .padding()
        .background(.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
      } else {
        CANUnitsUnavailable(
          title: "Playback unavailable",
          detail: "Synchronize or import retained listen-only evidence, then run analysis to create a playback timeline."
        )
      }
    }
  }
}

private struct CANUnitsSection<Content: View>: View {
  let title: String
  let subtitle: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.title3.bold())
        Text(subtitle).font(.caption).foregroundStyle(.secondary)
      }
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct CANUnitsBadge: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text)
      .font(.caption2.bold())
      .foregroundStyle(color)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(color.opacity(0.1), in: Capsule())
  }
}

private struct CANUnitsUnavailable: View {
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Label(title, systemImage: "questionmark.circle").font(.headline)
      Text(detail).font(.footnote).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
  }
}

private func canUnitsLabel(_ unit: String) -> String {
  switch unit {
  case "percent": "%"
  case "degC": "°C"
  case "degrees": "°"
  case "raw": "raw count"
  default: unit
  }
}

private func canUnitsNumber(_ value: Double, digits: Int = 2) -> String {
  value.formatted(.number.precision(.fractionLength(0...digits)))
}

private struct CANStandardCard: View {
  let sample: J1979StandardSample

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
      VStack(alignment: .leading, spacing: 4) {
        Text(sample.name).font(.headline)
        Text(sample.signalID).font(.caption.monospaced()).foregroundStyle(.secondary)
        Text("ECU \(sample.ecuAddress) · PID 0x\(String(format: "%02X", sample.pid))")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 5) {
        Text("\(canUnitsNumber(sample.value)) \(canUnitsLabel(sample.unit))")
          .font(.title3.bold().monospacedDigit())
        CANUnitsBadge(text: "OBSERVED", color: .green)
      }
    }
    .padding()
    .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
  }
}

private struct CANStandardDetail: View {
  let sample: J1979StandardSample

  var body: some View {
    List {
      Section("Observed value") {
        LabeledContent(
          "Value", value: "\(canUnitsNumber(sample.value)) \(canUnitsLabel(sample.unit))")
        CANUnitsBadge(text: "OBSERVED STANDARD", color: .green)
        Text("This value passed the current standard-response and freshness evidence gates.")
          .font(.footnote)
      }
      Section("Source") {
        LabeledContent("Canonical signal", value: sample.signalID)
        LabeledContent("ECU", value: sample.ecuAddress)
        LabeledContent("Mode / PID", value: "01 / \(String(format: "%02X", sample.pid))")
        LabeledContent("Raw bytes", value: sample.rawDataHex)
        LabeledContent("Sequence", value: sample.sourceSequence.formatted())
        LabeledContent("Observed", value: sample.observedAt)
      }
      Section("Decoder") {
        LabeledContent("Revision", value: sample.definitionRevision)
        Text("No passive Toyota hypothesis is substituted for this standard response.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .navigationTitle(sample.name)
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct CANEngineeringCard: View {
  let signal: CANUnitsSignal

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 3) {
          Text(signal.name).font(.headline)
          Text(signal.source).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 4) {
          Text("\(canUnitsNumber(signal.latestValue)) \(canUnitsLabel(signal.unit))")
            .font(.title3.bold().monospacedDigit())
          Text("LATEST RETAINED").font(.caption2).foregroundStyle(.secondary)
        }
      }
      if let raw = signal.latestRawValue {
        LabeledContent("Raw input", value: "\(canUnitsNumber(raw, digits: 3)) counts")
          .font(.caption)
      }
      if let statistics = signal.statistics {
        CANStatisticsGrid(statistics: statistics, unit: canUnitsLabel(signal.unit))
      }
      HStack {
        CANUnitsBadge(text: "UNVERIFIED UNIT", color: .blue)
        Spacer()
        Text("\(signal.lineage.sampleCount) samples")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .padding()
    .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
  }
}

private struct CANStatisticsGrid: View {
  let statistics: CANDescriptiveStatistics
  let unit: String

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
      GridRow {
        CANStat(label: "MIN", value: canUnitsNumber(statistics.minimum), unit: unit)
        CANStat(label: "MAX", value: canUnitsNumber(statistics.maximum), unit: unit)
        CANStat(label: "MEAN", value: canUnitsNumber(statistics.mean), unit: unit)
      }
      GridRow {
        CANStat(label: "σ", value: canUnitsNumber(statistics.populationStandardDeviation), unit: unit)
        CANStat(label: "P–P", value: canUnitsNumber(statistics.peakToPeak), unit: unit)
        CANStat(label: "CV", value: coefficientText, unit: coefficientUnit)
      }
    }
  }

  private var coefficientText: String {
    statistics.coefficientOfVariation.map { canUnitsNumber($0 * 100) } ?? "Unavailable"
  }

  private var coefficientUnit: String {
    statistics.coefficientOfVariation == nil ? "" : "%"
  }
}

private struct CANStat: View {
  let label: String
  let value: String
  let unit: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).font(.caption2.bold()).foregroundStyle(.secondary)
      Text(value).font(.caption.weight(.semibold).monospacedDigit())
      Text(unit).font(.caption2).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct CANRawCard: View {
  let signal: CANUnitsSignal

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 3) {
          Text(signal.name).font(.headline)
          Text(signal.source).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        Spacer()
        Text("\(canUnitsNumber(rawValue, digits: 3)) raw")
          .font(.title3.bold().monospacedDigit())
      }
      Text("Physical meaning or scale is unavailable. Exact raw evidence remains usable for labels and replay.")
        .font(.footnote)
        .foregroundStyle(.secondary)
      HStack {
        CANUnitsBadge(text: "RAW ONLY", color: .orange)
        Spacer()
        Text("\(signal.lineage.sampleCount) samples")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .padding()
    .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
  }

  private var rawValue: Double { signal.latestRawValue ?? signal.latestValue }
}

private struct CANSignalDetail: View {
  let signal: CANUnitsSignal

  var body: some View {
    List {
      Section("Authority") {
        CANUnitsBadge(
          text: signal.authority.exposesEngineeringUnit ? "UNVERIFIED UNIT" : "RAW ONLY",
          color: signal.authority.exposesEngineeringUnit ? .blue : .orange)
        Text(authorityText).font(.footnote)
      }
      Section("Latest retained input") {
        LabeledContent("Value", value: displayValue)
        if let raw = signal.latestRawValue {
          LabeledContent("Raw input", value: "\(canUnitsNumber(raw, digits: 3)) counts")
        }
        LabeledContent("Observed", value: signal.latestObservedAt)
        LabeledContent("Evidence reference", value: signal.latestEvidenceReference)
      }
      if let statistics = signal.statistics {
        Section("Derived statistics") {
          CANStatisticsGrid(statistics: statistics, unit: displayUnit)
          Text("Calculated across the complete retained projection before chart downsampling.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      lineage
      if let gate = signal.validationGate {
        Section("Required next evidence") { Text(gate) }
      }
    }
    .navigationTitle(signal.name)
    .navigationBarTitleDisplayMode(.inline)
  }

  private var authorityText: String {
    signal.authority.exposesEngineeringUnit
      ? "The formula is pinned, but scale and meaning await independent validation on this vehicle."
      : "The raw projection is repeatable, but no defensible target-vehicle physical unit is available."
  }

  private var displayUnit: String {
    signal.authority.exposesEngineeringUnit ? canUnitsLabel(signal.unit) : "raw count"
  }

  private var displayValue: String {
    let value = signal.authority.exposesEngineeringUnit
      ? signal.latestValue : signal.latestRawValue ?? signal.latestValue
    return "\(canUnitsNumber(value, digits: 3)) \(displayUnit)"
  }

  private var lineage: some View {
    Section("Lineage") {
      LabeledContent("Canonical signal", value: signal.signalID)
      LabeledContent("Definition status", value: signal.definitionStatus)
      LabeledContent("Formula ID", value: signal.lineage.formulaID)
      Text(signal.lineage.formulaText).font(.body.monospaced())
      LabeledContent("Formula SHA-256", value: signal.lineage.formulaSHA256)
      LabeledContent("Evidence SHA-256", value: signal.lineage.evidenceSHA256)
      LabeledContent("Samples", value: signal.lineage.sampleCount.formatted())
      LabeledContent("Sessions", value: signal.lineage.sessionCount.formatted())
      Text(signal.lineage.evidenceSelection).font(.footnote).foregroundStyle(.secondary)
    }
  }
}

private struct CANRelationshipSummary: View {
  let relationship: CANRotationalRelationship

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 3) {
          Text(relationship.name).font(.headline)
          Text("Same-gateway, same-session pairing").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 3) {
          Text(canUnitsNumber(relationship.candidateUnitRatio.mean, digits: 4))
            .font(.title3.bold().monospacedDigit())
          Text("MEAN RATIO").font(.caption2).foregroundStyle(.secondary)
        }
      }
      HStack(spacing: 16) {
        Label("\(relationship.pairCount) pairs", systemImage: "point.3.connected.trianglepath.dotted")
        Label("\(relationship.sessionCount) sessions", systemImage: "square.stack.3d.up")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      CANUnitsBadge(text: "UNVERIFIED DERIVED", color: .orange)
    }
    .padding()
    .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
  }
}

private struct CANRelationshipDetail: View {
  let relationship: CANRotationalRelationship

  var body: some View {
    List {
      Section("Authority") {
        CANUnitsBadge(text: "UNVERIFIED DERIVED", color: .orange)
        Text(
          "This is a descriptive relationship between two unverified projections. It does not establish gear, converter slip, or driveline health."
        )
        .font(.footnote)
      }
      Section("Aggregate") {
        LabeledContent(
          "Mean ratio", value: canUnitsNumber(relationship.candidateUnitRatio.mean, digits: 5))
        LabeledContent(
          "Range",
          value:
            "\(canUnitsNumber(relationship.candidateUnitRatio.minimum, digits: 5))…\(canUnitsNumber(relationship.candidateUnitRatio.maximum, digits: 5))")
        LabeledContent(
          "Population σ",
          value: canUnitsNumber(
            relationship.candidateUnitRatio.populationStandardDeviation, digits: 5))
        LabeledContent("Accepted pairs", value: relationship.pairCount.formatted())
        LabeledContent("Accepted sessions", value: relationship.sessionCount.formatted())
      }
      pairing
      sessions
      Section("Lineage") {
        LabeledContent("Formula", value: relationship.lineage.formulaID)
        Text(relationship.lineage.formulaText).font(.body.monospaced())
        LabeledContent("Formula SHA-256", value: relationship.lineage.formulaSHA256)
        LabeledContent("Evidence SHA-256", value: relationship.lineage.evidenceSHA256)
      }
    }
    .navigationTitle("Rotational Relationship")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var pairing: some View {
    Section("Pairing rule") {
      Text(relationship.pairingRule).font(.footnote)
      LabeledContent("Maximum skew", value: "\(relationship.maximumPairSkewMicroseconds) µs")
      LabeledContent(
        "Minimum pairs / session", value: relationship.minimumPairsPerSession.formatted())
      Text("No cross-session interpolation is allowed.")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.orange)
    }
  }

  private var sessions: some View {
    Section("Per-session results") {
      ForEach(relationship.sessions) { session in
        CANRelationshipSessionRow(session: session)
      }
    }
  }
}

private struct CANRelationshipSessionRow: View {
  let session: CANRotationalSessionAnalysis

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("Session \(session.sessionID)").font(.headline)
      Text(session.gatewayID).font(.caption.monospaced()).foregroundStyle(.secondary)
      LabeledContent("Pairs", value: session.pairCount.formatted())
      LabeledContent(
        "Mean ratio", value: canUnitsNumber(session.candidateUnitRatio.mean, digits: 5))
      LabeledContent(
        "Pearson r",
        value: session.pearsonCorrelation.map { canUnitsNumber($0, digits: 5) }
          ?? "Unavailable")
      LabeledContent(
        "Maximum skew", value: "\(session.maximumObservedPairSkewMicroseconds) µs")
    }
    .padding(.vertical, 4)
  }
}

private struct CANReportLineage: View {
  let report: CANUnitsReport

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      LabeledContent("Retained observations", value: report.observationCount.formatted())
      LabeledContent("Capture sessions", value: report.sessionCount.formatted())
      LabeledContent("Unit/raw fields", value: report.signals.count.formatted())
      LabeledContent("Relationships", value: report.relationships.count.formatted())
      Divider()
      LabeledContent("Definition catalog", value: report.catalogID)
      LabeledContent("Catalog version", value: report.catalogVersion)
      hashLabel("Evidence SHA-256", value: report.evidenceSHA256)
      hashLabel("Catalog SHA-256", value: report.catalogSHA256)
      Text("Statistics use the complete retained projection; graph downsampling cannot alter them.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .padding()
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
  }

  private func hashLabel(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.caption.monospaced()).textSelection(.enabled)
    }
  }
}
