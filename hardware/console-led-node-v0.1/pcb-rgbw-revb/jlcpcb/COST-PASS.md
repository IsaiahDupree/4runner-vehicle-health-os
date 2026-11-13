# Lower-cost JLCPCB prototype for the 2005 4Runner V8

Quote **truck-lm5169-mixed** for two shields if you want JLC to fit both Molex
ports. The assembled unit stacks the shield on the owned UNO-format ESP32-S3
and plugs into the Toyota inline harness at **J1** and the RGBW light harness
at **J2**. The enclosure carries both replaceable MINI fuses under the screw
lid. Use the [Rev B wiring and bench sequence](../README.md) and the
[shopping and hand-assembly list](HAND-ASSEMBLY.csv).

## Assembly options

| Order option | Factory work per shield | 2 shields | 5 shields | 10 shields |
| --- | --- | ---: | ---: | ---: |
| Original LM5164 SMT | 55 SMT placements | $128.60 | $200.00 | $312.43 |
| [LM5169 SMT](truck-lm5169-smt/BOM.csv) | 55 SMT placements | $110.93 | $160.49 | $240.42 |
| Original LM5164 mixed | 55 SMT placements and both Molex ports | $142.15 | $219.29 | $338.24 |
| [LM5169 mixed](truck-lm5169-mixed/BOM.csv) | 55 SMT placements and both Molex ports | $124.48 | $179.78 | $266.22 |
| [LM5169 with factory fuse holders](truck-lm5169-fuses/BOM.csv) | Mixed assembly plus both fuse holders | $140.82 | — | — |

