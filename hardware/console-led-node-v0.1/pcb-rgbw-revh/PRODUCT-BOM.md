# Rev H complete-product BOM and partial material pricing

Quantity basis: **one controller**, with **one optional DD7440 lamp**. Public catalog/retail observations dated November 21, 2026. No order was placed. These are material consumption figures; minimum purchase packs, assembly, factory loss parts, taxes and freight can raise cash cost.

**Priced partial materials: $39.14 without the lamp; $119.09 with one lamp. The full product total is unknown.** Blank prices are unquoted, never zero-cost parts. The PCB component portion is $23.58. See [PRODUCT-BOM.csv](PRODUCT-BOM.csv) for every row and [price/source record](references/product-cost-2026-11-21.json).

The 31-SKU PCB list covers all 67 factory-populated positions, including all six screw blocks and both fuse holders. Customer component soldering is excluded. Programming, harness preparation, terminal torque and enclosure assembly must be factory box-build operations under [BOX-BUILD.md](BOX-BUILD.md). JLC PCBA alone does not supply that complete product.

The six-cavity Toyota tee is the only vehicle power input. The new controller has one integrated PCB and wireless telemetry from the existing CAN ESP32. The existing CAN node, phone/head unit and installation tools are not new BOM purchases.

## Factory PCB components

