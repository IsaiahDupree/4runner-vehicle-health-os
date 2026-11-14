# Rev E single-board 4Runner RGBW controller

One four-layer PCB carries the ESP32-S3-WROOM-1-N16R8, 3.3 V regulator,
the existing automotive input protection and two MINI fuses, two Toyota
illumination inputs, and the four RGBW drivers. The separate CAN ESP32
provides telemetry wirelessly. The 2005 4Runner V8's white IR1 connector is
the sole installed power source. One Toyota branch enters the enclosure and
one RGBW lead leaves it. [Espressif module datasheet](https://documentation.espressif.com/esp32-s3-wroom-1_wroom-1u_datasheet_en.pdf) ·
[Toyota diagrams and meter checks](../connector-adapter/IR1-WIRE-PLAN.md).

## Wire register

| Connection | Where it goes |
| --- | --- |
| IR1-5, white/black | J1-1 GND |
| IR1-6, pink/blue | J1-2 switched ACC, through the shield's 3 A main fuse |
| IR1-1, green | J1-3 TAIL, protected input to ESP32 GPIO5 |
| IR1-2, white/green | J1-4 DIM, protected input to ESP32 GPIO4 |
| IR1-3, green | Factory lighter ring and tee reserve A, labeled `IR1-3 TAIL` |
| IR1-4, white/green | Factory dimmer return and tee reserve B, labeled `IR1-4 DIM` |
| J2-1 through J2-5 | R−, G−, B−, protected common +12 V, W− |

Build the external Toyota tee 1:1 across all six cavities where the original
mate is in use. The controller takes four wires through the existing sleeve
and case saddle. Give IR1-3 and IR1-4 short, labeled 22 AWG TXL service tails
on the tee. Use individually insulated closed-end caps and tie the tails to
the loom where they remain accessible. The pair can later be terminated in
a keyed two-cavity connector. They are duplicate accesses to the upstream
TAIL and dimmer circuits and can support an equivalent low-current console
locator lamp after checking the factory lamp rating and dimmer behavior.
Check all six pass-throughs and the two reserve leads by cavity number. The
matching pairs share colors. [Printable wire register](WIRE-REGISTER.csv) ·
[IR1 mating-face diagram](../connector-adapter/IR1-WIRE-PLAN.md#mating-face-reference).

J2 lists the **board pad numbers**. Use continuity through the actual five-pin
pod lead and confirm its polarity and current on a current-limited bench
supply before connecting it. The donor cable's wire colors and contact
numbers depend on the part in hand. [Diode Dynamics M8 lead](https://www.diodedynamics.com/rgbw-m8-5-pin-extension-wire.html).

## Power and programming

The LM5164-Q1 reference build retains the 5 V rail for the RGBW gate drivers.
The TLV62569DBVR generates 3.318 V nominal for the module. The TLV803EC30
supervisor holds EN low during startup or brownout. The PWM GPIOs remain 18,
17, 14 and 2 for red, green, blue and white, with GPIO21 enabling the drivers.
The module antenna overhangs the PCB edge. Keep nearby vehicle metal, wiring,
and mounting hardware clear of that end and test radio performance installed.
[TI regulator](https://www.ti.com/lit/ds/symlink/tlv62569.pdf) ·
[TI supervisor](https://www.ti.com/lit/ds/symlink/tlv809e.pdf) ·
[Espressif antenna layout guidance](https://docs.espressif.com/projects/esp-hardware-design-guidelines/en/latest/esp32s3/pcb-layout-design.html#general-principles-of-pcb-layout-for-modules).

To flash on the bench, disconnect the truck and LEDs. Supply 12 V through
J1 from a fused, current-limited supply. With the lid off, attach a **3.3 V
logic UART** probe to TP9–TP13. TP9 is ground. TP10 (board TX) goes to adapter
RX and TP11 (board RX) goes to adapter TX. Hold TP12 (BOOT) low and pulse
TP13 (EN) low, then release EN before BOOT. TP14 is a 3.3 V measurement pad.
Leave the adapter's power wire disconnected. This revision uses a service
probe with access under the lid. The lighting firmware and head-unit relay
still need implementation. [Espressif download mode](https://docs.espressif.com/projects/esptool/en/latest/esp32s3/advanced-topics/boot-mode-selection.html).

## Assembly and build files

- [KiCad project](generated/vhos_rgbw_reve.kicad_pro) · [Board render](generated/shield.png) · [Schematic PDF](generated/schematic.pdf) · [Board STEP](generated/4Runner_RGBW_RevE_PCB.step).
- [Four-layer Gerbers and drills](generated/4Runner_RGBW_RevE_Gerbers.zip) · [Reference parts list](generated/PCB-BOM.csv) · [Stock-optimized JLCPCB BOM](jlcpcb/stock-lm5164-smt/BOM.csv) · [Matched placement file](jlcpcb/stock-lm5164-smt/CPL.csv).
- [FreeCAD assembly](generated/4Runner_RevE_Assembly.FCStd) · [CAD cutaway](generated/RevE-Toyota-wiring.png) · [Base STL](generated/case_base.stl) · [Lid STL](generated/case_lid.stl) · [Verification](generated/verification.json).

The stock-optimized quote specifies 85 top-side placements, including the ESP32-S3.
Complete L1, D7/D8, U6/U7, both Keystone 3568 fuse holders and their 3 A
and 1 A elements, and the two cable tails locally. Check the module and
semiconductor orientation, loaded quantities, stock and total in the
supplier preview. [Stock, prices and assembly options](jlcpcb/README.md) ·
[Harness and case parts](HARNESS-AND-CASE.csv) ·
[JLCPCB ESP32 module](https://jlcpcb.com/partdetail/ESP32-S3-WROOM-1-N16R8/C2913202) ·
[JLCPCB 3.3 V regulator](https://jlcpcb.com/partdetail/TLV62569DBVR/C141836).

## Fit and bring-up

The case body is 150 × 76 × 36 mm. The lid brings the height to 39.2 mm and
the mounting ears bring the length to 164 mm. Compared with Rev D, the
assembly is 10 mm shorter in height and 18 mm longer along the antenna axis.
The base uses four PCB mounts and four lid fasteners. Dry-fit the printed
pair, keyed Toyota mate, cable sleeve, fuse puller and vehicle mounting
location. The external tee reserve tails stay accessible beside the loom.

Meter the truck's IR1-6 ACC supply, IR1-5 return, fitted fuse and available
current. Confirm TAIL and the dimmer waveform, then check the board's rails,
boot, transient response, temperature and radio link on the bench and in the
intended mounting position. [IR1 meter worksheet](../connector-adapter/IR1-WIRE-PLAN.md#verify-on-the-truck-before-soldering).

Regenerate on Orion from `pcb-rgbw-revb` with
`python3 -B orion_client.py start UNIQUE-ID --stage toyota-rev-e`. Use
`status`, `fetch` and `stop` with the same identity.
