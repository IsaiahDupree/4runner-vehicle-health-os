# iPhone BLE connection flight recorder

## Purpose

Vehicle Health OS persists the CoreBluetooth evidence the app can actually observe whenever it
scans for, connects to, validates, loses, or reconnects to the OBD/CAN ESP32. This makes a failed
car visit diagnosable without leaving the iPhone attached to Xcode or relying on screenshots.

This is an application-layer flight recorder. An ordinary iOS app cannot export Bluetooth bond
keys, pairing secrets, raw controller/HCI packets, or every over-the-air SMP packet. Those require
an Apple diagnostic capture, a Mac-side controller log, or an external BLE sniffer during a
separately authorized escalation.

## Persisted events

The recorder receives the same structured milestones used by the commissioning console, including:

- app version/build and CoreBluetooth restoration identity;
- user Connect, Reconnect, Cancel, and Disconnect intent;
- Bluetooth manager power/restoration state;
- saved-UUID retrieval and filtered scan lifecycle;
- candidate name, identifier, RSSI, selection evidence, and duplicate/stale-link rejection;
- physical connection or exact `CBErrorDomain` failure;
- service and characteristic discovery;
- encrypted stream-CCCD request, timeout, and result;
- handshake write begin, per-write acknowledgement, response timeout, and CRC-valid verification;
- decoded health/capture-index arrival;
- disconnect reason, automatic-reconnect scheduling, and recovered handshake;
- OTA and capture-synchronization transport milestones.

The recorder does not infer that a pairing succeeded merely because iOS lists a device as
Connected. The application contract is successful only after the CRC-valid VHOS handshake is
decoded on the current link session.

## Record contract

Each line is independently valid JSON under `ble.connection.event@1.0.0`:

```json
{
  "contract": "ble.connection.event",
  "contract_version": "1.0.0",
  "sequence": 42,
  "recorded_at": "2026-08-18T12:00:00.123Z",
  "monotonic_microseconds": 98431234,
  "process_instance": "A1B2C3D4",
  "event": "HANDSHAKE_VERIFIED",
  "detail": "client=A1B2C3D4 HANDSHAKE_VERIFIED firmware=0.1.0-dev.29"
}
```

Wall time supports human correlation with the ESP32 UART log. Monotonic time supports duration
analysis without wall-clock corrections. Process instance and link-session details prevent a late
callback from an older physical link from being attributed to a new one.

## Retention and privacy

- Storage is append-only NDJSON in the app's Application Support directory.
- A file rotates at 512 KiB.
- The newest eight files are retained, bounding normal storage to approximately 4 MiB plus one
  oversized record at a rotation boundary.
- Each event is synchronized after append so a later app crash does not erase the preceding
  connection history.
- No bond key, bearer token, OTA password, firmware signing key, or unrestricted advertisement
  payload is written.
- Export remains an explicit owner action through the iOS share sheet.

## Owner export path

1. Open **Evidence** in the iPhone app.
2. Find **Bluetooth connection flight recorder**.
3. Tap **Prepare Bluetooth connection log**.
4. Tap **Share ble-connection-flight-recorder.ndjson**.
5. Save to Files, AirDrop it to the Mac, or attach it to the engineering handoff.

The export concatenates retained segments in chronological filename order without changing any
record bytes. CAN evidence remains a separate export because Bluetooth transport health and vehicle
observations have different evidence authority.

## Triage queries

Useful event sequences include:

```text
CONNECT_REQUEST
LINK_CONNECTED
SERVICES_DISCOVERED
CHARACTERISTICS_DISCOVERED
SUBSCRIBE_REQUEST
SUBSCRIBE_READY
HANDSHAKE_REQUEST_WRITE_ACK
HANDSHAKE_VERIFIED
HEALTH_DECODED
```

Common failure boundaries:

```text
LINK_FAILED_DETAIL                 physical connection did not complete
SUBSCRIBE_FAILED                   encrypted notification setup failed
SUBSCRIBE_WATCHDOG_TIMEOUT         iOS did not finish the CCCD operation in time
HANDSHAKE_WRITE_ACK_TIMEOUT        reliable command write did not complete
HANDSHAKE_RESPONSE_EXHAUSTED       physical/GATT link exists but VHOS contract did not answer
LINK_DISCONNECTED                  established link was lost
RECONNECT_SCHEDULED                automatic recovery began
```

Analysis should group records by process instance and `link_session`, then calculate phase latency,
failure frequency, recovery time, RSSI at selection, last successful milestone, and whether the same
failure repeats across app, ESP32, power, and vehicle environments.

## Escalation evidence

If the application log ends at a pairing or controller boundary, collect it together with:

- the ESP32 UART trace using the same wall-clock window;
- the iPhone app version/build and firmware version;
- whether the system Pair sheet appeared and the approximate tap time;
- an Apple sysdiagnose/Bluetooth diagnostic captured immediately after reproduction when available;
- a Mac PacketLogger or external BLE-sniffer capture only when radio-layer evidence is necessary.

The app flight recorder is the default field artifact. Deeper OS/radio captures are escalation tools,
not a prerequisite for normal users.

## Physical verification

The signed iPhone build `0.3.4 (10)` was installed on the paired development iPhone on
2026-08-18. A read-only app-container copy recovered 15 valid records across two app launches with
one continuous sequence (`1...15`), proving that the log survives replacement installs and process
relaunches.

That run also captured a real unsuccessful bench reconnect without relying on a screenshot:

```text
KNOWN_GATEWAY_RECONNECT
CONNECT_REQUEST
CONNECT_TIMEOUT                         about 12 seconds later
RESTORED_PERIPHERAL_RETIRING
RESTORED_PERIPHERAL_RETIRED
RESTORED_CLEANUP_COMPLETE
SCAN_START                              service-filtered recovery
SCAN_FALLBACK                           zero advertisements observed
```

This evidence localizes that attempt before GATT discovery: the saved gateway was known to iOS,
but its physical BLE connection did not complete and the gateway was not subsequently observed by
the filtered or fallback scan. It does not support blaming the VHOS handshake, CCCD, frame decoder,
or CAN path for that attempt because none of those phases had begun.
