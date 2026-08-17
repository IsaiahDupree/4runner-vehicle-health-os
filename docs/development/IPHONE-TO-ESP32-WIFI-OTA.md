# iPhone to ESP32 authenticated Wi-Fi OTA

Status: app and gateway implementation complete for development build `0.3.0 (6)` / firmware
`v0.1.0-dev.12`; automated tests pass; physical install and rollback acceptance pending

## Purpose

After one USB installation, the owner should be able to bring an iPhone within BLE/Wi-Fi range,
select a trusted `.vhosota` package, approve the update, and install the inner signed ESP-IDF
application without a Mac or another USB trip. The normal telemetry path remains BLE. Wi-Fi exists
only as a temporary bulk transport for an approved image.

This is not remote internet OTA. The ESP32 never joins a home network and exposes no public host.

## User flow

1. Connect the app to the versioned VHOS BLE service.
2. The development build seeds its checked-in 32-byte Ed25519 public key into Keychain only when no
   release key exists. Manual key import remains available for controlled rotation.
3. Select a `.vhosota` file from Files.
4. The app verifies the package signature, exact firmware SHA-256, manifest contract, and length.
5. Tap Install and explicitly confirm the owner action.
6. The app pauses the passive recorder and waits for both the capture index and live health to
   report a flushed inactive state.
7. Preflight verifies deterministic PARKED, reported supply voltage, listen-only agreement,
   hardware compatibility, minimum bootloader, required capabilities, size, and no downgrade.
8. The app sends `ACTIVATE` over the encrypted BLE command characteristic.
9. The gateway returns a gateway-bound SSID, passphrase, upload URL, token, and lease over the
   encrypted OTA notification characteristic.
10. iOS presents the system join prompt and applies a hidden `joinOnce` hotspot configuration.
11. The app POSTs only the inner signed application bytes with the bearer token.
12. The gateway validates and responds before rebooting.
13. The app removes the temporary configuration. BLE restoration/reconnect obtains `POST_PASSED`
    or `ROLLED_BACK` from the gateway.

If any step before accepted upload fails, the app requests OTA cancellation, removes the temporary
Wi-Fi configuration, and resumes passive logging.

## Why both BLE and Wi-Fi are used

BLE provides an encrypted, identity-preserving control path and is already connected before the
update. It is suitable for the small activation/status contracts. Wi-Fi provides sufficient
throughput for an approximately 1 MiB application without turning a long BLE transfer into a
fragile foreground session.

The credentials travel only through encrypted BLE. The application image travels through a hidden
WPA2/PMF local network plus bearer authorization, and remains protected by Ed25519 container and
ESP-IDF ECDSA image signatures.

## iOS capability and privacy declarations

The Xcode project contains:

- `com.apple.developer.networking.HotspotConfiguration = true` in the signed app entitlement;
- `NSLocalNetworkUsageDescription` for the isolated gateway link;
- `NSAllowsLocalNetworking` for the local HTTP endpoint; and
- the existing Bluetooth central permission/background declaration.

`NEHotspotConfiguration` is configured with `hidden = true` and `joinOnce = true`. The app also
calls `removeConfiguration(forSSID:)` after success or failure. iOS may briefly leave the normal
Wi-Fi network; this is expected and bounded. The gateway provides no internet route, so the phone
may use cellular during the update.

The app never silently joins an advertised ESP32 network at launch.

## Package contract

The v1 `.vhosota` layout is:

| Offset | Field | Encoding |
| --- | --- | --- |
| 0 | Magic | `VHUP` |
| 4 | Format version | UInt16 big-endian, `1` |
| 6 | Manifest length | UInt32 big-endian |
| 10 | Firmware length | UInt32 big-endian |
| 14 | Signature length | UInt16 big-endian |
| 16 | Manifest | canonical sorted-key compact UTF-8 JSON |
| next | Firmware | exact natively signed ESP-IDF application image |
| final | Signature | Ed25519 signature over `SHA256(manifest || firmware)` |

The manifest binds:

- package UUID, release channel, and creation time;
- firmware version and immutable build ID;
- exact firmware SHA-256 and byte count;
- exact supported hardware revisions;
- optional minimum bootloader;
- minimum gateway supply voltage; and
- required `ota.ab`, `ota.signed-image`, and `ota.rollback-self-test` capabilities.

The development package command is:

