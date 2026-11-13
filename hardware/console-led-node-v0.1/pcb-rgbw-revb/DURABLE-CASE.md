# Reinforced, support-free 4Runner RGBW enclosure

The [Toyota-powered build](TOYOTA-POWER-BUILD.md) uses its own matched base
and lid with strain relief for the captive wires. This document describes the
earlier enclosure for removable Molex plugs.

This matched base and lid fit the existing Rev B RGBW shield and the
UNO-format ESP32-S3. J1 is the Molex Mega-Fit vehicle-power port. J2 is the
Molex Micro-Fit RGBW port. Use the [existing wiring map](README.md#two-cable-connections).

## Reinforcement and fit

- The floor and lid have 3.2 mm nominal skins, the sidewalls are 3.0 mm,
  and the connector web is 3.6 mm. Floor gussets spread loads at the
  PCB bosses. The chassis ears have rounded 4.2 mm-thick mounting pads,
  with one 4.6 mm round hole and one 4.6 × 6.4 mm slot on the original axes.
  Recessed **12V IN** and **RGBW** markings keep the lid's bed face flat.
- Each cable opening has a flared lower guide, two side cheeks and a
  top-open latch path. Inside, the lid backstops limit rearward housing
  motion during insertion. Roof pads and base shoes limit upward and
  sideways motion. Four gusseted shield mounts transfer withdrawal loads
  to the floor. The case uses the through-hole connectors' existing
  board locks. The nominal housing-stop gaps are 0.9 mm. Measure the
  molded plastic contact areas on the assembled shield. If a verified gap
  is large, cut 0.3 mm or 0.6 mm nonconductive shim stock to fit the stop
  face and secure it against migration. The lid should seat freely on the
  rim, with no preload on the shield or housings.
- The cable openings have 0.90 mm per side and 0.80 mm below the Rev B
  mate envelopes. The CAD checks add another 0.45 mm around those
  envelopes. The lid locator nominally has 0.65 mm per-side clearance.
  The four lid clearance bores are 3.8 mm with a lead-in on the print
  face. The 4.0 mm nominal blind insert pilots have a lead-in at the seat.
  Confirm actual as-printed dimensions with the selected process and
  coupon before choosing a compensation. The four shield holes and the
  controller stack retain their original nominal positions.

The closed enclosure spans 146 × 76 mm over the ears and reaches 52.2 mm
with the lid screws installed. Allow additional space at the plug face
for the cable bend and unplugging. This stronger design uses about 133 cm³
of solid material, compared with about 102 cm³ for the earlier service case.

[Molex J1 sales drawing](https://www.molex.com/content/dam/molex/molex-dot-com/products/automated/en-us/salesdrawingpdf/768/76825/768250002_sd.pdf) ·
[Molex J2 sales drawing](https://www.molex.com/content/dam/molex/molex-dot-com/products/automated/en-us/salesdrawingpdf/430/43045/430450800_sd.pdf) ·
[JLC3DP print tolerances](https://jlc3dp.com/help/article/3d-printing-design-guideline).

## Print and assemble

| Part | Orientation and use |
| --- | --- |
| [Base STL](durable-cad/case_base.stl) | Exterior floor on the bed. Cavity and insert bores face up. |
| [Lid STL](durable-cad/case_lid.stl) | Exterior face on the bed. Locators and backstops face up. |
| [Front port coupon](durable-cad/front_ports_coupon.stl) and [matching lid slice](durable-cad/front_lid_coupon.stl) | Use the actual Molex cable mates to check the guides, opening dimensions and latch reach. |
| [M3 tolerance coupon](durable-cad/m3_tolerance_coupon.stl) | Compare 3.85, 4.00, and 4.15 mm pilots in order along the strip. The isolated hole is the 3.8 mm screw clearance witness. |

For JLC3DP, quote **3201 PA-F SLS nylon** as separate parts in
millimeters. For FDM, keep the supplied orientations. The geometry screen
uses a 0.4 mm nozzle and 0.20 mm layers. The base, lid and three coupons
all sliced with zero generated supports. The steepest downward face is
45° from vertical. Use a printer and filament
combination suitable for cabin heat, and check the coupon for shrinkage,
first-layer swell, and insert retention. The print geometry and nozzle
screen do not establish the behavior of an actual printed material.
[JLC3DP 3201 PA-F](https://jlc3dp.com/help/article/3201pa-f-nylon) ·
[Prusa ASA print considerations](https://help.prusa3d.com/article/asa_1809).

Heat-set the 11 inserts with the base empty. Fasten the lower board with
three M3 × 6 mm screws before fitting the shield. Fasten the shield with
four M3 × 6 mm screws, fit the fuses, and install the four M3 × 8 mm lid
screws. Use the existing insulating washers under the seven board screws.
Check both latch releases with the lid on, and pull each plug by its
housing. The CAD tool profiles are a straight 6 mm heat-set nose, 8 mm
shank, and long 2.5 mm hex driver. See the [earlier tool setup](SERVICE-CASE.md#tool-path-and-assembly-order)
for the full tool profiles.

The board and header clearances use the routed shield STEP, drawing-based
connector envelopes and nominal ESP32 board geometry. Measure the actual
left mounting holes on the ShengYang board. Print the coupon, then dry-fit
the boards and unpowered plugs. Before using the case in the truck,
check for shell or PCB movement during repeated mating, verify insert
retention, and test under cabin heat and vibration.

[Tool path results](durable-cad/tool-access.json) ·
[Enclosure fit results](durable-cad/durable-fit.json) ·
[Print geometry screen](durable-cad/support-free.json) ·
[Orion artifact receipt](durable-cad/verification.json).

Regenerate the source-pinned geometry and offline print screen with
`python3 -B orion_client.py start UNIQUE-ID --stage durable-case` from the
Rev B directory. Use `status`, `fetch` and `stop` with the same identity.
