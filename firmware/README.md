# ESP32 gateway boundary

Firmware implementation begins in E2 after the exact ESP32 board, CAN transceiver/protection, and power design are selected and bench hardware is available.

The component catalog in `components.toml` is the accepted architecture. It does not contain fake hardware drivers or a permissive transmit stub.

## Startup safety state

1. Boot with vehicle-bus transmission disabled.
2. Validate signed configuration, hardware revision, compatibility, and checksums.
3. Initialize TWAI in listen-only mode and expose health counters.
4. Permit only firmware-resident, versioned read-request allowlist entries after deterministic policy checks.
5. Never expose Active Tests, arbitrary raw-frame transmission, code clearing, ECU flashing, or actuation in MVP.

The permanent installation requires a protected automotive power input and external CAN transceiver. ESP32 GPIO must never connect directly to CANH/CANL.
