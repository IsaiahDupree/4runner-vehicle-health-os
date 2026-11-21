# Saved lighting-app direction — 2026-11-21

Owner-approved reference: **WLED's UI/UX and lighting functionality**.

## Interface

- Keep Colors, Effects, Segments and Presets as the primary tabs.
- Make the circular hue/saturation picker the main color control, with a target dropdown, three WLED effect-color slots, brightness, dedicated white, HEX and palettes.
- Use clear, bold control labels and direct lighting interactions.
- Keep presets on the WLED controller using its existing preset system.
- Keep the approved CAN relay, supply-voltage monitor, Toyota inputs and connection settings under Config.
- Use no vehicle illustration, decorative photo, promotional hero, unrelated app design reference or phone-only scene system.
- Add functionality only when requested; a WLED-inspired interface is not authorization to add unrelated features or change the PCB architecture.

## Hardware and evidence

The present Rev I board has one analog RGBW zone: segment 0 / Whole strip. Its three color slots are effect colors, not separately wired physical sections. Independent sections require an explicit hardware/LED change.

The six-pin Toyota inlet remains the sole power input. Supply sensing reads ACC_FUSED at the controller; it does not measure the resting battery with ACC off. CAN information comes from the existing gateway software over the verified BLE → foreground iPhone → controller Wi-Fi path.

Keep unavailable readings and disconnected controls explicit. Do not substitute preview colors, assumed parameters or test inputs for live vehicle observations.

## Saved deliverables

- [App configuration and feature map](README.md)
- [Native UI screenshots and test receipt](evidence/ui-checks.json)
- [Build, test and installation boundaries](VERIFICATION.md)
- [Signed development-package verification](evidence/development-package.json)
- [Rev I PCB, CAD and factory BOM](../../hardware/console-led-node-v0.1/pcb-rgbw-revi/README.md)
- [Matched controller firmware configuration](../../firmware/console-led-revg/CONFIGURATION.md)

Implementation source was committed in `ff540e4`; signed-package verification was recorded in `ffdb308`. Both were pushed to `codex/4runner-revg-glands-wled` in `IsaiahDupree/4runner-vehicle-health-os`. The signed IPA, installer, provisioning data and original test/build evidence are retained privately outside Git.

Physical iPhone installation, controller/strip integration, sensor calibration and vehicle qualification remain pending. A successful build, signature check or simulator test must not be described as a physical installation or hardware pass. GitHub Actions and automatic deployments remain disabled.
