import SwiftUI
import VHOSCore

private enum StudioPalette {
  static let background = Color(white: 0.12)
  static let panel = Color(white: 0.18)
  static let accent = Color.white
  static let teal = Color.green
}

extension LightingColor {
  var displayColor: Color { Color(red: Double(red)/255, green: Double(green)/255, blue: Double(blue)/255) }
}

private enum LightingPage: String, CaseIterable {
  case colors = "Colors", effects = "Effects", segments = "Segments", presets = "Presets"
  var icon: String {
    switch self { case .colors: "paintpalette"; case .effects: "sparkles";
      case .segments: "slider.horizontal.3"; case .presets: "list.bullet.rectangle" }
  }
}

struct LightingStudioView: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var studio = LightingStudioModel()
  @State private var page: LightingPage = .colors
  @State private var configuration = false

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        HStack(spacing: 18) {
          VStack(alignment: .leading, spacing: 3) {
            Text("4Runner Lighting").font(.headline.bold())
            Text(studio.connected ? "Connected · \(studio.status?.mode ?? "")" : "Controller offline")
              .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("LightingConnectionStatus")
          }
          Spacer(minLength: 0)
          Button { Task { await studio.power() } } label: {
            Image(systemName: "power").font(.title3).frame(width: 44, height: 44)
              .background(studio.status.map { $0.mode != "off" } == true ? Color.white.opacity(0.25) : Color.white.opacity(0.06), in: Circle())
          }.buttonStyle(.plain).disabled(!studio.connected || studio.busy)
            .accessibilityLabel("Power").accessibilityIdentifier("LightingPower")
          Button { configuration = true } label: {
            Image(systemName: "gearshape").font(.title3).frame(width: 38, height: 44)
          }.buttonStyle(.plain).accessibilityLabel("Config").accessibilityIdentifier("LightingConfig")
        }.padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 5)
        StudioLevel(title: "Brightness", value: $studio.color.brightness, symbol: "sun.max") {
          Task { await studio.applyColor() }
        }.padding(.horizontal, 18).padding(.bottom, 12)
        Divider()
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 16) {
              Color.clear.frame(height: 0).id("lighting-top")
              if let notice = studio.notice {
                Button { studio.dismissNotice() } label: {
                  HStack(alignment: .top) {
                    Text(notice).font(.footnote).multilineTextAlignment(.leading)
                    Spacer(minLength: 0); Image(systemName: "xmark").font(.caption)
                  }.padding(11).background(StudioPalette.panel, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityIdentifier("LightingNotice")
              }
              switch page {
              case .colors: LightingColorsPage(studio: studio)
              case .effects: LightingEffectsPage(studio: studio)
              case .segments: LightingSegmentsPage(studio: studio)
              case .presets: LightingPresetsPage(studio: studio)
              }
            }.padding(.horizontal, 18).padding(.bottom, 16)
          }.onChange(of: page) { _, _ in proxy.scrollTo("lighting-top", anchor: .top) }
        }
        Divider()
        HStack(spacing: 0) {
          ForEach(LightingPage.allCases, id: \.self) { item in
            Button { page = item } label: {
              VStack(spacing: 6) {
                Image(systemName: item.icon).font(.system(size: 20, weight: page == item ? .bold : .regular))
                Text(item.rawValue).font(.system(size: 11, weight: page == item ? .bold : .regular))
              }.foregroundStyle(page == item ? Color.white : Color.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(page == item ? Color.white.opacity(0.06) : .clear)
            }.buttonStyle(.plain).accessibilityIdentifier("LightingTab\(item.rawValue)")
              .accessibilityAddTraits(page == item ? .isSelected : [])
          }
        }.background(StudioPalette.panel)
      }.background(StudioPalette.background)
        .toolbar(.hidden, for: .navigationBar)
    }
    .tint(.white).preferredColorScheme(.dark)
    .sheet(isPresented: $configuration) {
      NavigationStack {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) { LightingSetupPage(studio: studio) }.padding(18)
        }.background(StudioPalette.background)
          .navigationTitle("Config").navigationBarTitleDisplayMode(.inline)
          .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { configuration = false } } }
      }.tint(.white).preferredColorScheme(.dark)
    }
    .task(id: "\(scenePhase == .active)-\(studio.connectionGeneration)-\(studio.wantsConnection)") {
      if scenePhase == .active && studio.wantsConnection { await studio.poll() }
    }
    .onChange(of: scenePhase) { _, phase in if phase != .active { Task { await studio.suspend() } } }
    .onDisappear { Task { await studio.disconnect() } }
  }
}

