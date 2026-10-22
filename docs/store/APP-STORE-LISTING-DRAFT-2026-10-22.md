# Vehicle Health OS — App Store listing draft

Status: proposal for the iOS `com.isaiahdupree.VehicleHealthOS` target (App Store Connect version 0.3.27). Not saved to App Store Connect. Current source reviewed 2026-10-22; exact attached-binary-to-source match remains unverified, so every claim below must be checked against the submitted build before use.

## Proposed metadata

**Name (17/30):** Vehicle Health OS  
**Subtitle:** Gateway Telemetry & Evidence  
**Candidate category:** Utilities. Confirm App Store category taxonomy and audience positioning before saving.  
**Promotional text:** Connect a compatible VHOS gateway to inspect its status, collect vehicle evidence, and keep each result traceable.  
**Keywords:** OBD2,vehicle,gateway,telemetry,diagnostics,mechanic,maintenance,evidence,bluetooth,logs

**Description:**

Vehicle Health OS pairs your iPhone with a compatible VHOS gateway over Bluetooth LE. Use the commissioning dashboard to review the phone-to-gateway connection, gateway handshake, OBD-II availability, safety state, and evidence status as separate signals.

Collect and organize vehicle evidence with its source, session, time, freshness, and verification status. Depending on the connected gateway and its capabilities, review retained passive CAN captures, inspect read-only OBD responses, export connection diagnostics, and create local technician case drafts. Simulator output is identified separately and is never presented as a vehicle observation. Unknown or unverified data remains visibly unverified.

A compatible VHOS gateway and supported vehicle interface are required for gateway features. Availability depends on the gateway firmware, vehicle, connection, and captured evidence. Some advanced workflows require commissioning and additional setup. This app does not turn incomplete evidence into a confirmed vehicle-health finding, and technician case drafts are not canonical vehicle maintenance history.

Review the exact submitted build before publication to confirm its feature set, supported hardware, permission prompts, privacy behavior, and any account or network requirements.

## Screenshot plan

Use the exact attached build on a real iPhone or approved simulator. Do not use simulator-generated vehicle values as real evidence.

1. Commissioning dashboard with distinct iPhone/BLE, gateway, OBD-II, safety, and evidence states — “See Each Connection and Safety State”
2. Verified gateway identity and capabilities — “Know Which Gateway Is Connected”
3. Retained evidence view with source and validation labels — “Keep Vehicle Evidence Traceable”
4. Read-only OBD availability with unsupported values clearly unavailable — “See What the Vehicle Actually Reports”
5. Technician case draft showing evidence authority — “Prepare a Local Service Handoff”

## Market evidence and positioning

The category is crowded with adapter-dependent OBD tools. [OBD Fusion](https://apps.apple.com/us/app/obd-fusion/id650684932) promotes live vehicle data, trouble codes, dashboards, and fuel-economy tools. [OBDLink](https://apps.apple.com/us/app/obdlink/id879636351) emphasizes its own adapter ecosystem and diagnostic reports. [OBDeleven](https://apps.apple.com/us/app/obdeleven-obd2-car-scanner/id1643119107) combines diagnostics with supported-brand coding and maintenance features. These public listings establish competing feature claims, not demand or conversion rates.

A defensible positioning hypothesis is evidence provenance and explicit separation of gateway health, vehicle observations, simulator output, and technician-authored drafts. It should not be marketed as a universal OBD scanner, repair advisor, safety certification, or vehicle-health score without build-level and field evidence.

## Release gates

- Match the App Store Connect attached build to the exact source commit and confirm all proposed screens/features exist in that binary.
- Capture screenshots from that exact build, with genuine or clearly labeled test evidence.
- Verify the privacy policy and support URLs are live and app-specific; neither is supplied in this draft.
- Audit the archived binary and SDK privacy report before completing App Privacy.
- Complete age rating and content-rights answers against the exact binary and bundled content.
- Decide category and price with product-owner evidence; do not infer willingness to pay from competitor prices.
- Complete reviewer contact, notes, and a repeatable path to the compatible hardware state.
- Confirm required hardware, supported vehicles, setup, and account/network behavior in the submitted build.

No App Store Connect write, build upload, review submission, or privacy declaration change is included.
