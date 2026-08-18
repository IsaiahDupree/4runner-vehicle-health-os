import SwiftUI
import VHOSCore

struct RootView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    TabView {
      NavigationStack { SystemStatusView() }
        .tabItem { Label("Status", systemImage: "gauge.with.dots.needle.50percent") }
      NavigationStack { DiscoveryView() }
        .tabItem { Label("Discovery", systemImage: "wave.3.right.circle") }
      NavigationStack { FirmwareView() }
        .tabItem { Label("Firmware", systemImage: "arrow.triangle.2.circlepath") }
      NavigationStack { EvidenceView() }
        .tabItem { Label("Evidence", systemImage: "doc.text.magnifyingglass") }
      NavigationStack { ReleaseHubView() }
        .tabItem { Label("Releases", systemImage: "shippingbox.and.arrow.backward") }
    }
    .safeAreaInset(edge: .bottom) {
      if let error = model.errorMessage {
        Text(error)
          .font(.footnote)
          .foregroundStyle(.white)
          .padding(10)
          .frame(maxWidth: .infinity)
          .background(.red)
          .onTapGesture { model.errorMessage = nil }
      } else if let notice = model.noticeMessage {
        Text(notice)
          .font(.footnote)
          .padding(10)
          .frame(maxWidth: .infinity)
          .background(.thinMaterial)
          .onTapGesture { model.noticeMessage = nil }
      }
    }
  }
}

private struct ReleaseHubView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    List {
      Section("Signed catalog") {
        Text(model.releaseHub.status)
          .font(.footnote)
          .foregroundStyle(.secondary)
        Button(model.releaseHub.catalog == nil ? "Verify release catalog" : "Refresh release catalog") {
          Task {
            do { try await model.releaseHub.refresh(); model.errorMessage = nil }
            catch { model.errorMessage = error.localizedDescription }
          }
        }
        .disabled(model.releaseHub.isLoading)
      }
      if let catalog = model.releaseHub.catalog {
        ForEach(catalog.artifacts) { artifact in
          Section(releaseTitle(artifact.target)) {
            LabeledContent("Version", value: artifact.version)
            LabeledContent("Readiness", value: artifact.readiness.rawValue)
            LabeledContent("Install", value: artifact.installMethod.rawValue)
            Text(artifact.releaseNotes).font(.footnote).foregroundStyle(.secondary)
            Button(model.releaseHub.stagedURLs[artifact.artifactID] == nil ? "Download and verify" : "Verified locally") {
              Task { await model.stageRelease(artifact) }
            }
            .disabled(model.releaseHub.isLoading || model.releaseHub.stagedURLs[artifact.artifactID] != nil)
            if let staged = model.releaseHub.stagedURLs[artifact.artifactID] {
              ShareLink(item: staged) {
                Label("Share verified artifact", systemImage: "square.and.arrow.up")
              }
            }
            if artifact.kind == .esp32VHOSOTA,
              model.releaseHub.stagedURLs[artifact.artifactID] != nil
            {
              Text("Continue in Firmware. PARKED, supply, hardware, capture-flush, signature, and rollback gates still apply.")
                .font(.footnote).foregroundStyle(.orange)
            }
            if artifact.installMethod == .usbSerialInitialFlash {
              Text("USB recovery only. The iPhone cannot flash this build to the A/C ESP32-S3.")
                .font(.footnote).foregroundStyle(.orange)
            }
          }
        }
      }
    }
    .navigationTitle("Release Hub")
    .task {
      guard model.releaseHub.catalog == nil else { return }
      do { try await model.releaseHub.refresh() }
      catch { model.errorMessage = error.localizedDescription }
    }
  }

  private func releaseTitle(_ target: ReleaseTarget) -> String {
    switch target {
    case .androidHeadUnit: "Android head unit"
    case .esp32OBDGateway: "OBD/CAN ESP32"
    case .esp32ACSensorNode: "A/C ESP32-S3"
    }
  }
}

private struct DiscoveryView: View {
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
      && model.gateway.health?.vehicleMotion == .parked
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
          pass: model.gateway.health?.vehicleMotion == .parked)
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
    .navigationTitle("Protocol Discovery")
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

private struct FirmwareView: View {
  @Environment(AppModel.self) private var model
  @State private var keyText = ""
  @State private var importingFirmware = false
  @State private var confirmingUpdate = false

