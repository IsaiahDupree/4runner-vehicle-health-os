# VHOS Gateway Provisioner

Public, backup-first Web Serial provisioner for the Vehicle Health OS WiCAN Pro
firmware. The site detects the ESP32-S3, reads and downloads the complete flash,
verifies the published merged image by byte count and SHA-256, flashes it at
address zero, and can restore a same-capacity full-flash backup.

## Safety boundary

- Development and bench use only.
- Supports the MeatPi WiCAN Pro (`MP-WICAN-PRO`) ESP32-S3 target only.
- Requires a completed full-flash backup and explicit hardware confirmation
  before enabling installation.
- Does not expose CAN, K-line, J1850, or OBD transmit controls.
- The published development firmware is passive/listen-only. Signed Wi-Fi OTA
  activation and active protocol discovery remain locked pending implementation
  and physical recovery validation.

WiCAN Pro must be powered through its OBD connection while USB-C supplies the
data path. Follow the hardware and bench-power guidance in
`../docs/hardware/RECOMMENDED-HARDWARE.md` before connecting a board.

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
