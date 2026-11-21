import XCTest

final class LightingStudioUITests: XCTestCase {
  @MainActor func testWLEDControlsWheelSegmentsPresetsAndVehicleConfig() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    addUIInterruptionMonitor(withDescription: "First-run Bluetooth permission") { alert in
      guard alert.label.localizedCaseInsensitiveContains("Bluetooth") else { return false }
      for label in ["Don’t Allow", "Don't Allow"] where alert.buttons[label].exists {
        alert.buttons[label].tap(); return true
      }
      return false
    }
    app.launch()
    XCTAssertTrue(app.buttons["LightingTabColors"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["LightingPower"].isEnabled)
    XCTAssertFalse(app.staticTexts["Set the tone."].exists)
    XCTAssertTrue(app.buttons["LightingSegmentSelector"].exists)
    let wheel = app.descendants(matching: .any).matching(identifier: "LightingColorWheel").firstMatch
    XCTAssertTrue(wheel.exists)
    app.buttons["LightingSwatchTeal"].tap()
    let hex = app.textFields["LightingHex"]
    XCTAssertEqual(hex.value as? String, "#00FFC8")
    wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    let centered = try XCTUnwrap(hex.value as? String)
    let rgb = try XCTUnwrap(UInt32(centered.replacingOccurrences(of: "#", with: ""), radix: 16))
    XCTAssertGreaterThanOrEqual((rgb >> 16) & 255, 250)
    XCTAssertGreaterThanOrEqual((rgb >> 8) & 255, 250)
    XCTAssertGreaterThanOrEqual(rgb & 255, 250)
    app.buttons["LightingColorSlot1"].tap()
    XCTAssertEqual(hex.value as? String, "#000000")
    app.buttons["LightingSwatchBlue"].tap()
    XCTAssertEqual(hex.value as? String, "#0000FF")
    app.buttons["LightingColorSlot0"].tap()
    XCTAssertEqual(hex.value as? String, centered)
    app.buttons["LightingSwatchTeal"].tap()
    attach("01-Colors", app)
    app.buttons["LightingTabEffects"].tap()
    XCTAssertTrue(app.staticTexts["Connect to load this controller’s WLED effects."].exists)
    attach("02-Effects", app)
    app.buttons["LightingTabSegments"].tap()
    XCTAssertTrue(app.staticTexts["Analog RGBW output"].exists)
    attach("03-Segments", app)
    app.buttons["LightingTabPresets"].tap()
    XCTAssertFalse(app.buttons["LightingCreatePreset"].isEnabled)
    XCTAssertTrue(app.staticTexts["Connect to load presets saved on the WLED controller."].exists)
    attach("04-Presets", app)
    app.buttons["LightingConfig"].tap()
    XCTAssertTrue(app.secureTextFields["LightingRelayKey"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.buttons["Connect controller"].isEnabled)
    attach("05-Config", app)
    let can = app.buttons["CAN automation"]
    if !can.isHittable { app.swipeUp() }
    can.tap()
    XCTAssertFalse(app.buttons["Start CAN relay"].isEnabled)
    attach("06-CAN", app)
  }
  @MainActor private func attach(_ name: String, _ app: XCUIApplication) {
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
  }
}