private struct StudioCard<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 14) { content }
      .padding(15).frame(maxWidth: .infinity, alignment: .leading)
      .background(StudioPalette.panel, in: RoundedRectangle(cornerRadius: 10))
  }
}

private struct LightingColorsPage: View {
  @Bindable var studio: LightingStudioModel
  @State private var hex = ""
  private let swatches: [(String, LightingColor)] = [
    ("Red", .init(red:255,green:0,blue:0)), ("Amber", .init(red:255,green:160,blue:0)),
    ("Yellow", .init(red:255,green:200,blue:0)), ("White", .init(red:255,green:255,blue:255)),
    ("Violet", .init(red:255,green:0,blue:255)), ("Blue", .init(red:0,green:0,blue:255)),
    ("Teal", .init(red:0,green:255,blue:200)), ("Green", .init(red:8,green:255,blue:0))
  ]
  var body: some View {
    HStack {
      Text("Colors").font(.title3.bold())
      Spacer()
      Menu {
        Button {} label: { Label(studio.segmentName, systemImage: "checkmark") }
      } label: {
        HStack(spacing: 6) {
          Text(studio.segmentName).font(.subheadline.bold())
          Image(systemName: "chevron.down").font(.caption2)
        }.padding(.horizontal, 13).padding(.vertical, 10)
          .background(StudioPalette.panel, in: RoundedRectangle(cornerRadius: 8))
      }.accessibilityLabel("Target segment").accessibilityIdentifier("LightingSegmentSelector")
    }
    HStack {
      Spacer(minLength: 0)
      LightingWheel(color: $studio.editingColor) { Task { await studio.applyColor() } }
        .frame(width: 260, height: 260)
      Spacer(minLength: 0)
    }
    HStack(spacing: 24) {
      Spacer()
      ForEach(0..<3) { slot in
        Button { studio.colorSlot = slot } label: {
          Text("\(slot+1)").font(.system(size: 14, weight: .bold))
            .foregroundStyle(slotColor(slot).red + slotColor(slot).green + slotColor(slot).blue > 600 ? .black : .white)
            .frame(width: 38, height: 38).background(slotColor(slot).displayColor, in: Circle())
            .overlay(Circle().stroke(studio.colorSlot == slot ? .white : .gray.opacity(0.4), lineWidth: studio.colorSlot == slot ? 3 : 1).padding(-4))
        }.buttonStyle(.plain).accessibilityLabel("Color slot \(slot+1)")
          .accessibilityIdentifier("LightingColorSlot\(slot)")
      }
      Spacer()
    }.padding(.vertical, 4)
    StudioLevel(title: "White channel", value: $studio.editingColor.white, symbol: "sun.min") { Task { await studio.applyColor() } }
    HStack(spacing: 10) {
      ForEach(swatches, id: \.0) { name, color in
        Button {
          var updated = studio.editingColor
          updated.red = color.red; updated.green = color.green; updated.blue = color.blue
          studio.editingColor = updated
          Task { await studio.applyColor() }
        } label: { Circle().fill(color.displayColor).frame(width: 28, height: 28).overlay(Circle().stroke(.white.opacity(0.2))) }
          .buttonStyle(.plain).accessibilityLabel(name).accessibilityIdentifier("LightingSwatch\(name)")
      }
    }.frame(maxWidth: .infinity)
    HStack(spacing: 12) {
      Text("HEX").font(.caption.bold()).foregroundStyle(.secondary)
      TextField("RRGGBB", text: $hex).font(.body.monospaced()).textInputAutocapitalization(.characters)
        .autocorrectionDisabled().onSubmit { applyHex() }.accessibilityIdentifier("LightingHex")
      Button { applyHex() } label: { Image(systemName: "checkmark").frame(width: 32, height: 32) }
        .accessibilityLabel("Apply hex color")
    }.padding(8).background(StudioPalette.panel, in: RoundedRectangle(cornerRadius: 8))
    HStack {
      Text("Color palette").font(.subheadline.bold())
      Spacer()
      Menu {
        ForEach(studio.palettes.indices, id: \.self) { i in
          Button(studio.palettes[i]) { studio.selectedPalette = i; Task { await studio.applyColor() } }
        }
      } label: { Label(studio.paletteName, systemImage: "chevron.down").font(.subheadline) }
        .disabled(studio.palettes.isEmpty)
    }
    if !studio.connected { Text("Color preview · connect to send changes").font(.caption).foregroundStyle(.secondary) }
    else { Text(studio.status?.reason ?? "").font(.caption).foregroundStyle(.secondary) }
    Text("Analog RGBW · one whole-strip segment").font(.caption2).foregroundStyle(.secondary)
      .onAppear { hex = studio.editingColor.hex }
      .onChange(of: studio.editingColor) { _, color in hex = color.hex }
  }
  private func slotColor(_ slot: Int) -> LightingColor { slot == 1 ? studio.secondary : slot == 2 ? studio.tertiary : studio.color }
  private func applyHex() {
    let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
    guard clean.count == 6, let value = UInt32(clean, radix: 16) else { hex = studio.editingColor.hex; return }
    var updated = studio.editingColor
    updated.red = Int(value >> 16); updated.green = Int((value >> 8) & 255); updated.blue = Int(value & 255)
    studio.editingColor = updated; Task { await studio.applyColor() }
  }
}

