# Native WLED control app — verification, 2026-11-21

The final design follows the requested WLED control structure. The earlier illustrated concept and phone-only scenes were removed before publication. No physical lighting-controller replies are substituted in the screenshots or tests.

| Verification | Result |
|---|---|
| Swift core | 241 tests passed, including actual request encoding, existing real-CAN replay, parser rejection, calibration bounds and a 361-point hue/saturation-wheel sweep |
| Python regression suite | 246 tests passed |
| Domain schemas | 52 schemas valid |
| Native iPhone 11 simulator UI | Passed: wheel center gesture, direct swatches, color-slot isolation, segment selector, all four WLED tabs, unavailable-device gates, Config and CAN navigation |
| UI evidence | Six native XCTest screenshots plus [hash-bound receipt](evidence/ui-checks.json); no simulated controller responses |
| Phone target | Dedicated 4RunnerLighting scheme, iOS 17 minimum, arm64, native SwiftUI |
| Simulator and Release device compilation | Both passed on the Mac with one build job / one Swift compiler job |
| Signing preflight | Existing local Apple Development identity and active profile matched the owner's registered iPhone 15; no new Apple resource was needed |
| Source-audit helper | Five real/boundary checks passed; [AppFleet revision 91d9297](https://github.com/IsaiahDupree/AppFleet/commit/91d9297) adds an explicit source scheme and task cache without altering global Xcode settings |
| Physical testing / installation | Not performed: preferred iPhone 11 and delivery iPhone 15 reported unavailable developer connections |

The signed package result is recorded separately in `evidence/development-package.json` when packaging succeeds. Development IPAs and provisioning identifiers remain in private owner artifact storage, outside Git. A signed package is not proof of installation or hardware operation, and does not provide a TestFlight distribution link.

The default Xcode DerivedData symlink targets an offline volume. Build and source-audit commands use an explicit task cache. Unrelated AppFleet changes, other simulators and the global cache configuration were preserved. GitHub Actions and automatic deployments remain disabled.

## Physical boundaries

The current PCB has one analog RGBW zone. Segment 0 represents the whole strip; color slots 1–3 are effect colors, not three physical output sections. The app validates the expected one-segment WLED layout before using its segment state. Unsupported layouts remain unavailable through that lane.

The controller must have the matched firmware, secured private AP, verified output bus and explicit arming. Presets and effect catalogs require the actual controller. Preset-file refresh supplies storage evidence; an HTTP save acknowledgement alone is not a flash-write verification.

CAN automation retains verified gateway/session/sequence, ECU and freshness checks. The relay stays in the foreground, ends on app background/dismissal, and the controller has its own 2.5-second sample deadline. No new vehicle transmit authority is added.

Voltage measures the fused switched supply at the box. Calibration, pulse/reset behavior, actual Toyota wiring, strip current/voltage/temperature, sealing and final installed behavior remain bench/vehicle acceptance work. There is no ACC-off resting battery measurement or inferred battery-health verdict.
