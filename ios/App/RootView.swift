import SwiftUI
import VHOSCore

struct RootView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    TabView {
      NavigationStack { DashboardView() }
        .tabItem { Label("Garage", systemImage: "car.side") }
      NavigationStack { DiscoveryView() }
        .tabItem { Label("Discovery", systemImage: "wave.3.right.circle") }
      NavigationStack { FirmwareView() }
        .tabItem { Label("Firmware", systemImage: "arrow.triangle.2.circlepath") }
      NavigationStack { EvidenceView() }
        .tabItem { Label("Evidence", systemImage: "doc.text.magnifyingglass") }
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

private struct DashboardView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    List {
      Section("Gateway") {
        LabeledContent("State", value: model.gateway.state.rawValue)
        if let name = model.gateway.discoveredName { LabeledContent("Device", value: name) }
        if let message = model.gateway.transportMessage { Text(message).font(.footnote) }
        HStack {
          Button("Scan") { model.gateway.startScan() }
            .disabled(model.gateway.state == .scanning || model.gateway.state == .connecting)
          Spacer()
          Button("Disconnect", role: .destructive) { model.gateway.disconnect() }
            .disabled(model.gateway.state == .disconnected)
        }
      }
      if let handshake = model.gateway.handshake {
        Section("Verified contract") {
          LabeledContent("Gateway ID", value: handshake.gatewayID)
          LabeledContent("Hardware", value: handshake.hardwareRevision)
          LabeledContent("Firmware", value: handshake.firmwareVersion)
          LabeledContent("Build", value: handshake.firmwareBuildID)
          if let bootloader = handshake.bootloaderVersion {
            LabeledContent("Bootloader", value: bootloader)
          }
          LabeledContent("Mode", value: handshake.listenOnly ? "Listen only" : "Active")
        }
      }
      if let health = model.gateway.health {
        Section("Live health") {
          LabeledContent("Vehicle", value: health.vehicleMotion.rawValue)
          LabeledContent("Capture", value: health.captureActive ? "Active" : "Idle")
          LabeledContent("Received", value: health.receivedFrames.formatted())
          LabeledContent("Dropped", value: health.droppedFrames.formatted())
          if let millivolts = health.supplyMillivolts {
            LabeledContent("Supply", value: String(format: "%.2f V", Double(millivolts) / 1000))
          }
        }
      }
      if let banner = model.gateway.factoryBanner {
        Section("Factory firmware") {
          Text(banner)
          Text(
            "Factory compatibility is read-only. The app does not expose ELM or raw CAN transmit commands."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
      }
    }
    .navigationTitle("Vehicle Health OS")
  }
}

private struct DiscoveryView: View {
  @Environment(AppModel.self) private var model
  @State private var kind: DiscoveryKind = .passiveCAN
  @State private var approved = false

  private var canRun: Bool {
    model.gateway.state == .vhosConnected
      && model.gateway.health?.vehicleMotion == .parked
      && model.gateway.health?.captureActive == false
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
        SafetyRow(
          label: "Motion deterministically PARKED",
          pass: model.gateway.health?.vehicleMotion == .parked)
        SafetyRow(label: "No active capture", pass: model.gateway.health?.captureActive == false)
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
          "Update requires a current PARKED health report, idle capture, stable voltage, compatible hardware, A/B rollback capabilities, and the gateway-advertised private Wi-Fi endpoint."
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

  var body: some View {
    List {
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
    }
    .navigationTitle("Evidence")
  }
}
