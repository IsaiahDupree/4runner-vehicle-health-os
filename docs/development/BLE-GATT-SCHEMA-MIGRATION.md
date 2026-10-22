# BLE GATT schema migration and automatic iPhone recovery

Status: app recovery implemented after the `v0.1.0-dev.13` gateway incident

## Observed failure

The iPhone could discover `VHOS-MRDIY-B08D14`, establish the Core Bluetooth link, and report a
healthy RSSI, but it remained at `VALIDATING`. The versioned VHOS BLE service stayed `NOT FOUND`, so
the command channel, notification streams, handshake, OBD evidence, and tests never became ready.

This combination is important:

- advertisement received;
- physical BLE link connected;
- service discovery did not complete;
- signal strength was healthy.

It is evidence of a GATT identity/cache problem, not evidence of poor range or an OBD-II problem.

## Root cause

The dev12 firmware added an OTA status characteristic while retaining the gateway's bonded,
random-static BLE identity. iOS is permitted to cache the GATT database for a bonded peripheral.
The radio link could therefore reconnect using the previous identity while Core Bluetooth still
held obsolete service metadata.

The app's prior timeout path canceled that link and scheduled another connection to the same
`CBPeripheral`. That made recovery circular: reconnect, validate, time out, reconnect.

## Two-sided recovery contract

Gateway firmware and the iPhone app now have separate responsibilities.

### Gateway

The gateway persists an integer GATT schema version. When that version changes, firmware clears
obsolete NimBLE bond/CCCD records and rotates the random-static identity once before advertising.
Ordinary reboots with the same schema retain the identity and bond.

### iPhone

If service or characteristic discovery fails or times out, the app:

1. disables reconnect to that stale in-memory candidate;
2. cancels the current Core Bluetooth link;
3. resets only the transient transport session;
4. resumes the service-filtered scan;
5. selects the newly advertised gateway identity;
6. performs fresh service discovery and pairing.

This does not call private APIs, erase iPhone Bluetooth settings, or ask the owner to forget a
device. Permanent capture logs and vehicle evidence are unaffected.

## What the owner should experience

During the first connection after a GATT-changing firmware update, the status message may briefly
say that the saved gateway database is stale and that the app is scanning for the current identity.
The normal sequence then resumes automatically:

```text
gateway candidate
  -> BLE link
  -> VHOS service
  -> four characteristics
  -> encrypted notifications
  -> handshake
  -> health stream
```

The Settings instruction “Forget This Device” is not part of the normal or recovery workflow.

## Field evidence for dev13

The connected MrDIY device was flashed over USB without erasing NVS or the capture partition. Its
post-migration boot reported:

- firmware `0.1.0-dev.13`;
- GATT schema `2`;
- a new random-static BLE address;
- zero stale local and peer security records;
- SoftAP disabled;
- listen-only CAN enabled;
- self-test pass.

An independent macOS Core Bluetooth scan then observed the complete advertised VHOS service UUID.
A GATT connection enumerated the required command, evidence-stream, health, and OTA-status
characteristics with their expected properties. This proves the gateway database is available; the
remaining acceptance gate is the iPhone completing pairing, subscriptions, handshake, and live
health after selecting the new identity.

### Follow-up validation on 2026-08-17

After the iPhone again displayed `CANDIDATE`, `VALIDATING`, and `VHOS BLE service: NOT FOUND`, the
same powered gateway was tested independently from macOS. The Mac found
`VHOS-MRDIY-B08D14`, connected, and enumerated the exact service plus all four required
characteristics. The ESP32 UART simultaneously recorded a valid connection, ATT MTU 247, accepted
connection-parameter update, clean client disconnect, and resumed advertising. This isolates the
remaining loop to the installed iPhone app/Core Bluetooth session rather than the firmware GATT
database or RF range.

App `0.3.1` build `7` therefore includes both the stale-candidate rescan behavior and a dedicated
Debug commissioning entitlement set. The Debug build can be signed by the existing wildcard local
development profile and installed for BLE commissioning; it intentionally does not claim automatic
Wi-Fi network joining. Release still requires an Apple provisioning profile that explicitly grants
Hotspot Configuration before iPhone-managed Wi-Fi OTA is accepted.

The signed commissioning build passed the physical-device SDK build. Installation and the final
iPhone handshake remain pending whenever the paired iPhone is offline or unavailable to CoreDevice.

## Future schema rule

Firmware must increment its GATT schema constant whenever it changes a registered service,
characteristic, descriptor, UUID, property, or attribute order. Payload-only changes do not require
a schema increment. App recovery remains enabled as a second line of defense for interrupted
migrations and stale restored Core Bluetooth state.
