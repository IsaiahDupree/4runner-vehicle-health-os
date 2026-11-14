# Rev E JLCPCB assembly and stock

Use **stock-lm5164-smt** for the first vehicle-intent prototype. It retains
the 1 A LM5164-Q1 regulator and the existing Toyota input protection. All
41 factory part numbers had stock for two boards in the November 14, 2026
JLCPCB snapshot. Check D7/D8 availability before committing to that
population. The bench population gives you a fit and electronics test while
those diodes are on backorder. Use the same 122 × 53.34 mm Rev E Gerbers for
each population. [Gerbers and drills](../generated/4Runner_RGBW_RevE_Gerbers.zip) ·
[JLCPCB catalog snapshot](catalog-snapshot.csv).

| Population | Factory SMT placements per board | 2 boards | 5 boards |
| --- | ---: | ---: | ---: |
| Original LM5164-Q1 quote input | 85 | $190.04 | $291.73 |
| Stock-optimized LM5164-Q1 [BOM](stock-lm5164-smt/BOM.csv) · [CPL](stock-lm5164-smt/CPL.csv) | 85 | **$183.36** | **$285.06** |
| LM5164-Q1 with U6/U7 fitted [BOM](stock-lm5164-clamps-smt/BOM.csv) · [CPL](stock-lm5164-clamps-smt/CPL.csv) | 87 | $191.17 | $298.71 |
| Bench LM5164 with all four sense clamps fitted [BOM](bench-lm5164-smt/BOM.csv) · [CPL](bench-lm5164-smt/CPL.csv) | 89 | $172.10 | $245.57 |

