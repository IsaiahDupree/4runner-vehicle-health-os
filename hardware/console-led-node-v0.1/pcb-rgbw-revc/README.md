# Rev C Toyota-powered RGBW shield

The white six-pin Toyota console plug supplies the switched 12 V and ground
for both the ESP32-S3 and the RGBW lights. It is the box's only wired input
in service. The five-wire RGBW cable takes protected power and four switched
returns from the shield to the lights. Vehicle data comes wirelessly from the
existing CAN ESP32.

Rev C uses two dedicated Toyota power solder pads and five RGBW solder pads.
It removes the three unused signal pads and three locating holes from the
former connector footprints and marks each wire function on the board. The
active pad centers, trace routing, fuse locations, UNO stack headers and
enclosure mounting points carry over from Rev B. The case saddles grip the
cable jackets and carry pull loads.

| Top-side pads | Wire assignment |
| --- | --- |
| J1 power in | 1 ground, 2 switched +12 V. Nominal 1.80 mm plated drills. |
| J2 RGBW out | 1 R−, 2 G−, 3 B−, 4 protected common +12 V, 5 W−. Nominal 1.02 mm plated drills. |

The pad numbers identify the shield. Verify the two Toyota cavities on the
truck before wiring the mating housing. If the Toyota connector serves factory
equipment, preserve its factory circuits in the inline harness and branch only
the verified power and return. Verify the upstream fuse, available current and
combined controller and pod load before connecting to the truck.
[Toyota connector research](../connector-adapter/README.md).

## Model and fabrication files

- [Board preview](generated/shield.png) · [Shield STEP](generated/4Runner_RGBW_RevC_Shield.step) · [KiCad project](generated/vhos_rgbw_revc.kicad_pro).
- [Rev C Gerbers and drills](generated/4Runner_RGBW_RevC_Gerbers.zip) · [LM5169 SMT-only BOM](../pcb-rgbw-revb/jlcpcb/truck-lm5169-smt/BOM.csv) · [Matched placement file](../pcb-rgbw-revb/jlcpcb/truck-lm5169-smt/CPL.csv).
- [Case base](../pcb-rgbw-revb/toyota-power-cad/case_base.stl) · [Lid](../pcb-rgbw-revb/toyota-power-cad/case_lid.stl) · [Cable saddle coupon](../pcb-rgbw-revb/toyota-power-cad/front_ports_coupon.stl) · [Lid slice](../pcb-rgbw-revb/toyota-power-cad/front_lid_coupon.stl).
- [Shield pad coordinates](generated/harness-pads.json) · [Verification receipt](generated/verification.json).

Use the four-layer Rev C fabrication files with the SMT-only pair. The native
schematic shows the LM5164 reference population. The assembly pair specifies
the lower-cost LM5169 and its matched resistor set. Fit the specified inductor,
both fuse holders and the stack and RUN headers locally. Check regulation on
the bench before closing the RUN shunt. [Regulator and bench details](../pcb-rgbw-revb/jlcpcb/COST-PASS.md#lm5169-board-build).

The PCB and enclosure models support prototype evaluation. Vehicle pinout,
physical fit, transient and thermal performance, and the lighting relay still
need verification on the hardware.

Regenerate on Orion from `pcb-rgbw-revb` with
`python3 -B orion_client.py start UNIQUE-ID --stage toyota-rev-c`. Use `status`,
`fetch` and `stop` with the same identity. See the
[KiCad 10 CLI reference](https://docs.kicad.org/10.0/en/cli/cli.html) for the
export formats.
