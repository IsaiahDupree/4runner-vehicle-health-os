import SwiftUI
import VHOSCore

struct DiscoveryView: View {
  @Environment(AppModel.self) private var model

  private var engineeringUnlocked: Bool {
    model.gateway.hasCurrentParkedAuthority
  }

  private var recentIdentifierCount: Int {
    Set(model.gateway.recentCANObservations.map(\.identifier)).count
  }

  private var standardSignalCount: Int {
    Set(
      model.gateway.standardOBDSamples.filter(model.gateway.isCurrentStandardOBDSample).map(
        \.signalID)
    )
    .count
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        DiscoveryAuthorityBanner()
        DiscoveryEngineeringGateBanner(
          motion: model.gateway.health?.vehicleMotion ?? .unknown,
          currentParkedAuthority: model.gateway.hasCurrentParkedAuthority)

        VStack(alignment: .leading, spacing: 0) {
          DiscoveryMetricRow(
            label: "Gateway",
            value: model.gateway.state == .vhosConnected ? "Connected" : "Not connected",
            state: model.gateway.state == .vhosConnected ? .observed : .unavailable)
          DiscoveryMetricRow(
            label: "Vehicle bus",
            value: vehicleBusDescription,
            state: vehicleBusObserved ? .observed : .unavailable)
          DiscoveryMetricRow(
            label: "OBD ECUs",
            value: obdECUDescription,
            state: currentOBDAvailability.isEmpty ? .unavailable : .observed)
          DiscoveryMetricRow(
            label: "Bus frames",
            value: vehicleBusObserved
              ? model.gateway.health?.receivedFrames.formatted() ?? "Unavailable"
              : "Unavailable",
            state: vehicleBusObserved ? .observed : .unavailable,
            detail: "Gateway cumulative counter")
          DiscoveryMetricRow(
            label: "Visible CAN IDs",
            value: vehicleBusObserved && recentIdentifierCount > 0
              ? recentIdentifierCount.formatted() : "Unavailable",
            state: vehicleBusObserved && recentIdentifierCount > 0 ? .observed : .unavailable,
            detail: vehicleBusObserved && recentIdentifierCount > 0
              ? "Recent in-memory window" : nil)
          DiscoveryMetricRow(
            label: "Standard OBD signals",
            value: standardSignalCount > 0 ? standardSignalCount.formatted() : "Unavailable",
            state: standardSignalCount > 0 ? .observed : .unavailable)
          DiscoveryMetricRow(
            label: "Experimental candidates",
            value: model.canResearchReport.map { $0.series.count.formatted() } ?? "Unavailable",
            state: model.canResearchReport == nil ? .unavailable : .experimental)
          DiscoveryMetricRow(
            label: "Vehicle validated",
            value: "Unavailable",
            state: .unavailable,
            detail: "No validation registry is installed")
          DiscoveryMetricRow(
            label: "Current capture",
            value: captureDescription,
            state: model.gateway.hasCurrentGatewayHealth
              && model.gateway.health?.captureActive == true
              ? .observed : .unavailable)
          DiscoveryMetricRow(
            label: "Gateway storage",
            value: storageDescription,
            state: model.gateway.captureLogIndex?.freeBytes == nil ? .unavailable : .observed,
            showDivider: false)
        }
        .padding(.horizontal)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20))

        VStack(spacing: 12) {
          NavigationLink {
            DiscoveryTestLibraryView()
          } label: {
            DiscoveryActionLabel(
              title: "Run a Test",
              subtitle: "Choose a controlled procedure and record ground-truth events",
              systemImage: "checklist")
          }
          .buttonStyle(.plain)

          NavigationLink {
            BoundedProtocolExperimentView()
          } label: {
            DiscoveryActionLabel(
              title: "Scan Vehicle",
              subtitle: "Run an owner-approved passive or allowlisted protocol plan",
              systemImage: "dot.radiowaves.left.and.right")
          }
          .buttonStyle(.plain)
          .disabled(!engineeringUnlocked)
          .opacity(engineeringUnlocked ? 1 : 0.55)

          NavigationLink {
            DiscoverySignalExplorerView()
          } label: {
            DiscoveryActionLabel(
              title: "Explore Signals",
              subtitle: "Review actual standard OBD samples and retained candidates",
              systemImage: "waveform.path.ecg")
          }
          .buttonStyle(.plain)

          NavigationLink {
            DiscoveryCaptureReviewView()
          } label: {
            DiscoveryActionLabel(
              title: "Captures & Replay",
              subtitle: "Inspect stored sessions and replay retained CAN evidence",
              systemImage: "play.rectangle.on.rectangle")
          }
          .buttonStyle(.plain)

          NavigationLink {
            DiscoveryCandidateInboxView()
          } label: {
            DiscoveryActionLabel(
              title: "Candidate Inbox",
              subtitle: "Review hypotheses without granting them vehicle authority",
              systemImage: "tray.full")
          }
          .buttonStyle(.plain)

          NavigationLink {
            DiscoveryProgressView()
          } label: {
            DiscoveryActionLabel(
              title: "Discovery Progress",
              subtitle: "See what is observed and what remains unknown",
              systemImage: "chart.bar.doc.horizontal")
          }
          .buttonStyle(.plain)
        }
      }
      .padding()
    }
    .navigationTitle("Discovery")
    .refreshable {
      model.gateway.refreshCaptureLogIndex()
      model.refreshCANResearch()
    }
  }

  private var vehicleBusObserved: Bool {
    guard model.gateway.state == .vhosConnected, let health = model.gateway.health,
      let receivedAt = model.gateway.lastHealthReceivedAt
    else { return false }
    let age = Date().timeIntervalSince(receivedAt)
    guard age >= 0, age <= 5 else { return false }
    return health.receivedFrames > 0 || health.canPassiveLock == true
  }

  private var vehicleBusDescription: String {
    guard vehicleBusObserved, let health = model.gateway.health else { return "Unavailable" }
    if let bitrate = health.canBitrateBps, health.canPassiveLock == true {
      return "CAN observed · \(bitrate / 1_000) kbit/s"
    }
    if health.receivedFrames > 0 { return "Traffic observed" }
    return "Not observed"
  }

  private var obdECUDescription: String {
    let values = currentOBDAvailability
    guard !values.isEmpty else { return "Unavailable" }
    let complete = values.filter(\.enumerationComplete).count
    return complete == values.count
      ? "\(values.count) · PID scan complete" : "\(values.count) · scan incomplete"
  }

  private var captureDescription: String {
    if model.gateway.hasCurrentGatewayHealth, model.gateway.health?.captureActive == true {
      return "Recording"
    }
    if model.gateway.captureHistoryTransferActive { return "Synchronizing history" }
    return model.gateway.hasCurrentGatewayHealth ? "Not recording" : "Unavailable"
  }

  private var currentOBDAvailability: [J1979ECUAvailability] {
    model.gateway.hasCurrentGatewayHealth ? model.gateway.j1979Availability : []
  }

  private var storageDescription: String {
    guard let free = model.gateway.captureLogIndex?.freeBytes else { return "Unavailable" }
    return ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .file) + " free"
  }
}

