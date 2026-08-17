import SwiftUI

@main
struct VehicleHealthOSApp: App {
  @State private var model = AppModel.shared

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(model)
    }
  }
}
