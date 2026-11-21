# WLED and native iOS learnings

Accepted source snapshot: 2026-11-21. For the current native UI, prefer [Lighting README](../../../ios/Lighting/README.md) and [design decisions](../../../ios/Lighting/DESIGN-DECISIONS.md). The firmware configuration also documents an earlier embedded web UI; it is not authority to restore that as the native app's front door.

## Interface decisions that survived review

The owner selected WLED lighting controls as the reference and rejected decorative SUV imagery, promotional screens, other app references and phone-only scenes. Keep the four primary tabs: Colors, Effects, Segments, Presets. Colors centers on a circular hue/saturation wheel, target dropdown, three effect-color slots, brightness, white level, HEX and palettes. The current target is segment 0 / Whole strip; slots 1–3 cannot drive separate vehicle sections on this board.

Effects/palettes come from the controller's real catalogs, preserving source IDs when filtering reserved entries. Presets use `/presets.json` and WLED `/json/state` operations `ps`, `psave`, `pdel`. Saving the current state uses `ib=true`, `sb=false` to include brightness and preserve installed segment bounds. A save acknowledgement is not flash/storage evidence; refresh the real preset file.

Disconnected color editing is an explicit preview. Disable hardware actions and show unavailable readings as unavailable, never as invented zeros or telemetry. Do not infer full upstream WLED feature parity from the implemented controls.

## Implementation entry points

| Source, relative to repository root | Responsibility |
|---|---|
| `ios/App/LightingStudioView.swift` | Native wheel, tabs, target, effects/presets, Config |
| `ios/App/LightingStudioModel.swift` | Real controller requests, lifecycle, polling and foreground relay |
| `ios/Core/Sources/VHOSCore/LightingControl.swift` | Typed DTOs, validation, request encoding and color/preset math |
| `ios/Core/Tests/VHOSCoreTests/LightingControlTests.swift` | Core request and interaction invariants |
| `ios/LightingUITests/LightingStudioUITests.swift` | Actual native UI interactions and offline gates |
| `ios/project.yml` | Dedicated `4RunnerLighting` target/scheme |
| `firmware/console-led-revg/` | WLED usermod, input/relay policies and head-unit web UI |

The dedicated app bundle is `com.isaiahdupree.4RunnerLighting`, iOS 17 minimum. The lighting target does not start the broader VHOS automatic evidence-upload service.

## Real integration behavior

Use the matched [firmware configuration](../../../firmware/console-led-revg/CONFIGURATION.md) and inspect the actual handlers before modifying protocol fields. At this snapshot WLED is pinned to v16.0.1, commit `29b389df1c1aaec6ff53aea742d17063b985906c`; Rev I target is `vhos_revi_n16r2` with `VHOS_SUPPLY_SENSE`. Unmodified Rev G/H uses its original target without GPIO1 supply sensing.

The controller uses its isolated secured AP `4Runner-Lighting`, `192.168.88.1`. Commission a private password and unique relay key; never commit their values. Accessory requests use `X-VHOS-Key`. The native client uses an ephemeral session, bounded responses/timeouts, no cookies/cache and refused redirects. Preserve these boundaries when adding an endpoint.

| API | Boundary to preserve |
|---|---|
| `GET /vhos/status`, authenticated `/api/health` alias | Typed `vhos.lighting.status@1.0.0`; readiness, source, freshness and availability |
| `POST /vhos/manual` | Set/off; manual color/effect/preset takes over from CAN automation |
| `POST /vhos/config` | Validate the complete configuration atomically; 202 means applied in RAM/save scheduled, not verified persistence |
| `POST /vhos/voltage` | Two real meter-referenced bench points; calibration cannot arm the outputs |
| `POST /vhos/lighting` | Existing explicit start/sample/stop session protocol; no CAN transmit endpoint |

Boot intent is off. Arming, verified analog bus, secured isolated AP and a client are required for readiness. Driver enable falls low on initialization, lost readiness and zero effective output.

CAN data travels from the existing BLE gateway through the foreground iPhone to controller Wi-Fi. Accepted samples require the active session/signal and increasing sequence; invalid or duplicate packets must not refresh the 2.5-second deadline. Preserve ECU disambiguation and verified supported J1979 response semantics. Passive activity must come from actual verified current frames. Backgrounding/dismissing the app stops the relay; manual takeover stops it too. The Android browser supports manual controls/configuration, not a separately implemented always-running CAN relay.

TAIL/DIM are measured, opt-in inputs, disabled by default. Existing policy uses at least 50 mV TAIL hysteresis, 200 ms debounce, a 100 mV minimum DIM span and 250 ms ADC freshness. These are project engineering settings, not Toyota service specifications. Rule/calibration edits stop the automatic session and require explicit restart.

Supply voltage comes from ACC_FUSED after F1, before the eFuse. With ACC off the board loses power. Show raw ADC and calibration quality, without battery-post voltage, resting state of charge or an inferred charging diagnosis. The calibration policy accepts 6–17 V references and rejects insufficient separation/implausible gain; ADC above 1200 mV is over-range with no numeric voltage.

## Implementation failures and fixes worth reusing

- Put polling and relay lifecycle on the containing navigation stack. A root scroll view disappears when navigating to Effects/Config, which can incorrectly stop ongoing work.
- Invalidate old polls when a mutation starts, and use request generations so a late reply cannot overwrite newer intent. Coalesce edits while busy; do not send startup defaults as user commands. Send a wheel gesture on release only when ready.
- With Swift observation macros, use one `@State`/observable variable per declaration. Comma-separated declarations caused macro expansion failures.
- Unwrap Swift Testing `#require` results before other macros/assertions; separate throwing expressions from boolean autoclosures when required by the compiler.
- Load independent settings independently. A failed Keychain lookup once prevented unrelated local state from loading. The later approved design removed phone-only scenes; that earlier failure is not a reason to restore them.
- Treat key retention as opt-in, device-only Keychain storage. Empty/invalid credentials must keep connection and CAN actions gated.

See [verification and delivery](verification-delivery.md) for the actual test scope. No physical controller responses or fake production providers were used to make the final native screenshots appear connected.
