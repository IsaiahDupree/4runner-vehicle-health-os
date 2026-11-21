# Verification and delivery learnings

This is an evidence index and reusable workflow, not an instruction to rerun every heavy check for a documentation change. Results below describe the accepted 2026-11-21 snapshot. A later revision needs its own appropriate checks.

## Evidence sources and what they establish

| Retained evidence | Scope established |
|---|---|
| [Rev I verification](../../../hardware/console-led-node-v0.1/pcb-rgbw-revi/VERIFICATION.md) and [manifest](../../../hardware/console-led-node-v0.1/pcb-rgbw-revi/generated/verification.json) | Native board/CAD jobs, source/output hashes, factory reconciliation, fit and slice checks |
| [Firmware build receipt](../../../firmware/console-led-revg/builds/revi-strip-ui-03/firmware-build.json) | Pinned WLED/usermod inputs and exact cross-compiled image bytes |
| [Native app verification](../../../ios/Lighting/VERIFICATION.md) | Latest native app checks and delivery boundaries; supersedes the earlier hardware handoff's iOS test count |
| [Native UI receipt](../../../ios/Lighting/evidence/ui-checks.json) | Six real XCTest screenshots and actual UI interactions/offline gates |
| [Sanitized development-package receipt](../../../ios/Lighting/evidence/development-package.json) | Source-bound signed arm64 package validation, without publishing private provisioning data |

Accepted native hardware used Orion PCB job `mdl_f15786fc8a0e4fb4` and case job `mdl_5499c39857324978`: zero reported ERC/DRC/unrouted/parity findings under the retained rules, 497 fit/wire checks, eight insert/driver axes, three closed meshes and three support-disabled Cura slices with zero support segments. Inspect ignored/disabled rules too; a clean reported DRC is not a complete physical/electrical validation.

The case consumed populated-board STEP SHA-256 `a31710ef6d8f9d77c1a0409b38cb6069b1c685f4759248359d8ebcfecf1f0c8b`. Firmware job `mdl_cb1e5c876f05405c` produced the Rev I images; use the receipt for sizes/hashes and verify the current files rather than reusing an old successful job as proof for changed source.

The final native app snapshot passed 241 Swift core tests, 246 Python tests, 52 schema validations and an actual iPhone 11 simulator UI run. Earlier hardware documentation lists 232 Swift tests because it predates the native control revision. Preserve that chronology instead of silently treating both counts as current.

## Choose checks by the change

Before committing, run the repository-required checks from its root using the existing environment:

```bash
.venv/bin/vhos contracts check
.venv/bin/python -m pytest
```

If the environment is missing, follow `AGENTS.md` setup. Additional test/source entry points:

- `tests/test_revi_voltage_hardware.py`: actual native artifact identities, loaded sensor network, factory files and fit evidence.
- `tests/test_lighting_workspace.py`: firmware/client workspace integration; retain real policy execution and genuine connection-failure checks.
- `ios/Core` Swift package: request encoding, real retained CAN replay, parser and calibration/color math.
- `ios/LightingUITests/LightingStudioUITests.swift`: real native interactions, color-slot isolation, four tabs, unavailable-device gates and Config/CAN navigation.

Do not replace missing hardware with a fake production provider or label simulator inputs as vehicle evidence. Use existing real evidence/corpora and explicit disconnected-state tests. Run capture/replay bundle checks when capture or replay behavior actually changes, as required by `AGENTS.md`.

Native PCB/CAD, renders, firmware builds and slicing use the existing authenticated typed Orion control plane. Review `hardware/console-led-node-v0.1/pcb-rgbw-revi/orion_client.py`, the project job sources and the owner's `orion-control-plane/` registration before dispatch. Missing registration/input/worker is a concrete prerequisite failure, not authorization for heavy local or hosted work. Fetch complete results and reconcile lengths/hashes before publishing them.

## Bounded Apple builds and packaging

The dedicated scheme is `4RunnerLighting`; use `ios/project.yml` as source. Generate with `xcodegen generate --spec ios/project.yml` when needed. Select the exact simulator/device destination and an explicit task-specific DerivedData directory. The default cache here pointed to an offline volume; preserve the owner's global cache configuration.

Bound Xcode to one build job **and** one Swift compiler job: `-jobs 1` alone still allowed `swiftc -j12`. Preserve inherited Swift flags when adding `-j1`. Attach UI evidence to the exact tested build and keep the original result bundle/logs privately.

The owner's preferred physical test phone is Sarah's stationary iPhone 11. Resolve its exact UDID from current owner instructions; never select the first device or silently switch to the personal iPhone. After assigned testing, retain evidence, uninstall only the tested app's exact bundle ID and verify absence. For a task-created simulator, clean up only that simulator/app. `simctl listapps` may return OpenStep plist: use `plutil` conversion before JSON processing rather than assuming Python `plistlib` accepts it directly.

Use an existing matching development identity/profile for an authorized device package when possible. Inspect before creating Apple resources. Local development packaging is distinct from TestFlight/App Store submission. The [AppFleet fix at 91d9297](https://github.com/IsaiahDupree/AppFleet/commit/91d9297) supports explicit source scheme and DerivedData for source audit; it was published on its own branch, not assumed merged into every AppFleet checkout. Verify helper provenance before reuse.

Keep the IPA, certificate/profile/device identifiers, signing configuration and installer in private owner storage, outside public Git and skills. A retained package should bind source hashes, target identity, actual signature/entitlements, compatible profile/device, expiry and unpacked IPA bytes. An installer verification-only check does not prove installation. Never infer a physical device pass from a signature or simulator result.

For this snapshot, a signed owner delivery package exists but neither paired phone had a usable developer connection; **no physical installation/testing occurred**. That delivery exception does not change the preferred routine test device. Review the private retained receipt for device details rather than copying personal identifiers into this skill.

## Physical acceptance still outstanding

Truck cavity function/polarity and actual connector mating; meter-based voltage calibration; switch/ADC reset isolation; input pulse/clamp energy; brownout/recovery; PWM/driver/current/temperature; exact strip length and end sealing; connector torque/retention/vibration; printed tolerances and installed fit; factory programming and final box QA.

Report these boundaries when relevant to a manufacturing or plug-and-play claim. They do not prevent an authorized source edit, digital fit check or skill save. Preserve separate evidence for compilation, native UI, digital geometry, actual assembly and vehicle behavior.