private struct DiscoveryEngineeringGateBanner: View {
  let motion: VehicleMotion
  let currentParkedAuthority: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(
        systemName: currentParkedAuthority ? "checkmark.shield.fill" : "lock.shield.fill"
      )
      .foregroundStyle(currentParkedAuthority ? .green : .orange)
      VStack(alignment: .leading, spacing: 4) {
        Text(currentParkedAuthority ? "Engineering controls available" : "Parked state required")
          .font(.headline)
        Text(
          currentParkedAuthority
            ? "Fresh gateway health deterministically reports PARKED."
            : "Latest motion is \(motion.rawValue), but no fresh verified PARKED authority is active. Parked-only and raw engineering controls stay locked. Use Run a Test → Park / Selector Bootstrap to gather passive selector evidence; stored review and replay remain available."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
    .background(
      (currentParkedAuthority ? Color.green : Color.orange).opacity(0.09),
      in: RoundedRectangle(cornerRadius: 16))
  }
}

private struct DiscoveryAuthorityBanner: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("ENGINEERING MODE", systemImage: "wrench.and.screwdriver.fill")
        .font(.caption.weight(.bold))
        .foregroundStyle(.blue)
      Text(
        "Unknown bytes become candidates here. Only independently corroborated evidence may become Vehicle Validated or Promoted."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
    .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
  }
}

private enum DiscoveryAuthorityState {
  case observed
  case experimental
  case validated
  case promoted
  case unavailable

  var label: String {
    switch self {
    case .observed: "OBSERVED"
    case .experimental: "EXPERIMENTAL CANDIDATE"
    case .validated: "VEHICLE VALIDATED"
    case .promoted: "PROMOTED"
    case .unavailable: "UNAVAILABLE"
    }
  }

  var color: Color {
    switch self {
    case .observed: .green
    case .experimental: .orange
    case .validated: .blue
    case .promoted: .purple
    case .unavailable: .secondary
    }
  }
}

private struct DiscoveryMetricRow: View {
  let label: String
  let value: String
  let state: DiscoveryAuthorityState
  var detail: String? = nil
  var showDivider = true

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(label).font(.body.weight(.medium))
          if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 3) {
          Text(value).font(.body.monospacedDigit())
          Text(state.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(state.color)
        }
      }
      .padding(.vertical, 12)
      if showDivider { Divider() }
    }
  }
}

private struct DiscoveryActionLabel: View {
  let title: String
  let subtitle: String
  let systemImage: String

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: systemImage)
        .font(.title2)
        .foregroundStyle(.blue)
        .frame(width: 42, height: 42)
        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.headline)
        Text(subtitle).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Image(systemName: "chevron.right").foregroundStyle(.tertiary)
    }
    .padding()
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
  }
}

private struct DiscoveryMarkerAction: Identifiable, Sendable {
  let id: String
  let label: String
  let kind: DiscoveryMarkerKind
}

private struct DiscoveryTemplatePresentation: Identifiable, Sendable {
  let template: TestTemplate
  let markerActions: [DiscoveryMarkerAction]
  let iPhoneInteractiveSupported: Bool

  var id: String { template.id }
  var title: String { template.title }
  var category: String { template.category.displayName }
  var summary: String { template.hypothesis }
  var safety: String { template.safetyInstructions.joined(separator: " ") }

