# Rev D Toyota IR1 RGBW controller

See [Rev E](../pcb-rgbw-reve/README.md) for the single-board version and full
wire register.

This 2005 4.7 L V8 4Runner prototype uses the white six-pin IR1 connector for
switched power, ground and two illumination readings. One Toyota harness
branch enters the enclosure. One five-wire RGBW cable leaves it. The existing
CAN ESP32 provides vehicle data wirelessly. [Toyota diagrams and truck-side checks](../connector-adapter/IR1-WIRE-PLAN.md).

| Toyota cavity | Shield pad | Role |
| --- | --- | --- |
| IR1-5, white/black | J1-1 GND | Chassis return for the ESP32 and RGBW load |
| IR1-6, pink/blue | J1-2 ACC | Sole +12 V supply. F1 is the 3 A main fuse, and F2 is the 1 A logic fuse. |
| IR1-1, green | J1-3 TAIL | Protected analog input on GPIO5 (A4) for parking lamps and headlights |
| IR1-2, white/green | J1-4 DIM | Protected analog input on GPIO4 (A5) for the ashtray lamp dimmer return |
| IR1-3 and IR1-4 | Factory pass-through | Lighter-ring supply and dimmer return, sharing the same upstream signals as IR1-1 and IR1-2 |

Keep all six cavities wired straight through on the external tee when the
original IR1 mate is in use. Branch only the four tabled leads into the case.
For an unused prewire, insulate the unused contacts individually. J2 carries
`R−`, `G−`, `B−`, fused common positive and `W−` in pad order 1 through 5.

## KiCad shield