private struct LightingWheel: View {
  @Binding var color: LightingColor
  let changed: () -> Void
  private let hues: [Color] = (0...6).map { Color(hue: Double($0)/6, saturation: 1, brightness: 1) }
  var body: some View {
    GeometryReader { bounds in
      let diameter = min(bounds.size.width,bounds.size.height)
      let point = LightingColorWheel.position(for: color, diameter: diameter)
      ZStack(alignment: .topLeading) {
        Circle().fill(AngularGradient(colors: hues, center: .center, startAngle: .degrees(0), endAngle: .degrees(360)))
          .overlay(Circle().fill(RadialGradient(colors: [.white,.white.opacity(0)],center:.center,startRadius:0,endRadius:diameter/2)))
          .overlay(Circle().stroke(.white.opacity(0.3),lineWidth:1))
        Circle().fill(color.displayColor).frame(width:25,height:25)
          .overlay(Circle().stroke(.white,lineWidth:3)).shadow(color:.black.opacity(0.5),radius:2)
          .position(x:point.x,y:point.y)
      }.frame(width:diameter,height:diameter)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance:0).onChanged { gesture in
          color = LightingColorWheel.color(x:gesture.location.x,y:gesture.location.y,diameter:diameter,preserving:color)
        }.onEnded { _ in changed() })
        .accessibilityElement(children:.ignore).accessibilityLabel("Color wheel").accessibilityValue(color.hex)
        .accessibilityIdentifier("LightingColorWheel")
    }
  }
}

