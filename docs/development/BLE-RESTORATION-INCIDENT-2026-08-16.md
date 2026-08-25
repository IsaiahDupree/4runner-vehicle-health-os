# BLE restoration incident — 2026-08-16

## Summary

During physical iPhone commissioning, the VHOS gateway could complete its secure handshake and
stream health data, then later cycle between `CONNECTED` and `RECONNECTING`. In another observed
state, the app scanned more than 1,600 nearby advertisements without seeing the gateway.

This was not evidence that the saved BLE bond had been lost. The ESP32 retained one local and one
peer security record, and the iPhone repeatedly recognized the same peripheral identifier.

## Observed failure modes

1. CoreBluetooth established the radio link, but the VHOS service was not available before a
   connection timeout.
2. After app termination or replacement, CoreBluetooth restored the peripheral with state
   `.connected`, but GATT service discovery could remain unresponsive.
3. With auto-scan requested, the app could ignore that restored live peripheral and scan instead.
   A connected ESP32 does not advertise, so the scan could never rediscover it.
4. The app could issue another `connect` call for an already-connected or already-connecting
   peripheral.
5. Reconnect attempt accounting reset at the low-level link event, producing repeated attempt-one
   cycles even though the gateway contract had not recovered.
6. CoreBluetooth system auto-reconnect raced the app's own scheduled retry. The system could
   reconnect immediately even while the UI correctly reported a longer backoff, creating another
   connection-timeout loop.
7. Firmware serial evidence identified disconnect reason `520` as a controller-reported HCI
   connection-supervision timeout (`0x08`). At the time, a short inherited supervision window was
   one plausible contributor to some reconnects even when encryption and notification
   subscriptions restored successfully.

### Later decoding clarification — 2026-08-17

Later synchronized `dev.20` evidence refined how these numbers must be interpreted. In that run,
`BLE_ENCRYPTION status=13` was exactly NimBLE host error `BLE_HS_ETIMEOUT` after the Security
Manager's 30-second procedure timer. Disconnect reason `520` arrived later and decoded as host-
encoded HCI `0x08`, connection supervision timeout. It was the controller's terminal report for a
link that had already stalled, not proof by itself that the configured supervision interval caused
the security failure.

Disconnect reason `531` is different: `0x213` decodes to HCI `0x13`, remote user terminated the
connection. From the ESP32's perspective this is expected when iOS intentionally cancels or retires
a link, including stale-restoration cleanup. It must not be grouped with reason `520` or reported as
an ESP32 reset.

The complete `dev.20` through `dev.23` diagnosis, including pre-`CONNECT` encryption/CCCD restore
ordering, is in the
[pairing and restored-session incident](BLE-PAIRING-RESET-INCIDENT-2026-08-17.md).

The earlier ESP32 `nimble_host` stack overflow was a separate failure and was fixed in firmware
`v0.1.0-dev.4` by increasing the host stack and pacing notification traffic.

## Corrective behavior

iOS build 5 changes the connection state machine to:

- adopt a restored `.connected` peripheral and resume GATT discovery directly;
- wait for a restored `.connecting` peripheral instead of duplicating the request;
- query system-connected VHOS/factory peripherals before starting an advertisement scan;
- cancel and reconnect an unresponsive GATT session after six seconds while retaining the bond;
- retain exponential reconnect history until the versioned VHOS handshake succeeds; and
- use one app-managed retry policy rather than overlapping it with system auto-reconnect; and
- emit commissioning traces containing disconnect domains/codes and GATT discovery phases.

Firmware `v0.1.0-dev.5` requests a 30–50 ms connection interval, zero peripheral latency, and a
six-second supervision timeout. It logs the initial, requested, and active connection parameters
plus the negotiated ATT MTU so physical reconnect failures remain diagnosable.

No ordinary recovery path erases the phone pairing or ESP32 NVS. `Forget This Device` is reserved
for confirmed security-state corruption, intentional NVS erase, or gateway replacement.

## Physical verification

The corrected iOS build was signed and installed on the attached iPhone. Firmware
`v0.1.0-dev.5` was flashed only to the application partition, preserving both NVS bond records,
and produced this real sequence:

```text
BLE_BOND_STORE our_security_records=1 peer_security_records=1
GATEWAY_MATCH name=VHOS-MRDIY-B08D14 rssi=-50
LINK_CONNECTED source=did-connect state=2
BLE_CONN_PARAMS_REQUEST interval_units=24-40 latency=0 supervision_units=600
BLE_CONN_PARAMS_ACTIVE interval_units=40 latency=0 supervision_units=600
BLE_MTU value=247
SERVICES_DISCOVERED uuids=33613EB3-FFCA-42D1-83FA-A18F12B3F123
CHARACTERISTICS_DISCOVERED count=4
HANDSHAKE_VERIFIED firmware=0.1.0-dev.5
```

The first verified session then remained connected for more than one minute with recurring live
health notifications and no supervision timeout. An app terminate/relaunch test recovered the
same saved peripheral and completed another verified handshake without `Forget This Device` or an
ESP32 NVS erase. Longer foreground/background, ESP32-reboot, and radio-loss endurance testing
remains an acceptance gate rather than a claim made by this incident check.

## Wi-Fi access-point status

The current MrDIY target firmware does **not** initialize Wi-Fi, start a SoftAP, run an HTTP
server, or expose a browser status page. Its current real data path is BLE only. The public VHOS
web flasher runs on the internet and programs the ESP32 over desktop USB; it is not hosted by the
ESP32.

A future read-only local status surface should use the same gateway-health source as BLE and may
show firmware/build identity, uptime/reset reason, listen-only enforcement, received/dropped/error
frame counters, storage, supply, and OTA/rollback state. It must not expose arbitrary CAN transmit
or diagnostic commands. The SoftAP must be authenticated, time-bounded or explicitly enabled, and
must not publish secrets, bond identities, raw keys, or fabricated unavailable values.

Update: that surface was implemented in the unreleased `v0.1.0-dev.6` bench image. Physical Mac
association testing showed that automatic boot activation was disruptive, so `v0.1.0-dev.7`
keeps Wi-Fi completely off by default and reserves activation for an explicit encrypted owner
action. See the [SoftAP activation incident and decision](ESP32-SOFTAP-ACTIVATION-INCIDENT-2026-08-16.md).

Update: a later vehicle session exposed a separate identity-selection failure in which a generic
`FEE0` peripheral named `Battery Monitor` was shown as the ESP32 link. The correction and its
evidence ladder are recorded in
[BLE gateway identity incident](BLE-GATEWAY-IDENTITY-INCIDENT-2026-08-16.md).
