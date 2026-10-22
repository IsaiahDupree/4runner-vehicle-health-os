# Device-free field-return acceptance

Status: implemented
Date: 2026-08-24

## Purpose

This runner turns one copied iPhone app-data directory into a complete desktop
acceptance pass. It does not contact an iPhone, ESP32, Android head unit, BLE
radio, serial port, Wi-Fi access point, or vehicle. The same captured evidence
can therefore be analyzed, replayed, stress-tested, rendered, and regression
tested repeatedly without another trip to the car.

Run:

```bash
.venv/bin/python ios/tools/vhos_device_free_acceptance.py \
  --app-data build/device-data/2026-08-24-field-return-185114 \
  --baseline build/device-data/2026-08-22-iphone-return-latest \
  --output build/device-free-acceptance/2026-08-24-185114 \
  --android-repo ../4runner-vhos-android \
  --soak-cycles 20
```

The output directory must not already exist. This prevents a later run from
overwriting or blending with prior acceptance evidence. It also may not equal
or be nested beneath the current or baseline app-data directory; this is
rejected before any output file is created so analysis cannot mutate its input.

## Required desktop gates

The command runs these gates in order and stops on the first failure:

1. shared JSON contract validation;
2. the complete Python test suite;
3. atomic `vhos analyze-field-return` evidence recovery, discovery, marker
   correlation, replay, and reliability analysis;
4. Swift Core tests;
5. iOS application tests on a real CoreSimulator runtime;
6. an unsigned generic iOS Simulator build; and
7. Android JVM tests, lint, and debug APK assembly under JDK 17 and Android SDK
   37.

Set `VHOS_IOS_SIMULATOR_DESTINATION` when the named default simulator is not
installed. It must remain an iOS Simulator destination. `JAVA_HOME`,
`ANDROID_SDK_ROOT`, and `ANDROID_HOME` can select equivalent local JDK 17 and
SDK 37 installations.

## Durable, fail-closed result

Read:

```text
build/device-free-acceptance/.../summary.json
```

The summary is atomically replaced after every gate transition. Each gate
records its exact argument vector, printable command, working directory,
non-secret environment overrides, start/completion time, duration, exit code,
timeout, available test/build counts, and SHA-256-addressed log. The accepted
field-return manifest/summary, replay-corpus manifest, replay and reliability
reports, iOS Simulator executable, and Android debug APK are also SHA-256
inventoried.

Before the first gate and again before success, the runner hashes each Git
commit plus every tracked and non-ignored untracked source file in both the
product and Android repositories. A source change during the run fails the
acceptance instead of combining test/build results from different snapshots.
Android tasks use `--rerun-tasks`; fresh, nonzero test XML, lint XML, APK, and
iOS test/application results are required so cached `NO-SOURCE` work cannot be
misreported as acceptance.

The `field_return_evidence_chain` section independently joins the analysis,
corpus, live replay, historical replay, and all reliability scenarios by corpus
ID, record count, semantic digest, exact-payload result, and requested soak
count. For the current August 24 field return this proves that the same 11,045
recovered listen-only observations feed both replay modes and every one of the
15 reliability scenarios; the reliability stage is not running against an
unrelated fixture.

A machine interruption leaves `outcome=RUNNING`, never a false pass. A command
failure leaves `outcome=FAIL` and makes the run terminal. Success is reported as
`PASS_DEVICE_FREE`, not a generic release pass. `offline_passed_gates` and
`remaining_physical_gates` are separate collections, and `release_ready`
deliberately remains false.

## What remains physical

The JSON always retains explicit `NOT_RUN` gates for:

- iPhone BLE sustain/reconnect under real transfer load and interference;
- two concurrent GATT links on the installed Android vendor stack;
- installed-head-unit SQLCipher/keystore instrumentation and restart recovery;
- real DLC power, CAN traffic, and OBD ECU/protocol response;
- real J1979 enumeration and synchronized Techstream/reference acquisition;
- ignition loss, rail loss, brownout, OTA, and rollback behavior;
- repeated labeled signal experiments with independent ground truth; and
- in-vehicle phone/head-unit interaction and readability.

Desktop replay can prove deterministic software behavior against captured
evidence. It cannot create evidence for a physical state that was never
captured, promote a Toyota mapping without corroboration, or prove a particular
radio/electrical environment.
