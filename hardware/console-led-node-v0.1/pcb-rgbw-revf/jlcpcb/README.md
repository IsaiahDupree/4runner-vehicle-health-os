# Rev F JLCPCB stock and assembly

Use [BOM.csv](BOM.csv) and [CPL.csv](CPL.csv) together with the
[Rev F Gerbers](../generated/4Runner_RGBW_RevF_Gerbers.zip). The build uses
a 122 × 53.34 mm, four-layer, 1.6 mm PCB and 90 top-side SMT placements.
The populated board includes the onboard ESP32-S3 and the 1 A LM5164-Q1.
Confirm the assembly preview, component orientation, rail clearance for the
ESP32 antenna overhang, and the quote tier and parts stock at checkout.
[PCB assembly capabilities](https://jlcpcb.com/capabilities/pcb-assembly-capabilities).

## Parts that moved to factory assembly

| References | Exact part | JLCPCB | Snapshot stock |
| --- | --- | --- | ---: |
| L1 | TDK SPM6545VT-680M-D, 68 µH | [C2047878](https://jlcpcb.com/partdetail/SPM6545VT-680M-D/C2047878) | 1,845 |
| D7, D8 | onsemi NSVBAT54HT1G, SOD-323 | [C179609](https://jlcpcb.com/partdetail/NSVBAT54HT1G/C179609) | 63,009 |
| U6, U7 | Diodes LM4040C25QFTA, 2.5 V | [C531175](https://jlcpcb.com/partdetail/DiodesIncorporated-LM4040C25QFTA/C531175) | 35 |

All 43 selected catalog codes cleared the loaded quantities for two and five
boards in the November 14, 2026 snapshot. U6/U7 are the first line to recheck,
with 10 pieces required for a five-board run. DigiKey lists the same shunt
MPN for local sourcing. These three lines add three Extended feeder charges.
The stock network drops the 41.2 kΩ and 158 kΩ Extended lines for Basic
values and reuses the existing precision 46.4 kΩ code at R34. The reference
assembly stays at 28 modeled Extended feeder charges with five additional
factory placements per board.
[Dated catalog](catalog-snapshot.csv) ·
[Exact shunt at DigiKey](https://www.digikey.com/en/products/detail/diodes-incorporated/LM4040C25QFTA/4948433).

## Estimated Economic assembly cost

| Population | Factory SMT per board | Two boards | Five boards |
| --- | ---: | ---: | ---: |
| Rev E stock assembly | 85 | $183.36 | $285.06 |
| Rev E with both shunt clamps | 87 | $191.17 | $298.71 |
| **Rev F full SMT** | **90** | **$188.28** | **$296.15** |

Rev F saves $2.89 at two boards and $2.56 at five compared with the
87-placement Rev E option. That Rev E option still needs the inductor and
both negative clamps fitted locally. The 85-placement option leaves five
SMT placements per board to source and install. As a listed-price
comparison, two Rev E boards plus the five manual parts per board totaled
about $193.96 before local labor and shipping. That adds $4.64 for the
inductors, $0.84 for the four diodes and $5.12 for the four shunts to
$183.36. The old diode listing was backordered. [Rev E comparison](../../pcb-rgbw-reve/jlcpcb/README.md) ·
[Mouser Rev E inductor](https://www.mouser.com/en/ProductDetail/Coilcraft/MSS1246T-683MLC?qs=zCSbvcPd3paxUT6FfGLWRw%3D%3D) ·
[DigiKey Rev E diode](https://www.digikey.com/en/products/detail/nexperia-usa-inc/BAT54H-QX/22126053) ·
[DigiKey Rev E shunt](https://www.digikey.com/en/products/detail/texas-instruments/LM4040C25QDBZR/765300).

## Hand assembly

Fit two black Keystone 3568 holders, the 3 A and 1 A MINI fuse elements and
the two captive cable leads locally. Check the cable polarity and fuse ratings using the [bench sequence](../BENCH.md). The earlier stock check
found four red holders in the JLCPCB catalog and zero black. The local
black holder avoids the factory through-hole handling fee and is an
available exact part. [Keystone 3568 at DigiKey](https://www.digikey.com/en/products/detail/keystone-electronics/3568/2137306).

The model includes parts, loaded quantities and attrition, setup, stencil,
top-side placement and catalog-flagged X-ray. Get the actual quote for bare
boards, any additional inspection, printed parts, local hardware, shipping,
tax and tariff. [Cost calculation](assembly-estimate.json) ·
[JLCPCB fee schedule](https://jlcpcb.com/help/article/pcb-assembly-price).
