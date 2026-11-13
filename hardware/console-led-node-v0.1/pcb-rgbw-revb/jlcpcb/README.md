# JLCPCB prototype package for the 4Runner RGBW controller

For the current [Toyota-powered captive-lead build](../TOYOTA-POWER-BUILD.md),
use the [LM5169 SMT-only BOM](truck-lm5169-smt/BOM.csv) and matching
[CPL](truck-lm5169-smt/CPL.csv). The assembly and pricing comparisons below
document the earlier plug-equipped options.

The [PCB and JLCPCB prototype guide](../../../../docs/hardware/PCB-JLCPCB-PROTOTYPE-GUIDE.md)
captures the design, assembly and sourcing workflow for reuse on the next board.

The [lower-cost LM5169 assembly and lightweight print package](COST-PASS.md)
adds a pin-compatible automotive buck option, two more factory-installable
parts and a smaller nylon volume. The original Rev B choices follow below.

Use the **truck-smt** BOM for the first automotive-intent prototype. Quote five
four-layer shields with two assembled if the cart offers that split. The owner
finishes the through-hole work and installs the exact Coilcraft inductor. The
shield still stacks on the owned UNO-format ESP32-S3 and takes two cable plugs.
The Gerbers come from Rev B, commit `94b40aca84e0b9ec02733ed880a0ae316addabdc`.

| Quote files | Factory placements per shield | Hardware finished locally |
| --- | ---: | --- |
| **Truck SMT** · [BOM](truck-smt/BOM.csv) · [CPL](truck-smt/CPL.csv) | 55 top-side SMT, automotive LM5164-Q1 buck | L1, both Molex headers, both fuse holders, four stack headers and JP1 |
| **Truck mixed** · [BOM](truck-mixed/BOM.csv) · [CPL](truck-mixed/CPL.csv) | Same 55 SMT plus J1 and J2 | L1, both fuse holders, four stack headers and JP1 |
| **Bench SMT** · [BOM](bench-smt/BOM.csv) · [CPL](bench-smt/CPL.csv) | Same 55 positions with commercial LM5164DDAR at U1 | Same hand assembly as Truck SMT. Use a current-limited bench supply. |

[Rev B Gerbers and drills](../generated/Prototype_PCB_Gerbers.zip) ·
[Shopping and hand-assembly list](HAND-ASSEMBLY.csv) ·
[Rev B wiring and bench sequence](../README.md).

## Assembly cost

| Shields assembled | Truck SMT | Truck mixed | Bench SMT |
| ---: | ---: | ---: | ---: |
| 2 | $128.60 | $142.15 | $105.29 |
| 5 | $200.00 | $219.29 | $141.73 |
| 10 | $312.43 | $338.24 | $202.66 |

