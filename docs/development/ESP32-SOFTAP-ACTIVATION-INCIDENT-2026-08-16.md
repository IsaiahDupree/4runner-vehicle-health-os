# ESP32 SoftAP activation incident — 2026-08-16

## Outcome

The VHOS gateway status SoftAP is now **off by default** in firmware source and release
configuration. The safe-default fix is committed and pushed as firmware commit
`5077da0221d1` (`v0.1.0-dev.7`). The exact clean image has been built and is ready to flash when
the classic ESP32 returns on `/dev/cu.usbserial-0001`.

The development Mac has also been repaired:

- `VHOS-STATUS-B08D14` was removed from its preferred Wi-Fi networks;
- the Wi-Fi interface was cycled;
- its normal `192.168.1.118` address and `192.168.1.254` default gateway returned; and
- only the normal `ATT8ePb7xg` network remains preferred.

## What happened

The unreleased `v0.1.0-dev.6` bench image automatically created an authenticated SoftAP for the
first 900 seconds after every boot. The Mac test deliberately executed an association with
`VHOS-STATUS-B08D14`. The ESP32 DHCP server assigned the Mac `192.168.4.2`, proving the AP worked.

A Wi-Fi client interface normally associates with one infrastructure network at a time. Joining
the isolated ESP32 network therefore moved the Mac away from its normal network. Because the VHOS
SoftAP intentionally has no internet or upstream LAN route, normal connectivity disappeared. The
effect looked like the surrounding Wi-Fi had been disabled.

The ESP32 did not modify or take control of the home router. Nevertheless, automatic SoftAP boot
was the wrong policy because it created three avoidable hazards:

1. macOS could remember and later autojoin the no-internet gateway network;
2. ESP32 Wi-Fi plus BLE increases 2.4 GHz coexistence and power demand; and
3. a service that is needed only during commissioning should not broadcast after every power
   cycle.

The USB serial device disappeared later in the test, so authenticated HTTP route verification did
not complete. That disappearance is recorded as a physical connection/power interruption, not as
proof of a firmware HTTP failure. No release claim is made for the uncompleted HTTP checks.

## Immediate firmware correction

`v0.1.0-dev.7` adds a Kconfig policy named `VHOS_STATUS_SOFTAP_AUTOSTART` with default `n`.
The normal release path now:

1. initializes NVS;
2. starts TWAI/CAN in hardware listen-only mode;
3. starts the bonded NimBLE transport;
4. does **not** initialize ESP-NETIF, Wi-Fi, DHCP, or HTTP;
5. logs `VHOS_SOFTAP_DISABLED reason=default-safe-policy`; and
6. omits `status.softap.readonly` from the live capability handshake.

The status source remains in the repository and is compiled for source verification, but the
linker removes the unreachable service from the default release image. The application shrank
from approximately 981 KB to 503 KB and has about 68% of either 1.5 MB OTA slot free.

The release validator fails if:

- the release sdkconfig enables SoftAP autostart;
- the Kconfig default is not `n`;
- the status server gains methods other than its three `GET` routes;
- restart, erase, OTA-write, or CAN-transmit authority enters the status module;
- WPA2, PMF, the one-station limit, NVS credential, Basic authentication, or constant-time
  comparison is removed; or
- the embedded page gains external network dependencies.

## Why “enable when the Mac is out of range” is not used

The ESP32 cannot reliably prove that a specific Mac is absent without a cooperative authenticated
presence protocol. Apple devices use private Wi-Fi addresses, sleep their radios, and do not
continuously emit a stable identity. Passive probe observation is incomplete and privacy-
invasive. BLE scanning would add shared-radio load and would still confuse a missed advertisement
with actual absence.

That design would fail open: a sleeping Mac, changed private address, missed scan, reboot, or radio
interference would unexpectedly enable the AP. In VHOS terms, “Mac not observed” is an evidence
gap, not a valid fact that authorizes Wi-Fi startup.

## Approved activation direction

The next implementation should use an explicit owner action over the already bonded and encrypted
iPhone BLE session:

```text
iPhone user action
    -> encrypted BLE semantic request
    -> firmware validates contract and current session
    -> one-shot SoftAP activation
    -> authenticated, read-only page for <= 900 seconds
    -> automatic Wi-Fi/HTTP shutdown
```

The BLE request may activate a read-only observer. It may not:

- supply arbitrary Wi-Fi parameters;
- extend the 900-second limit indefinitely;
- retrieve or replace the gateway credential;
- transmit CAN or issue OBD diagnostics;
- upload or activate firmware;
- reboot, erase, delete bonds, or mutate configuration; or
- treat failure to detect another device as authorization.

A physical-presence input may be considered later if a verified, accessible hardware control is
identified. No GPIO or board button will be assumed without physical verification.

## Current physical state and recovery step

The ESP32 was last physically flashed with the `v0.1.0-dev.6` autostart bench image. Its AP still
shuts down automatically after 900 seconds, and the Mac no longer has credentials saved to join
it. The gateway was not enumerated after the computer restart, so `v0.1.0-dev.7` could not yet be
installed.

When the gateway is reconnected, flash only its application partition to preserve the BLE bond and
NVS:

```bash
uvx esptool --chip esp32 --port /dev/cu.usbserial-0001 --baud 460800 \
  write-flash 0x10000 \
  targets/mrdiy-esp32-v13/build/vhos_mrdiy_esp32_v13.bin
```

Acceptance evidence after the reflash must prove:

- firmware `0.1.0-dev.7` and exact build `v4.50p-13-g5077da0221d1`;
- persisted BLE bond counts;
- `PASSIVE_CAN_READY mode=listen-only`;
- `VHOS_SOFTAP_DISABLED`;
- no `VHOS-STATUS-*` SSID after boot;
- iPhone reconnection and a versioned handshake without forgetting the device; and
- continued normal Mac Wi-Fi routing.

## Detailed firmware records

The full component, API, security, operations, and decision rationale lives in the public firmware
repository at commit `5077da0221d1`:

- `targets/mrdiy-esp32-v13/docs/SOFTAP-ACTIVATION-POLICY.md`
- `targets/mrdiy-esp32-v13/docs/SOFTAP-STATUS-ARCHITECTURE.md`
- `targets/mrdiy-esp32-v13/docs/SOFTAP-STATUS-API.md`
- `targets/mrdiy-esp32-v13/docs/SOFTAP-STATUS-SECURITY.md`
- `targets/mrdiy-esp32-v13/docs/SOFTAP-STATUS-OPERATIONS.md`

