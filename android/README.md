# Android workspace boundary

Android implementation begins in E1 after E0's contracts are stable. The app will be a Kotlin/Compose, local-first client whose domain and calculation modules have no dependency on a live gateway.

The development architecture for the installed head unit, simultaneous OBD/CAN and A/C ESP32
sessions, iPhone ownership handoff, platform audit, permissions, persistence, UI, and acceptance
gates is maintained in
[`docs/development/ANDROID-HEAD-UNIT-DUAL-GATEWAY.md`](../docs/development/ANDROID-HEAD-UNIT-DUAL-GATEWAY.md).

`modules.toml` is the accepted dependency-direction catalog. Gradle files are intentionally not generated until the minimum supported Android API, installed head-unit OS, application ID, signing posture, and database encryption choice are recorded. This avoids committing a non-buildable or misleading Android stub.

Core rules:

- Room/SQLite is the durable structured store; raw captures remain chunked files with manifests/hashes.
- Append-only service, inspection, lifecycle, calculation, equation, configuration, and audit events are source truth.
- “Latest state” is a rebuildable projection.
- UI and domain code depend on a source abstraction shared by simulator, replay, and gateway ingest.
- Drive mode cannot reach engineering, firmware, or raw-frame controls.
- No Android API accepts arbitrary CAN frame bytes for transmission.