  var body: some View {
    Form {
      Section("Release trust") {
        Label(
          model.releasePublicKeyConfigured
            ? "Ed25519 public key configured" : "Release key required",
          systemImage: model.releasePublicKeyConfigured ? "checkmark.shield.fill" : "shield.slash"
        )
        TextField("32-byte key as base64 or 64 hex characters", text: $keyText, axis: .vertical)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Button("Save verification key") {
          model.importReleasePublicKey(keyText)
          keyText = ""
        }
        .disabled(keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      Section("Signed package") {
        Button("Select .vhosota package") { importingFirmware = true }
          .disabled(!model.releasePublicKeyConfigured)
        if let package = model.verifiedFirmware {
          LabeledContent("File", value: model.selectedFirmwareName ?? "Verified package")
          LabeledContent("Version", value: package.manifest.firmwareVersion)
          LabeledContent("Build", value: package.manifest.firmwareBuildID)
          LabeledContent("Channel", value: package.manifest.releaseChannel)
          LabeledContent(
            "Image",
            value: ByteCountFormatter.string(
              fromByteCount: Int64(package.firmware.count), countStyle: .file))
        }
      }
      Section("Install") {
        Text(
          "Update requires a current PARKED health report, stable voltage, compatible hardware, and signed A/B rollback support. The app pauses and flushes the recorder, opens a hidden one-client gateway network over encrypted BLE, uploads, then removes that network from the iPhone."
        )
        .font(.footnote)
        Button("Run preflight and install") { confirmingUpdate = true }
          .disabled(model.verifiedFirmware == nil || model.updateInProgress)
        if let progress = model.uploadProgressDescription { Text(progress).font(.footnote) }
      }
    }
    .navigationTitle("Firmware")
    .fileImporter(
      isPresented: $importingFirmware, allowedContentTypes: [.data], allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        if let url = urls.first { model.importFirmware(from: url) }
      case .failure(let error):
        model.errorMessage = error.localizedDescription
      }
    }
    .confirmationDialog(
      "Install verified firmware?",
      isPresented: $confirmingUpdate,
      titleVisibility: .visible
    ) {
      Button("Install on gateway") { Task { await model.installVerifiedFirmware() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Keep the 4Runner parked and gateway power stable until probationary boot and POST complete."
      )
    }
  }
}

private struct EvidenceView: View {
  @Environment(AppModel.self) private var model
  @State private var exportURL: URL?
  @State private var canExportURL: URL?
  @State private var bleTraceExportURL: URL?
  @State private var syncExportURL: URL?
  @State private var importingSync = false
  @State private var outboxEndpoint = ""
  @State private var outboxToken = ""
  @State private var referencePreset: TechstreamReferencePreset = .engineSpeed
  @State private var referenceValue = ""
  @State private var referenceExportURL: URL?

  var body: some View {
    List {
      Section("Passive CAN flight recorder") {
        LabeledContent("Gateway capture") {
          Text(model.gateway.health?.captureActive == true ? "RECORDING" : "WAITING")
            .foregroundStyle(model.gateway.health?.captureActive == true ? .green : .secondary)
        }
        if let index = model.gateway.captureLogIndex {
          LabeledContent("Observed frames", value: index.observedFrames.formatted())
          LabeledContent("Retained records", value: index.retainedRecords.formatted())
          LabeledContent(
            "On-device logs",
            value: "\(index.previousRecords + index.currentRecords) records")
          LabeledContent(
            "Storage free",
            value: ByteCountFormatter.string(
              fromByteCount: Int64(index.freeBytes), countStyle: .file))
          if index.queueDroppedRecords > 0 || index.storageWriteFailures > 0 {
            Label(
              "\(index.queueDroppedRecords) queue drops; \(index.storageWriteFailures) write failures",
              systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
          }
        }
        Text(model.gateway.captureSyncMessage)
          .font(.footnote)
          .foregroundStyle(.secondary)
        Button("Refresh and sync gateway logs") {
          model.gateway.refreshCaptureLogIndex()
        }
        .disabled(model.gateway.state != .vhosConnected)
      }
      Section("Recent logs on iPhone") {
        if model.gateway.captureSessions.isEmpty {
          ContentUnavailableView(
            "No synchronized logs",
            systemImage: "externaldrive.badge.wifi",
            description: Text(
              "The app automatically downloads the gateway's current and previous capture segments after reconnecting."))
        } else {
          ForEach(model.gateway.captureSessions.prefix(12)) { session in
            VStack(alignment: .leading, spacing: 4) {
              Text("Session \(session.sessionID)").font(.headline)
              Text(session.gatewayID).font(.caption).foregroundStyle(.secondary)
              Text(
                "\(session.recordCount.formatted()) records • \(ByteCountFormatter.string(fromByteCount: session.byteCount, countStyle: .file))"
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
          }
          Button("Prepare passive CAN export") {
            do { canExportURL = try model.passiveCANExportURL() } catch {
              model.errorMessage = error.localizedDescription
            }
          }
          if let canExportURL {
            ShareLink(item: canExportURL) {
              Label("Share passive-can-recent-logs.ndjson", systemImage: "square.and.arrow.up")
            }
          }
        }
      }
      Section("Bluetooth connection flight recorder") {
        let trace = model.gateway.bleConnectionTraceSummary
        LabeledContent("Connection events", value: trace.recordCount.formatted())
        LabeledContent("Rotated files", value: trace.fileCount.formatted())
        LabeledContent(
          "Storage used",
          value: ByteCountFormatter.string(fromByteCount: trace.byteCount, countStyle: .file))
        Text(
          "The iPhone records app-observable scan, selection, link, GATT, subscription, "
            + "handshake, timeout, disconnect, and reconnect events as bounded NDJSON. "
            + "It does not expose pairing keys or raw Bluetooth controller packets."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        Button("Prepare Bluetooth connection log") {
          do { bleTraceExportURL = try model.bleConnectionTraceExportURL() } catch {
            model.errorMessage = error.localizedDescription
          }
        }
        if let bleTraceExportURL {
          ShareLink(item: bleTraceExportURL) {
            Label(
              "Share ble-connection-flight-recorder.ndjson",
              systemImage: "square.and.arrow.up"
            )
          }
        }
      }
      if let observation = model.gateway.latestCANObservation {
        Section("Latest live CAN observation") {
          LabeledContent("Identifier", value: "0x\(observation.identifierHex)")
          LabeledContent("Data", value: observation.dataHex)
          LabeledContent("Bitrate", value: "\(observation.bitrateBps / 1_000) kbit/s")
          LabeledContent("Sequence", value: observation.sourceSequence.formatted())
          Text("Live display is sampled; the gateway flight recorder is the durable evidence source.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      Section("Standard read-only OBD") {
        if model.gateway.j1979Availability.isEmpty {
          ContentUnavailableView(
            "No supported-PID evidence",
            systemImage: "car.front.waves.up",
            description: Text(
              "The production gateway remains default-deny until PARKED and signed-plan safety gates are available."
            ))
        } else {
          ForEach(model.gateway.j1979Availability) { ecu in
            VStack(alignment: .leading, spacing: 4) {
              Text("ECU \(ecu.ecuAddress)").font(.headline)
              Text(
                ecu.enumerationComplete
                  ? "\(ecu.supportedPIDs.count) supported Mode 01 PIDs; enumeration complete"
                  : ecu.incompleteReason ?? "Enumeration incomplete"
              )
              .font(.caption)
              .foregroundStyle(ecu.enumerationComplete ? .green : .orange)
            }
          }
          ForEach(latestStandardOBDSamples) { sample in
            LabeledContent(sample.name) {
              Text("\(sample.value.formatted(.number.precision(.fractionLength(0...3)))) \(sample.unit)")
            }
          }
          Text(
            "Values appear only after the same ECU completes its supported-PID bitmap chain. Raw response evidence and the pinned definition revision are retained."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
      }
      Section("Synchronized Techstream / OBD reference") {
        LabeledContent("Retained samples", value: model.synchronizedReferenceCount.formatted())
        Text(model.synchronizedReferenceMessage)
          .font(.footnote)
          .foregroundStyle(.secondary)
        Picker("Reference signal", selection: $referencePreset) {
          ForEach(TechstreamReferencePreset.allCases) { preset in
            Text(preset.label).tag(preset)
          }
        }
        TextField("Techstream value (\(referencePreset.unit))", text: $referenceValue)
          .keyboardType(.numbersAndPunctuation)
        Button("Record at current gateway CAN time") {
          model.recordTechstreamReference(
            signalID: referencePreset.signalID,
            valueText: referenceValue,
            unit: referencePreset.unit
          )
          if model.errorMessage == nil { referenceValue = "" }
        }
        .disabled(
          model.gateway.latestCANObservation == nil
            || referenceValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Prepare synchronized reference CSV") {
          do { referenceExportURL = try model.synchronizedReferenceExportURL() } catch {
            model.errorMessage = error.localizedDescription
          }
        }
        .disabled(model.synchronizedReferenceCount == 0)
        if let referenceExportURL {
          ShareLink(item: referenceExportURL) {
            Label("Share synchronized-reference-samples.csv", systemImage: "square.and.arrow.up")
          }
        }
        Text(
          "For one validation run, keep passive capture active, vary one input at a time, and record at least five Techstream values for engine speed, steering angle, and accelerator position. Standard J1979 values are retained here automatically. The analyzer only produces candidates; it never promotes Toyota CAN meanings by correlation alone."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
      Section("Experiment results") {
        if model.gateway.experimentResults.isEmpty {
          ContentUnavailableView(
            "No evidence yet", systemImage: "waveform.path.ecg",
            description: Text("Completed gateway experiments appear here."))
        } else {
          ForEach(Array(model.gateway.experimentResults.enumerated()), id: \.offset) { _, result in
            VStack(alignment: .leading) {
              Text(result.candidate.protocolID.rawValue).font(.headline)
              Text(result.outcome.rawValue)
              Text("Capture \(result.captureID)").font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
      Section("AI handoff") {
        Text(
          "The export contains gateway/config identity, experiment outcomes, checksums, and evidence references. It grants interpretation and proposal authority only."
        )
        .font(.footnote)
        Button("Prepare evidence package") {
          do { exportURL = try model.evidenceExportURL() } catch {
            model.errorMessage = error.localizedDescription
          }
        }
        if let exportURL {
          ShareLink(item: exportURL) {
            Label("Share agent-evidence-handoff.json", systemImage: "square.and.arrow.up")
          }
        }
      }
      Section("Private AI evidence outbox") {
        LabeledContent("Queued", value: model.evidenceOutboxPendingCount.formatted())
        LabeledContent("Uploaded", value: model.evidenceOutboxUploadedCount.formatted())
        Text(model.evidenceOutboxMessage)
          .font(.footnote)
          .foregroundStyle(.secondary)
        TextField("https://private-inbox.example/v1/evidence/packages", text: $outboxEndpoint)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
        SecureField(
          model.evidenceOutboxTokenConfigured ? "Bearer token saved in Keychain" : "Bearer token",
          text: $outboxToken)
        Button("Save private inbox") {
          model.configureEvidenceOutbox(endpointText: outboxEndpoint, bearerToken: outboxToken)
          outboxToken = ""
        }
        .disabled(outboxEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Toggle(
          "Upload automatically",
          isOn: Binding(
            get: { model.automaticEvidenceUpload },
            set: { model.setAutomaticEvidenceUpload($0) }
          ))
        Button("Queue current checksummed evidence") { model.queueCurrentEvidenceForAI() }
          .disabled(model.gateway.portableFrameCount == 0)
        Button("Send queued packages now") { Task { await model.processEvidenceOutbox() } }
          .disabled(
            model.evidenceOutboxPendingCount == 0 || model.evidenceOutboxUploadInProgress)
        Text(
          "Packages remain private and append-only. The receiver gets a SHA-256-bound envelope and interpretation/proposal authority only; it cannot activate experiments or emit vehicle frames."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
      Section("Android / iPhone evidence sync") {
        LabeledContent("Validated logical frames", value: model.gateway.portableFrameCount.formatted())
        Text(model.gateway.lastEvidenceSyncMessage)
          .font(.footnote)
          .foregroundStyle(.secondary)
        Button("Prepare checksummed .vhossync bundle") {
          do { syncExportURL = try model.evidenceSyncExportURL() } catch {
            model.errorMessage = error.localizedDescription
          }
        }
        if let syncExportURL {
          ShareLink(item: syncExportURL) {
            Label("Share vhos-evidence-sync.vhossync", systemImage: "arrow.left.arrow.right.circle")
          }
        }
        Button("Import Android/iPhone sync bundle") { importingSync = true }
        Text(
          "Import is append-only. The manifest, ZIP CRC, segment SHA-256, envelope SHA-256, VHOS CRC32C, and envelope metadata must all agree before any record is retained."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Evidence")
    .fileImporter(
      isPresented: $importingSync,
      allowedContentTypes: [.data],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        if let url = urls.first { model.importEvidenceSync(from: url) }
      case .failure(let error):
        model.errorMessage = error.localizedDescription
      }
    }
    .onAppear { outboxEndpoint = model.evidenceOutboxEndpoint }
  }

  private var latestStandardOBDSamples: [J1979StandardSample] {
    var latest: [String: J1979StandardSample] = [:]
    for sample in model.gateway.standardOBDSamples {
      latest["\(sample.ecuAddress):\(sample.signalID)"] = sample
    }
    return latest.values.sorted { $0.name < $1.name }
  }
}

private enum TechstreamReferencePreset: String, CaseIterable, Identifiable {
  case engineSpeed
  case steeringAngle
  case acceleratorPosition

  var id: String { rawValue }
  var label: String {
    switch self {
    case .engineSpeed: "Engine speed → test 0x2C4"
    case .steeringAngle: "Steering angle → test 0x025"
    case .acceleratorPosition: "Accelerator position → test 0x2C1"
    }
  }
  var signalID: String {
    switch self {
    case .engineSpeed: "reference.engine.speed"
    case .steeringAngle: "reference.steering.angle"
    case .acceleratorPosition: "reference.accelerator.position"
    }
  }
  var unit: String {
    switch self {
    case .engineSpeed: "rpm"
    case .steeringAngle: "deg"
    case .acceleratorPosition: "%"
    }
  }
}
