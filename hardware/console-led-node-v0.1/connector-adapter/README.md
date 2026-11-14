# Toyota console plug → ESP32 shield connection

Use the [Rev D build guide](../pcb-rgbw-revd/README.md) for power and
illumination sensing from the photographed white socket.
Use the [2005 V8 IR1 pinout and harness plan](IR1-WIRE-PLAN.md) to identify
all six factory wires and verify the feed.
The [Rev A inline harness build sheet](INLINE-HARNESS.md) records the earlier
wiring. This page retains the connector and CAD research from November 7, 2026.

The later mating-face photos and the supplied Corsa comparison show a white
six-contact socket in the Yazaki 7283-1060 pattern. The catalog mate is
**Yazaki 7282-1060**. IR1, the join between the instrument-panel loom and the
cigarette-lighter sub-loom, matches the plug location and circuit colors in the
2005 V8 service diagrams. Verify the latch and electrical behavior on the truck.

## Concrete plug candidate

Toyota's **2003 EWD514U, printed pp. 52–53**, shows IR1 at this console location and draws both halves with two upper cavities and four lower cavities. This is the layout to compare with the vehicle. **Yazaki 7282-1060 / 7283-1060**, 2.3II/090II unsealed six-way, is a geometry match inferred from the drawings. The factory housing part number for the photographed plug still needs physical confirmation.

Yazaki explicitly lists these two housings as mates. Its male housing is 38.0 mm long × 21.1 mm wide × 21.4 mm high; the female is 22.0 × 18.7 × 17.0 mm. These are **wire-harness housings using crimp terminals**. No documented, orderable PCB-tail mate for this exact interface was established in this research. Do not treat a housing's “PCB model” download as a solderable PCB connector.

| Role | Part / purchase lead | Evidence status |
| --- | --- | --- |
| Toyota-side pin housing | **Yazaki 7282-1060**, Corsa **090IIU-6P-1** kit | Catalog mate for the pictured socket pattern. Supplier cross-reference Toyota **90980-10796**. Physical fit pending |
| Opposite socket housing for the inline harness | **Yazaki 7283-1060**, Corsa **090IIU-6S-1** kit | Supplier cross-reference includes Toyota **90980-10797**. Check the factory mating half and retention |
| Small-wire male contact | **Yazaki 7114-4020** | Cataloged for 7282-1060 with 0.30–0.50 mm² wire. Select each pass-through contact by actual wire size |
| Matching small-wire female contact | **Yazaki 7116-5041-02** | Cataloged for 7283-1060 and mates with 7114-4020; 0.30–0.50 mm² AVSS/CAVS/CAVUS or 0.50 mm² AVS |
| New adapter cable end | **Molex 43025-0600**, one **43030-0007** socket | Populate J1-6 only. Socket accepts 20/22/24 AWG with insulation OD ≤1.85 mm |
| Shield PCB connector J1 | **Molex 43045-0600** | Six-way, 3 mm pitch, right-angle through-hole PCB header; matches the Micro-Fit cable end |
| Shield-to-controller headers | **SparkFun PRT-11417** | UNO R3 kit: 2 × eight-pin, 1 × ten-pin, 1 × six-pin. Physical compatibility with the owned ESP32 revision still pending |

Corsa listed the pin kit at $3.14 and socket kit at $3.03 during retrieval; SparkFun listed its header kit at $2.75. These are dated page observations before delivery/tax, not quotes or guaranteed stock. Confirm the contact size included in a kit. **Do not use the small branch contacts/wire to replace the original lighter's full-current pass-through conductors.**

## Rev A connection to the PCB

