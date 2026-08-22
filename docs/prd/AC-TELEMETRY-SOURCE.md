# A/C telemetry focused specification source record

Status: retrieved from connected Google Drive on 2026-08-16

## Authoritative focused document

- Title: `2005 Toyota 4Runner A/C Engine-Bay Telemetry Node Spec v1.0`
- Drive file ID: `1rMmG6yA9YKml6fOkHtBKk_CI0mZiWGaA`
- Drive URL: <https://docs.google.com/document/d/1rMmG6yA9YKml6fOkHtBKk_CI0mZiWGaA/edit?usp=drivesdk>
- MIME type: `application/vnd.openxmlformats-officedocument.wordprocessingml.document`
- Size reported by Drive: `55,630` bytes
- Created/modified time reported by Drive: `2026-08-16T23:44:04.647Z`

The Drive connector returned the complete readable document text. The binary
DOCX has not been duplicated into this repository, so this record does not
claim a local byte checksum. The existing immutable source documents remain in
this directory.

## Authority and implementation boundary

This focused v1.0 document controls the A/C sensor-node build. In particular:

- Nano ESP32 vehicle power uses protected approximately 6.5-7.0 V into `VIN`.
- Pressure sensors use an independent regulated 5 V rail.
- USB-C remains the bench/service/debug/recovery path.
- Raw high/low absolute pressure, temperature, power, calibration, firmware,
  configuration, POST/BIT, and storage/transport health evidence is preserved.
- Pressure lift, absolute pressure ratio, and vent delta-T may be implemented
  without vehicle-specific thresholds.
- R134a saturation, superheat, subcooling, stabilization, baseline comparison,
  and diagnostic hypotheses remain unavailable until their required validated
  inputs, property source, operating context, and equation versions exist.

## Explicit procurement and safety gates

The focused document does not freeze exact orderable high/low pressure-sensor
configurations, their transfer functions, or the final permanent refrigerant
fitting geometry. Software must therefore treat missing calibration as invalid
or unavailable and must not hard-code a generic sensor equation.

No software milestone authorizes opening, charging, evacuating, venting, or
modifying the refrigerant circuit. Vehicle installation still requires the
documented recovery, leak-check, mechanical-support, and qualified-service
gates.