  static func library() throws -> [DiscoveryTemplatePresentation] {
    try [
      parkSelectorBootstrap(),
      make(
        id: "discovery.electrical.ignition-cycle", title: "Ignition Cycle",
        category: .electrical,
        hypothesis: "Label OFF, accessory, ignition-on, crank, and running transitions.",
        safety: "Vehicle parked; transmission in Park.",
        actions: [
          ("OFF", .ignitionOff), ("ACCESSORY", .custom), ("IGNITION ON", .ignitionOn),
          ("CRANK", .custom), ("RUNNING", .engineStarted),
        ]),
      make(
        id: "discovery.engine.cold-start", title: "Cold Start", category: .engine,
        hypothesis: "Capture engine start, warm-up, voltage, RPM, and temperature transitions.",
        safety: "Use outdoors or with appropriate exhaust extraction.",
        actions: [
          ("BEFORE START", .ignitionOn), ("ENGINE STARTED", .engineStarted),
          ("IDLE STABLE", .custom),
        ]),
      make(
        id: "discovery.engine.rpm-sweep", title: "RPM Sweep", category: .engine,
        hypothesis: "Record separated, steady engine-speed levels for candidate comparison.",
        safety: "Vehicle parked; never exceed an owner-selected safe engine-speed limit.",
        actions: [
          ("IDLE", .acceleratorChanged), ("LEVEL 1", .acceleratorChanged),
          ("LEVEL 2", .acceleratorChanged), ("RELEASED", .acceleratorChanged),
        ]),
      make(
        id: "discovery.brakes.pulse", title: "Brake Pulse", category: .brakes,
        hypothesis:
          "Repeat released and pressed pedal states to label Boolean or analog candidates.",
        safety: "Vehicle parked for the initial validation run.",
        actions: [("BRAKE RELEASED", .brakeReleased), ("BRAKE PRESSED", .brakePressed)]),
      make(
        id: "discovery.steering.sweep", title: "Steering Sweep", category: .steering,
        hypothesis: "Label center, left, and right wheel positions with repeatable holds.",
        safety: "Vehicle stationary; keep hands and tools clear of moving parts.",
        actions: [
          ("CENTER", .steeringChanged), ("LEFT", .steeringChanged),
          ("RIGHT", .steeringChanged),
        ]),
      make(
        id: "discovery.engine.accelerator-sweep", title: "Accelerator Sweep",
        category: .engine,
        hypothesis: "Label released and separated pedal levels for accelerator candidates.",
        safety: "Vehicle parked; use only an explicitly approved bounded procedure.",
        actions: [
          ("RELEASED", .acceleratorChanged), ("LEVEL 1", .acceleratorChanged),
          ("LEVEL 2", .acceleratorChanged),
        ]),
      make(
        id: "discovery.hvac.ac-on-off", title: "A/C ON / OFF", category: .hvac,
        hypothesis: "Label commanded HVAC states and independent physical observations.",
        safety: "Do not open refrigerant service fittings from this workflow.",
        actions: [
          ("A/C OFF", .acOff), ("A/C ON", .acOn),
          ("COMPRESSOR OBSERVED", .compressorObservedOn),
        ]),
      make(
        id: "discovery.hvac.fan-speed", title: "Fan-Speed Sweep", category: .hvac,
        hypothesis: "Label each stable blower setting to separate command and feedback fields.",
        safety: "Vehicle parked.",
        actions: [
          ("FAN OFF", .custom), ("FAN LOW", .custom), ("FAN MEDIUM", .custom),
          ("FAN HIGH", .custom),
        ]),
      make(
        id: "discovery.four-wheel-drive.transition", title: "4WD Transition",
        category: .fourWheelDrive,
        hypothesis: "Label owner-commanded transfer-case states for later candidate review.",
        safety: "Follow the Toyota owner procedure; this app never commands the transfer case.",
        actions: [
          ("2WD", .custom), ("4WD REQUESTED", .custom), ("4WD INDICATED", .custom),
        ]),
      make(
        id: "discovery.electrical.load", title: "Electrical Load", category: .electrical,
        hypothesis:
          "Label stable accessory loads while observing voltage and alternator-related fields.",
        safety: "Vehicle parked; do not bypass protected vehicle circuits.",
        actions: [("BASELINE", .custom), ("LOAD ON", .custom), ("LOAD OFF", .custom)]),
      make(
        id: "discovery.tires.wheel-rotation", title: "Wheel Rotation", category: .tires,
        hypothesis: "Label individual wheel motion to distinguish wheel-speed candidates.",
        safety:
          "Vehicle parked and professionally supported before any wheel is raised; never work beneath an unsupported vehicle.",
        actions: [
          ("WHEEL STILL", .custom), ("FRONT LEFT ROTATING", .custom),
          ("FRONT RIGHT ROTATING", .custom), ("REAR LEFT ROTATING", .custom),
          ("REAR RIGHT ROTATING", .custom),
        ]),
      make(
        id: "discovery.hvac.temperature-sweep", title: "HVAC Temperature Sweep",
        category: .hvac,
        hypothesis: "Label stable temperature selections to separate HVAC state candidates.",
        safety: "Vehicle parked; allow each requested setting to stabilize before marking.",
        actions: [
          ("TEMPERATURE LOW", .custom), ("TEMPERATURE MID", .custom),
          ("TEMPERATURE HIGH", .custom),
        ]),
      make(
        id: "discovery.suspension.settle", title: "Suspension Settle",
        category: .suspension,
        hypothesis: "Label an undisturbed settle interval for height or compressor candidates.",
        safety:
          "Vehicle parked on level ground; keep people and tools clear of suspension movement.",
        actions: [
          ("SETTLE START", .custom), ("HEIGHT OBSERVED", .measurementTaken),
          ("SETTLE COMPLETE", .custom),
        ]),
      make(
        id: "discovery.tires.pressure-change", title: "Tire Pressure Change",
        category: .tires,
        hypothesis: "Align instrument pressure measurements with retained TPMS-related evidence.",
        safety:
          "Vehicle parked; remain within the tire and vehicle manufacturer's safe pressure range.",
        actions: [
          ("PRESSURE MEASURED", .measurementTaken), ("PRESSURE CHANGED", .custom),
          ("PRESSURE RECHECKED", .measurementTaken),
        ]),
      make(
        id: "discovery.transmission.controlled-road-test", title: "Controlled Road Test",
        category: .transmission,
        hypothesis: "Label speed, hold, shift, coast, and stop phases for driveline candidates.",
        safety:
          "Passenger supervision on a controlled route is required; the driver must never interact with this screen.",
        requiredMotion: .moving,
        iPhoneInteractiveSupported: false,
        actions: [
          ("ACCELERATE", .custom), ("HOLD SPEED", .custom), ("SHIFT OBSERVED", .custom),
          ("COAST", .custom), ("STOPPED", .custom),
        ]),
    ]
  }

