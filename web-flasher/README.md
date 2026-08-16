# VHOS Gateway Provisioner

Public, backup-first Web Serial provisioner for Vehicle Health OS gateway
firmware. The operator must select an exact hardware target before the site
requests serial access. The site rejects a mismatched chip, reads and downloads
the complete flash, verifies the target-specific merged image by byte count and
SHA-256, flashes it at address zero, and can restore a same-capacity full-flash
backup.

## Safety boundary

- Development and bench use only.
- Supports two distinct, non-interchangeable targets:
  - classic ESP32-D0WDQ6 + MrDIY CAN Shield v1.3+ (RX GPIO 4 / TX GPIO 5)
  - MeatPi WiCAN Pro (`MP-WICAN-PRO`) ESP32-S3
- Requires explicit target selection and rejects cross-family flashing.
- Requires a completed full-flash backup and explicit hardware confirmation
  before enabling installation.
- Does not expose CAN, K-line, J1850, or OBD transmit controls.
- The published development firmware is passive/listen-only. Physical backup,
  merged-image, A/B topology, and rollback recovery validation are published with
  each MrDIY release. Signed Wi-Fi OTA activation and active protocol discovery
  remain locked pending implementation.

Follow the target-specific connection copy in the provisioner and the hardware
and bench-power guidance in `../docs/hardware/RECOMMENDED-HARDWARE.md` before
connecting either board.

## Browser requirements

- Desktop Chrome or Edge with Web Serial support.
- HTTPS in production (`localhost` is accepted for development).
- A known-good USB-C data cable.

## Local verification

```bash
npm ci
npm run lint
npm test
```

The release manifest and byte-identical merged image are served from
`public/firmware/` so browser verification stays same-origin. The canonical
source and release evidence are also published in
[`IsaiahDupree/4runner-vhos-firmware`](https://github.com/IsaiahDupree/4runner-vhos-firmware).