J1 has four plated solder pads. The power pads have nominal 1.80 mm drills, and
the sense pads have 1.20 mm drills. Both sense channels use a high-impedance
divider, positive and negative clamps, a supervised analog switch, and an
ADC filter. The switch isolates the reading path while the shield is unpowered.
The channels share the IR1-5 chassis reference. Confirm GPIO5, GPIO4 and the 3.3 V
header on the owned ShengYang D1 UNO ESP32-S3. [Pad coordinates](generated/harness-pads.json) ·
[Electrical calculations](generated/sense-electrical-screen.json) ·
[TI switch](https://www.ti.com/lit/ds/symlink/sn3257-q1.pdf) ·
[TI supervisor](https://www.ti.com/lit/ds/symlink/tlv809e.pdf) ·
[TI shunt](https://www.ti.com/lit/ds/symlink/lm4040.pdf) ·
[Nexperia diode](https://assets.nexperia.com/documents/data-sheet/BAT54H-Q.pdf).

Firmware can detect night mode from TAIL. With TAIL on, subtract the calibrated
DIM reading from calibrated TAIL to measure the voltage delivered to the lamp.
Check how the truck's dimmer sweeps and whether it pulses. The reading circuit
has a nominal gain of about 0.097 and an RC time constant of about 1 ms.
The lighting firmware and head-unit behavior still need implementation.

- [KiCad project](generated/vhos_rgbw_revd.kicad_pro) · [Schematic PDF](generated/schematic.pdf) · [Board preview](generated/shield.png).
- [Shield STEP](generated/4Runner_RGBW_RevD_Shield.step) · [Four-layer Gerbers and drills](generated/4Runner_RGBW_RevD_Gerbers.zip) · [PCB parts list](generated/PCB-BOM.csv).

### Assembly quote files

The matched Rev D JLCPCB files specify 71 SMT positions and use the earlier
LM5169PQDDARQ1 selection with its four matched resistor changes. The KiCad
schematic and `PCB-BOM.csv` describe the LM5164 reference population. Use
the quote BOM and CPL together when quoting the LM5169 version. Current
stock, final orientation, loaded quantity and total cost need supplier
confirmation. [JLCPCB BOM](jlcpcb/truck-lm5169-smt/BOM.csv) ·
[Matching placement file](jlcpcb/truck-lm5169-smt/CPL.csv) ·
[LM5169 regulator changes](../pcb-rgbw-revb/jlcpcb/COST-PASS.md#lm5169-board-build).

Complete L1, D7/D8, U6/U7, both MINI fuse holders, the four stack headers,
the RUN header and shunt, and the two captive leads locally. Follow the
fuse labels and check the 5 V rail before installing the RUN shunt.
[L1, fuse and header parts](../pcb-rgbw-revb/jlcpcb/HAND-ASSEMBLY.csv) ·
[D7/D8 clamp diodes](https://www.digikey.com/en/products/detail/nexperia-usa-inc/BAT54H-QX/22126053) ·
[U6/U7 shunts](https://www.digikey.com/en/products/detail/texas-instruments/LM4040C25QDBZR/765349) ·
[R28/R29/R32/R33 quote substitution](https://jlcpcb.com/partdetail/YAGEO-AT0603BRD0722KL/C5455453) ·
[Existing 100 nF quote part](https://jlcpcb.com/partdetail/Yageo-CC0603KRX7R9BB104/C14663).

## Case and wiring

The installed CAD traces the four individual leads from the candidate Toyota
mating housing to their board pads. It uses nominal 20 AWG TXL power wires
and 22 AWG TXL sense wires in a 7.2 mm OD sleeve. The saddle restrains the
sleeve and the wires fan out inside the case to keep pull loads off the pads.
The lower board is a nominal envelope around the Espressif module. Confirm
the crimp exit positions and cut lengths on the installed harness, including
room for the tee, strain relief and service slack.
[TXL wire dimensions](https://tebaoflex.com/cables/txl-automotive-cross-linked-wire/).

| Shield pad | Modeled housing exit to wire tip | Minimum bend radius |
| --- | ---: | ---: |
| J1-1 GND | 96.9 mm | 8 mm |
| J1-2 ACC | 89.4 mm | 8 mm |
| J1-3 TAIL | 98.8 mm | 7 mm |
| J1-4 DIM | 93.5 mm | 7 mm |

Each modeled length includes a 3.2 mm strip at the shield. The saddle's first
slot holds a nominal 2.5 × 0.65 mm strap. The sleeve ends between the slots
so the individual wires can fan out. Dry-fit the actual strap head and
check pull retention. The case body, lid and coupons match the previous
STL exports byte for byte. The Rev D assembly passed 97 wire and restraint
checks and 61 case checks. All 11 tool paths and five supports-off slices passed.

- [FreeCAD assembly](generated/4Runner_RevD_Assembly.FCStd) · [Toyota wires STEP](generated/4Runner_RevD_Toyota_Wires.step) · [Wiring cutaway](generated/RevD-Toyota-wiring.png).
- [Case base STL](../pcb-rgbw-revb/toyota-power-cad/case_base.stl) · [Lid STL](../pcb-rgbw-revb/toyota-power-cad/case_lid.stl) · [Cable saddle coupon](../pcb-rgbw-revb/toyota-power-cad/front_ports_coupon.stl) · [Lid slice](../pcb-rgbw-revb/toyota-power-cad/front_lid_coupon.stl).
- [Harness and case parts](HARNESS-AND-CASE.csv) · [Wire clearances and bend radii](generated/ir1-wire-fit.json) · [Verification receipt](generated/verification.json).

## Before connecting to the truck

Verify the actual power and ground at IR1-6 and IR1-5, the fuse feeding the
circuit, and the expected TAIL and DIM readings. The service diagram shows
a CIG fuse and both 2005 owner's manuals identify that slot as unused. Meter
the particular truck before relying on IR1 to supply the full RGBW load.
Dry-fit the actual UNO board, keyed housing, wire sizes and printed parts.
Bench-test the sense inputs with TAIL present and ACC off and during supply
transitions, then check transient response and the combined pod current.
[IR1 meter worksheet and sources](../connector-adapter/IR1-WIRE-PLAN.md#verify-on-the-truck-before-soldering).

Regenerate on Orion from `pcb-rgbw-revb` with
`python3 -B orion_client.py start UNIQUE-ID --stage toyota-rev-d`. Use `status`,
`fetch` and `stop` with the same identity.
