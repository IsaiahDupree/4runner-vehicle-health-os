# iPhone field-return evidence runbook

Use this sequence whenever an iPhone returns from the vehicle. Its purpose is to preserve the
original application evidence before installing a new build, prove that an in-place upgrade did
not rewrite the evidence, and keep derived analysis reproducible from exact source bytes.

## Safety rules

- Copy before launching, installing, importing, exporting, or retrying a failed ledger read.
- Use the app data container only; never infer evidence from the iOS Bluetooth Settings label.
- Never overwrite an earlier snapshot. Give every destination a new timestamp or descriptive name.
- Treat `VHOS/PassiveCAN` as the durable recorder archive and `VHOSPortableFrames` as a recovery
  source. Portable evidence is always `RECOVERED EVIDENCE • NOT LIVE` and has no vehicle authority.
- Hash source ledgers before analysis. Derived reports and exports do not replace those ledgers.
- Install over the existing bundle. Do not uninstall the app, because uninstalling removes its data
  container.

## 1. Resolve the attached iPhone

```sh
xcrun devicectl list devices
```

Record the CoreDevice identifier for the available, paired iPhone. Use a task-specific shell
variable for the remaining commands:

```sh
VHOS_DEVICE_ID='COREDEVICE-IDENTIFIER-FROM-THE-LIST'
```

## 2. Make the pre-install read-only copy

Choose a destination that does not exist:

```sh
xcrun devicectl device copy from \
  --device "$VHOS_DEVICE_ID" \
  --domain-type appDataContainer \
  --domain-identifier com.isaiahdupree.VehicleHealthOS \
  --source 'Library/Application Support' \
  --destination 'build/device-data/YYYY-MM-DD-field-return-HHMMSS'
```

This copy does not mutate the phone. Preserve at minimum:

- `VHOS/PassiveCAN/**/*.ndjson`
- `VHOSPortableFrames/v1/logical-frames.ndjson`
- `VHOSDiscoveryEvidence/v1/*.ndjson`
- `VehicleHealthOS-Evidence/BLEConnectionTrace/*.ndjson`

Validate every NDJSON line and compute SHA-256 for each source file before analysis. An invalid
committed Discovery ledger must remain untouched and fail closed; the app's retry action only
re-reads it.

## 3. Analyze without changing authority

Run ordinary passive-CAN discovery only on strict durable `gateway.passive-can-observation`
records. If a new recorder session exists only in the portable ledger, create a v2 recovered
extraction and analyze it through the dedicated recovered-evidence command. Do not strip the
wrapper or feed recovered rows into the ordinary live-evidence loader.

```sh
.venv/bin/vhos extract-portable-can \
  build/device-data/YYYY-MM-DD-field-return-HHMMSS \
  --session-id CAPTURE_SESSION_ID \
  --output build/can-portable-recovery-YYYY-MM-DD-SESSION

.venv/bin/vhos discover-recovered-can \
  build/can-portable-recovery-YYYY-MM-DD-SESSION \
  --output build/can-portable-recovery-YYYY-MM-DD-SESSION-discovery.json
```

The recovered report must retain both:

```text
source_classification = RECOVERED_PORTABLE_EVIDENCE
vehicle_claims_authorized = false
```

It must also retain `recovery_provenance`: the exact extraction-manifest SHA-256 and byte count,
the original portable source-file and source-bundle inventories, and the declared recovered output
files. The report's analyzed `source_files` must cross-bind exactly to those outputs. Do not accept a
detached report that asserts recovered authority wording but omits this provenance object.

## 4. Install the verified build

Verify the app's signature, bundle identifier, version, build number, and test results first. Then
install the `.app` over the existing application:

```sh
xcrun devicectl device install app \
  --device "$VHOS_DEVICE_ID" \
  'build/DerivedData-device/Build/Products/Debug-iphoneos/Vehicle Health OS.app'

xcrun devicectl device info apps \
  --device "$VHOS_DEVICE_ID" \
  --bundle-id com.isaiahdupree.VehicleHealthOS
```

Launching after the install is allowed only after the pre-install copy succeeds:

```sh
xcrun devicectl device process launch \
  --device "$VHOS_DEVICE_ID" \
  com.isaiahdupree.VehicleHealthOS
```

## 5. Prove preservation after the upgrade

Copy Application Support again to another new destination. Recompute SHA-256 for the portable
ledger, capture files, test-run ledger, marker ledger, and capture-binding ledger. The source-file
hashes must match the pre-install snapshot unless the running app has appended a clearly newer,
independently valid record. Never accept silent replacement, truncation, or a changed interior
record.

Record the following in the field report:

- device and app version/build;
- pre-install and post-install snapshot paths;
- source-file byte counts and SHA-256 values;
- durable session/record counts;
- portable recovery classification and authority denial;
- BLE trace filename/hash and terminal CoreBluetooth error;
- any recorder loss, deliberate suppression, persistence failure, or storage exhaustion as
  separate counters;
- which interpretations remain raw relationships, candidates, or validated signals.

## Acceptance result

A return is complete only when the source bytes are preserved, analysis is reproducible, the
installed app identity is verified, and the post-install readback proves preservation. A successful
recovery is not automatically a promotion-quality vehicle capture.
