# 4Runner Lighting for iPhone

Native SwiftUI app for the integrated Rev I RGBW controller. The dedicated Xcode scheme is **4RunnerLighting**, bundle **com.isaiahdupree.4RunnerLighting**, iOS 17 or newer. It installs separately from Vehicle Health OS. The existing VHOS app also opens these native controls from System → 4Runner lighting.

The [saved design decisions and handoff](DESIGN-DECISIONS.md) preserve the approved WLED-only interface direction, current hardware scope and exact implementation/package references.

The UI follows WLED’s control structure: **Colors, Effects, Segments and Presets**. Colors has a hue/saturation wheel, three effect color slots, HEX, global brightness, white-channel level, target dropdown and controller palette selection. Gestures send changes on release when connected; disconnected editing is a labeled preview. Power is a direct control in the header. No vehicle illustration, photo, promotional hero or phone-only scene system is included.

Effects and palettes load from the actual WLED catalog. Presets load, save and delete on the controller using WLED’s preset file/API. Saving captures the controller’s current state with brightness and preserves the installed segment bounds. An acknowledgement is a request result; the returned preset file is the evidence for stored contents.

The existing board exposes **one analog RGBW output zone**, represented by segment 0 / Whole strip. The three color circles are WLED effect color slots, not independent physical zones. This app does not create pretend left/right/front zones or change the PCB’s output architecture. Multi-pixel patterns and independently colored sections require suitable addressable LEDs or separate output channels.

## Vehicle additions under Config

- Authenticated private-Wi-Fi controller connection, with optional device-only Keychain storage for the relay key.
- Existing verified BLE CAN gateway → foreground iPhone → controller Wi-Fi relay, with one supported signal/rule, ECU disambiguation and the existing freshness/session checks.
- Rev I supply-voltage display, calibration quality, raw ADC and two-point meter calibration. It measures ACC_FUSED at the box; ACC-off resting battery voltage is unavailable.
- Measured TAIL gating, DIM scaling and the complete Toyota/RGBW wire register.
- Links to the controller’s existing WLED setup pages for commissioning.

The lighting target does not start VHOS’s automatic evidence-upload service. No extra cloud service, account, arbitrary CAN transmit console or diagnostic workspace is added to its lighting navigation. The relay stops on background/dismissal; the controller also expires stale samples after 2.5 seconds. Manual color/effect/preset takeover stops the native relay.

## Connect

1. Commission the installed controller’s private AP, one analog RGBW bus, relay key and output arming using the [matched firmware configuration](../../firmware/console-led-revg/CONFIGURATION.md).
2. Join **4Runner-Lighting** in iPhone Wi-Fi settings. In the app’s Config, enter the relay key and connect to **192.168.88.1**.
3. Use the color wheel, effect controls or controller presets. Open Config → CAN automation to connect the existing verified gateway and load/save its lighting rule.

The current electrical screen remains 500 mA/channel and 1 A combined; the LED rail follows protected, unregulated vehicle voltage. App controls do not qualify a strip length or replace bench/vehicle, calibration, power-transient, thermal or sealing tests.

## Build and verification

Generate the existing project with `xcodegen generate --spec ios/project.yml`, then select the **4RunnerLighting** scheme. Use a bounded, explicitly selected simulator/device and an explicit DerivedData path; this Mac’s default cache points to an offline volume. The lighting target requires no custom signing entitlement; Wi-Fi joining is manual in iOS settings.

The [native screenshot/test receipt](evidence/ui-checks.json) records the actual wheel gestures, color-slot isolation, segment selector, offline gates and vehicle-config navigation. Screenshots contain no connected-controller responses or simulated telemetry. [Verification and delivery](VERIFICATION.md) distinguishes software checks, signed package validation and physical installation.

Primary references: [WLED web UI](https://kno.wled.ge/basics/web-ui/), [JSON API](https://kno.wled.ge/interfaces/json-api/), [presets](https://kno.wled.ge/features/presets/) and the matched [v16.0.1 UI source](https://github.com/wled/WLED/blob/29b389df1c1aaec6ff53aea742d17063b985906c/wled00/data/index.htm). Native graphics are control widgets; no external pictures or copied third-party UI artwork are used.