These are USD **assembly subtotals for the batch** using JLC catalog prices and
stock observed Nov 12, 2026, US Eastern time. They include components, modeled
small-order minima and attrition, setup, stencil, and placement. Mixed also
includes hand-soldering charges for the headers. Add bare PCBs, case prints,
external parts, shipping, taxes and any DFM or inspection charge. The cart may
apply X-ray inspection to U4, estimated at $1.64 per shield if required.
[Estimate details](assembly-estimate.json) · [JLC fee table](https://jlcpcb.com/help/article/pcb-assembly-price) ·
[Economic assembly quantities](https://jlcpcb.com/blog/reduce-pcb-assembly-cost-prototype).

- The seven resistor values and two stocked capacitor lines moved from
  Extended to Basic, saving **$27.63 per Economic assembly order** in feeder
  fees. A tenth Basic line replaces the out-of-stock 3.3 nF capacitor and
  avoids another $3.07 versus an Extended replacement. The selected BOM uses
  11 Basic part numbers, including a 100 nF 100 V 0805 replacement for C13/C14.
  [Catalog snapshot](catalog-snapshot.csv) · [JLC Basic and Extended rules](https://jlcpcb.com/help/article/pcb-assembly-faqs).
- The automotive LM5164QDDARQ1 was **$14.21** at JLC, with 1,022 listed. The
  pin-compatible commercial LM5164DDAR was **$2.56**, with 854 listed. The
  bench BOM gives a separate option for firmware and dry fit. At two
  assemblies the modeled reduction is $23.31 for the batch. Add $5.12 if
  checkout requires a separate four-piece purchase of the commercial part.
  [JLC automotive buck](https://jlcpcb.com/partdetail/TexasInstruments-LM5164QDDARQ1/C2072225) ·
  [JLC commercial buck](https://jlcpcb.com/partdetail/TexasInstruments-LM5164DDAR/C477928) ·
  [TI automotive pinout](https://www.ti.com/lit/ds/symlink/lm5164-q1.pdf#page=3) ·
  [TI commercial pinout](https://www.ti.com/lit/ds/symlink/lm5164.pdf#page=3).
- JLC listed the exact Molex **76825-0002** and **43045-0800** as manual
  through-hole placements. Stock was 1,297 and 3,287. With two boards, the
  modeled vendor assembly premium is $13.55, including the two parts.
  Compare that premium with the parts and any separate shipping when quoting.
  L1 was unavailable for stock assembly and Mouser listed the exact Coilcraft
  part at **$2.33** in cut tape. The Keystone 3568 holder was unavailable at
  JLC and DigiKey listed it at **$1.31** each. Mouser also stocked the exact
  ATM-1 fuse. For the Toyota pass-through, Corsa lists the matching pin and
  socket kits at **$6.17** together, with contacts.
  [J1 catalog](https://jlcpcb.com/partdetail/MOLEX-768250002/C586017) ·
  [J2 catalog](https://jlcpcb.com/partdetail/MOLEX-430450800/C122422) ·
  [Coilcraft at Mouser](https://www.mouser.com/en/ProductDetail/Coilcraft/MSS1246T-683MLC?qs=zCSbvcPd3paxUT6FfGLWRw%3D%3D) ·
  [Keystone at DigiKey](https://www.digikey.com/en/products/detail/keystone-electronics/3568/2137306) ·
  [Eaton at Mouser](https://www.mouser.com/en/ProductDetail/Bussmann-Eaton/ATM-1?qs=67eC1vNVLiXluUOuCQSxUw%3D%3D) ·
  [Corsa pin kit](https://www.corsa-technic.com/item.php?item_id=1359) ·
  [Corsa socket kit](https://www.corsa-technic.com/item.php?item_id=1360).
- The selected JLC parts support the modeled ten-board lot at observed stock.
  Recheck C5372271 (two capacitors per shield) and C544585 (two gate drivers
  per shield) when quoting. Buy loose parts from the listed retail suppliers.
  The JLC assembly catalog and LCSC retail inventory are separate.
  [JLC sourcing FAQ](https://jlcpcb.com/help/article/pcb-assembly-faqs-part-2).

## Review the PCB quote

1. Upload the Gerber ZIP. Select **four-layer FR-4, 1.6 mm, green,
   1 oz outer and 0.5 oz inner copper**, Economic top-side assembly.
   Quote lead-free HASL and ENIG. Confirm the finish with JLC for the 0.5 mm
   pitch WSON at U4. The 121.58 × 53.34 mm notched board exceeds the
   100 × 100 mm box used for the advertised entry price.
   [PCB assembly capabilities](https://jlcpcb.com/capabilities/pcb-assembly-capabilities) ·
   [PCB capabilities and drill tolerances](https://jlcpcb.com/capabilities/pcb-capabilities) ·
   [Prototype offer conditions](https://jlcpcb.com/ads/pcb-prototype).
2. Upload the BOM and CPL from the same folder. Compare the part numbers,
   side and orientation in JLC's viewer, especially U1–U4, Q1–Q6, and
   electrolytics C1/C17. For mixed assembly also confirm connector pin 1,
   latch direction and board-edge overhang. The connector positions use the
   drawing body centers and a nominal 90° top rotation. Ask JLC to confirm
   assembly feasibility for the overhang or use the SMT-only quote.
   [JLC placement format](https://jlcpcb.com/help/article/pick-place-file-for-pcb-assembly) ·
   [Molex Mega-Fit](https://www.molex.com/en-us/products/part-detail/768250002) ·
   [Molex Micro-Fit](https://www.molex.com/en-us/products/part-detail/0430450800).
3. Inspect the DFM proposal for tooling holes and rails before approving the
   build. Keep any new holes out of circuit copper and preserve the outline,
   connector locator holes and four case mounts. Confirm finished fuse
   holder bores of at least 1.60 mm from the 1.70 mm nominal plated drills.
   Verify that the assembly stencil leaves L1 clean for local attachment.
   [Economic tooling holes](https://jlcpcb.com/help/article/how-to-add-tooling-holes-for-pcb-assembly-order) ·
   [Assembly stencil rules](https://jlcpcb.com/help/article/smt-stencil-data-prepared-for-smt-orders) ·
   [Keystone drawing](https://www.keyelco.com/product-pdf.cfm?p=306).

The BOM substitutions use the existing pads. C2/C3 keep 2.2 µF, 100 V X7R and
AEC-Q200. C7/C8 keep 22 µF, 25 V X7R and AEC-Q200. C4 retains TI's 2.2 nF,
50 V X7R bootstrap specification. Q5/Q6 use the AEC-Q101 100 V LFPAK56
BUK9Y19-100E. At 2 A, the increase from 15 to 18 mΩ at 10 V gate drive adds
about 12 mW per MOSFET at the datasheet reference condition. Gate charge,
inrush and cutoff behavior still require the assembled prototype.
[Samsung C2/C3](https://product.samsungsem.com/cn/mlcc/CL32B225KCJVPJ.do) ·
[Taiyo Yuden C7/C8 spec](https://datasheet.lcsc.com/datasheet/pdf/f37249c55fbdd7144a5f5b7f420f8268.pdf?productCode=C5372271) ·
[Nexperia selection guide](https://assets.nexperia.com/documents/selection-guide/Nexperia_Selection_guide_2024.pdf).

D1 uses the automotive **SMBJ28CAQ-13-F**, with a 28 V standoff and 45.4 V
published clamp at its rated 10/1000 µs pulse. Those numbers track the
original TPSMB33CA's **28.2 V** standoff and **45.7 V** clamp. D3–D6 use the
24 V SMBJ24CAQ-13-F. Recheck input pulse behavior, reverse polarity, gate-off
timing and LED-cable transients on the prototype. The in-line harness still
needs actual keying, pass-through continuity, verified switched feed with
source-side protection and a dedicated return. Diode Dynamics describes
its M8 controller as common-positive and calls the black lead ground in a
separate extension Q&A. Continuity-map the actual cable and verify the
pod's common-positive polarity on a current-limited supply before connecting
it to the shield. [Original Littelfuse datasheet](https://www.littelfuse.com/~/media/electronics/datasheets/tvs_diodes/littelfuse_tvs_diode_tpsmb_datasheet.pdf.pdf) ·
[Diodes Inc. 28 V clamp](https://www.diodes.com/part/view/SMBJ28CAQ) ·
[Diodes Inc. 24 V clamp](https://jlcpcb.com/partdetail/DiodesIncorporated-SMBJ24CAQ_13F/C1974053) ·
[M8 controller](https://www.diodedynamics.com/rgbw-bluetooth-controller.html) ·
[M8 extension Q&A](https://www.diodedynamics.com/rgbw-m8-5-pin-extension-wire.html).

## Quote and print the enclosure

Use **JLC3DP SLS 3201 PA-F nylon, standard finish**. Upload each STL as its
own part in millimeters. Start with one combined port and insert coupon. It
uses **11.61 cm³** of solid material, about **10%** of the full case's
119.44 cm³. JLC's price depends on the model and shipping. Confirm the
coupon's delivered cost and the later base-and-lid cost in the cart.
[3201 PA-F nylon](https://jlc3dp.com/help/article/3201pa-f-nylon) ·
[JLC3DP quote and order inputs](https://jlc3dp.com/help/article/how-to-place-a-3d-printing-order).

| Print file | Envelope | Solid volume |
| --- | --- | ---: |
| [Ports and inserts coupon](print/ports_and_inserts_coupon.stl) | 19 × 62 × 46 mm | 11.61 cm³ |
| [Updated base](print/case_base.stl) | 146 × 76 × 46 mm with mounting ears | 89.18 cm³ |
| [Lid](print/case_lid.stl) | 132 × 76 × 4.2 mm across the locating ribs | 30.27 cm³ |

The 2.6 mm walls and 3 mm floor and lid panels exceed the SLS material's
published 1 mm recommendation. The thin lid and 19 mm-wide coupon fall
outside JLC's published FDM ABS minimum dimensions. JLC's 147 °C figure is
a heat-deflection measurement at 0.45 MPa. Print the coupon and final case
in the same material and finish and check cabin exposure and fastener
retention with the assembled unit. JLC documents combined PCB/print orders.
Check shipping together for the actual basket once the coupon fits.
[JLC size limits](https://jlc3dp.com/help/article/3d-printing-design-guideline) ·
[Combined ordering](https://jlc3dp.com/help/article/how-to-combine-orders-for-jlc3dp-and-jlcpcb-products).

The JLC base uses **4.0 mm nominal pilots, 7.0 mm blind depth** and **8.0 mm
diameter lower bosses**. The earlier 6.2 mm pilots fell below ruthex's
6.7 mm recommendation and the 7.0 mm lower bosses gave only 1.5 mm of wall
before printing tolerances. The updated lower bosses give 2.0 mm nominal
radial wall. Order raw nylon and fit the standard RX-M3x5.7 inserts locally
after checking the coupon. JLC's installation service calls for a 3 mm wall
and a 14 × 14 mm landing. The original PCB mounts, lid screws and both
connector cutouts line up with the same parts.
[ruthex technical drawing](https://www.igo3d.com/mediafiles/Sonstiges/Ruthex/ruthex_Datenblatt_RX-Serie.pdf) ·
[JLC insert service requirements](https://jlc3dp.com/help/article/threaded-insert-service).

Dry-fit both keyed cable plugs. Check latch travel and removal with the
planned cable bend. Heat-set one insert in each sample boss and check
seating, cracking, screw tip clearance and retention. Then dry-fit the full
stack, including the real ESP32 board, fuse puller access and under-console
mounting clearance. Orion verified 38 nominal assembly checks and seven
coupon geometry checks on the corrected print files. Physical fit and
electrical qualification remain pending.
[Case check report](print/mechanical-observation.json) ·
[Coupon check report](print/ports-and-inserts-coupon-checks.json) ·
[Orion receipt](print/verification.json).

Regenerate the quote CSVs and estimate with `python3 -B jlcpcb/prepare_quote.py`
from the Rev B folder. The checked-in catalog records the part-number,
stock, library and price evidence used for this quote. Regenerate the
corrected print parts on Orion with
`python3 -B orion_client.py start UNIQUE-ID --stage jlc-case`, then use
`status`, `fetch` and `stop` with the same identity.