| Qty | Part / JLCPCB code | References | Line material USD |
|---:|---|---|---:|
| 3 | [CL32B225KCJVPJE / C5596903](https://jlcpcb.com/partdetail/C5596903) | C2,C3,C30 | 0.8769 |
| 1 | [0603B103K500NT / C57112](https://jlcpcb.com/partdetail/C57112) | C4 | 0.0044 |
| 3 | [CL21B104KCFNNNE / C28233](https://jlcpcb.com/partdetail/C28233) | C13,C27,C29 | 0.0480 |
| 1 | [EEEFK1H470P / C278400](https://jlcpcb.com/partdetail/C278400) | C17 | 0.3230 |
| 5 | [CC0603KRX7R9BB104 / C14663](https://jlcpcb.com/partdetail/C14663) | C18,C19,C20,C25,C28 | 0.0280 |
| 4 | [CL31A226KAHNNNE / C12891](https://jlcpcb.com/partdetail/C12891) | C22,C23,C24,C31 | 0.4112 |
| 1 | [CL10A105KB8NNNC / C15849](https://jlcpcb.com/partdetail/C15849) | C26 | 0.0092 |
| 2 | [SMBJ28CAQ-13-F / C1975352](https://jlcpcb.com/partdetail/C1975352) | D1,D2 | 0.8312 |
| 2 | [NSVBAT54HT1G / C179609](https://jlcpcb.com/partdetail/C179609) | D7,D8 | 0.0828 |
| 1 | [SS56 / C65009](https://jlcpcb.com/partdetail/C65009) | D9 | 0.0506 |
| 1 | [SPM6545VT-220M-D / C2047872](https://jlcpcb.com/partdetail/C2047872) | L1 | 0.8623 |
| 1 | [AO3400A / C20917](https://jlcpcb.com/partdetail/C20917) | Q1 | 0.0796 |
| 1 | [0603WAF8201T5E / C25981](https://jlcpcb.com/partdetail/C25981) | R1 | 0.0035 |
| 2 | [0603WAF4702T5E / C25819](https://jlcpcb.com/partdetail/C25819) | R2,R5 | 0.0032 |
| 5 | [0603WAF1002T5E / C25804](https://jlcpcb.com/partdetail/C25804) | R3,R13,R36,R37,R38 | 0.0085 |
| 1 | [0603WAF1503T5E / C22807](https://jlcpcb.com/partdetail/C22807) | R4 | 0.0017 |
| 5 | [0603WAF1003T5E / C25803](https://jlcpcb.com/partdetail/C25803) | R17,R18,R19,R20,R39 | 0.0145 |
| 1 | [RT0603BRD0746K4L / C861420](https://jlcpcb.com/partdetail/C861420) | R21 | 0.0570 |
| 1 | [RT0603BRD073K92L / C728591](https://jlcpcb.com/partdetail/C728591) | R22 | 0.0473 |
| 4 | [RT1206BRD0749K9L / C706414](https://jlcpcb.com/partdetail/C706414) | R24,R25,R26,R27 | 0.3240 |
| 4 | [0603WAF2202T5E / C31850](https://jlcpcb.com/partdetail/C31850) | R28,R29,R32,R33 | 0.0168 |
| 2 | [0603WAF1802T5E / C25810](https://jlcpcb.com/partdetail/C25810) | R30,R31 | 0.0056 |
| 1 | [LMR51610XDBVR / C20539658](https://jlcpcb.com/partdetail/C20539658) | U1 | 0.6250 |
| 1 | [DRV8803PWPR / C114177](https://jlcpcb.com/partdetail/C114177) | U2 | 1.4431 |
| 1 | [TPS26600PWPR / C544399](https://jlcpcb.com/partdetail/C544399) | U4 | 1.5494 |
| 1 | [SN3257QPWRQ1 / C1858301](https://jlcpcb.com/partdetail/C1858301) | U5 | 1.1257 |
| 2 | [LM4040C25QFTA / C531175](https://jlcpcb.com/partdetail/C531175) | U6,U7 | 1.2566 |
| 1 | [TLV803EC30DBZR / C2877924](https://jlcpcb.com/partdetail/C2877924) | U10 | 0.6070 |
| 1 | [ESP32-S3-WROOM-1-N16R2 / C2913205](https://jlcpcb.com/partdetail/C2913205) | U11 | 5.2306 |
| 2 | [3568-10 / C3205378](https://jlcpcb.com/partdetail/C3205378) | F1,F2 | 6.5018 |
| 6 | [KF128-5.08-2P-AA / C474952](https://jlcpcb.com/partdetail/C474952) | JT1,JT2,JT3,JT4,JT5,JT6 | 1.1556 |
| **67** | **PCB component material subtotal** | **31 SKUs** | **23.5841** |

There are 18 Extended and 13 Basic SKUs in the captured catalog. Factory loading, SMT and through-hole assembly charges must be quoted separately. The captured holder stock was only two pieces, enough for one board with no loss allowance; batch supply is not established.

## All remaining product materials

| Item | Qty | Specification / source | Material USD |
|---|---:|---|---:|
| Bare PCB | 1 piece | Rev H four-layer 133 x 65 mm, 1.6 mm FR-4 | Unquoted |
| Toyota pin-side housing and contacts | 1 piece | [Corsa 090IIU-6P-1 / Yazaki 7282-1060](https://www.corsa-technic.com/item.php?item_id=1359) | 3.14 |
| Toyota socket-side housing and contacts | 1 piece | [Corsa 090IIU-6S-1 / Yazaki 7283-1060](https://www.corsa-technic.com/item.php?item_id=1360) | 3.03 |
| Toyota tee wiring and round jacketed branch | 1 assembly | Six paths straight through plus six-core branch; 7.2 mm nominal jacket OD | Unquoted |
| Six branch junctions and insulation | 6 joint | Supplier-approved crimp/splice junction and insulating cover | Unquoted |
| M16 gland | 1 piece | [LAPP 53017210](https://www.tme.com/us/en-us/details/st-iso-m16-r9005/glands/lapp/53017210/) | 0.83 |
| M12 gland | 1 piece | [LAPP 53010000](https://www.tme.com/us/en-us/details/st-iso-m12-r9005/glands/lapp/53010000/) | 1.87 |
| M16 locknut | 1 piece | [LAPP 53119110](https://www.tme.com/us/en-us/details/skintop-n16b/nuts-for-glands/lapp/53119110/) | 0.17 |
| M12 locknut | 1 piece | [LAPP 53119100](https://www.tme.com/us/en-us/details/skintop-n12b/nuts-for-glands/lapp/53119100/) | 0.15 |
| 3 A main fuse cartridge | 1 piece | [Littelfuse 0297003.WXNV candidate](https://www.digikey.com/en/products/detail/littelfuse-inc/0297003-WXNV/146575) | 0.42 |
| 1 A logic fuse cartridge | 1 piece | [Eaton ATM-1 / BK/ATM-1 candidate; supplier confirmation pending](https://www.eaton.com/us/en-us/skuPage.ATM-1.html) | Unquoted |
| case_base | 1 piece | Rev H case_base.stl | Unquoted |
| case_lid | 1 piece | Rev H case_lid.stl | Unquoted |
| gland_plate | 1 piece | Rev H gland_plate.stl | Unquoted |
| Heat-set inserts | 8 piece | [ruthex RX-M3x5.7](https://www.ruthex.de/en/products/ruthex-gewindeeinsatz-m3-100-stuck-rx-m3x5-7-messing-gewindebuchsen) | Unquoted |
| Lid screws | 4 piece | M3 x 8 socket head | Unquoted |
| PCB screws | 4 piece | M3 x 6 socket head | Unquoted |
| PCB insulating washers | 4 piece | 7 mm OD x 3.2 mm ID x 0.5 mm | Unquoted |
| Vehicle mounting screws | 2 piece | M4, length selected after console measurement | Unquoted |
| Vehicle mounting washers | 2 piece | M4 compatible with measured attachment | Unquoted |
| Five-core RGBW lead / M8 donor | 1 piece | [Diode Dynamics DD4084, 3 m candidate](https://www.diodedynamics.com/extension-wire-m8-3m.html) | 5.95 |
| One prototype RGBW rock light | 1 piece | [Diode Dynamics DD7440 candidate](https://www.diodedynamics.com/stage-series-rgbw-led-rock-light-one.html) | 79.95 |

The two Toyota kits include twelve contacts in total; they are not charged again as loose terminals. All six tee branch junctions still require the harness supplier to specify and quote an approved crimp/splice and insulation method. Cable lengths and the exact six-core construction remain open. The DD4084 candidate includes the LED lead material; a different finished five-core cable would replace that line, not automatically add to it.

The two locknuts use five-piece minimum purchase tiers. They consume $0.32 per product, but buying both minimum packs costs $1.60 before delivery. Ruthex lists EUR 8.99 for 100 inserts; eight consume EUR 0.7192, kept outside the USD subtotal. The complete retail pack and its shipping are additional cash outlay.

Fuse procurement remains open for the 1 A MINI cartridge. Eaton lists ATM-1, while the DigiKey BK/ATM-1 page is unavailable. The older Littelfuse 168.6785.4102 is obsolete; its suggested 0287001.PXCN alternative is a different ATO form factor and must not be assumed to fit this board. The nominal 1 A rating remains unchanged. The 3 A Littelfuse candidate is separately priced; both cartridges still need the normal supplier/first-article approval.

The lamp assumption is one external DD7440 at $79.95, not four lights or an approved multi-lamp load. Its manufacturer mounting kit and zip ties are included. A four-light product requires a separate load, wiring and pricing review. The CAD, gland and cable candidates are not yet physically qualified.

## Factory work and delivered price still unquoted

- PCB fabrication/finish and JLC setup, all SMT and through-hole assembly, Extended-part loading, inspection, minimums and spare/loss parts.
- Firmware programming and boot/radio/control checks.
- Toyota tee crimping/splicing, cable cutting, strain relief and controlled terminal torque.
- Printing, insert installation, fastener installation and final enclosure assembly.
- Functional QC and first-article physical/electrical/thermal/transient/vehicle qualification; first-article costs must be separated from repeat unit costs.
- Packing, freight, taxes and duties.

**The $100 goal remains an unverified target for the assembled controller board.** The priced PCB components plus one premium lamp already total $103.53 before all other materials and factory work. No $100 finished controller-and-lights claim is supported.
