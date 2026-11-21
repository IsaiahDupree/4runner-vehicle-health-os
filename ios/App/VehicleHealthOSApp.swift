import SwiftUI

@main
struct VehicleHealthOSApp: App {
  @State private var model = AppModel.shared

  var body: some Scene {
    WindowGroup {
      #if LIGHTING_STUDIO
      LightingStudioView()
        .environment(model)
      #else
      RootView()
        .environment(model)
        .task { model.startEvidenceAutomation() }
      #endif
    }
  }
}