USD batch subtotals use JLC's Economic fee schedule and the November 12,
2026 US Eastern catalog observations. They include components, setup,
stencil and modeled placement charges. Add PCB fabrication, any required
X-ray, printed parts, loose parts, shipping and tax. For example, the model
adds $3.28 for two shields if JLC requires X-ray on U4. Request four-layer
FR-4, 1.6 mm and top-side Economic assembly. Quote five bare PCBs with two
assembled if checkout supports that split. At the preview, inspect pin 1
and mating direction on both Molex ports and check the four plated joints
on each fuse holder if selected.
[Cost calculation](assembly-estimate.json) ·
[Catalog observations](catalog-snapshot.csv) ·
[JLC fee schedule](https://jlcpcb.com/help/article/pcb-assembly-price) ·
[Rev B Gerbers and drills](../generated/Prototype_PCB_Gerbers.zip).

JLC listed **55 LM5169PQDDARQ1** at **$6.9318** each versus **$14.2136**
for LM5164QDDARQ1 at the single-unit tier. DigiKey also lists the exact
LM5169PQDDARQ1. The LM5169 assembly saves **$17.67 for two shields**
with either placement choice. Both Molex ports add $13.55 to the two-board
SMT estimate, including the ports.
[JLC LM5169](https://jlcpcb.com/partdetail/TexasInstruments-LM5169PQDDARQ1/C5665169) ·
[JLC LM5164](https://jlcpcb.com/partdetail/TexasInstruments-LM5164QDDARQ1/C2072225) ·
[DigiKey LM5169](https://www.digikey.com/en/products/detail/texas-instruments/LM5169PQDDARQ1/17884965) ·
[JLC Molex J1](https://jlcpcb.com/partdetail/MOLEX-768250002/C586017) ·
[JLC Molex J2](https://jlcpcb.com/partdetail/MOLEX-430450800/C122422).

### Parts to finish locally

- All versions use one **Coilcraft MSS1246T-683MLC** per shield, one SparkFun
  **PRT-11417** UNO header kit and one **JP1** RUN header with shunt. Mouser
  lists the Coilcraft part and the header kit. JLC's global sourcing can be
  quoted separately if factory placement of L1 is worth its lead time and
  minimums. The public stock BOM leaves L1 open. Fit L1 before power-up.
  [Coilcraft at Mouser](https://www.mouser.com/en/ProductDetail/Coilcraft/MSS1246T-683MLC?qs=zCSbvcPd3paxUT6FfGLWRw%3D%3D) ·
  [Header kit at Mouser](https://www.mouser.com/en/ProductDetail/SparkFun/PRT-11417?qs=WyAARYrbSnb%252BtXjDIp5vcQ%3D%3D) ·
  [JLC sourcing](https://jlcpcb.com/help/article/how-to-use-jlcpcb-global-sourcing-parts-service).
- Fit two black Keystone **3568** holders locally for the lower-cost mixed
  option. Mouser listed them at **$1.15 each** and also lists both fuse
  elements. The factory option uses two red Keystone **3568-10** holders per
  shield with the same 9.91 × 3.40 mm pin matrix. JLC listed nine. The
  two-board estimate adds $16.34 and moves eight plated joints per board to
  the factory. The red body is a color code. The installed elements remain
  **F1 3 A / 58 V** and **F2 1 A / 32 V**, both inserted locally. Mark their
  values inside the lid. Verify the 1.60 mm minimum finished holes at DFM.
  [Black Keystone holder at Mouser](https://www.mouser.com/c/?q=534-3568) ·
  [Red Keystone drawing](https://www.keyelco.com/product-pdf.cfm?p=14233) ·
  [JLC red holder](https://jlcpcb.com/partdetail/Keystone-356810/C3205378) ·
  [F1 element at Mouser](https://www.mouser.com/en/ProductDetail/Littelfuse/0997003.WXN?qs=bpnLQM2ZShxe%2FpZJCwjNUA%3D%3D) ·
  [F2 element at Mouser](https://www.mouser.com/en/ProductDetail/Bussmann-Eaton/ATM-1?qs=67eC1vNVLiXluUOuCQSxUw%3D%3D).
- For a future PCB layout, JLC listed **34 Bourns SRR1260A-680M** at about
  $1.01 each. It is an AEC-Q200 68 µH inductor. Its recommended 6.8 mm pad
  gap differs from the Rev B Coilcraft footprint's 4.5 mm gap. Quote it
  after a new land pattern and clearance check. For this order use the
  exact Coilcraft.
  [Bourns land pattern](https://bourns.com/docs/product-datasheets/srr1260a.pdf) ·
  [JLC Bourns stock](https://jlcpcb.com/partdetail/BOURNS-SRR1260A680M/C3224096).
- The Toyota mating kits, cable crimp contacts, M8 LED pigtail, screw and
  insert hardware are on the shopping list. The plug-in installation
  assumes the inline harness has been assembled, its six original circuits
  pass through cavity-for-cavity, its ACC branch has a verified switched
  source and source-end protection, and the pod's five conductors have been
  mapped on the real hardware.
  [Harness and hardware shopping list](HAND-ASSEMBLY.csv) ·
  [Corsa pin kit](https://www.corsa-technic.com/item.php?item_id=1359) ·
  [Corsa socket kit](https://www.corsa-technic.com/item.php?item_id=1360).

## LM5169 board build

Use a matching LM5169 BOM and CPL with the Rev B Gerbers. The five
assembly changes below apply as a set. The native schematic records the
original LM5164 build. The rest of the protection, LED drive, fuse and
connector circuit carries over to the LM5169 assembly. Keep the original
LM5164 BOM available when a higher-current buck or an earlier turn-on
threshold is needed.

| Ref | LM5164 build | LM5169 build | JLC |
| --- | --- | --- | --- |
| U1 | LM5164QDDARQ1 | LM5169PQDDARQ1 | C5665169 |
| R1 | 41.2 kΩ | 49.9 kΩ, 1% | C23184 |
| R3 | 221 kΩ | 180 kΩ, 1% | C22827 |
| R4 | 158 kΩ | 154 kΩ, 1% | C22881 |
| R6 | 150 kΩ | 68 kΩ, 1% | C23231 |

The lower-current buck is rated 650 mA and is evaluated at 5 V and 500 mA.
R1 sets about 250 kHz and shares the same Basic part as R5. R3 sets about
9.83 V turn-on and 9.18 V turn-off at the buck input. Expect a reset if
cranking takes the feed below the turn-off point. R4 brings the nominal DC
divider setpoint to 4.90 V before the Type 3 ripple offset. R6 provides
approximately 57 mV peak-to-peak of injected feedback ripple at 13.8 V.
The feedback ripple is internal to the control loop. The 5 V output rail
must be measured separately.

The first-order screen uses an 8.7–17.0 V buck-input sweep, ±20% switching
frequency sensitivity, 48.96–81.6 µH effective inductance and ±20% effective
C5 sensitivity. It estimates a 685 mA maximum ideal peak at the 500 mA test
load and a 26 mV minimum injected feedback ripple. The TI limits used for
comparison are 710 mA minimum peak current limit and 12 mV minimum injected
feedback ripple. These are static design estimates. Measure the switching
waveform and thermal rise on the actual four-layer board. The regulator's
peak-current headroom is small under the screened conditions. Check load
steps with the exact ESP32 transmitting over Wi-Fi and BLE, and compare
the two regulator builds if the ESP32 load or inrush exceeds the target.
[TI LM5169-Q1 datasheet](https://www.ti.com/lit/ds/symlink/lm5169-q1.pdf) ·
[TI Type 3 ripple analysis](https://www.ti.com/lit/an/snva874/snva874.pdf) ·
[Calculation script](screen_lm5169.py).

Leave JP1 open during the current-limited bench check. With L1 installed,
verify stable 5 V regulation at light load and at 500 mA, a 4.75–5.25 V
rail during representative load steps, startup and recovery through the
expected ACC and cranking transitions, and stable switching from the
lowest operating input to the input protection cutoff. Check hot operation
and transient protection on the built shield. Confirm the installed C2/C3
provide at least 2.2 µF combined effective ceramic input capacitance at
operating bias and temperature. Verify USB isolation before
installing JP1 and powering the lower board from the shield. Road-vehicle
fit, electrical qualification and gateway/client firmware integration
are pending.

## Print the lower-volume enclosure

Use **JLC3DP SLS 3201 PA-F nylon, standard finish**, with the base, lid
and combined coupon as individual parts in millimeters. The lightweight
case removes material in the broad panels, leaving 2 mm at their thinnest
and full-thickness screw seats, connector wall, mounting ears and supports.
The port and mounting locations match the original JLC case. Orion verified
44 assembly and geometry checks and seven coupon checks on the exported
solids. The lower ESP32 outline and connector extraction reserves remain
nominal models. Print the coupon in the final material and test the actual
cable latches and heat-set inserts before printing the full case.

| Part | Previous volume | Lower-volume STL |
| --- | ---: | ---: |
| [Base](print-lite/case_base.stl) | 89.18 cm³ | 78.24 cm³ |
| [Lid](print-lite/case_lid.stl) | 30.27 cm³ | 24.25 cm³ |
| Base and lid together | 119.44 cm³ | **102.49 cm³** |
| [Port and insert coupon](print-lite/ports_and_inserts_coupon.stl) | 11.61 cm³ | 11.61 cm³ |

The 14.19% reduction is solid material volume. JLC3DP calculates the print
price from the uploaded geometry, material and process. The 2 mm panels
exceed the vendor's 1 mm recommendation for this nylon. Test fit and
retention at the actual console mounting points and under cabin temperature
and vibration before installing the lightened version in the truck.
[JLC3DP 3201 PA-F](https://jlc3dp.com/help/article/3201pa-f-nylon) ·
[JLC3DP pricing](https://jlc3dp.com/help/article/what%27s-the-price-of-your-3d-printing-parts) ·
[Fit checks](print-lite/mechanical-observation.json) ·
[Coupon checks](print-lite/ports-and-inserts-coupon-checks.json) ·
[Orion receipt](print-lite/verification.json).

Regenerate the print solids on Orion with
`python3 -B orion_client.py start UNIQUE-ID --stage jlc-lite-case` from
the Rev B folder. Use `status`, `fetch` and `stop` with the same identity.