  private static func parkSelectorBootstrap() throws -> DiscoveryTemplatePresentation {
    let template = try DiscoveryMutationPolicy.parkSelectorBootstrapTemplate()
    let actions: [(String, DiscoveryMarkerKind)] = [
      ("SAFETY SETUP CONFIRMED", .custom),
      ("SELECTOR: PARK", .selectorPark),
      ("SELECTOR: REVERSE", .selectorReverse),
      ("SELECTOR: NEUTRAL", .selectorNeutral),
      ("SELECTOR: DRIVE", .selectorDrive),
      ("SELECTOR: PARK (RETURN)", .selectorPark),
    ]
    return DiscoveryTemplatePresentation(
      template: template,
      markerActions: actions.enumerated().map { index, action in
        DiscoveryMarkerAction(
          id: "\(template.id).marker.\(index + 1)", label: action.0, kind: action.1)
      },
      iPhoneInteractiveSupported: true)
  }

  private static func make(
    id: String,
    title: String,
    category: DiscoveryTestCategory,
    hypothesis: String,
    safety: String,
    requiredMotion: VehicleMotion = .parked,
    iPhoneInteractiveSupported: Bool = true,
    actions: [(String, DiscoveryMarkerKind)]
  ) throws -> DiscoveryTemplatePresentation {
    let markerActions = actions.enumerated().map { index, action in
      DiscoveryMarkerAction(id: "\(id).marker.\(index + 1)", label: action.0, kind: action.1)
    }
    let steps = try markerActions.enumerated().map { index, action in
      try TestStep(
        id: "\(id).step.\(index + 1)",
        sequence: index + 1,
        instruction: "At the physical transition, mark \(action.label).",
        expectedMarkerKind: action.kind)
    }
    let template = try TestTemplate(
      id: id,
      templateVersion: "1.0.0",
      title: title,
      category: category,
      hypothesis: hypothesis,
      requiredVehicleMotion: requiredMotion,
      safetyInstructions: [safety],
      requiredGatewayCapabilities: [.passiveCapture],
      targetedValidationRequirements: [.targetVehicleCapture, .goldenReplay],
      steps: steps)
    return DiscoveryTemplatePresentation(
      template: template,
      markerActions: markerActions,
      iPhoneInteractiveSupported: iPhoneInteractiveSupported)
  }
}

extension DiscoveryTestCategory {
  fileprivate var displayName: String {
    switch self {
    case .engine: "Engine"
    case .brakes: "Brakes"
    case .steering: "Steering"
    case .transmission: "Transmission"
    case .hvac: "HVAC / A/C"
    case .suspension: "Suspension"
    case .tires: "Tires"
    case .electrical: "Electrical"
    case .fourWheelDrive: "4WD"
    case .lighting: "Lighting"
    case .custom: "Custom"
    }
  }
}

private struct DiscoveryTestLibraryView: View {
  private let loadResult = Result { try DiscoveryTemplatePresentation.library() }

