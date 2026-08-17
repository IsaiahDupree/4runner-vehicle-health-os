import SwiftUI
import VHOSCore

enum IndicatorLevel {
  case pass
  case active
  case warning
  case blocked
  case pending

  var label: String {
    switch self {
    case .pass: "PASS"
    case .active: "ACTIVE"
    case .warning: "CHECK"
    case .blocked: "BLOCKED"
    case .pending: "WAIT"
    }
  }

  var symbol: String {
    switch self {
    case .pass: "checkmark.circle.fill"
    case .active: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .blocked: "xmark.octagon.fill"
    case .pending: "circle.dotted"
    }
  }

  var color: Color {
    switch self {
    case .pass: .green
    case .active: .blue
    case .warning: .orange
    case .blocked: .red
    case .pending: .secondary
    }
  }
}

struct StatusIndicator: Identifiable {
  let id: String
  let title: String
  let value: String
  let detail: String
  let level: IndicatorLevel

  init(
    _ id: String,
    title: String,
    value: String,
    detail: String,
    level: IndicatorLevel
  ) {
    self.id = id
    self.title = title
    self.value = value
    self.detail = detail
    self.level = level
  }
}

struct SystemStatusView: View {
  @Environment(AppModel.self) private var model

  private var gateway: GatewayBLEClient { model.gateway }
  private var protocolSummary: ProtocolEvidenceSummary {
    ProtocolEvidenceSummary(results: gateway.currentSessionExperimentResults)
  }

