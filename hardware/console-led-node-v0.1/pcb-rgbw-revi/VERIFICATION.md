# Rev I verification — 2026-11-21

This record covers the one-board ACC voltage-sense revision and its WLED lighting workspace. The source and artifacts are evaluation deliverables. No physical circuit, installed strip, printed enclosure or truck passed qualification in this work.

## Native hardware results

| Check | Actual result |
|---|---|
| Native PCB job | Orion `mdl_f15786fc8a0e4fb4`, succeeded in 27.4 s |
| Native case/slice job | Orion `mdl_5499c39857324978`, succeeded in 84.4 s |
| KiCad 10.0.6 ERC / DRC / unrouted / schematic parity | Zero reported findings under the retained project rules; detailed enabled/ignored checks are recorded in [ERC](generated/erc.json) and [DRC](generated/drc.json) |
| Existing footprint positions | Unchanged, including terminal blocks and mounting holes |
| Factory coverage | Actual saved PCB, BOM and CPL reconcile to 75 populated positions and 31 manufacturer SKUs |
| New sensor geometry | All eight added component references occur in the exported populated-board STEP |
| Case input identity | Exact new PCB STEP SHA-256 `a31710ef6d8f9d77c1a0409b38cb6069b1c685f4759248359d8ebcfecf1f0c8b` |
| Populated-board / case / wire clearance | 497 of 497 checks passed, with 11 modeled conductors |
| Insert and screwdriver access | Eight of eight tool axes passed, including heat-set radial allowance |
| Meshes and support-free slicing | Three closed meshes; all three CuraEngine 5.9.0 / FLSUN V400 offline slices passed with support disabled and zero support segments |

The [publication manifest](generated/verification.json) binds the shipped files to the accepted native jobs. Windows text normalization is explicit; binary CAD and image files remain byte identical. Factory BOM/CPL identity, centroids, rotations, source SKU pricing and Gerber archive CRC are also checked by the host tests. The retained stock capture is a dated input, not a current checkout quote or assembly order.

## Firmware, app and interface results

| Check | Actual result |
|---|---|
| WLED source | v16.0.1 at `29b389df1c1aaec6ff53aea742d17063b985906c` |
| Rev I cross-compile | Orion `mdl_cb1e5c876f05405c`, succeeded in 116.7 s; `vhos_revi_n16r2` |
| Factory image | 1,151,264 bytes; SHA-256 `fce2b17f71056bcb6f1021ede2fff22136674a26c3ea63ac367a8c6abd39cfe8` |
| App image | 1,085,728 bytes; SHA-256 `60a3eb13ac6d61b217ad70b4a1bbfd66a9d839807455642b823a2deffb4f9635` |
| Source/image binding | Every usermod source hash and image hash matches the [native build receipt](../../../firmware/console-led-revg/builds/revi-strip-ui-03/firmware-build.json) |
| Host regression suite | `.venv/bin/python -m pytest`: 246 passed, 8.95 s |
| Schema validation | `.venv/bin/vhos contracts check`: 52 schemas valid |
| Native policy execution | Actual C++ relay, input, voltage and command policies compiled and executed under undefined-behavior sanitizer; malformed commands, stale/wrong-session data, hysteresis, rollover, ADC range and calibration rejection covered |
| Browser/client checks | Actual Node client validation plus real local HTTP missing-controller failure; deterministic embedded UI agrees with editable source |
| Visual interaction checks | Actual WebKit captures at 1280×800 and 390×844, three screens each; local swatches, no horizontal overflow/JS errors, unavailable controller rejected, hardware actions disabled and no invented voltage. [Receipts and images](../../../firmware/console-led-revg/ui/evidence/ui-checks.json) |
| iOS core | 232 Swift tests passed, including retained real-CAN replay and the existing relay |
| iOS app | Bounded generic-iOS, signing-disabled Xcode build succeeded, including the new embedded controller web view |
| Preferred physical iPhone | Paired iPhone 11 reported unavailable developer tunnel/services; no physical test or installation performed |

The six-wire inlet remains the sole power connection. Firmware reports an uncalibrated estimate until two meter-referenced bench readings are applied. ACC-off resting battery voltage is unavailable. No battery-state-of-charge or charging-system diagnosis is derived.

## Required physical acceptance

The following remain unverified: actual Toyota cavity assignment/polarity, supply voltage accuracy and calibration, ADC/switch reset isolation, pulse/clamp energy, brownout/recovery, factory programming, PWM/driver behavior, strip instantaneous current and temperature, end sealing, connector retention/torque/vibration, printed tolerances and final truck fit. Digital checks do not replace these tests.

The selected BTF nominal-12-V strip has no qualified installed length here. Its output rail follows protected, unregulated vehicle voltage. Retain the existing 0.5 A/channel and 1 A combined electrical screen; the 25% firmware PWM ceiling is not an instantaneous-current limit. Do not infer full-reel compatibility from a successful compile or an IP67 label.

The existing CAN path is BLE gateway → foreground VHOS iPhone → authenticated controller Wi-Fi. Leaving the lighting view/backgrounding the app stops the native relay; the controller also expires stale samples. The Android browser supports manual controls and configuration, with no standalone head-unit CAN relay claimed.
