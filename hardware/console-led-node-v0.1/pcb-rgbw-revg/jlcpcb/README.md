# Rev G JLCPCB assembly and stock

The PCB is 122 × 53.34 mm, four layers, 1.6 mm, with 59 top-side SMT
placements. For outsourcing all PCB soldering, use the [mixed-assembly
BOM](factory-holders/BOM.csv) and [matching CPL](factory-holders/CPL.csv)
with the [Gerbers and drills](../generated/4Runner_RGBW_RevG_Gerbers.zip).
It adds factory placement of both MINI fuse holders. The box-build
vendor installs the fuse elements and solders both captive cable leads.
Check the assembly preview, exposed-pad inspection, removal of tooling
rails and the ESP32 antenna overhang. [JLCPCB assembly capabilities](https://jlcpcb.com/capabilities/pcb-assembly-capabilities) ·
[Finished-unit vendor scope](../BOX-BUILD.md).

The original [SMT-only BOM](BOM.csv) and [CPL](CPL.csv) are the basis of
the cost comparison below.

| Economic SMT | Rev F assembly | Rev G assembly | Rev G per board |
| --- | ---: | ---: | ---: |
| Two boards | $188.28 | **$98.61** | $49.31 |
| Five boards | $296.15 | $142.22 | $28.44 |
| Ten boards | $449.89 | $205.58 | $20.56 |

The two-board estimate includes $39.11 in parts, $49.12 in Extended
feeders, $9.71 for setup and stencil, and $0.67 for SMT placement.
For two boards, the revision saves $49.30 in parts, $36.84 in Extended
feeder charges, $0.25 in placement and $3.28 in catalog-flagged X-ray.
It brings the surface-mount BOM from 90 to 59 placements and from 28 to
16 Extended part numbers. One 3.3 V regulator replaces the two-stage
supply, one eFuse integrates the input protection, and one RGBW driver
replaces the discrete switching stages. The dated catalog flags zero
Rev G placements for X-ray. JLCPCB may still require exposed-pad
inspection. See the finished-unit quote for costs beyond SMT.
[Published fees](https://jlcpcb.com/help/article/pcb-assembly-price) ·
[Rev F calculation](../../pcb-rgbw-revf/jlcpcb/assembly-estimate.json) ·
[Rev G calculation](assembly-estimate.json) ·
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

## Board with the fuse holders soldered

The red Keystone **3568-10**, code **C3205378**, matches both existing
four-pin footprints. The dated catalog showed four available, exactly
enough for the two-board build. Check inventory when placing the order.
The modeled **$19.92** batch charge includes the four holders, a $3.07
feeder allowance, the manual setup and 16 solder joints. That brings mixed
assembly to **$118.53** before board fabrication and delivery. The
dimension-only calculator showed **$34.30** for five bare boards with
lead-free HASL or **$29.10** with OSP on November 14, 2026. Allow
**$152.83** for the lead-free HASL batch with two boards assembled
and three bare spares. Confirm the combined price with real files in
the vendor's assembly checkout.
[Door-to-door build scope](../BOX-BUILD.md) ·
[JLCPCB holder listing](https://jlcpcb.com/partdetail/3568-10/C3205378) ·
[Mixed-assembly calculation](factory-holders/assembly-estimate.json) ·
[Holder catalog snapshot](factory-holders/holder-catalog.csv) ·
[Bare-board calculator inputs](factory-holders/bare-board-calculator.json) ·
[JLCPCB calculator](https://cart.jlcpcb.com/quote).
