# 4Runner RGBW enclosure and tool access

This case fits the 2005 4Runner V8 controller stack built around the Rev B
shield and the UNO-format ESP32-S3. The lid has raised **12V IN** and **RGBW**
labels next to the two latching cable plugs. Rounded reliefs at the lid
edge give a fingertip more room above each latch. Both MINI fuses remain
under the removable lid.

## Print and hardware

| Item | Files or specification |
| --- | --- |
| Base and lid | [Base STL](service-cad/case_base.stl) and [lid STL](service-cad/case_lid.stl). Print as separate parts. |
| Fit coupon | [Ports and inserts STL](service-cad/ports_and_inserts_coupon.stl). Includes the two plug openings and the three boss types. |
| Inserts | 11 ruthex RX-M3x5.7, with 4.0 mm nominal pilot bores and 7.0 mm blind depth. |
| Board screws | Seven M3 × 6 mm socket heads with 0.5 mm-thick, 7 mm OD insulating washers. |
| Lid screws | Four M3 × 8 mm socket heads. |
| Enclosure process | JLC3DP SLS 3201 PA-F nylon, standard finish. Quote in millimeters. |

The case is **146 × 76 × 49.9 mm** over the mounting ears and the
raised lettering, before screw heads and cables. The screw heads reach
**52 mm** from the bottom. The base and lid use **101.89 cm³** of solid
material. The two plugs and their straight withdrawal corridors use the
existing Rev B mating locations.
[JLC3DP SLS guidance](https://jlc3dp.com/3d-printing/selective-laser-sintering) ·
[ruthex M3 insert](https://www.ruthex.de/en/products/ruthex-gewindeeinsatz-m3-100-stuck-rx-m3x5-7-messing-gewindebuchsen).

## Tool path and assembly order

| Stage | Vertical access | Nominal screw engagement | Screw-tip gap to blind end |
| --- | --- | ---: | ---: |
| Empty base | Heat-set all 11 inserts | — | — |
| ESP32-S3 on its supports | Fasten three M3 × 6 mm screws before placing the shield | 3.9 mm | 3.1 mm |
| Shield seated | Fasten four M3 × 6 mm screws through the shield | 3.9 mm | 3.1 mm |
| Lid seated | Fasten four M3 × 8 mm screws from above | 5.0 mm | 2.0 mm |

The fourth lower boss supports the board near its header. It carries no
screw. The boss locations follow the nominal UNO R3 mounting pattern.
The ShengYang seller-family drawing differs at the left pair. Measure the
actual ESP32 mounting centers and dry-seat the stack before printing the
full base. [ShengYang mechanical reference](../controller-board/README.md).

All 11 approach axes were checked against the exported solids with the
boards and lid in the appropriate service state. The heat-set tool envelope
has a **6 mm nose for the first 10 mm**, an **8 mm shank for the next
55 mm**, and a **25 mm handle**. The geometry also passed with **0.25 mm
radial allowance** around the nose and shank. A long **2.5 mm hex driver**
was checked using a **6 mm shaft for 55 mm** and a **25 mm handle**. Verify
that the actual heat-set tip and driver fit these profiles, then test insert
seating, screw clearance and retention on the same-material coupon.

For fuse service, disconnect power, remove the four lid screws, lift the lid
and pull the selected fuse vertically. The CAD retains a 6.4 mm nominal
gap from the fuse height reserve to the lid underside. The cable-mate and
puller shapes are clearance estimates for real-hardware fit tests.
[Rev B assembly and wiring](README.md) · [JLC assembly and parts options](jlcpcb/COST-PASS.md).

## CAD and evidence

The download package includes the grouped FreeCAD assembly, the STEP
assembly, separate STEP and STL print parts, and an empty-base FreeCAD
view with the insert approach solids. The shield comes from routed KiCad
geometry. The ESP32 module and brass insert use manufacturer STEP models.
The complete lower board, cable plugs, screws and fuse bodies use nominal
geometry and drawing-based dimensions.

[Tool path results](service-cad/tool-access.json) ·
[Assembly fit results](service-cad/mechanical-observation.json) ·
[Coupon results](service-cad/ports-and-inserts-coupon-checks.json) ·
[Orion artifact receipt](service-cad/verification.json) ·
[Geometry and tool dimensions](service-case.json).

Regenerate on Orion from the Rev B directory with
`python3 -B orion_client.py start UNIQUE-ID --stage service-case`.
Use `status`, `fetch` and `stop` with the same identity.
