# Passive CAN vehicle run — 2026-08-16

## Outcome

The BLE transport, gateway contract, health decoder, and bounded passive bitrate state machine are
working end to end on physical hardware. The connected gateway did not observe a valid CAN frame
during repeated 500 kbit/s and 250 kbit/s windows. The vehicle-bus outcome is therefore
`INCONCLUSIVE / NO_PASSIVE_LOCK`; it is not an OBD-II rejection.

## Exact artifacts

| Layer | Accepted artifact |
| --- | --- |
| Gateway hardware | MrDIY CAN Shield v1.3+ target, classic ESP32 MAC `94:54:c5:b0:8d:14` |
| Firmware | `v0.1.0-dev.10`, commit `3cd94915beef42477289d0d65d274f5f7bf3d3a1` |
| Firmware config | `mrdiy-v13-passive-can-scan` version `0.2.0` |
| Application image SHA-256 | `3a37e543467eff68261614a4fab2b0e1bb60c5424500c2b7acff3126848459ac` |
| iOS app | version `0.2.0`, commit `a7bdea8970d3df47992b05414e2ae416927c0c2f` plus the trace-only follow-up that links to this record |
| iPhone | Paired development iPhone 15, wireless install through CoreDevice |

Only the application partition at `0x10000` was flashed. NVS, the persisted BLE identity epoch, the
bootloader, partition table, OTA metadata, and rollback topology were not erased or replaced.

## Boot and safety evidence

The physical serial run reported:

```text
App version: 0.1.0-dev.10
PASSIVE_CAN_READY mode=listen-only initial_bitrate=500000 probe_window_ms=10000 lock_minimum_frames=3 rx_gpio=4 tx_gpio=5
BLE_BOND_STORE our_security_records=1 peer_security_records=1
BLE_IDENTITY_READY type=random-static source=persisted address=e3:2d:bd:5e:5d:ed
VHOS_SOFTAP_DISABLED reason=default-safe-policy activation=encrypted-ble-pending
VHOS_SELF_TEST_PASS firmware=0.1.0-dev.10 build=v4.50p-17-g3cd94915beef
```

Release validation independently passed the ESP32 target, byte-exact merged image, A/B topology,
rollback configuration, application size, listen-only/no-transmit source check, passive 500/250
probe controls, persistent BLE identity recovery, and default-off authenticated status surface.

The target contains no `twai_transmit` call, has a zero-length transmit queue, and installs every
TWAI controller instance in `TWAI_MODE_LISTEN_ONLY`.

## iPhone evidence

The newly installed app automatically found the existing CoreBluetooth peripheral, connected,
discovered the versioned VHOS service, verified the `dev.10` handshake, subscribed to the health
stream, and decoded repeated health frames. No iOS Settings “Forget This Device” action was used.

The live frames followed the expected state sequence:

```text
PROBING_500K  bitrate=500000  frames=0  candidate=none
PROBING_250K  bitrate=250000  frames=0  candidate=none
PROBING_500K  bitrate=500000  frames=0  candidate=none
PROBING_250K  bitrate=250000  frames=0  candidate=none
```

The iOS System Status page now exposes the controller state, probe state/cycle, active bitrate,
passive candidate, 11-bit/29-bit counts, 500/250-kbit counts, received/dropped/error/bus-off
counters, and the existing BLE/contract/notification states. A CAN lock is explicitly labeled as a
passive candidate and never promotes the OBD-II indicator.

## Interpretation boundary

The run proves that software is changing the local CAN controller bitrate and reporting each state
over an authenticated BLE session. Zero valid frames cannot, by itself, identify which downstream
condition applies:

- the vehicle was not in the required awake ignition state;
- the DLC-to-transceiver CAN path, transceiver power/standby state, or GPIO mapping is incorrect;
- the target network uses another CAN bitrate not included in this bounded milestone; or
- the target diagnostic transport is ISO 9141-2, ISO 14230-4, or SAE J1850 rather than CAN.

Supply voltage, vehicle motion, storage, and OBD protocol remain unavailable or unverified. No
software should infer those states from the successful BLE connection or silent CAN windows.

## Next accepted experiment

1. Record the vehicle VIN profile and test state explicitly: ignition on or engine running, parked,
   and no second active scan tool connected.
2. Repeat at least one complete 500/250 cycle. Preserve the exact health frames and timestamps.
3. If counters remain zero, inspect the physical DLC/transceiver path with the vehicle wiring
   information and qualified test equipment. Do not add termination to the vehicle bus or probe it
   with an active CAN source.
4. Bench-validate this MrDIY target against CANable 2.0 using labeled 11-bit and 29-bit frames at
   both rates. That separates firmware/GPIO/transceiver behavior from the vehicle.
5. Use the specified WiCAN Pro dedicated all-protocol interpreter for the signed, allowlisted
   supported-PID discovery sequence in [Safe protocol discovery](SAFE-PROTOCOL-DISCOVERY.md).
6. Corroborate the selected protocol independently with OBDLink MX+ before promotion.

The exact field and bench devices are maintained in
[Recommended hardware](../hardware/RECOMMENDED-HARDWARE.md). The current MrDIY board is useful for
passive CAN development but cannot electrically test the K-line or J1850 candidates required by
the all-protocol fallback.