```bash
.venv/bin/vhos package-firmware \
  --firmware /path/to/natively-signed-application.bin \
  --output /path/to/vhos-mrdiy-v0.1.0-dev.12.vhosota \
  --private-key "$HOME/.config/vhos/keys/mrdiy-v13-development-release-ed25519.pem" \
  --firmware-version 0.1.0-dev.12 \
  --firmware-build-id <exact-git-build-id> \
  --hardware-revision 'MrDIY-CAN-SHIELD-v1.3+' \
  --minimum-supply-millivolts 11800
```

The private key path shown is an operator example, not a repository path. The public key is safe to
publish. Verify a package before release with:

```bash
.venv/bin/vhos verify-firmware-package firmware.vhosota \
  --public-key keys/mrdiy-v13-development-release-ed25519.base64
```

The checked-in development public key (also bundled in the development app) has SHA-256 fingerprint
`6cd5ba1db6c2918ce58b167f3a6649c86187ba82fe7ef940eb68a9bac1246102`. The matching private
key is external to the repository and must never be copied into source control or the app bundle.

## Preflight behavior and current honest blocker

The installer intentionally refuses `UNKNOWN` motion and `null` supply voltage. The current MrDIY
gateway health contract still reports both values as unavailable. Therefore this first software
version can prove package verification, connection, capability discovery, and update UI, but it
will stop and resume capture before activating Wi-Fi on a real vehicle.

The next enabling firmware work is not an override button. It is deterministic evidence for:

- vehicle stationary/PARKED state with freshness and failure semantics; and
- gateway input supply with calibrated units, range, freshness, and brownout margin.

Only after those facts exist should the physical updater be enabled on the vehicle.

## Failure semantics

| Failure | App/gateway behavior |
| --- | --- |
| Package signature/hash invalid | File rejected; no BLE command and no Wi-Fi |
| Missing capability or hardware mismatch | Preflight blocked; recorder resumed |
| Motion unknown/moving | Preflight blocked; recorder resumed |
| Supply missing/low | Preflight blocked; recorder resumed |
| Recorder cannot flush | Timed-out block; no Wi-Fi |
| OTA network response missing/mismatched gateway | Cancel request; recorder resumed |
| User rejects iOS join prompt | Cancel request; temporary configuration removed |
| Wrong token/size/hash/native signature | Gateway rejects, closes AP, resumes recorder |
| Transfer interrupted or lease expires | Inactive slot abandoned; running slot unchanged |
| Probationary image fails POST/reset | ESP-IDF bootloader rolls back |

None of these failures is presented as a vehicle fault.

## Observable status

The System Status screen now distinguishes:

- OTA notification characteristic discovery and subscription;
- verified distribution package selection;
- gateway temporary-network advertisement/lease state;
- update operation state;
- probationary boot/POST result; and
- missing release key, supply, motion, or capability gates.

The UI never labels a gateway as updated solely because HTTP returned 2xx. Acceptance requires the
post-reboot firmware handshake and persisted outcome.

## Automated acceptance

- Swift core package: OTA activation request encodes exact snake_case IDs and sizes.
- Swift core package: encrypted status payload decodes gateway/package identity and credentials.
- Python tooling: a real generated Ed25519 key signs a real binary package; verification succeeds;
  tampering is rejected.
- Xcode build: iOS 17+ Swift 6 app compiles with NetworkExtension and the hotspot entitlement.
- Firmware build: ESP-IDF 5.5.3 classic ESP32 image compiles with signed-on-update and rollback.
- Firmware validator: checks default-off activation, BLE encryption, WPA2/PMF/lease/token, exact
  image validation, inactive-slot write, native signature verification, and no CAN transmit path.

## Physical acceptance still required

- Verify the signed development profile contains Hotspot Configuration on the attached iPhone.
- Test the correct package plus wrong distribution key, wrong ECDSA key, unsigned app, wrong hash,
  wrong token, truncated transfer, and oversize image.
- Interrupt power early/middle/late in upload and during first boot.
- Force the probationary self-test to fail and record a real rollback.
- Confirm BLE identity/bond persists across update and reconnect requires no Forget This Device.
- Confirm the AP is absent at normal boot, ends after every path, and neither iPhone nor Mac retains
  it as a preferred network.
- Confirm the passive recorder resumes after cancellation/failure and capture evidence is intact.

Release evidence must include exact app/firmware commits, package/inner-image hashes, source key
fingerprints (never private key bytes), serial trace, iPhone model/iOS version, gateway chip/revision,
and each matrix result.