  var body: some View {
    List {
      Section {
        Text(
          "Templates define a repeatable procedure and ground-truth labels. They do not assert that any CAN field has a specific meaning."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
      switch loadResult {
      case .success(let templates):
        let groups = Dictionary(grouping: templates, by: \.category)
        ForEach(groups.keys.sorted(), id: \.self) { category in
          Section(category) {
            ForEach(groups[category] ?? []) { template in
              NavigationLink {
                DiscoveryTestRunnerView(template: template)
              } label: {
                VStack(alignment: .leading, spacing: 4) {
                  Text(template.title).font(.headline)
                  Text(template.summary).font(.caption).foregroundStyle(.secondary)
                  if !template.iPhoneInteractiveSupported {
                    Text("PASSENGER-SUPERVISED WORKFLOW REQUIRED")
                      .font(.caption2.weight(.bold))
                      .foregroundStyle(.orange)
                  }
                }
                .padding(.vertical, 4)
              }
              .disabled(!template.iPhoneInteractiveSupported)
            }
          }
        }
      case .failure(let error):
        ContentUnavailableView(
          "Test library unavailable",
          systemImage: "exclamationmark.shield",
          description: Text(
            "The versioned template catalog failed validation: \(error.localizedDescription)"))
      }
    }
    .navigationTitle("Test Library")
  }
}

private struct DiscoveryTestRunnerView: View {
  @Environment(AppModel.self) private var model
  let template: DiscoveryTemplatePresentation

  private var activeRun: DiscoveryTestRunDraft? {
    model.activeDiscoveryTestRun
  }

  private var runMatchesTemplate: Bool {
    guard let activeRun else { return false }
    return DiscoveryMutationPolicy.testRunIdentityMatches(
      template: template.template,
      templateID: activeRun.templateID,
      templateVersion: activeRun.templateVersion)
  }

  private var activeRunMatchesGatewayCapture: Bool {
    guard let activeRun, let observation = model.gateway.latestCANObservation else { return false }
    return activeRun.gatewayID == observation.gatewayID
      && activeRun.gatewaySessionID == observation.sessionID
  }

  private var evidenceReady: Bool {
    model.discoveryMutationAuthority(for: template.template) != nil
      && template.iPhoneInteractiveSupported
  }

  private var isParkSelectorBootstrap: Bool {
    template.id == DiscoveryMutationPolicy.parkSelectorBootstrapTemplateID
  }

  private var markerReady: Bool {
    evidenceReady && runMatchesTemplate && activeRunMatchesGatewayCapture
  }

  private var recordedBootstrapMarkers: [DiscoveryOrderedMarkerRequirement] {
    guard isParkSelectorBootstrap, let activeRun else { return [] }
    return model.discoveryMarkers.filter { $0.testRunID == activeRun.id }.map {
      DiscoveryOrderedMarkerRequirement(kind: $0.marker.kind, label: $0.label)
    }
  }

  private var nextBootstrapMarker: DiscoveryOrderedMarkerRequirement? {
    DiscoveryMutationPolicy.nextParkSelectorBootstrapMarker(after: recordedBootstrapMarkers)
  }

  private var bootstrapComplete: Bool {
    DiscoveryMutationPolicy.parkSelectorBootstrapIsComplete(recordedBootstrapMarkers)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 8) {
          Text(template.category.uppercased())
            .font(.caption.weight(.bold))
            .foregroundStyle(.blue)
          Text(template.title).font(.largeTitle.bold())
          Text(template.summary).foregroundStyle(.secondary)
        }

        Label(template.safety, systemImage: "exclamationmark.shield.fill")
          .font(.footnote)
          .foregroundStyle(.orange)
          .padding()
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))

        if isParkSelectorBootstrap {
          Label(
            "Evidence only: this workflow does not create or upgrade Park authority. It cannot unlock OTA, diagnostic transmission, or other parked-only controls.",
            systemImage: "lock.shield.fill"
          )
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.blue)
          .padding()
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        }

        VStack(alignment: .leading, spacing: 10) {
          Text("Evidence readiness").font(.headline)
          SafetyRow(label: "VHOS gateway contract", pass: model.gateway.state == .vhosConnected)
          SafetyRow(
            label: "Passive recorder active", pass: model.gateway.health?.captureActive == true)
          if isParkSelectorBootstrap {
            if model.gateway.hasCurrentParkedAuthority {
              SafetyRow(label: "Current deterministic PARKED authority", pass: true)
            } else {
              SafetyRow(
                label: "Gateway motion honestly remains UNKNOWN",
                pass: model.gateway.hasCurrentGatewayHealth
                  && model.gateway.health?.vehicleMotion == .unknown)
            }
          } else {
            SafetyRow(
              label: "Motion deterministically PARKED",
              pass: model.gateway.hasCurrentParkedAuthority)
          }
          SafetyRow(
            label: "Fresh verified listen-only CAN timeline",
            pass: model.discoveryTimelineCurrent)
          SafetyRow(
            label: "Required gateway capabilities",
            pass: template.template.requiredGatewayCapabilities.allSatisfy {
              model.gateway.handshake?.capabilities.contains($0) == true
            })
          if let observation = model.gateway.latestCANObservation {
            Text(
              "Markers will bind to gateway session \(observation.sessionID), sequence \(observation.sourceSequence), and monotonic time \(observation.monotonicMicroseconds) µs."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))

        VStack(alignment: .leading, spacing: 12) {
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text("Test run draft").font(.headline)
              Text(
                "This stays a draft until retained archive and manifest hashes can finalize a canonical CaptureSession."
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
            Spacer()
            Text(runMatchesTemplate ? "ACTIVE" : "NOT STARTED")
              .font(.caption.weight(.bold))
              .foregroundStyle(runMatchesTemplate ? .green : .secondary)
          }

          if let activeRun, !runMatchesTemplate {
            VStack(alignment: .leading, spacing: 8) {
              Text(
                "Another or incompatible test run draft is active (\(activeRun.templateID) v\(activeRun.templateVersion)). Abort it before beginning this procedure. Its existing append-only evidence will be retained."
              )
              .font(.footnote)
              .foregroundStyle(.orange)
              Button("Abort incompatible run") { model.abortDiscoveryTestRun() }
                .buttonStyle(.bordered)
                .tint(.red)
            }
          }

          if runMatchesTemplate, !activeRunMatchesGatewayCapture {
            Text(
              "The gateway recorder session changed. Abort this draft and begin a new run; markers cannot cross capture lineage."
            )
            .font(.footnote)
            .foregroundStyle(.orange)
          }

          if runMatchesTemplate {
            HStack {
              Button("End Session") { model.endDiscoveryTestRun() }
                .buttonStyle(.borderedProminent)
                .disabled(
                  !evidenceReady || !activeRunMatchesGatewayCapture
                    || (isParkSelectorBootstrap && !bootstrapComplete))
              Button("Abort") { model.abortDiscoveryTestRun() }
                .buttonStyle(.bordered)
                .tint(.red)
            }
          } else {
            Button("Begin Session") {
              model.beginDiscoveryTestRun(template: template.template)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!evidenceReady || activeRun != nil)
          }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))

        VStack(alignment: .leading, spacing: 12) {
          Text("Mark what happened").font(.title2.bold())
          Text(
            "Tap at the physical transition. Each marker is append-only and uses the latest gateway evidence timestamp."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)

          ForEach(template.markerActions) { action in
            Button {
              model.recordDiscoveryMarker(
                template: template.template,
                kind: action.kind,
                label: action.label)
            } label: {
              Text(action.label)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 58)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
              !markerReady
                || (isParkSelectorBootstrap
                  && nextBootstrapMarker
                    != DiscoveryOrderedMarkerRequirement(kind: action.kind, label: action.label)))
          }

          if !isParkSelectorBootstrap {
            Button {
              model.recordDiscoveryMarker(
                template: template.template,
                kind: .custom,
                label: "EVENT")
            } label: {
              Label("MARK EVENT", systemImage: "bookmark.fill")
                .font(.title3.bold())
                .frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .disabled(!markerReady)
          }
        }

        DiscoveryMarkerLedgerView(templateID: template.id, testRunID: activeRun?.id)

        NavigationLink("Open bounded gateway experiment controls") {
          BoundedProtocolExperimentView()
        }
        .buttonStyle(.bordered)
      }
      .padding()
    }
    .navigationTitle("Run Test")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct DiscoveryMarkerLedgerView: View {
  @Environment(AppModel.self) private var model
  let templateID: String
  let testRunID: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Markers retained on this iPhone").font(.headline)
      let markers = model.discoveryMarkers.filter {
        $0.templateID == templateID && (testRunID == nil || $0.testRunID == testRunID)
      }.suffix(12)
      if markers.isEmpty {
        Text("No synchronized markers have been recorded for this test.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      } else {
        ForEach(Array(markers.reversed())) { marker in
          HStack(alignment: .top) {
            Image(systemName: "bookmark.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
              Text(marker.label).font(.subheadline.weight(.semibold))
              Text(
                "Gateway session \(marker.captureSessionID) · sequence \(marker.sourceSequence)"
              )
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
              Text(marker.marker.kind.rawValue)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            }
            Spacer()
          }
        }
      }
    }
    .padding()
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
  }
}

