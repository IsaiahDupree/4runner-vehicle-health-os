# Cost and procurement snapshot

The latest requested load is a whole-strip RGB/RGBW strip, replacing the optional
pod procurement assumption. See [strip-build materials](strips/README.md#strip-build-material-delta).
Removing the DD7440 and its DD4084 donor lead leaves **$33.19** in previously
priced materials. The selected strip, its lead/seals/mounts, unquoted materials
and factory work are additional; no complete strip-build total is established.
The figures below and in the earlier product-BOM scenario remain dated records.

For the enclosure, harness, fuses, mounting hardware and optional lamp as well,
see the [complete-product BOM](PRODUCT-BOM.md) and [itemized CSV](PRODUCT-BOM.csv).
The priced portion is $39.14 without the optional lamp or $119.09 with one
DD7440. These are incomplete material subtotals, not a finished-product price;
the complete BOM explicitly marks the remaining unquoted materials and work.

All 31 JLCPCB SKUs in the 67-position factory BOM were retrieved on November 21, 2026. All matched the BOM manufacturer part numbers and had enough observed stock for one board. See [catalog-live.json](jlcpcb/catalog-live.json) for exact capture times, primary URLs, prices, stock and page hashes. Stock and prices can change.

The nominal component material subtotal at one-board quantities is **$23.58 USD**. It includes the ESP32, all other PCB components, two fuse holders and six terminal blocks. It excludes actual fuse cartridges and every charge below. This is component consumption at captured price tiers, not a checkout or finished-product quote.

| PCB component group | Positions | Nominal material USD |
|---|---:|---:|
| Capacitors | 18 | 1.7007 |
| Diodes and surge clamps | 5 | 0.9646 |
| Inductor | 1 | 0.8623 |
| Enable MOSFET | 1 | 0.0796 |
| Resistors | 26 | 0.4821 |
| ICs and ESP32 module | 8 | 11.8374 |
| Fuse holders | 2 | 6.5018 |
| Screw terminal blocks | 6 | 1.1556 |

Six C474952 blocks contribute $1.1556, using one new Extended SKU and twelve through-hole solder joints. The factory BOM also includes both four-pin fuse holders. The factory must populate all 67 positions; no customer soldering is priced as a saving.

A finished-product quote must additionally include:

- bare four-layer PCB fabrication and finish;
- SMT setup, placement, Extended-part loading, assembly minimums, extra/loss parts, through-hole insertion and soldering, and any inspection fees;
- firmware programming, actual fuse cartridges and their insertion;
- Toyota tee housings/contacts, qualified outer-jacketed cables, LED lead, glands and locknuts;
- three printed enclosure parts, eight inserts, eight screws, four insulating washers, and vehicle mounting hardware;
- harness stripping/crimping, controlled terminal torque, enclosure assembly and functional/acceptance testing;
- packing, freight, tax and duties.

The $100 target remains a quote target. Neither the $23.58 component subtotal nor older Rev G assembly estimates establish a delivered, programmed, wired and tested product price. Use [BOX-BUILD.md](BOX-BUILD.md) as the supplier scope.
