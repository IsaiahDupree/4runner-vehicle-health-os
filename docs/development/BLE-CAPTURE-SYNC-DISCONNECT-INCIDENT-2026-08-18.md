# BLE capture-sync disconnect incident

Date: 2026-08-18
Status: firmware dev29 and iOS 0.3.3 (9) installed; BLE reset/process-loss recovery passed;
nonempty vehicle-capture transfer acceptance remains open

## Symptom

Firmware dev27 connected and verified normally in the vehicle, then the iPhone resumed a previous
2,208-record CAN capture. The download advanced through record offset 840 before the BLE link
dropped. Later physical links reached the controller but GATT service enumeration timed out. A
separate strong-RSSI macOS discovery probe reproduced the GATT timeout, placing the failure inside
the gateway rather than the iPhone UI or saved peripheral selection.

## Root boundary

The dev27 capture-read command performed SPIFFS open, seek, and read operations synchronously in
the NimBLE GATT write callback. Filesystem latency therefore owned the BLE host event thread during
a bulk transfer. The exact filesystem call cannot be allowed to delay pairing, ATT, supervision,
or disconnect processing.

The later boot investigation found a second, independent retention defect. Rotation always removed
the previous segment before examining whether the current segment contained a complete record. A
header-only or empty current segment after another reboot could therefore replace a useful previous
capture. The already-lost segment cannot be reconstructed and is not claimed as downloaded.

## Corrections

Firmware dev28 moves capture export to a dedicated 6 KiB worker with a single-request queue and a
transport generation. The GATT callback validates and queues an allowlisted request without file
I/O. Results are admitted only while their generation and connection epoch still match. Disconnect
or host reset invalidates old work.

Firmware dev29 retains a previous segment unless the current file contains at least one complete,
CRC-framed capture record. Promotion is logged as `CAPTURE_ROTATE_PROMOTED`; an empty/header-only
current file logs `CAPTURE_ROTATE_PRESERVED_PREVIOUS`. A failed rename stops rotation and keeps the
current source file rather than silently discarding evidence.

iOS 0.3.3 (9) complements that boundary:

- waits three seconds after a healthy contract before starting Recent Logs synchronization;
- keeps exactly one 24-record capture request in flight;
- spaces successful chunks by 500 ms;
- applies an eight-second response timeout;
- pauses only background Recent Logs synchronization on a timeout or write error;
- keeps live health and the application session connected;
- resumes later from the durable local record offset.

The same build now retires any connected or connecting CoreBluetooth object inherited from a
previous app process before opening a fresh link. It preserves the verified UUID and iOS bond, so
process recovery cannot reuse a previous process's unconfirmed notification state.

## Physical result and evidence boundary

Firmware dev29 and iOS 0.3.3 (9) passed baseline plus six alternating real-device faults: three
CP2102 RTS resets and three app process kills/relaunches. Every cycle opened a new physical link,
verified firmware dev29, and delivered five health frames inside a 55-second total budget. The
full chronology and stopped-file hashes are in
[the fault-injection plan](BLE-FAULT-INJECTION-TEST-PLAN.md).

This proves the exercised BLE boot, saved-bond, stale-restoration, application-contract, and health
recovery paths. It does not yet prove:

- a true electrical rail cut;
- preservation of a nonempty previous capture across repeated vehicle-power cycles;
- complete resumable transfer of a real nonempty capture through an injected mid-download loss;
- sustained in-vehicle CAN recording; or
- signed OTA upload and rollback under power loss.

Those remain field gates. No simulator output or zero-frame USB-bench report may be substituted for
them.
