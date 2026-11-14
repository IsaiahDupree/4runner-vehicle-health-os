# Rev G JLCPCB assembly and stock

Use the matched [Gerbers and drills](../generated/4Runner_RGBW_RevG_Gerbers.zip),
[BOM](BOM.csv) and [CPL](CPL.csv). The PCB is 122 × 53.34 mm, four
layers, 1.6 mm, with 59 top-side SMT placements. The two fuse holders
and captive leads are fitted locally. Check the assembly preview,
exposed-pad inspection requirements and depaneling clearance near the
ESP32 antenna overhang. [JLCPCB assembly capabilities](https://jlcpcb.com/capabilities/pcb-assembly-capabilities).

| Economic SMT | Rev F assembly | Rev G assembly | Rev G per board |
| --- | ---: | ---: | ---: |
| Two boards | $188.28 | **$98.61** | $49.31 |
| Five boards | $296.15 | $142.22 | $28.44 |
| Ten boards | $449.89 | $205.58 | $20.56 |

The two-board estimate includes $39.11 in parts, $49.12 in Extended
feeders, $9.71 for setup and stencil, and $0.67 for SMT placement.
Rev G uses 16 Extended codes, down from 28. The dated catalog flags
zero Rev G placements for X-ray. JLCPCB may still specify inspections
for the exposed pads. Two-board assembly leaves $1.39 before the $100
batch target. Price bare boards, local hardware, case, LED pod, delivery,
tax and tariffs for the actual order.
[Published fees](https://jlcpcb.com/help/article/pcb-assembly-price) ·
[Calculation](assembly-estimate.json) ·
[November 14, 2026 catalog snapshot](catalog-snapshot.csv).

| Job | Exact part | JLCPCB | Catalog stock |
| --- | --- | --- | ---: |
| Reverse, overvoltage and current protection | TPS26600PWPR | [C544399](https://jlcpcb.com/partdetail/TPS26600PWPR/C544399) | 4,460 |
| Direct 3.3 V buck | LMR51610XDBVR | [C20539658](https://jlcpcb.com/partdetail/TexasInstruments-LMR51610XDBVR/C20539658) | 8,976 |
| Four RGBW returns | DRV8803PWPR | [C114177](https://jlcpcb.com/partdetail/DRV8803PWPR/C114177) | 7,686 |
| Wi-Fi and BLE | ESP32-S3-WROOM-1-N16R2 | [C2913205](https://jlcpcb.com/partdetail/ESP32-S3-WROOM-1-N16R2/C2913205) | 7,664 |
| 22 µH buck inductor | SPM6545VT-220M-D | [C2047872](https://jlcpcb.com/partdetail/SPM6545VT-220M-D/C2047872) | 388 |
| 22 µF logic capacitors, Basic | CL31A226KAHNNNE | [C12891](https://jlcpcb.com/partdetail/13537-CL31A226KAHNNNE/C12891) | 2,750,535 |

All 29 codes had enough stock for ten boards with the catalog's loaded
quantity and attrition rules. The first parts to recheck include U6 and
U7, with 35 of the shunt reference in stock, and U10, with 91 of the
reset supervisor. Factory inventory and assembly eligibility can change.
[Shunt reference](https://jlcpcb.com/partdetail/DiodesIncorporated-LM4040C25QFTA/C531175) ·
[Reset supervisor](https://jlcpcb.com/partdetail/TexasInstruments-TLV803EC30DBZR/C2877924).

Fit two Keystone 3568 fuse holders, their 3 A and 1 A MINI fuses,
and the two leads from the hardware register. Buy the mating housings
and terminals as a set after verifying the truck's latch and cavity
markings. [Keystone 3568](https://www.digikey.com/en/products/detail/keystone-electronics/3568/2137306) ·
[Harness and case hardware](../HARNESS-AND-CASE.csv) ·
[Bring-up sequence](../BENCH.md).