private struct StudioLevel: View {
  let title: String
  @Binding var value: Int
  let symbol: String
  var finished: () -> Void = {}
  var body: some View {
    VStack(spacing: 5) {
      HStack {
        Label(title,systemImage:symbol).font(.subheadline.bold())
        Spacer(); Text("\(Int((Double(value)*100/255).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      }
      Slider(value:Binding(get:{Double(value)},set:{value=Int($0.rounded())}),in:0...255,step:1,
        onEditingChanged:{ if !$0 { finished() } }).accessibilityLabel(title)
    }
  }
}

private struct LightingEffectsPage: View {
  @Bindable var studio: LightingStudioModel
  @State private var search = ""
  var body: some View {
    Text("Effects").font(.title3.bold())
    TextField("Search effects",text:$search).padding(11).background(StudioPalette.panel,in:RoundedRectangle(cornerRadius:8))
    StudioLevel(title:"Speed",value:$studio.effectSpeed,symbol:"speedometer") { Task { await studio.applyColor() } }
    StudioLevel(title:"Intensity",value:$studio.effectIntensity,symbol:"dial.medium") { Task { await studio.applyColor() } }
    if studio.effects.isEmpty {
      Text("Connect to load this controller’s WLED effects.").font(.subheadline).foregroundStyle(.secondary)
    } else {
      LazyVStack(spacing:5) {
        ForEach(studio.effects.indices.filter { !["RSVD","-"].contains(studio.effects[$0]) && (search.isEmpty || studio.effects[$0].localizedCaseInsensitiveContains(search)) },id:\.self) { id in
          Button { studio.selectedEffect=id; Task { await studio.applyColor() } } label: {
            HStack { Text(studio.effects[id]).font(.body.weight(studio.selectedEffect == id ? .bold : .regular));Spacer()
              if studio.selectedEffect == id { Image(systemName:"checkmark") }
            }.padding(13).background(StudioPalette.panel,in:RoundedRectangle(cornerRadius:8))
          }.buttonStyle(.plain)
        }
      }
    }
    Text("The whole analog strip changes together. Multi-pixel chases require addressable LEDs.").font(.caption).foregroundStyle(.secondary)
  }
}

private struct LightingSegmentsPage: View {
  @Bindable var studio: LightingStudioModel
  var body: some View {
    Text("Segments").font(.title3.bold())
    StudioCard {
      HStack { Image(systemName:"checkmark.circle.fill");Text(studio.segmentName).font(.headline);Spacer();Text("0").foregroundStyle(.secondary) }
      Text("Analog RGBW output").font(.subheadline).foregroundStyle(.secondary)
      if let segment=studio.segments.first {
        HStack { Text("Start: \(segment.start.map(String.init) ?? "—")");Spacer();Text("Stop: \(segment.stop.map(String.init) ?? "—")") }.font(.caption.monospacedDigit())
      }
      Text("This board provides one physical color zone. Independent sections require addressable LEDs or additional output channels.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}

private struct LightingPresetsPage: View {
  @Bindable var studio: LightingStudioModel
  @State private var creating=false
  @State private var name=""
  @State private var slot=""
  @State private var overwrite=false
  @State private var deleting: LightingWLEDPreset?
  var body: some View {
    HStack { Text("Presets").font(.title3.bold());Spacer();Button { Task { await studio.refreshPresets() } } label:{Image(systemName:"arrow.clockwise")}.disabled(!studio.connected) }
    Button {
      slot=(1...250).first(where:{id in !studio.presets.contains(where:{$0.id==id})}).map(String.init) ?? ""
      creating=true
    } label:{Label("Create preset",systemImage:"plus").frame(maxWidth:.infinity).padding(8)}
      .buttonStyle(.bordered).disabled(!studio.connected || !studio.wledAvailable || studio.busy)
      .accessibilityIdentifier("LightingCreatePreset")
    if !studio.connected {
      Text("Connect to load presets saved on the WLED controller.").font(.subheadline).foregroundStyle(.secondary)
    } else if studio.presetsAvailable && studio.presets.isEmpty {
      Text("No presets saved on this controller.").font(.subheadline).foregroundStyle(.secondary)
    } else {
      ForEach(studio.presets) { preset in
        Button { Task { await studio.loadPreset(preset) } } label:{
          HStack { Text("\(preset.id)").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width:26)
            Text(preset.name).font(.body.bold());Spacer();Image(systemName:"play.fill").font(.caption)
          }.padding(14).background(StudioPalette.panel,in:RoundedRectangle(cornerRadius:8))
        }.buttonStyle(.plain).disabled(!studio.outputReady)
          .contextMenu { Button("Delete preset",role:.destructive){deleting=preset} }
      }
    }
    Text("Presets are stored on the controller, using WLED’s preset system.").font(.caption).foregroundStyle(.secondary)
      .task { await studio.refreshPresets() }
      .sheet(isPresented:$creating){
        NavigationStack {
          Form {
            Section("Save current controller state") {
              TextField("Preset name",text:$name)
              TextField("Preset ID · 1–250",text:$slot).keyboardType(.numberPad)
              Text("Includes brightness and colors. Segment bounds stay unchanged.").font(.caption).foregroundStyle(.secondary)
            }
          }.navigationTitle("Create preset").navigationBarTitleDisplayMode(.inline)
            .toolbar {
              ToolbarItem(placement:.cancellationAction){Button("Cancel"){creating=false}}
              ToolbarItem(placement:.confirmationAction){Button("Save"){
                if let id=Int(slot),studio.presets.contains(where:{$0.id==id}){overwrite=true}
                else{save()}
              }.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !(Int(slot).map{(1...250).contains($0)} ?? false))}
            }
            .alert("Overwrite this controller preset?",isPresented:$overwrite){Button("Overwrite",role:.destructive){save()};Button("Cancel",role:.cancel){}}
        }.tint(.white).preferredColorScheme(.dark)
      }
      .confirmationDialog("Delete this controller preset?",isPresented:Binding(get:{deleting != nil},set:{if !$0{deleting=nil}})) {
        Button("Delete",role:.destructive){if let preset=deleting{Task{await studio.deletePreset(preset)}};deleting=nil}
      }
  }
  private func save(){guard let id=Int(slot) else{return};Task{await studio.savePreset(id:id,name:name)};creating=false}
}

private struct LightingAutomationPage: View {
  @Bindable var studio: LightingStudioModel
  @State private var signal: LightingRelaySignal = .rpm
  @State private var on = ""
  @State private var off = ""
  var body: some View {
    Text("CAN automation").font(.title2.bold())
    StudioCard {
      HStack {
        Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(StudioPalette.teal)
        Text("CAN gateway").font(.headline); Spacer()
        Text(studio.gateway.applicationSessionHealthy ? "Verified" : "Offline").font(.caption).foregroundStyle(.secondary)
      }
      Text(studio.gateway.transportMessage ?? "Your existing VHOS gateway connects over Bluetooth.").font(.caption).foregroundStyle(.secondary)
      Button(studio.gateway.applicationSessionHealthy ? "Release gateway" : "Connect gateway") {
        if studio.gateway.applicationSessionHealthy { studio.gateway.disconnect() }
        else { studio.gateway.startScan(source: "lighting-studio") }
      }.buttonStyle(.bordered).disabled(studio.gateway.connectionCleanupActive)
      NavigationLink("Gateway details") { SystemStatusView() }
    }
    StudioCard {
      HStack { Text("CAN rule").font(.title3.bold()); Spacer(); Image(systemName: "waveform.path").foregroundStyle(StudioPalette.accent) }
      Picker("Parameter", selection: $signal) {
        ForEach(LightingRelaySignal.allCases) { Text($0.label).tag($0) }
      }.tint(.primary).onChange(of: signal) { _, _ in on = ""; off = "" }
      StudioField(label: "Turn on at or above · \(signal.controlUnit)", text: $on)
      StudioField(label: "Turn off below · \(signal.controlUnit)", text: $off)
      Text("Uses your current RGBW preview and requested brightness. Lower off thresholds add hysteresis.").font(.caption).foregroundStyle(.secondary)
      Button("Load controller rule") { load() }.disabled(!studio.connected)
      Button { Task { await studio.saveRule(signal: signal, on: on, off: off) } } label: {
        Text("Save rule to controller").frame(maxWidth: .infinity).padding(8)
      }.buttonStyle(.borderedProminent).disabled(!studio.connected || studio.busy || on.isEmpty || off.isEmpty)
    }
    StudioCard {
      Text(studio.relay.running ? "Relay active" : "CAN relay").font(.title3.bold())
      Text(studio.relay.message).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("LightingRelayStatus")
      TextField("ECU address · optional unless responses are ambiguous", text: $studio.ecu)
        .font(.footnote).textInputAutocapitalization(.never).autocorrectionDisabled()
        .padding(12).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
      Button {
        if studio.relay.running { Task { await studio.relay.stop() } } else { studio.startRelay() }
      } label: {
        Label(studio.relay.running ? "Stop relay" : "Start CAN relay", systemImage: studio.relay.running ? "stop.fill" : "play.fill")
          .frame(maxWidth: .infinity).padding(8)
      }.buttonStyle(.borderedProminent)
        .disabled(!studio.relay.running && (!studio.outputReady || !studio.gateway.applicationSessionHealthy))
      Text("The relay uses the rule currently on the controller. Keep this app in the foreground. Backgrounding stops the relay; stale samples expire after 2.5 seconds.")
        .font(.caption).foregroundStyle(.secondary)
    }
    Text("Supported J1979 data and current verified CAN activity only. Unavailable or ambiguous data stays unavailable; no vehicle-control commands are sent.")
      .font(.caption).foregroundStyle(.secondary)
      .onAppear { load() }
  }
  private func load() {
    guard let c = studio.status?.config, let s = LightingRelaySignal(rawValue: c.signal) else { return }
    signal = s
    // Defer fields until Picker's signal-change reset has run.
    Task { @MainActor in
      await Task.yield(); on = String(Double(c.onCenti)/100); off = String(Double(c.offCenti)/100)
    }
  }
}

private struct StudioField: View {
  let label: String
  @Binding var text: String
  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(label).font(.caption).foregroundStyle(.secondary)
      TextField("Measured value", text: $text).keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never)
        .autocorrectionDisabled().font(.body.monospacedDigit()).padding(12)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel(label)
    }
  }
}

private struct LightingSetupPage: View {
  @Bindable var studio: LightingStudioModel
  @State private var tail = false
  @State private var dim = false
  @State private var tailOn = ""
  @State private var tailOff = ""
  @State private var dimMin = ""
  @State private var dimMax = ""
  @State private var dimLow = ""
  @State private var dimHigh = ""
  @State private var lowADC = ""
  @State private var lowMeter = ""
  @State private var highADC = ""
  @State private var highMeter = ""
  var body: some View {

    connectionCard
    NavigationLink {
      ScrollView { VStack(alignment: .leading, spacing: 16) { LightingAutomationPage(studio: studio) }.padding(18) }
        .background(StudioPalette.background).navigationTitle("CAN").navigationBarTitleDisplayMode(.inline)
    } label: { Label("CAN automation", systemImage: "waveform.path").font(.headline).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(StudioPalette.panel, in: RoundedRectangle(cornerRadius: 10)) }
    voltageCard
    inputsCard
    wiringCard
    StudioCard {
      Text("Controller tools").font(.headline)
      Link("Open WLED setup", destination: LightingRelayCommand.controller)
      Link("Open the head-unit control page", destination: LightingRelayCommand.controller.appending(path: "vhos/ui"))
      Text("Set the private AP password, one analog RGBW bus (18/17/14/2), relay key and output arming in WLED. This app does not bypass commissioning or power limits.")
        .font(.caption).foregroundStyle(.secondary)
    }
    Text("Evaluation hardware · 500 mA/channel, 1 A combined electrical screen. Output follows protected vehicle voltage. Installed strip length, current, sealing and vehicle wiring need physical qualification.")
      .font(.caption).foregroundStyle(.secondary)
  }
  private var connectionCard: some View {
    StudioCard {
      Label("Your lighting controller", systemImage: "wifi").font(.headline)
      Text(studio.connectionMessage).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("LightingConnectionStatus")
      if let notice = studio.notice { Text(notice).font(.footnote).foregroundStyle(.yellow) }
      Text("Join 4Runner-Lighting in iPhone Wi-Fi settings. The controller is at 192.168.88.1.").font(.caption).foregroundStyle(.secondary)
      SecureField("Controller relay key", text: $studio.keyText).textInputAutocapitalization(.never).autocorrectionDisabled()
        .padding(12).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .disabled(studio.connected).accessibilityIdentifier("LightingRelayKey")
      Toggle("Remember key in this iPhone’s Keychain", isOn: $studio.rememberKey).font(.caption).disabled(studio.connected)
      Button {
        if studio.connected || studio.wantsConnection { Task { await studio.disconnect() } } else { studio.connect() }
      } label: {
        Text(studio.connected || studio.wantsConnection ? "Disconnect" : "Connect controller")
          .frame(maxWidth: .infinity).padding(8)
      }.buttonStyle(.borderedProminent).disabled(!studio.wantsConnection && !studio.validKey)
      if let s = studio.status { Text("\(s.board) · \(s.armed ? "Armed" : "Disarmed") · \(s.configurationPendingSave ? "Save scheduled" : "No save pending")").font(.caption2).foregroundStyle(.secondary) }
    }
  }
  private var voltageCard: some View {
    StudioCard {
      Label("Supply voltage · Rev I", systemImage: "bolt.heart").font(.headline)
      LabeledContent("ACC supply", value: voltageText).font(.headline.monospacedDigit()).accessibilityIdentifier("LightingVoltage")
      Text(studio.status?.voltage.quality ?? "No live reading").font(.caption).foregroundStyle(.secondary)
      Text("Senses ACC_FUSED at the controller after the main fuse. ACC-off resting battery voltage is unavailable.").font(.caption).foregroundStyle(.secondary)
      HStack {
        Text("Supply ADC").font(.caption)
        Spacer(); Text(studio.status.map { $0.inputs.supplyAdcMv >= 0 ? "\($0.inputs.supplyAdcMv) mV" : "—" } ?? "—").font(.caption.monospacedDigit())
      }
      DisclosureGroup("Two-point meter calibration") {
        VStack(spacing: 14) {
          Text("Use a controlled bench supply and a meter. Enter two actual readings; calibration does not arm output.")
            .font(.caption).foregroundStyle(.secondary)
          StudioField(label: "Low point · ADC mV", text: $lowADC)
          StudioField(label: "Low point · meter mV", text: $lowMeter)
          StudioField(label: "High point · ADC mV", text: $highADC)
          StudioField(label: "High point · meter mV", text: $highMeter)
          Button("Save measured calibration") { Task { await studio.calibrate([lowADC, lowMeter, highADC, highMeter]) } }
            .buttonStyle(.bordered).disabled(!studio.connected || studio.status?.voltage.fitted != true || studio.busy)
        }.padding(.top, 14)
      }.font(.subheadline)
    }
  }
  private var inputsCard: some View {
    StudioCard {
      Label("Toyota inputs", systemImage: "cable.connector").font(.headline)
      HStack {
        Text("TAIL \(adc(studio.status?.inputs.tailAdcMv))"); Spacer(); Text("DIM \(adc(studio.status?.inputs.dimAdcMv))")
      }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      DisclosureGroup("Measured TAIL / DIM settings") {
        VStack(alignment: .leading, spacing: 14) {
          Button("Load controller settings") { loadInputs() }.disabled(!studio.connected)
          Toggle("Gate output with TAIL", isOn: $tail)
          StudioField(label: "TAIL on boundary · ADC mV", text: $tailOn)
          StudioField(label: "TAIL off boundary · ADC mV", text: $tailOff)
          Toggle("Scale brightness with DIM", isOn: $dim)
          StudioField(label: "DIM minimum · ADC mV", text: $dimMin)
          StudioField(label: "DIM maximum · ADC mV", text: $dimMax)
          StudioField(label: "Brightness at minimum · %", text: $dimLow)
          StudioField(label: "Brightness at maximum · %", text: $dimHigh)
          Button("Save input settings") {
            Task { await studio.saveInputs(tail: tail, tailOn: tailOn, tailOff: tailOff, dim: dim,
              dimMin: dimMin, dimMax: dimMax, dimLow: dimLow, dimHigh: dimHigh) }
          }.buttonStyle(.bordered).disabled(!studio.connected || studio.busy)
          Text("Use measured ADC values, not vehicle-wire volts. TAIL needs at least 50 mV hysteresis; DIM needs at least a 100 mV span.")
            .font(.caption).foregroundStyle(.secondary)
        }.padding(.top, 14)
      }.font(.subheadline)
    }
  }
  private var wiringCard: some View {
    StudioCard {
      Text("Wiring").font(.headline)
      DisclosureGroup("Six-pin Toyota inlet · design map") {
        VStack(spacing: 12) {
          wire("Cavity 6", "ACC → JT1-2")
          wire("Cavity 5", "Ground → JT1-1")
          wire("Cavity 1", "TAIL → JT2-1")
          wire("Cavity 2", "DIM → JT2-2")
          wire("Cavity 3", "Isolated reserve → JT3-1")
          wire("Cavity 4", "Isolated reserve → JT3-2")
          Text("Verify the actual truck’s cavity orientation, circuits and polarity before power. All six retain inline harness pass-through.")
            .font(.caption).foregroundStyle(.secondary)
        }.padding(.top, 14)
      }.font(.subheadline)
      DisclosureGroup("Five-wire analog RGBW outlet") {
        VStack(spacing: 12) {
          wire("Common +", "JT5-2")
          wire("R− / G−", "JT4-1 / JT4-2")
          wire("B− / W−", "JT5-1 / JT6-1")
          wire("Empty spare", "JT6-2")
        }.padding(.top, 14)
      }.font(.subheadline)
    }
  }
  private func adc(_ n: Int?) -> String { n.map { $0 >= 0 ? "\($0) mV" : "—" } ?? "—" }
  private var voltageText: String {
    guard let voltage = studio.status?.voltage, voltage.fitted, let mv = voltage.inputMv else { return "— V" }
    return (voltage.calibrated ? "" : "≈ ") + String(format: "%.2f V", Double(mv)/1000)
  }
  private func wire(_ left: String, _ right: String) -> some View {
    HStack { Text(left).foregroundStyle(.secondary); Spacer(); Text(right) }.font(.caption)
  }
  private func loadInputs() {
    guard let c = studio.status?.config else { return }
    tail = c.tailEnabled == 1; dim = c.dimEnabled == 1
    tailOn = String(c.tailOnMv); tailOff = String(c.tailOffMv); dimMin = String(c.dimMinMv); dimMax = String(c.dimMaxMv)
    dimLow = String(c.dimAtMinPercent); dimHigh = String(c.dimAtMaxPercent)
    if let v = studio.status?.voltageCalibration, v.isValid {
      lowADC = String(v.lowAdcMv); lowMeter = String(v.lowInputMv); highADC = String(v.highAdcMv); highMeter = String(v.highInputMv)
    }
  }
}