  var body: some View {
    List {
      Section("At a glance") {
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8
        ) {
          StatusSummaryCard(title: "ESP32", indicator: esp32Summary)
          StatusSummaryCard(title: "OBD-II", indicator: obdSummary)
          StatusSummaryCard(title: "Tests", indicator: testSummary)
        }
        .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
      }

      Section("Connection controls") {
        HStack {
          Button {
            gateway.startScan()
          } label: {
            Label(
              gateway.scanActive ? "Scanning…" : "Scan for gateway",
              systemImage: "antenna.radiowaves.left.and.right")
          }
          .disabled(
            gateway.scanActive || gateway.peripheralConnected || gateway.state == .connecting)

          Spacer()

          Button("Disconnect", role: .destructive) { gateway.disconnect() }
            .disabled(!gateway.peripheralConnected && gateway.state == .disconnected)
        }
        if let message = gateway.transportMessage {
          Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }

      StatusIndicatorSection(title: "iPhone → ESP32 transport", indicators: transportIndicators)
      StatusIndicatorSection(title: "ESP32 gateway", indicators: gatewayIndicators)
      StatusIndicatorSection(title: "OBD-II and vehicle bus", indicators: obdIndicators)

      Section("Protocol test matrix") {
        ForEach(protocolSummary.tests) { test in
          StatusIndicatorRow(indicator: protocolIndicator(test))
        }
        Text(
          "A passive lock proves vehicle-network traffic at that candidate. OBD CONFIRMED requires an allowlisted diagnostic response; the app does not infer one from CAN traffic alone."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      StatusIndicatorSection(title: "Safety and test readiness", indicators: safetyIndicators)
      StatusIndicatorSection(title: "Gateway capability contract", indicators: capabilityIndicators)
      StatusIndicatorSection(title: "Firmware and OTA", indicators: firmwareIndicators)
      StatusIndicatorSection(title: "Evidence and AI handoff", indicators: evidenceIndicators)

      Section("Indicator semantics") {
        Text(
          "PASS is backed by app, gateway, or experiment evidence. ACTIVE means an operation is in progress. CHECK requires review. BLOCKED prevents the operation. WAIT means the app has not received enough evidence yet."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .navigationTitle("System Status")
  }

  private var esp32Summary: StatusIndicator {
    if gateway.handshake != nil {
      return StatusIndicator(
        "summary.esp32", title: "ESP32", value: "VHOS ONLINE",
        detail: gateway.discoveredName ?? "Gateway connected", level: .pass)
    }
    if gateway.peripheralConnected, gateway.factoryServiceDiscovered {
      return StatusIndicator(
        "summary.esp32", title: "ESP32", value: "FACTORY MODE",
        detail: "BLE connected; VHOS firmware required", level: .warning)
    }
    if gateway.state == .failed || gateway.state == .degraded {
      return StatusIndicator(
        "summary.esp32", title: "ESP32", value: "LINK ERROR",
        detail: gateway.transportMessage ?? "Gateway link failed", level: .blocked)
    }
    if gateway.peripheralConnected || gateway.state == .connecting || gateway.scanActive {
      return StatusIndicator(
        "summary.esp32", title: "ESP32", value: "CONNECTING",
        detail: gateway.transportMessage ?? "Negotiating", level: .active)
    }
    return StatusIndicator(
      "summary.esp32", title: "ESP32", value: "NOT CONNECTED",
      detail: "Scan for the powered gateway", level: .pending)
  }

  private var obdSummary: StatusIndicator {
    if let result = protocolSummary.latestOBDConfirmation {
      return StatusIndicator(
        "summary.obd", title: "OBD-II", value: "CONFIRMED",
        detail: result.candidate.protocolID.displayName, level: .pass)
    }
    if let result = protocolSummary.latestNetworkConfirmation {
      return StatusIndicator(
        "summary.obd", title: "OBD-II", value: "NETWORK ONLY",
        detail: "\(result.candidate.protocolID.displayName) traffic detected", level: .warning)
    }
    if gateway.handshake == nil {
      return StatusIndicator(
        "summary.obd", title: "OBD-II", value: "UNVERIFIED",
        detail: "VHOS handshake required", level: .pending)
    }
    return StatusIndicator(
      "summary.obd", title: "OBD-II", value: "NOT TESTED",
      detail: "Run bounded protocol discovery", level: .pending)
  }

  private var testSummary: StatusIndicator {
    if experimentPending {
      return StatusIndicator(
        "summary.tests", title: "Tests", value: "RUNNING",
        detail: model.lastSubmittedExperimentKind?.rawValue ?? "Awaiting gateway result",
        level: .active)
    }
    if experimentAwaitingResult {
      return StatusIndicator(
        "summary.tests", title: "Tests", value: "INTERRUPTED",
        detail: "Gateway disconnected before a result arrived", level: .blocked)
    }
    if let latest = protocolSummary.latestResult {
      return StatusIndicator(
        "summary.tests", title: "Tests", value: latest.outcome.shortLabel,
        detail: latest.candidate.protocolID.displayName,
        level: indicatorLevel(for: latest.outcome))
    }
    if coreTestReady {
      return StatusIndicator(
        "summary.tests", title: "Tests", value: "READY",
        detail: "Safety gates satisfied", level: .pass)
    }
    return StatusIndicator(
      "summary.tests", title: "Tests", value: "BLOCKED",
      detail: "Review readiness indicators", level: .blocked)
  }

  private var transportIndicators: [StatusIndicator] {
    [
      StatusIndicator(
        "transport.bluetooth", title: "Bluetooth radio",
        value: gateway.bluetoothReady ? "READY" : gateway.bluetoothStateDescription.uppercased(),
        detail: "iPhone Core Bluetooth state: \(gateway.bluetoothStateDescription)",
        level: gateway.bluetoothReady ? .pass : bluetoothUnavailableLevel),
      StatusIndicator(
        "transport.scan", title: "Gateway scan",
        value: gateway.scanActive
          ? "SCANNING"
          : (gateway.gatewayIdentityValidated
            ? "VERIFIED" : (gateway.discoveredName == nil ? "IDLE" : "CANDIDATE")),
        detail: gateway.discoveredName
          ?? gateway.lastObservedAdvertisement.map {
            "Observed \(gateway.scanObservationCount) advertisements; latest: \($0)"
          }
          ?? "No BLE advertisements observed yet (\(gateway.scanMode))",
        level: gateway.scanActive
          ? .active
          : (gateway.gatewayIdentityValidated
            ? .pass : (gateway.discoveredName == nil ? .pending : .active))),
      StatusIndicator(
        "transport.peripheral", title: "Gateway BLE link",
        value: gateway.peripheralConnected
          ? (gateway.gatewayIdentityValidated ? "VERIFIED" : "VALIDATING")
          : (gateway.automaticReconnectActive ? "RECONNECTING" : "DISCONNECTED"),
        detail: peripheralDetail,
        level: gateway.gatewayIdentityValidated
          ? .pass
          : (gateway.peripheralConnected || gateway.automaticReconnectActive
            ? .active : connectionFailureLevel)),
      StatusIndicator(
        "transport.rssi", title: "Discovery signal",
        value: gateway.discoveredRSSI.map { "\($0) dBm" } ?? "UNAVAILABLE",
        detail: discoverySignalDetail,
        level: discoverySignalLevel),
      StatusIndicator(
        "transport.vhos-service", title: "VHOS BLE service",
        value: gateway.vhosServiceDiscovered ? "DISCOVERED" : "NOT FOUND",
        detail: gateway.factoryServiceDiscovered && !gateway.vhosServiceDiscovered
          ? "Factory WiCAN service is present; install the VHOS firmware fork"
          : "Versioned gateway service UUID",
        level: gateway.vhosServiceDiscovered
          ? .pass : (gateway.factoryServiceDiscovered ? .warning : .pending)),
      StatusIndicator(
        "transport.command", title: "Reliable command channel",
        value: gateway.commandChannelReady ? "READY" : "UNAVAILABLE",
        detail: "Required for handshake, signed plans, and constrained control",
        level: gateway.commandChannelReady ? .pass : .pending),
      notificationIndicator(
        id: "transport.stream", title: "Evidence stream notifications",
        discovered: gateway.streamChannelDiscovered,
        enabled: gateway.streamNotificationsEnabled),
      notificationIndicator(
        id: "transport.health", title: "Health stream notifications",
        discovered: gateway.healthChannelDiscovered,
        enabled: gateway.healthNotificationsEnabled),
      notificationIndicator(
        id: "transport.ota", title: "OTA status notifications",
        discovered: gateway.otaStatusChannelDiscovered,
        enabled: gateway.otaStatusNotificationsEnabled),
      StatusIndicator(
        "transport.frames", title: "Frame CRC and decode",
        value: gateway.frameDecodeErrorCount > 0
          ? "\(gateway.frameDecodeErrorCount) ERRORS" : "\(gateway.decodedFrameCount) VALID",
        detail: lastFrameDetail,
        level: gateway.frameDecodeErrorCount > 0
          ? .blocked : (gateway.decodedFrameCount > 0 ? .pass : .pending)),
      StatusIndicator(
        "transport.sequence", title: "Sequence continuity",
        value: gateway.sequenceDiscontinuityCount == 0
          ? (gateway.decodedFrameCount > 0 ? "CONTINUOUS" : "NO DATA")
          : "\(gateway.sequenceDiscontinuityCount) GAPS",
        detail: gateway.missingSequenceCount == 0
          ? "No missing frame sequences observed in this BLE session"
          : "\(gateway.missingSequenceCount) frame sequence numbers were skipped",
        level: gateway.sequenceDiscontinuityCount > 0
          ? .warning : (gateway.decodedFrameCount > 0 ? .pass : .pending)),
    ]
  }

  private var gatewayIndicators: [StatusIndicator] {
    let handshake = gateway.handshake
    let health = gateway.health
    return [
      StatusIndicator(
        "gateway.mode", title: "Firmware mode",
        value: handshake != nil
          ? "VHOS" : (gateway.factoryServiceDiscovered ? "FACTORY" : "UNKNOWN"),
        detail: handshake != nil
          ? "Project gateway contract is active"
          : "Factory compatibility is read-only and cannot run VHOS experiments",
        level: handshake != nil ? .pass : (gateway.factoryServiceDiscovered ? .warning : .pending)),
      StatusIndicator(
        "gateway.handshake", title: "Contract handshake",
        value: handshake.map { $0.contractVersion } ?? "NOT RECEIVED",
        detail: timestampDetail("Handshake", gateway.lastHandshakeReceivedAt),
        level: handshake == nil ? .pending : .pass),
      StatusIndicator(
        "gateway.identity", title: "Gateway identity",
        value: handshake?.gatewayID ?? "UNAVAILABLE",
        detail: handshake.map { "Hardware \($0.hardwareRevision)" }
          ?? "Awaiting signed gateway identity",
        level: handshake == nil ? .pending : .pass),
      StatusIndicator(
        "gateway.firmware", title: "Firmware identity",
        value: handshake?.firmwareVersion ?? "UNAVAILABLE",
        detail: handshake.map { "Build \($0.firmwareBuildID)" } ?? "Awaiting handshake",
        level: handshake == nil ? .pending : .pass),
      StatusIndicator(
        "gateway.bootloader", title: "Bootloader identity",
        value: handshake?.bootloaderVersion ?? "NOT ADVERTISED",
        detail: "Required only when a signed firmware manifest declares a minimum",
        level: handshake?.bootloaderVersion == nil ? .pending : .pass),
      StatusIndicator(
        "gateway.config", title: "Active configuration",
        value: handshake?.activeConfigVersion ?? "UNAVAILABLE",
        detail: handshake.map { $0.activeConfigID } ?? "Awaiting handshake",
        level: handshake == nil ? .pending : .pass),
      StatusIndicator(
        "gateway.health", title: "Live health report",
        value: health == nil ? "NOT RECEIVED" : "RECEIVED",
        detail: health.map { "Gateway observed at \($0.observedAt)" }
          ?? "No current-session gateway health evidence",
        level: health == nil ? .pending : .pass),
      StatusIndicator(
        "gateway.health-arrival", title: "Health stream arrival",
        value: gateway.lastHealthReceivedAt.map(clockTime) ?? "UNAVAILABLE",
        detail: timestampDetail("Health frame", gateway.lastHealthReceivedAt),
        level: gateway.lastHealthReceivedAt == nil ? .pending : .pass),
      StatusIndicator(
        "gateway.supply", title: "Gateway supply",
        value: health?.supplyMillivolts.map(voltage) ?? "UNAVAILABLE",
        detail: "Reported by the gateway; package-specific OTA limits are evaluated separately",
        level: health?.supplyMillivolts == nil ? .pending : .pass),
      StatusIndicator(
        "gateway.motion", title: "Vehicle motion",
        value: health?.vehicleMotion.rawValue ?? "UNKNOWN",
        detail: motionDetail,
        level: motionLevel),
      StatusIndicator(
        "gateway.capture", title: "Capture state",
        value: health.map { $0.captureActive ? "ACTIVE" : "IDLE" } ?? "UNKNOWN",
        detail: health?.captureActive == true
          ? "Discovery and OTA remain blocked until capture is persisted and stopped"
          : "No active capture reported",
        level: health.map { $0.captureActive ? .active : .pass } ?? .pending),
      StatusIndicator(
        "gateway.listen-only", title: "Listen-only guard",
        value: listenOnlySatisfied ? "ENFORCED" : "NOT VERIFIED",
        detail: "Both handshake and live health must report listen-only mode",
        level: handshake == nil || health == nil
          ? .pending : (listenOnlySatisfied ? .pass : .blocked)),
      StatusIndicator(
        "gateway.storage", title: "Capture storage",
        value: health.flatMap(\.storageFreeBytes).map {
          ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        }
          ?? "UNAVAILABLE",
        detail: "Gateway-reported free storage",
        level: health.flatMap(\.storageFreeBytes).map { $0 > 0 ? .pass : .warning } ?? .pending),
      StatusIndicator(
        "gateway.can-controller", title: "CAN observer",
        value: health?.canControllerRunning == true
          ? "RUNNING" : (health?.canControllerRunning == false ? "STOPPED" : "UNAVAILABLE"),
        detail: "ESP32 TWAI controller; listen-only policy is evaluated separately",
        level: health?.canControllerRunning == true
          ? .pass : (health?.canControllerRunning == false ? .blocked : .pending)),
      StatusIndicator(
        "gateway.can-probe", title: "Passive CAN probe",
        value: health?.canScanState?.rawValue.replacingOccurrences(of: "_", with: " ")
          ?? "UNAVAILABLE",
        detail: passiveCANProbeDetail,
        level: passiveCANProbeLevel),
      StatusIndicator(
        "gateway.can-bitrate", title: "Observed CAN bitrate",
        value: health?.canBitrateBps.map { "\($0 / 1_000) kbit/s" } ?? "UNAVAILABLE",
        detail: health?.canPassiveLock == true
          ? "Locked after repeatable valid frames"
          : "Current bounded listen-only observation window",
        level: health?.canPassiveLock == true
          ? .pass : (health?.canBitrateBps == nil ? .pending : .active)),
      StatusIndicator(
        "gateway.can-candidate", title: "Passive CAN candidate",
        value: health?.passiveCanCandidate ?? "UNVERIFIED",
        detail: health?.passiveCanCandidate == nil
          ? "No multi-frame passive lock yet"
          : "Valid CAN traffic observed; this does not confirm OBD-II",
        level: health?.passiveCanCandidate == nil ? .pending : .pass),
      StatusIndicator(
        "gateway.can-formats", title: "CAN identifier formats",
        value: canIdentifierFormatValue,
        detail: "Valid standard (11-bit) / extended (29-bit) frames since boot",
        level: canObservedFrameCount > 0 ? .pass : .pending),
      StatusIndicator(
        "gateway.can-rate-counts", title: "Frames by bitrate",
        value: canBitrateFrameValue,
        detail: "Valid 500 kbit/s / 250 kbit/s frames since boot",
        level: canObservedFrameCount > 0 ? .pass : .pending),
      counterIndicator(
        id: "gateway.received", title: "Vehicle-bus frames", count: health?.receivedFrames,
        zeroLevel: .pending, nonzeroLevel: .pass),
      counterIndicator(
        id: "gateway.dropped", title: "Dropped frames", count: health?.droppedFrames,
        zeroLevel: .pass, nonzeroLevel: .warning),
      counterIndicator(
        id: "gateway.errors", title: "Bus errors", count: health?.busErrorCount,
        zeroLevel: .pass, nonzeroLevel: .warning),
      counterIndicator(
        id: "gateway.bus-off", title: "Bus-off events", count: health?.busOffCount,
        zeroLevel: .pass, nonzeroLevel: .blocked),
    ]
  }

  private var obdIndicators: [StatusIndicator] {
    let health = gateway.health
    let network = protocolSummary.latestNetworkConfirmation
    let diagnostic = protocolSummary.latestOBDConfirmation
    return [
      StatusIndicator(
        "obd.power", title: "DLC / OBD power evidence",
        value: health?.supplyMillivolts.map(voltage) ?? "UNVERIFIED",
        detail: "A gateway supply reading proves gateway power, not protocol compatibility",
        level: health?.supplyMillivolts == nil ? .pending : .pass),
      StatusIndicator(
        "obd.traffic", title: "Vehicle-network traffic",
        value: (health?.receivedFrames ?? 0) > 0 ? "OBSERVED" : "NOT OBSERVED",
        detail: health.map { "\($0.receivedFrames.formatted()) gateway-reported frames" }
          ?? "Awaiting gateway health",
        level: (health?.receivedFrames ?? 0) > 0 ? .pass : .pending),
      StatusIndicator(
        "obd.network", title: "Latest confirmed network protocol",
        value: network?.candidate.protocolID.displayName ?? "NOT CONFIRMED",
        detail: network.map(evidenceDetail)
          ?? "No passive lock or allowlisted read result received",
        level: network == nil ? .pending : .pass),
      StatusIndicator(
        "obd.diagnostic", title: "OBD diagnostic response",
        value: diagnostic?.candidate.protocolID.displayName ?? "NOT CONFIRMED",
        detail: diagnostic.map(evidenceDetail)
          ?? "Requires a READ_CONFIRMED result from the firmware-resident supported-PIDs allowlist",
        level: diagnostic == nil ? (network == nil ? .pending : .warning) : .pass),
      latestProtocolResultIndicator,
    ]
  }

  private var safetyIndicators: [StatusIndicator] {
    let health = gateway.health
    return [
      StatusIndicator(
        "safety.contract", title: "VHOS contract",
        value: gateway.state == .vhosConnected ? "CONNECTED" : "REQUIRED",
        detail: "Factory WiCAN mode cannot activate project experiments",
        level: gateway.state == .vhosConnected ? .pass : .blocked),
      StatusIndicator(
        "safety.health", title: "Current-session health",
        value: health == nil ? "REQUIRED" : "AVAILABLE",
        detail: timestampDetail("Last received", gateway.lastHealthReceivedAt),
        level: health == nil ? .blocked : .pass),
      StatusIndicator(
        "safety.parked", title: "Motion deterministically PARKED",
        value: health?.vehicleMotion.rawValue ?? "UNKNOWN",
        detail: "There is no manual motion override",
        level: health?.vehicleMotion == .parked ? .pass : .blocked),
      StatusIndicator(
        "safety.capture", title: "Capture idle",
        value: health.map { $0.captureActive ? "ACTIVE" : "IDLE" } ?? "UNKNOWN",
        detail: "An active capture blocks a new experiment and OTA",
        level: health.map { $0.captureActive ? .blocked : .pass } ?? .blocked),
      StatusIndicator(
        "safety.listen-only", title: "Listen-only mode",
        value: listenOnlySatisfied ? "ENFORCED" : "REQUIRED",
        detail: "Handshake and health must agree",
        level: listenOnlySatisfied ? .pass : .blocked),
      StatusIndicator(
        "safety.command-queue", title: "BLE command queue",
        value: gateway.commandChunksPending == 0
          ? "IDLE" : "\(gateway.commandChunksPending) PENDING",
        detail: "Reliable-write chunks awaiting gateway acknowledgement",
        level: gateway.commandChunksPending == 0 ? .pass : .active),
      StatusIndicator(
        "safety.signing", title: "Experiment signing identity",
        value: model.experimentSigningKeyConfigured ? "KEYCHAIN READY" : "ON FIRST APPROVAL",
        detail: "The device-local Ed25519 key is generated when the first approved plan is signed",
        level: model.experimentSigningKeyConfigured ? .pass : .pending),
      StatusIndicator(
        "safety.approval", title: "Explicit owner approval",
        value: "REQUIRED PER RUN",
        detail: "Approval is collected on the Discovery screen and is never cached",
        level: .warning),
      StatusIndicator(
        "safety.pending", title: "Experiment execution",
        value: experimentPending
          ? "AWAITING RESULT" : (experimentAwaitingResult ? "INTERRUPTED" : "IDLE"),
        detail: pendingExperimentDetail,
        level: experimentPending ? .active : (experimentAwaitingResult ? .blocked : .pass)),
    ]
  }

  private var capabilityIndicators: [StatusIndicator] {
    GatewayCapability.allCases.map { capability in
      let advertised = gateway.handshake?.capabilities.contains(capability) == true
      return StatusIndicator(
        "capability.\(capability.rawValue)",
        title: capability.displayName,
        value: advertised ? "ADVERTISED" : "NOT ADVERTISED",
        detail: capability.rawValue,
        level: gateway.handshake == nil ? .pending : (advertised ? .pass : .warning)
      )
    }
  }

  private var firmwareIndicators: [StatusIndicator] {
    let handshake = gateway.handshake
    let health = gateway.health
    return [
      StatusIndicator(
        "firmware.key", title: "Release verification key",
        value: model.releasePublicKeyConfigured ? "KEYCHAIN READY" : "REQUIRED",
        detail: "Pinned Ed25519 public key for .vhosota verification",
        level: model.releasePublicKeyConfigured ? .pass : .pending),
      StatusIndicator(
        "firmware.package", title: "Signed firmware package",
        value: model.verifiedFirmware?.manifest.firmwareVersion ?? "NOT SELECTED",
        detail: model.verifiedFirmware.map {
          "Signature and SHA-256 verified for build \($0.manifest.firmwareBuildID)"
        } ?? "Select a package only after configuring release trust",
        level: model.verifiedFirmware == nil ? .pending : .pass),
      StatusIndicator(
        "firmware.endpoint", title: "Private Wi-Fi OTA endpoint",
        value: handshake?.otaUploadURL == nil ? "NOT ADVERTISED" : "ADVERTISED",
        detail: handshake?.otaUploadURL ?? "Awaiting gateway handshake",
        level: handshake?.otaUploadURL == nil ? .pending : .pass),
      StatusIndicator(
        "firmware.preflight", title: "OTA preflight",
        value: firmwarePreflight.value,
        detail: firmwarePreflight.detail,
        level: firmwarePreflight.level),
      StatusIndicator(
        "firmware.update", title: "Update operation",
        value: model.updateInProgress ? "UPLOADING" : "IDLE",
        detail: model.uploadProgressDescription ?? "No update in progress",
        level: model.updateInProgress ? .active : .pass),
      StatusIndicator(
        "firmware.post", title: "Probationary boot / POST",
        value: gateway.lastOTAStatusAt == nil ? "NO STATUS" : "STATUS RECEIVED",
        detail: timestampDetail("Last OTA status", gateway.lastOTAStatusAt),
        level: gateway.lastOTAStatusAt == nil ? .pending : .pass),
      StatusIndicator(
        "firmware.context", title: "OTA context availability",
        value: handshake != nil && health != nil ? "AVAILABLE" : "INCOMPLETE",
        detail: "Preflight requires both gateway identity and live health",
        level: handshake != nil && health != nil ? .pass : .pending),
    ]
  }

  private var evidenceIndicators: [StatusIndicator] {
    let results = gateway.experimentResults
    let latest = results.last
    let complete =
      latest.map {
        !$0.evidenceReferences.isEmpty
          && $0.manifestSHA256.count == 64
          && $0.manifestSHA256.allSatisfy(\.isHexDigit)
      } ?? false
    return [
      StatusIndicator(
        "evidence.results", title: "Experiment results",
        value: "\(results.count)",
        detail: gateway.lastExperimentResultAt.map {
          "Last result arrived at \(clockTime($0))"
        } ?? "No gateway experiment evidence received",
        level: results.isEmpty ? .pending : .pass),
      StatusIndicator(
        "evidence.references", title: "Latest evidence references",
        value: latest.map { "\($0.evidenceReferences.count) REFERENCES" } ?? "UNAVAILABLE",
        detail: latest.map { "Capture \($0.captureID)" } ?? "Run a bounded experiment first",
        level: latest == nil ? .pending : (complete ? .pass : .blocked)),
      StatusIndicator(
        "evidence.manifest", title: "Latest capture manifest",
        value: latest == nil ? "UNAVAILABLE" : (complete ? "CHECKSUM PRESENT" : "INCOMPLETE"),
        detail: latest?.manifestSHA256 ?? "No manifest SHA-256 received",
        level: latest == nil ? .pending : (complete ? .pass : .blocked)),
      StatusIndicator(
        "evidence.export", title: "AI evidence export",
        value: gateway.handshake != nil && gateway.health != nil ? "READY" : "BLOCKED",
        detail: "Requires gateway/config identity and current-session health",
        level: gateway.handshake != nil && gateway.health != nil ? .pass : .blocked),
      StatusIndicator(
        "evidence.authority", title: "AI authority boundary",
        value: "ENFORCED",
        detail: "Interpret and propose only; no activation or raw vehicle frames",
        level: .pass),
    ]
  }

  private var latestProtocolResultIndicator: StatusIndicator {
    guard let latest = protocolSummary.latestResult else {
      return StatusIndicator(
        "obd.latest", title: "Latest protocol test", value: "NOT TESTED",
        detail: "No experiment result received", level: .pending)
    }
    return StatusIndicator(
      "obd.latest", title: "Latest protocol test",
      value: latest.outcome.shortLabel,
      detail: "\(latest.candidate.protocolID.displayName) • \(evidenceDetail(latest))",
      level: indicatorLevel(for: latest.outcome))
  }

  private func protocolIndicator(_ test: ProtocolTestStatus) -> StatusIndicator {
    let level: IndicatorLevel
    switch test.state {
    case .notTested: level = .pending
    case .noLock, .inconclusive: level = .warning
    case .networkDetected, .obdConfirmed: level = .pass
    case .rejected: level = .blocked
    }
    return StatusIndicator(
      "protocol.\(test.protocolID.rawValue)",
      title: test.protocolID.displayName,
      value: test.state.shortLabel,
      detail: test.latestResult.map(evidenceDetail) ?? protocolTestDetail(test.protocolID),
      level: level
    )
  }

  private func notificationIndicator(
    id: String,
    title: String,
    discovered: Bool,
    enabled: Bool
  ) -> StatusIndicator {
    StatusIndicator(
      id,
      title: title,
      value: enabled ? "SUBSCRIBED" : (discovered ? "ENABLING" : "UNAVAILABLE"),
      detail: enabled ? "Core Bluetooth notifications active" : "Awaiting VHOS characteristic",
      level: enabled ? .pass : (discovered ? .active : .pending)
    )
  }

  private func counterIndicator(
    id: String,
    title: String,
    count: UInt64?,
    zeroLevel: IndicatorLevel,
    nonzeroLevel: IndicatorLevel
  ) -> StatusIndicator {
    StatusIndicator(
      id,
      title: title,
      value: count?.formatted() ?? "UNAVAILABLE",
      detail: "Gateway cumulative counter from the latest health report",
      level: count.map { $0 == 0 ? zeroLevel : nonzeroLevel } ?? .pending
    )
  }

  private var firmwarePreflight: (value: String, detail: String, level: IndicatorLevel) {
    guard let package = model.verifiedFirmware else {
      return ("WAITING", "Select and verify a signed firmware package", .pending)
    }
    guard let handshake = gateway.handshake, let health = gateway.health else {
      return ("BLOCKED", "VHOS handshake and current-session health are required", .blocked)
    }
    do {
      try package.validatePreflight(
        .init(
          handshake: handshake,
          health: health,
          bootloaderVersion: handshake.bootloaderVersion
        ))
      return (
        "PASS", "Signed manifest, hardware, voltage, motion, size, and capabilities pass", .pass
      )
    } catch {
      return ("BLOCKED", error.localizedDescription, .blocked)
    }
  }

  private var coreTestReady: Bool {
    guard let handshake = gateway.handshake, let health = gateway.health else { return false }
    return gateway.state == .vhosConnected
      && gateway.commandChannelReady
      && health.vehicleMotion == .parked
      && !health.captureActive
      && handshake.listenOnly
      && health.listenOnly
      && handshake.capabilities.contains(.signedExperimentPlan)
  }

  private var experimentPending: Bool {
    gateway.peripheralConnected && experimentAwaitingResult
  }

  private var experimentAwaitingResult: Bool {
    guard let id = model.lastSubmittedExperimentID else { return false }
    return !gateway.experimentResults.contains { $0.experimentID == id }
  }

  private var pendingExperimentDetail: String {
    guard experimentAwaitingResult else {
      return "No signed experiment is awaiting a gateway result"
    }
    let kind = model.lastSubmittedExperimentKind?.rawValue ?? "Bounded experiment"
    let submitted = model.lastSubmittedExperimentAt.map(clockTime) ?? "unknown time"
    return "\(kind) submitted at \(submitted)"
  }

  private var listenOnlySatisfied: Bool {
    gateway.handshake?.listenOnly == true && gateway.health?.listenOnly == true
  }

  private var motionLevel: IndicatorLevel {
    switch gateway.health?.vehicleMotion {
    case .parked: .pass
    case .moving: .warning
    case .unknown, nil: .pending
    }
  }

  private var motionDetail: String {
    switch gateway.health?.vehicleMotion {
    case .parked: "Gateway reports PARKED; other gates still apply"
    case .moving: "Vehicle tests and OTA are blocked while moving"
    case .unknown, nil: "Motion must be deterministically PARKED before tests or OTA"
    }
  }

  private var passiveCANProbeLevel: IndicatorLevel {
    switch gateway.health?.canScanState {
    case .locked500K, .locked250K: .pass
    case .probing500K, .probing250K: .active
    case .error: .blocked
    case nil: .pending
    }
  }

  private var passiveCANProbeDetail: String {
    guard let health = gateway.health else { return "Awaiting gateway health" }
    switch health.canScanState {
    case .locked500K, .locked250K:
      return "Multi-frame passive lock; OBD-II remains independently unverified"
    case .probing500K, .probing250K:
      return "Cycle \(health.canScanCycles ?? 0); alternates after a bounded silent window"
    case .error:
      return "TWAI bitrate reconfiguration failed; inspect gateway evidence"
    case nil:
      return "Installed firmware does not report passive probe state"
    }
  }

  private var canObservedFrameCount: UInt64 {
    (gateway.health?.canStandardFrames ?? 0) + (gateway.health?.canExtendedFrames ?? 0)
  }

  private var canIdentifierFormatValue: String {
    guard let health = gateway.health,
      let standard = health.canStandardFrames,
      let extended = health.canExtendedFrames
    else { return "UNAVAILABLE" }
    return "\(standard) / \(extended)"
  }

  private var canBitrateFrameValue: String {
    guard let health = gateway.health,
      let frames500k = health.canFrames500k,
      let frames250k = health.canFrames250k
    else { return "UNAVAILABLE" }
    return "\(frames500k) / \(frames250k)"
  }

  private var bluetoothUnavailableLevel: IndicatorLevel {
    switch gateway.bluetoothStateDescription {
    case "initializing", "unknown", "resetting": .pending
    default: .blocked
    }
  }

  private var discoverySignalLevel: IndicatorLevel {
    guard let rssi = gateway.discoveredRSSI else { return .pending }
    return rssi <= -80 ? .warning : .pass
  }

  private var discoverySignalDetail: String {
    guard let rssi = gateway.discoveredRSSI else {
      return "RSSI is available after a supported gateway advertisement is selected"
    }
    if rssi <= -90 {
      return "Very weak commissioning signal; place the iPhone beside the ESP32 before pairing"
    }
    if rssi <= -80 {
      return "Weak signal; move closer before pairing, evidence transfer, or OTA"
    }
    return "RSSI from the selected gateway advertisement; no vehicle-health inference is applied"
  }

  private var connectionFailureLevel: IndicatorLevel {
    switch gateway.state {
    case .failed, .degraded: .blocked
    case .connecting, .scanning: .active
    default: .pending
    }
  }

  private var peripheralDetail: String {
    if gateway.automaticReconnectActive {
      return "Automatic reconnect attempt \(gateway.reconnectAttemptCount) • \(gateway.discoveredName ?? "saved gateway")"
    }
    if let name = gateway.discoveredName, let identifier = gateway.discoveredIdentifier {
      return "\(name) • \(identifier)"
    }
    return "No ESP32 gateway BLE connection"
  }

  private var lastFrameDetail: String {
    guard let date = gateway.lastFrameReceivedAt else {
      return "No valid VHOS frame received in this BLE session"
    }
    return
      "Last valid frame at \(clockTime(date)); sequence \(gateway.lastReceivedSequence?.formatted() ?? "unknown")"
  }

  private func evidenceDetail(_ result: ProtocolExperimentResult) -> String {
    "Capture \(result.captureID) • \(result.receivedRecords.formatted()) records • \(result.errorCount.formatted()) errors"
  }

  private func protocolTestDetail(_ protocolID: DiscoveryProtocol) -> String {
    protocolID.isPassiveCAN
      ? "Not tested; passive listen only"
      : "Not tested; requires the firmware-resident supported-PIDs allowlist"
  }

  private func timestampDetail(_ label: String, _ date: Date?) -> String {
    date.map { "\(label) at \(clockTime($0))" } ?? "\(label) not received in this connection"
  }

  private func clockTime(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .standard)
  }

  private func voltage(_ millivolts: Int) -> String {
    String(format: "%.2f V", Double(millivolts) / 1000)
  }

  private func indicatorLevel(for outcome: DiscoveryOutcome) -> IndicatorLevel {
    switch outcome {
    case .passiveLock, .readConfirmed: .pass
    case .noLock, .inconclusive: .warning
    case .rejectedError: .blocked
    }
  }
}

private struct StatusIndicatorSection: View {
  let title: String
  let indicators: [StatusIndicator]

  var body: some View {
    Section(title) {
      ForEach(indicators) { indicator in
        StatusIndicatorRow(indicator: indicator)
      }
    }
  }
}

private struct StatusIndicatorRow: View {
  let indicator: StatusIndicator

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: indicator.level.symbol)
        .foregroundStyle(indicator.level.color)
        .font(.title3)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 3) {
        Text(indicator.title)
          .font(.body.weight(.medium))
        Text(indicator.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }

      Spacer(minLength: 8)

      VStack(alignment: .trailing, spacing: 4) {
        Text(indicator.value)
          .font(.caption.weight(.semibold))
          .foregroundStyle(indicator.level.color)
          .multilineTextAlignment(.trailing)
        Text(indicator.level.label)
          .font(.caption2.weight(.bold))
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .foregroundStyle(indicator.level.color)
          .background(indicator.level.color.opacity(0.12), in: Capsule())
      }
      .frame(maxWidth: 120, alignment: .trailing)
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(indicator.title), \(indicator.value), \(indicator.level.label), \(indicator.detail)")
  }
}

private struct StatusSummaryCard: View {
  let title: String
  let indicator: StatusIndicator

  var body: some View {
    VStack(spacing: 7) {
      Image(systemName: indicator.level.symbol)
        .font(.title2)
        .foregroundStyle(indicator.level.color)
      Text(title)
        .font(.caption.weight(.semibold))
      Text(indicator.value)
        .font(.caption2.weight(.bold))
        .foregroundStyle(indicator.level.color)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .minimumScaleFactor(0.7)
      Text(indicator.level.label)
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, minHeight: 105)
    .padding(8)
    .background(indicator.level.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(indicator.level.color.opacity(0.22), lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title), \(indicator.value), \(indicator.level.label)")
  }
}

extension DiscoveryProtocol {
  fileprivate var displayName: String {
    switch self {
    case .can11Bit500K: "CAN 11-bit / 500 kbit/s"
    case .can29Bit500K: "CAN 29-bit / 500 kbit/s"
    case .can11Bit250K: "CAN 11-bit / 250 kbit/s"
    case .can29Bit250K: "CAN 29-bit / 250 kbit/s"
    case .iso9141: "ISO 9141-2"
    case .iso14230Fast: "ISO 14230 fast init"
    case .iso14230Slow: "ISO 14230 slow init"
    case .j1850PWM: "SAE J1850 PWM"
    case .j1850VPW: "SAE J1850 VPW"
    }
  }
}

extension ProtocolTestState {
  fileprivate var shortLabel: String {
    switch self {
    case .notTested: "NOT TESTED"
    case .noLock: "NO LOCK"
    case .networkDetected: "NETWORK"
    case .obdConfirmed: "OBD CONFIRMED"
    case .inconclusive: "INCONCLUSIVE"
    case .rejected: "REJECTED"
    }
  }
}

extension DiscoveryOutcome {
  fileprivate var shortLabel: String {
    switch self {
    case .noLock: "NO LOCK"
    case .passiveLock: "NETWORK"
    case .readConfirmed: "OBD CONFIRMED"
    case .rejectedError: "REJECTED"
    case .inconclusive: "INCONCLUSIVE"
    }
  }
}

extension GatewayCapability {
  fileprivate var displayName: String {
    switch self {
    case .passiveCapture: "Passive capture"
    case .signedExperimentPlan: "Signed experiment plans"
    case .allowlistedDiagnosticRead: "Allowlisted diagnostic reads"
    case .otaAB: "A/B OTA partitions"
    case .otaSignedImage: "Signed OTA images"
    case .otaRollbackSelfTest: "Rollback self-test"
    case .evidenceExport: "Evidence export"
    case .persistentEvidenceLog: "Persistent CAN log"
    }
  }
}
