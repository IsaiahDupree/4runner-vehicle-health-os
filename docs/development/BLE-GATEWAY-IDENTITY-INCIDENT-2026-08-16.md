# BLE gateway identity incident — generic FEE0 peripheral selected

## Outcome

The iOS gateway client no longer treats a raw Bluetooth connection or the generic `FEE0`
service as proof that a peripheral is a VHOS/WiCAN gateway. A signed development build containing
the correction was installed on the paired iPhone on 2026-08-16.

The physical vehicle gateway was independently identified over USB as the expected classic ESP32:

```text
USB port: /dev/cu.usbserial-0001
chip: ESP32-D0WDQ6 revision 1.1
base MAC: 94:54:c5:b0:8d:14
firmware: 0.1.0-dev.7
build: v4.50p-13-g5077da0221d1
BLE name: VHOS-MRDIY-B08D14
CAN: listen-only, 500000 bit/s, RX GPIO 4, TX GPIO 5
SoftAP: disabled by default-safe policy
```

The iPhone then selected the correct versioned VHOS advertisement and discovered the expected
service and four characteristics in a live run. Later runs continued to select only
`VHOS-MRDIY-B08D14`, but their approximately `-83` to `-95 dBm` RSSI was too weak for a repeatable
contract handshake. That weak-link condition remains an open physical acceptance gate; this
record does not claim OBD-II confirmation or a durable vehicle session.

## User-visible symptom

The status screen showed:

- **Gateway scan: FOUND — Battery Monitor**;
- **ESP32 BLE link: CONNECTED**;
- **VHOS BLE service: NOT FOUND**; and
- **OBD-II: UNVERIFIED**.

The lower indicators were more truthful than the summary, but the green raw-link indicators still
implied that an ESP32 gateway had been found. The selected CoreBluetooth identifier was not the
known VHOS gateway identifier.

## Root causes

### `FEE0` was treated as gateway identity

The factory-compatibility path accepted any advertisement or system-connected peripheral exposing
`FEE0`. That UUID is not exclusive proof of WiCAN identity. A nearby `Battery Monitor` could
therefore enter service discovery and appear as a found gateway.

### State restoration selected the first peripheral

CoreBluetooth restoration may return more than one peripheral associated with a restoration
identifier. The client selected the first item without first checking whether that exact
CoreBluetooth identifier had completed a prior gateway service validation.

### Stale callbacks could mutate the active session

After an unverified restored peripheral was cancelled, its delayed connect, failure, service, or
disconnect callback could arrive after the real VHOS advertisement had been selected. The callback
handlers did not require the callback peripheral to equal the current selection.

### More than one model could construct a radio owner

The BLE client performed CoreBluetooth initialization in its constructor. SwiftUI can construct
transient model values while resolving state, which allowed more than one central manager to
compete for the same peripheral. The BLE client is now a process singleton; all UI and lifecycle
paths use the same instance.

### The GATT timeout collapsed identity and transport failure

A service-discovery timeout was treated the same as a definitive wrong-service result. At very
weak RSSI, the real VHOS advertisement could be rejected and rescanned instead of retaining its
strong advertisement evidence and retrying the link.

## Correct identity policy

The evidence ladder is now explicit:

1. A generic advertisement is only an observation.
2. The versioned VHOS service UUID in an advertisement is sufficient to select a **candidate**.
3. A name containing `VHOS` or `WiCAN` may select a fallback candidate, but does not prove it.
4. A discovered versioned VHOS GATT service proves VHOS gateway identity for that session.
5. Factory compatibility requires both the `FEE0` GATT service and `VHOS`/`WiCAN` name evidence.
6. A previously validated CoreBluetooth identifier may be restored as a candidate, but its saved
   identifier alone never proves the current firmware identity.
7. A versioned handshake is still required before the app reports `VHOS ONLINE` or enables any
   experiment path.

`Battery Monitor + FEE0` therefore fails both candidate selection from advertisements and gateway
proof after service discovery.

## State-machine corrections

The iOS client now:

- retrieves system-connected peripherals only by the versioned VHOS service, not `FEE0`;
- keeps a local allowlist only after successful service-level gateway validation;
- rejects unallowlisted CoreBluetooth restoration entries and resumes a service-filtered scan;
- validates every asynchronous callback against the current peripheral identifier;
- ignores duplicate scan requests while scanning or connecting;
- distinguishes `CANDIDATE`/`VALIDATING` from `VERIFIED` in the status UI;
- reports CoreBluetooth RSSI sentinel `127` as unavailable;
- retains a trusted VHOS advertisement across a slow GATT timeout and reconnects instead of
  forgetting it; and
- uses exactly one process-wide `GatewayBLEClient`/`CBCentralManager` owner.

## Verification

Automated policy tests cover:

- rejection of `Battery Monitor + FEE0`;
- authoritative acceptance of the versioned VHOS service;
- name evidence required for factory compatibility; and
- exact-identifier allowlisting for restoration.

The complete `VHOSCore` suite passes with 18 tests. The full iPhoneOS target builds both unsigned
and with the paired development profile. The signed app was installed through CoreDevice.

Live commissioning trace established:

```text
GATEWAY_MATCH name=VHOS-MRDIY-B08D14 rssi=-91
LINK_CONNECTED id=1AF5AF93-4942-23AC-3A95-3BF8C3FA43A8
SERVICES_DISCOVERED uuids=33613EB3-FFCA-42D1-83FA-A18F12B3F123
CHARACTERISTICS_DISCOVERED ... count=4
```

The trace also showed later RSSI values down to `-95 dBm`. Final vehicle acceptance requires the
iPhone beside the gateway or an antenna/enclosure placement that yields a stable BLE link, then:

1. versioned handshake received;
2. recurring current-session health frames;
3. listen-only state reported by both handshake and health;
4. nonzero vehicle-bus frames while the vehicle is producing traffic; and
5. a bounded protocol experiment result before any OBD-II status is promoted.

## Why the UI remains conservative

A connected BLE socket proves only that iOS opened a radio link to a peripheral. It does not prove
the peer is an ESP32, that VHOS firmware is running, that CAN is wired, or that an OBD protocol has
responded. Each green state is therefore delayed until its own evidence layer is present. This is
the transport equivalent of the project rule that no displayed conclusion may outrun its evidence.