private struct DiscoverySignalExplorerView: View {
  @Environment(AppModel.self) private var model
  @State private var filter = SignalFilter.all

  private enum SignalFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case observed = "Observed"
    case candidates = "Candidates"
    var id: String { rawValue }
  }

  private var latestStandardSamples: [J1979StandardSample] {
    Dictionary(
      grouping: model.gateway.standardOBDSamples.filter(model.gateway.isCurrentStandardOBDSample),
      by: \.signalID
    ).values.compactMap {
      $0.max { $0.gatewayMonotonicMicroseconds < $1.gatewayMonotonicMicroseconds }
    }.sorted { $0.name < $1.name }
  }

  var body: some View {
    List {
      Section {
        Picker("Authority", selection: $filter) {
          ForEach(SignalFilter.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
      }

      if filter != .candidates {
        Section("Observed · Standard OBD") {
          if latestStandardSamples.isEmpty {
            Text("No validated SAE J1979 samples are available in this connection.")
              .foregroundStyle(.secondary)
          } else {
            ForEach(latestStandardSamples) { sample in
              VStack(alignment: .leading, spacing: 5) {
                HStack {
                  Text(sample.name).font(.headline)
                  Spacer()
                  Text(
                    sample.value.formatted(.number.precision(.fractionLength(0...2))) + " "
                      + sample.unit
                  )
                  .monospacedDigit()
                }
                HStack {
                  Text(sample.signalID).font(.caption.monospaced())
                  Spacer()
                  Text("OBSERVED").font(.caption2.weight(.bold)).foregroundStyle(.green)
                }
                Text(
                  "ECU \(sample.ecuAddress) · PID 0x\(String(format: "%02X", sample.pid)) · source sequence \(sample.sourceSequence)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
              }
              .padding(.vertical, 4)
            }
          }
        }
      }

      if filter != .observed {
        Section("Experimental Candidates · Retained Evidence") {
          if let report = model.canResearchReport, !report.series.isEmpty {
            ForEach(report.series) { series in
              NavigationLink {
                DiscoveryCandidateDetailView(report: report, seriesID: series.id)
              } label: {
                VStack(alignment: .leading, spacing: 5) {
                  HStack {
                    Text(series.label).font(.headline)
                    Spacer()
                    Text(series.identifierHex).font(.subheadline.monospaced())
                  }
                  Text(series.candidateSemantic).font(.caption.monospaced())
                  HStack {
                    Text("\(series.recordCount) retained records")
                    Spacer()
                    Text("EXPERIMENTAL CANDIDATE")
                      .font(.caption2.weight(.bold))
                      .foregroundStyle(.orange)
                  }
                  .font(.caption)
                  .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
              }
            }
          } else {
            Text(model.canResearchMessage).foregroundStyle(.secondary)
          }
        }
      }
    }
    .navigationTitle("Signal Explorer")
    .toolbar {
      Button("Refresh") { model.refreshCANResearch() }
    }
  }
}

private struct DiscoveryCandidateDetailView: View {
  let report: PassiveCANResearchReport
  let seriesID: String
  @State private var selectedSeriesID: String

  init(report: PassiveCANResearchReport, seriesID: String) {
    self.report = report
    self.seriesID = seriesID
    _selectedSeriesID = State(initialValue: seriesID)
  }

  private var series: PassiveCANResearchSeries? {
    report.series.first(where: { $0.id == seriesID })
  }

  var body: some View {
    List {
      if let series {
        Section("Authority") {
          Label("EXPERIMENTAL CANDIDATE", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Text(
            "This cross-model hypothesis is not Vehicle Validated and cannot drive owner health."
          )
          .font(.footnote)
        }
        Section("Evidence") {
          LabeledContent("CAN ID", value: series.identifierHex)
          LabeledContent("Retained records", value: series.recordCount.formatted())
          LabeledContent("Capture sessions", value: series.sessionCount.formatted())
          LabeledContent("Distinct raw values", value: series.distinctRawValues.formatted())
          LabeledContent(
            "Raw range", value: "\(series.rawMinimum.formatted())…\(series.rawMaximum.formatted())")
          LabeledContent("Candidate source count", value: series.sourceCount.formatted())
        }
        Section("Required next evidence") {
          Text(series.validationGate)
        }
        Section("Replay") {
          PassiveCANPlaybackLab(report: report, selectedSeriesID: $selectedSeriesID)
        }
      }
    }
    .navigationTitle(series?.label ?? "Candidate")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct DiscoveryCaptureReviewView: View {
  @Environment(AppModel.self) private var model
  @State private var selectedSeriesID = "toyota.2c4.engine-speed.be16"
  @State private var draftExportURL: URL?

  var body: some View {
    List {
      Section("Gateway recorder") {
        LabeledContent(
          "State",
          value: !model.gateway.hasCurrentGatewayHealth
            ? "Unavailable"
            : model.gateway.health?.captureActive == true ? "Recording" : "Not recording")
        Text(model.gateway.captureSyncMessage).font(.footnote).foregroundStyle(.secondary)
        Button("Refresh capture inventory") { model.gateway.refreshCaptureLogIndex() }
          .disabled(model.gateway.state != .vhosConnected)
        Button("Pause, download, and resume") { model.pauseDownloadAndResumeGatewayHistory() }
          .disabled(
            model.gateway.state != .vhosConnected || model.gateway.captureHistoryTransferActive
              || !model.gateway.hasCurrentParkedAuthority)
      }

      Section("Stored sessions on iPhone") {
        if model.gateway.captureSessions.isEmpty {
          Text("No retained gateway sessions are stored on this iPhone.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(model.gateway.captureSessions.prefix(20)) { session in
            VStack(alignment: .leading, spacing: 4) {
              Text("Session \(session.sessionID)").font(.headline)
              Text(session.gatewayID).font(.caption.monospaced()).foregroundStyle(.secondary)
              Text(
                "\(session.recordCount.formatted()) records · \(ByteCountFormatter.string(fromByteCount: session.byteCount, countStyle: .file))"
              )
              .font(.caption)
              Text(session.updatedAt.formatted(date: .abbreviated, time: .standard))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
          }
        }
      }

      Section("Discovery test run drafts") {
        if model.discoveryTestRuns.isEmpty {
          Text("No Discovery test run drafts are retained on this iPhone.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(model.discoveryTestRuns.reversed()) { run in
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Text(run.templateID).font(.headline)
                Spacer()
                Text(run.state.rawValue)
                  .font(.caption2.weight(.bold))
                  .foregroundStyle(run.state == .active ? .green : .secondary)
              }
              Text("TEST RUN DRAFT · not a finalized CaptureSession")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.orange)
              Text(
                "Gateway session \(run.gatewaySessionID) · \(model.discoveryMarkers.count(where: { $0.testRunID == run.id })) markers"
              )
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
              Text(run.startedAt).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
          }
        }

        Button("Prepare draft marker export") {
          do {
            draftExportURL = try model.discoveryDraftEvidenceExportURL()
            model.errorMessage = nil
          } catch {
            draftExportURL = nil
            model.errorMessage = error.localizedDescription
          }
        }
        if let draftExportURL {
          ShareLink(item: draftExportURL) {
            Label("Export drafts and canonical markers", systemImage: "square.and.arrow.up")
          }
        }
      }

      if let report = model.canResearchReport, !report.series.isEmpty {
        Section("Replay Lab") {
          PassiveCANPlaybackLab(report: report, selectedSeriesID: $selectedSeriesID)
        }
      } else {
        Section("Replay Lab") {
          ContentUnavailableView(
            "No replayable candidates",
            systemImage: "play.slash",
            description: Text(model.canResearchMessage))
        }
      }
    }
    .navigationTitle("Captures & Replay")
    .onAppear { model.refreshCANResearch() }
  }
}

private struct DiscoveryCandidateInboxView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    List {
      Section {
        Text(
          "Candidate ranking is unavailable until labeled markers, repeatability scoring, and independent corroboration are present. The cards below are retained cross-model hypotheses, not ranked discoveries."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
      if let report = model.canResearchReport, !report.series.isEmpty {
        Section("Needs More Evidence") {
          ForEach(report.series) { series in
            NavigationLink {
              DiscoveryCandidateDetailView(report: report, seriesID: series.id)
            } label: {
              VStack(alignment: .leading, spacing: 5) {
                Text(series.label).font(.headline)
                Text("\(series.identifierHex) · \(series.recordCount) retained observations")
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                Text("Recommended next evidence: \(series.validationGate)")
                  .font(.caption)
                  .lineLimit(3)
                Text("EXPERIMENTAL CANDIDATE")
                  .font(.caption2.weight(.bold))
                  .foregroundStyle(.orange)
              }
              .padding(.vertical, 4)
            }
          }
        }
      } else {
        ContentUnavailableView(
          "Candidate inbox unavailable",
          systemImage: "tray",
          description: Text(model.canResearchMessage))
      }
    }
    .navigationTitle("Candidate Inbox")
  }
}

private struct DiscoveryProgressView: View {
  @Environment(AppModel.self) private var model

  private var supportedPIDCount: Int {
    guard model.gateway.hasCurrentGatewayHealth else { return 0 }
    return Set(model.gateway.j1979Availability.flatMap(\.supportedPIDs)).count
  }

  private var currentStandardSamples: [J1979StandardSample] {
    model.gateway.standardOBDSamples.filter(model.gateway.isCurrentStandardOBDSample)
  }

  var body: some View {
    List {
      Section("Current evidence coverage") {
        DiscoveryProgressRow(
          label: "Gateway observations",
          value: model.gateway.hasCurrentGatewayHealth
            ? model.gateway.health?.receivedFrames.formatted() ?? "Unavailable" : "Unavailable",
          state: model.gateway.hasCurrentGatewayHealth ? .observed : .unavailable)
        DiscoveryProgressRow(
          label: "Supported standard PIDs",
          value: supportedPIDCount > 0 ? supportedPIDCount.formatted() : "Unavailable",
          state: supportedPIDCount > 0 ? .observed : .unavailable)
        DiscoveryProgressRow(
          label: "Decoded standard signals",
          value: currentStandardSamples.isEmpty
            ? "Unavailable" : Set(currentStandardSamples.map(\.signalID)).count.formatted(),
          state: currentStandardSamples.isEmpty ? .unavailable : .observed)
        DiscoveryProgressRow(
          label: "Experimental candidates",
          value: model.canResearchReport.map { $0.series.count.formatted() } ?? "Unavailable",
          state: model.canResearchReport == nil ? .unavailable : .experimental)
        DiscoveryProgressRow(label: "Vehicle validated", value: "Unavailable", state: .unavailable)
        DiscoveryProgressRow(
          label: "Promoted registry signals", value: "Unavailable", state: .unavailable)
        DiscoveryProgressRow(
          label: "Used by health models", value: "Unavailable", state: .unavailable)
      }
      Section("Why there is no percentage yet") {
        Text(
          "A coverage percentage requires a versioned target signal inventory for this exact VIN configuration. No such registry is installed, so the app reports observed counts and leaves the denominator unknown."
        )
        .font(.footnote)
      }
    }
    .navigationTitle("Discovery Progress")
  }
}

private struct DiscoveryProgressRow: View {
  let label: String
  let value: String
  let state: DiscoveryAuthorityState

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(label)
        Text(state.label).font(.caption2.weight(.bold)).foregroundStyle(state.color)
      }
      Spacer()
      Text(value).monospacedDigit().foregroundStyle(state.color)
    }
  }
}

struct BoundedProtocolExperimentView: View {
  @Environment(AppModel.self) private var model
  @State private var kind: DiscoveryKind = .passiveCAN
  @State private var approved = false

  private var capabilityReady: Bool {
    guard let handshake = model.gateway.handshake else { return false }
    let required: GatewayCapability =
      kind == .passiveCAN ? .passiveCapture : .allowlistedDiagnosticRead
    return handshake.capabilities.contains(.signedExperimentPlan)
      && handshake.capabilities.contains(required)
  }

  private var canRun: Bool {
    model.gateway.state == .vhosConnected
      && model.gateway.commandChannelReady
      && model.gateway.hasCurrentParkedAuthority
      && model.gateway.health?.captureActive == false
      && model.gateway.handshake?.listenOnly == true
      && model.gateway.health?.listenOnly == true
      && capabilityReady
      && approved
  }

  var body: some View {
    Form {
      Section("Bounded experiment") {
        Picker("Mode", selection: $kind) {
          ForEach(DiscoveryKind.allCases) { Text($0.rawValue).tag($0) }
        }
        Text(
          kind == .passiveCAN
            ? "Listens at four bounded CAN candidates without transmitting."
            : "Uses the gateway's dedicated interpreter and only the semantic supported-PIDs allowlist entry."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
      Section("Safety gates") {
        SafetyRow(label: "VHOS contract", pass: model.gateway.state == .vhosConnected)
        SafetyRow(label: "Reliable command channel", pass: model.gateway.commandChannelReady)
        SafetyRow(label: "Current-session health", pass: model.gateway.health != nil)
        SafetyRow(
          label: "Motion deterministically PARKED",
          pass: model.gateway.hasCurrentParkedAuthority)
        SafetyRow(label: "No active capture", pass: model.gateway.health?.captureActive == false)
        SafetyRow(
          label: "Listen-only mode",
          pass: model.gateway.handshake?.listenOnly == true
            && model.gateway.health?.listenOnly == true)
        SafetyRow(label: "Required gateway capabilities", pass: capabilityReady)
        Toggle("I approve this bounded experiment", isOn: $approved)
        Button("Sign and run experiment") {
          model.runDiscovery(kind, explicitApproval: approved)
          approved = false
        }
        .disabled(!canRun)
      }
      Section("Authority") {
        Text(
          "The app sends signed semantic plans only. There is no raw frame console. AI may interpret returned evidence and propose a plan, but cannot activate it."
        )
        .font(.footnote)
      }
    }
    .navigationTitle("Vehicle Scan")
  }
}

private struct SafetyRow: View {
  let label: String
  let pass: Bool

  var body: some View {
    Label(label, systemImage: pass ? "checkmark.circle.fill" : "xmark.circle")
      .foregroundStyle(pass ? .green : .secondary)
  }
}