Batch estimates in USD cover Economic assembly setup, stencil, loaded
components, feeder fees, placement and catalog-flagged X-ray on the ESP32
module. The model charges each catalog Extended line at the published feeder
rate. The checkout determines any Preferred Extended exemptions, inspection
on additional hidden joints, and final assembly quantities and pricing.
Budget separately for bare boards, hand-fitted parts and labor, enclosure,
harness, shipping and taxes.
[Estimate and quantity breakdown](assembly-estimate.json) ·
[JLCPCB fee schedule](https://jlcpcb.com/help/article/pcb-assembly-price) ·
[JLCPCB Basic and Preferred Extended rules](https://jlcpcb.com/help/article/pcb-assembly-faqs).

## Changes to the factory BOM

| References | New JLCPCB part | Effect |
| --- | --- | --- |
| R3 | UNI-ROYAL 0603WAF2203T5E, C22961 | 220 kΩ, 1%, 0603. Removes an Extended feeder and raises stock from 2,785 to 963,060. |
| R30/R31 | UNI-ROYAL 0603WAF1001T5E, C21190 | 1 kΩ, 1%, 0603. Removes an Extended feeder on the ADC isolation resistors. |

R3 changes the buck's calculated enable/disable thresholds from 8.287/7.735 V
to 8.318/7.764 V nominal at the buck input. The calculated rising range is
7.91–8.74 V with the specified regulator thresholds and both divider
resistors at 1%. Check startup and recovery through the truck's measured ACC
dip. R30/R31 contribute less than 0.025% change in nominal small-signal gain
from their 1% tolerance alone and less than 0.029% change in the ADC filter
time constant. The 0.1% divider resistors stay specified at the factory and
the reference schematic records the original population.
[C22961](https://jlcpcb.com/partdetail/0603WAF2203T5E/C22961) ·
[C21190](https://jlcpcb.com/partdetail/C21190) ·
[TI LM5164-Q1 datasheet](https://www.ti.com/lit/ds/symlink/lm5164-q1.pdf).

The catalog listed 21,680 ESP32-S3-WROOM-1-N16R8 modules (C2913202), 998
automotive LM5164 regulators (C2072225), and 91 TLV803EC30DBZR reset
supervisors (C2877924). The supervisor is the lowest-stock line in the
85-placement quote. The exact LM4040C25QDBZR (C2872469) is an optional
factory part at U6/U7. The snapshot had 11, so five boards would consume
10 before any shop adjustment. It adds $7.81 for two boards to the factory
subtotal and saves two hand placements per board.
[ESP32 module](https://jlcpcb.com/partdetail/C2913202) ·
[LM5164-Q1](https://jlcpcb.com/partdetail/C2072225) ·
[Reset supervisor](https://jlcpcb.com/partdetail/C2877924) ·
[DigiKey supply for the exact shunt](https://www.digikey.com/en/products/detail/texas-instruments/LM4040C25QDBZR/765300).

## Parts to finish by hand

| Ref | Quantity per board | Part and sourcing |
| --- | ---: | --- |
| L1 | 1 | Coilcraft MSS1246T-683MLC, 68 µH. Fit before applying power. [Coilcraft](https://www.coilcraft.com/en-us/products/power/shielded-inductors/ferrite-drum/mss-mos/mss1246t/mss1246t-683/) |
| D7/D8 | 2 | Nexperia BAT54H-QX on the LM5164-Q1 builds. The exact AEC-Q101 SOD-123F part was backordered at the checked authorized distributors. [Nexperia](https://www.nexperia.com/product/BAT54H-Q) · [DigiKey](https://www.digikey.com/en/products/detail/nexperia-usa-inc/BAT54H-QX/22126053) · [Avnet](https://www.avnet.com/americas/product/nexperia/bat54h-qx/evolve-66110669/) |
| U6/U7 | 2 | TI LM4040C25QDBZR if using the 85-placement BOM. [DigiKey](https://www.digikey.com/en/products/detail/texas-instruments/LM4040C25QDBZR/765300) |
| F1/F2 holders | 2 | Black Keystone 3568. JLCPCB listed zero black and four red holders. Four black holders were $4.52 in parts at DigiKey versus $13.00 for four red at JLCPCB before through-hole labor. [DigiKey black](https://www.digikey.com/en/products/detail/keystone-electronics/3568/2137306) · [JLCPCB black](https://jlcpcb.com/partdetail/C5249699) · [JLCPCB red](https://jlcpcb.com/partdetail/C3205378) |
| F1/F2 elements | 1 each | F1 Littelfuse 0997003.WXN (3 A, 58 V), F2 Eaton ATM-1 (1 A, 32 V). [F1 DigiKey](https://www.digikey.com/en/products/detail/littelfuse-inc/0997003-WXN/701055) · [F2 Mouser](https://www.mouser.com/en/ProductDetail/Bussmann-Eaton/ATM-1?qs=67eC1vNVLiXluUOuCQSxUw%3D%3D) |
| J1/J2 | 1 lead each | Toyota branch and RGBW lead solder to the board pads and are captured by the case saddles. [Harness and case parts](../HARNESS-AND-CASE.csv) |

The **bench BOM** uses TI LM5164DDAR (C477928) and Nexperia BAT54H,115
(C426769). Both are standard-grade parts. TI lists the same DDA land
pattern, pinout, 1 A output and 6–100 V input range. The Nexperia diode shares
the SOD-123F land pattern, cathode on pin 1, and published room-temperature
low-current forward-voltage limits. The automotive Q1 regulator and
Q-series diode are specified for the vehicle-intent population. Check
buck startup, RF load steps, and TAIL/DIM clamp behavior on the bench.
[TI LM5164 datasheet](https://www.ti.com/lit/ds/symlink/lm5164.pdf) ·
[Nexperia BAT54H datasheet](https://assets.nexperia.com/documents/data-sheet/BAT54H.pdf) ·
[JLCPCB BAT54H,115](https://jlcpcb.com/partdetail/C426769).

Quote green 1.6 mm FR-4 with the standard four-layer stackup and top-side
Economic assembly for two boards. Confirm JLCPCB can panelize the board
with clearance for the overhanging antenna, and check pin 1, diode polarity
and the line-item fees in the placement preview. The single board's
53.34 mm width is under the published 70 mm minimum for unpanelized
Standard assembly.
[JLCPCB assembly capabilities](https://jlcpcb.com/capabilities/pcb-assembly-capabilities) ·
[JLCPCB process edges](https://jlcpcb.com/help/article/specifications-for-adding-process-edges-and-positioning-holes).

The estimates can be reproduced from the repository with
`python3 -B hardware/console-led-node-v0.1/pcb-rgbw-revb/jlcpcb/prepare_reve_stock_quote.py`.
It reads the [dated catalog data](catalog-snapshot.csv) and
[five native KiCad placement rows](hand-smt-placement.csv) from the Rev E
export. The model uses the greater of the assembly minimum and required
pieces plus listed attrition. The snapshot uses JLCPCB's public
component-detail endpoint and its overseas stock and assembly price fields.
