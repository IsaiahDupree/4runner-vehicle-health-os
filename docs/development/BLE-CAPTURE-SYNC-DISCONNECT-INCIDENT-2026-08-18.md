# BLE capture-sync disconnect incident

Date: 2026-08-18
Status: nonempty in-vehicle transfer failure reproduced on firmware dev29 and iOS 0.3.4 (10);
iOS 0.3.5 (11) contains the failure by using inventory-only refresh while recording is active;
firmware dev31 adds a matching server-side exclusion boundary; iOS 0.3.8 (14) records the reset
reason reported by dev31+ handshakes and defers fringe-range encrypted links; physical regression
acceptance remains open

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

## Nonempty in-vehicle reproduction

The previously open nonempty-transfer gate failed during the next in-vehicle run. The persistent
iPhone BLE flight recorder establishes this chronology in UTC:

| Time | Evidence |
| --- | --- |
| 15:09:54.750 | The iPhone verified the `0.1.0-dev.29` gateway contract. |
| 15:09:54.942 | Health reported 3,388 vehicle frames and 21 TWAI receive misses/overruns. |
| 15:10:03.155 | Health reported 7,807 vehicle frames and 57 receive misses/overruns, matching the field screenshot. |
| 15:10:05.201 | Health advanced to 8,893 vehicle frames and 66 receive misses/overruns. |
| 15:09:55–15:10:06 | In parallel, the app requested 24-record chunks from previous capture session `2175731012`. |
| 15:10:06.594 | CoreBluetooth reported a link disconnect. |
| 15:12:50.604 | A later application session verified dev29 again, with reset CAN counters and different capture-session identifiers, proving the gateway had rebooted during the recovery interval. |
| 15:13:11.032 | A second historical download was followed by another link disconnect. |

The source counters called **Dropped frames** in the UI are the gateway's cumulative TWAI
`rx_missed_count + rx_overrun_count`. They are not inferred from BLE sequence gaps. The move to a
firmware worker fixed filesystem work on the NimBLE callback thread, but this field run proves that
concurrent bulk export still creates unacceptable pressure while live CAN recording is active. The
available evidence does not identify the exact reset instruction or task; that requires a retained
reset reason and synchronized UART evidence in a later firmware build.

## iOS 0.3.5 containment

iOS 0.3.5 (11) changes capture synchronization policy:

- a capture index with `logging=true` updates inventory and recording status only;
- any pending history-transfer task and chunk timeout are cancelled;
- no historical capture-read command is issued while the recorder is actively writing;
- current and previous records remain on the ESP32; and
- the app emits `CAPTURE_SYNC_DEFERRED reason=recorder-active policy=inventory-only` into its
  connection flight recorder.

This containment protects the live CAN receive path and BLE application session. It does not claim
that firmware dev29 can safely export a nonempty capture concurrently with recording. Resumable
bulk transfer remains deferred until the recorder is stopped.

## Dev31 server boundary and iOS 0.3.6 evidence

Firmware dev31 independently enforces the same rule: a history read or manual rotation is rejected
until logging is stopped, CAN producers are quiescent, and every queued or in-flight record has
finished. The read path repeats that proof while holding the capture-file lock. Periodic health now
uses an in-memory status snapshot, export chunks are reduced to 12 records, and the handshake
reports `reset_reason` from ESP-IDF.

iOS 0.3.8 (14) preserves that optional reset reason in the persistent
`HANDSHAKE_VERIFIED` flight-recorder event. Older firmware remains compatible and records
`reset_reason=unavailable`. After one saved-identifier attempt, an encryption timeout moves to a
service-filtered scan. A matching advertisement weaker than -84 dBm remains visible but does not
start another encrypted link; the recorder emits
`WEAK_GATEWAY_DEFERRED` with the observed RSSI. The exact dev31 binary is source/build verified, but vehicle capture,
paused export, forced mid-transfer disconnect, and electrical power-loss acceptance remain open
until that binary is installed on the gateway and exercised in the car.
