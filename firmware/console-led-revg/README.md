# WLED for the 4Runner Rev G lighting controller

This build uses [WLED v16.0.1](https://github.com/wled/WLED/releases/tag/v16.0.1)
at commit 29b389df1c1aaec6ff53aea742d17063b985906c. It targets the
ESP32-S3-WROOM-1-N16R2 with 16 MB flash and 2 MB quad PSRAM. The single RGBW
driver uses GPIO18, GPIO17, GPIO14 and GPIO2 in R/G/B/W order. GPIO21 stays
low until the board is armed and a valid lighting command is active. GPIO5
and GPIO4 display the isolated TAIL and DIM ADC readings in WLED Info.
[Rev G electrical and bench instructions](../../hardware/console-led-node-v0.1/pcb-rgbw-revg/BENCH.md).

## Build and first power

The repository's authenticated Orion engineering lane cross-compiles the firmware.

    cd hardware/console-led-node-v0.1/pcb-rgbw-revb
    python3 -B orion_client.py start UNIQUE-ID --stage toyota-rev-g-wled

Use the same identity for status, fetch and stop. The isolated job expects the
Orion task venv at C:/orion/projects/revg-wled-16-0-1 with PlatformIO 6.1.19.
The output includes the build receipt, source pin and serial flash image.
WLED's EUPL-1.2 license applies to this firmware. The exact upstream code and
the [patch and usermod source](wled) accompany the build.

Power the verified Rev G board at J1 with a current-limited bench supply.
Follow the board's BOOT and EN instructions and the 3.3 V UART pinout. Use
the factory image at address 0x0 on the N16R2. Disconnect vehicle wiring and
leave the light unplugged for first boot. Check the output-enable pin and
PWM against a test fixture before attaching the pod. The 25% per-channel PWM
ceiling bounds duty in the evaluation build. Confirm actual peak and combined
current, heat, short response and brownout behavior on the board and load.

## Manual color from iPhone and Android

Join the 4Runner-Lighting access point and open [WLED](http://192.168.88.1)
in either device's browser. This firmware uses an isolated controller AP.
Set a new WPA2 passphrase of at least 12 characters in WLED Wi-Fi settings,
reconnect both devices, and set a WLED settings PIN. Once the electrical
bench checks pass, use Settings → Usermods → RevG to enable arm-output.
Change the color or brightness using the normal WLED screen or its
[local JSON API](https://kno.wled.ge/interfaces/json-api/). Every boot
begins with the LED driver off. Leaving or losing the private AP clears
active control when its last client disconnects.

## CAN lighting

The gateway sends verified telemetry to the existing VHOS iPhone app over BLE.
The app forwards selected values over the lighting AP as they arrive. In VHOS,
choose System → Rev G lighting, select the signal, enter the controller's
relay key and choose Start CAN relay. Keep that screen active for automation.
The Android head unit can use the WLED controls on the same AP.

In WLED Usermods → RevG, set a unique relay-key with 16–64 printable
non-space characters. Choose signal 0 for engine RPM, 1 for speed in km/h,
2 for coolant temperature in °C, 3 for calculated engine load in percent,
or 4 for live CAN activity. The threshold fields use hundredths of each
unit. For live CAN activity, use 100 for both thresholds. Choose RGBW
and brightness in the 0–255 fields. The selected color turns on at
on-centi and stays on through off-centi. It turns off below off-centi or
after 2.5 seconds without a fresh accepted sample. Set the threshold values
for the intended evaluation. The manual WLED color, brightness, preset or
power command takes control until the relay is explicitly started again.

The four vehicle parameters use the existing VHOS J1979 decoder. They become
available only when the gateway delivers fresh supported PID responses in the
current recorder session. An ECU address is needed when more than one current
ECU reports the same parameter. Live CAN activity means a new verified passive
frame was received. [Existing MRDIY CAN gateway](https://github.com/IsaiahDupree/4runner-vhos-firmware/tree/a523483abc984a406c73659653571198e46b04a0/targets/mrdiy-esp32-v13).

A relay can post form-encoded requests to /vhos/lighting with the X-VHOS-Key
header on the same AP. Each start specifies a positive session and a signal
matching the configured rule. Samples include session, signal, centi and a
strictly increasing positive seq. Send stop for the same session to turn its
automatic output off. A 204 means accepted. A 403 identifies an unusable
key or disarmed output. A 409 identifies an inactive session, a conflicting
rule, or a rejected sample. The relay reads gateway telemetry and writes only to the lighting controller.

## Verification

The portable C++ tests call the policy and relay functions used by the
ESP32-S3 build. They cover threshold crossings, malformed values, denied
and replayed requests, manual takeover, valid samples across rollover and
expired samples that must stay expired after the counter wraps.

    for test_name in policy relay; do
      clang++ -std=c++17 -Wall -Wextra -Werror -pedantic -fsanitize=undefined -fno-sanitize-recover=all \
        "firmware/console-led-revg/tests/${test_name}_test.cpp" -o "/tmp/revg-${test_name}" &&
        "/tmp/revg-${test_name}" || exit 1
    done

The Swift tests run a real J1979 decode through the relay's newest-per-ECU
selection and check its Wi-Fi request. The app build and Orion ESP32-S3 build
check their respective integration points. A real bench run still needs the
Rev G PCB, 3.3 V UART, power supply, actual rock light, CAN gateway and
phone/head-unit pairing. Start with CAN activity to exercise the BLE-to-Wi-Fi
path while collecting evidence of which additional vehicle samples arrive.

## Strip workspace and Rev I supply monitor

The newer [configuration and UI guide](CONFIGURATION.md) records the assumed BTF analog RGBW strip, controller-hosted phone/head-unit UI, native iOS embedding, calibrated TAIL/DIM behavior and the added Rev I ACC voltage-sense target. The older pod instructions above are historical commissioning context. The new target is vhos_revi_n16r2; source and exact evaluation-image hashes are retained in builds/revi-strip-ui-03. Digital/software verification does not approve a strip length or the vehicle installation.