The inline loom carries all six original circuits. It takes verified
switched positive through a branch fuse to J1-6. The shield's dedicated return
lands at J2-5. The Toyota housings and fuse holder sit outside the case, and
the shield mounts on the controller's headers and screw supports. See the
[wiring diagram and continuity table](INLINE-HARNESS.md#wiring).

## 2005 V8 IR1 circuits

The 2005 V8 service diagrams show the ACC feed and chassis ground on cavities
6 and 5, plus two lamps that share TAIL and dash dimmer circuits on cavities
1–4. Confirm that the CIG feed is populated on the truck before powering the
controller. Telemetry reaches the node wirelessly from the existing gateway.
[2005 V8 circuit sources, harness and meter checks](IR1-WIRE-PLAN.md).

`PINMAP-DRAFT.csv` preserves the earlier six-wire shield proposal.

## PCB footprint and UNO reference geometry

Use the official KiCad footprint `Connector_Molex:Molex_Micro-Fit_3.0_43045-0600_2x03_P3.00mm_Horizontal`, downloaded and hash-pinned in the pack. Relative to footprint pad 1, top-side layout coordinates are:

| Pad | X / Y mm |
| --- | --- |
| 1 / 2 / 3 | (0, 0) / (3, 0) / (6, 0) |
| 4 / 5 / 6 | (0, 3) / (3, 3) / (6, 3) |
| Retention hole | (3, −4.32), Ø3.0 mm non-plated |

The library uses Ø1.02 mm drills and 1.5 mm copper pads for the six contacts. Treat these as a library reference until compared with the selected manufacturer's current drawing and board stackup. Footprint coordinates are not the harness's mating-face view.

Official Arduino **A000066 UNO-TH_Rev3e.brd** was downloaded. `uno-r3-reference-header-coordinates.json` records its 32 header pad centers and four mounting holes in the original EAGLE millimeter coordinates. The two digital header groups have an **unusual 4.064 mm separation** between their adjacent pad centers; copying a uniform 2.54 mm grid will not fit. Opposite header rows are 48.26 mm apart. This is a reference for the proposed shield, **not proof that the owned ESP32 shares the holes, header locations, board height or USB/antenna keepouts**.

The user has now supplied the **ShengYang D1 UNO ESP32-S3 N16R8 / CH340**
product reference. [The board record](../controller-board/README.md) replaces
the earlier DIYables identity assumption, compares visible GPIO labels with a
seller-family diagram and proposes LED GPIO18/17/14 with GPIO21 for enable.
The product family is identified; physical revision, populated height, holes,
USB power path and antenna/connector keepouts remain unverified. GPIO is 3.3 V.

## Downloaded CAD and native inspection

The pack contains **Yazaki's directly downloaded 7282-1060 STEP**, both manufacturer housing drawings, the existing Molex header/housing STEP references, the official KiCad footprint, and Arduino's original EAGLE CAD ZIP. Toyota reference manuals are retained privately with their real model years.

Orion job **mdl_d7b7711c712a454c** imported the three pinned STEP files without repair and generated a catalog preview. Yazaki imported as one valid solid with bounds **21.1 × 21.4 × 38.000003 mm**, matching the published envelope. Its tessellated mesh is **not closed**; retain it as reference CAD, not a printable Toyota connector. The Molex models are valid 7-solid / 1-solid references, previously sourced from public mirrors. The catalog is not a mated assembly or shield-fit verification.

Remaining fit inputs are the actual Toyota latch and cavity alignment,
switched feed on this 2005 V8, and physical measurements of the identified
ESP32 revision.

## Sources

- [Toyota EWD514U routing, 2003, printed pp. 52–53](https://cdn3.guidessimo.com/view/1356/1356253-4runner_2003.pdf#page=62)
- [Toyota EM00T0U diagrams, 2006; printed p. 447 and pp. 296–297](https://www.datacar-manualrepair.com/wp-content/uploads/2018/09/Diagrama-el%C3%A9ctrico-Toyota-4Runner-2006.pdf)
- [Yazaki 7282-1060 manufacturer page](https://connector.yazaki-group.com/cgi-bin/english/detail.cgi?part_id=7282-1060), [matching 7283-1060](https://connector.yazaki-group.com/cgi-bin/english/detail.cgi?part_id=7283-1060)
- [Yazaki 7114-4020 contact](https://connector.yazaki-group.com/cgi-bin/english/detail.cgi?part_id=7114-4020), [7116-5041-02 contact](https://connector.yazaki-group.com/cgi-bin/english/detail.cgi?part_id=7116-5041-02)
- [Corsa pin kit / Toyota cross-reference](https://www.corsa-technic.com/item.php?item_id=1359), [socket kit / Toyota cross-reference](https://www.corsa-technic.com/item.php?item_id=1360)
- [Molex PCB header](https://www.molex.com/en-us/products/part-detail/430450600), [cable housing](https://www.molex.com/en-us/products/part-detail/430250600), [crimp sockets](https://www.molex.com/en-us/products/part-detail/430300007)
- [Official KiCad footprint](https://gitlab.com/kicad/libraries/kicad-footprints/-/raw/master/Connector_Molex.pretty/Molex_Micro-Fit_3.0_43045-0600_2x03_P3.00mm_Horizontal.kicad_mod)
- [SparkFun PRT-11417 headers](https://www.sparkfun.com/arduino-stackable-header-kit-r3.html), [Arduino UNO R3 official CAD](https://docs.arduino.cc/hardware/uno-rev3/)
- [DIYables prospective board](https://diyables.io/products/esp32-s3-development-board-with-esp32-s3-wroom-1-n16r8-wifi-bluetooth-uno-compatible-form-factor-works-with-arduino-ide)
