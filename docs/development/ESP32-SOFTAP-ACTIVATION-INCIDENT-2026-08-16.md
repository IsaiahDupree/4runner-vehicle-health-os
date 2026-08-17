# ESP32 SoftAP activation incident — 2026-08-16

## Outcome

The VHOS gateway status SoftAP is now **off by default** in firmware source, release
configuration, and the physical gateway. The safe-default fix is committed and pushed as
firmware commit `5077da0221d1` (`v0.1.0-dev.7`). The exact clean image was flashed to the classic
ESP32 at `/dev/cu.usbserial-0001` and its written hash was verified.

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

## Physical correction and verification

After the gateway re-enumerated, the updater verified both its classic `ESP32-D0WDQ6` identity and
hardware MAC `94:54:c5:b0:8d:14` before writing. Only the application partition was flashed, which
preserved NVS and both sides of the BLE bond:

```bash
uvx esptool --chip esp32 --port /dev/cu.usbserial-0001 --baud 460800 \
  write-flash 0x10000 \
  targets/mrdiy-esp32-v13/build/vhos_mrdiy_esp32_v13.bin
```

The physical boot produced:

```text
App version: 0.1.0-dev.7
BLE_BOND_STORE our_security_records=1 peer_security_records=1
PASSIVE_CAN_READY mode=listen-only bitrate=500000 rx_gpio=4 tx_gpio=5
VHOS_SOFTAP_DISABLED reason=default-safe-policy activation=encrypted-ble-pending
VHOS_SELF_TEST_PASS firmware=0.1.0-dev.7 build=v4.50p-13-g5077da0221d1
```

The installed image then passed the iPhone recovery check without forgetting the device or erasing
NVS:

```text
IPHONE_LINK_CONNECTED handle=0
BLE_ENCRYPTION status=0
BLE_SUBSCRIBE health/stream/OTA notify=1
BLE_CONN_PARAMS_ACTIVE interval_units=40 latency=0 supervision_units=600
BLE_MTU value=247
```

Recurring health notifications continued throughout the observation. Meanwhile the Mac retained
its normal `192.168.1.118` address and `192.168.1.254` default gateway, and its preferred-network
list contained only the normal home network.

Physical acceptance therefore proves:

- firmware `0.1.0-dev.7` and exact build `v4.50p-13-g5077da0221d1`;
- persisted BLE bond counts;
- `PASSIVE_CAN_READY mode=listen-only`;
- `VHOS_SOFTAP_DISABLED`;
- no Wi-Fi, DHCP, HTTP, or SoftAP initialization in the release boot path;
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
