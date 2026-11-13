# PCB design and JLCPCB assembly for small prototype runs

Use the 4Runner Rev B files as the worked example. The workflow applies to a
new design when you recheck the electrical requirements, footprints, stock,
and assembly terms for that board.
[Current 4Runner build and resources](../../hardware/console-led-node-v0.1/RESOURCES.md).

## Design the board around the parts and assembly

1. **Start at the mechanical interfaces.** Pin the connector part numbers,
   mates, keys, PCB locator holes, installed heights, and cable pull direction.
   Read the manufacturer drawings and align the KiCad footprints to the
   real board datum. Leave enough space for the mating plugs, fuse removal,
   mounting hardware, and the expected build tolerances. A drawing-based
   model is a fit hypothesis until checked with the physical part.
2. **Lock the critical copper before routing.** Route power and other
   sensitive paths deliberately. Lock their copper and carry the net classes
   into the router. Reconcile placed references and pins against the
   schematic after import. Check the routed widths on the resulting board.
   Rev B kept 44 locked copper segments, used four copper layers, and
   reconciled 185 connected pins across 73 placed references.
3. **Run the native checks before generating the manufacturing set.** Check
   ERC, DRC, open connections, and schematic parity. Inspect both plated
   and non-plated drill exports alongside copper, mask, paste and board
   outline. Export the Gerbers, BOM, placement CSV and 3D model from the
   same version of the native board. Rev B's published digital checks
   returned zero findings in all four categories.
4. **Give the assembler one matching BOM and CPL per build.** Confirm
   reference designators, JLC part numbers, top/bottom side, coordinates,
   rotations, and quantities. Use the manufacturer's body center for
   manual through-hole placement when the footprint origin is at pin 1.
   Count actual plated joints. One Rev B fuse holder has two electrical
   terminals and four solder joints. Inspect the placement preview for
   polarized parts, exposed pads, both keyed connectors, and overhang.
5. **Quote fabrication and assembly with the actual outline.** Check finish,
   copper, stackup, finished drills, rail and tooling-hole proposals, and
   any required inspection. The 121.58 × 53.34 mm Rev B outline exceeds the
   100 × 100 mm bounds of the advertised entry offer. A small quote should
   include bare PCB fabrication, components, feeder/setup charges, minimum
   part quantities, attrition, soldering, inspection, loose parts, shipping
   and taxes.

[Rev B design and bench procedure](../../hardware/console-led-node-v0.1/pcb-rgbw-revb/README.md) ·
[Native PCB verification](../../hardware/console-led-node-v0.1/pcb-rgbw-revb/generated/verification.json) ·
[JLC placement file format](https://jlcpcb.com/help/article/pick-place-file-for-pcb-assembly) ·
[JLC fabrication capabilities](https://jlcpcb.com/capabilities/pcb-capabilities).

## Optimize the bill of materials

- **Sort by total batch cost.** The price of a line is the loaded part
  quantity at its tier, plus its applicable feeder charge. Use the greater
  of the assembly minimum and required units plus attrition. Include separate
  procurement minimums when the order needs them. Compare Basic, fee-exempt
  Preferred Extended where applicable, and paid Extended parts using the
  selected assembly service. The dated Rev B model uses **$3.07 per loaded
  Extended part number** for Economic assembly. Nine stocking-compatible
  passive substitutions saved **$27.63 per order** in modeled feeder fees.
- **Share a value only where the circuit allows it.** Consolidate identical
  resistor and capacitor lines using an existing stocked part number if the
  tolerance, temperature rating, power rating, dielectric, and voltage
  rating still work. Check effective MLCC capacitance at voltage bias. In
  Rev B the LM5169 build reuses the 49.9 kΩ Basic part at R1 and R5.
- **Look for a high-cost, pin-compatible device before committing to new
  copper.** Rev B's automotive LM5169PQDDARQ1 was **$6.9318** versus
  **$14.2136** for LM5164QDDARQ1 at the single-unit tier. The cheaper device
  uses the same pads with four resistor changes. Its 650 mA rating, changed
  startup threshold, feedback ripple, thermal behavior, and real ESP32 RF
  load all matter. Document the exact group of changes in the alternate
  BOM. Recalculate and bench-test the assembly as built.
- **Keep a buildable path when stock changes.** Check JLC assembly stock
  and placement process against the quantity to be assembled. A retail
  listing elsewhere does not establish JLC assembly stock. Keep approved
  alternates and a dated snapshot. Quote outsourced through-hole placement
  as a separate line item and compare it to a single local parts order and
  the labor to finish it. Keep critical parts with unique footprints pinned
  until an alternate's recommended pads are checked.
- **Price the work you actually want the factory to do.** Use single-sided
  Economic assembly where the layout and components allow it. For Rev B,
  both factory-installed Molex ports added **$13.55** per two-shield batch.
  Factory fuse holders added another **$16.34** and moved eight plated
  joints per shield out of local assembly. The fuse elements still fit by
  hand. Confirm any wave/hand-solder eligibility and inspection in the cart.

[JLC assembly fees](https://jlcpcb.com/help/article/pcb-assembly-price) ·
[JLC Basic and Extended rules](https://jlcpcb.com/help/article/pcb-assembly-faqs) ·
[JLC global sourcing](https://jlcpcb.com/help/article/how-to-use-jlcpcb-global-sourcing-parts-service) ·
[TI LM5169-Q1](https://www.ti.com/lit/ds/symlink/lm5169-q1.pdf).

## Worked cost example

| Two Rev B shields | Modeled assembly subtotal |
| --- | ---: |
| Original LM5164 with both Molex ports fitted | $142.15 |
| LM5169 with both Molex ports fitted | **$124.48** |
| LM5169 with surface-mount assembly only | $110.93 |
| LM5169 with both Molex ports and both fuse holders fitted | $140.82 |

The matched LM5169 build reduced the two-shield subtotal by **$17.67**.
The prices and availability are a Nov. 12, 2026 catalog snapshot in US
Eastern time. Subtotals cover parts, setup, stencil and modeled placement.
Quote PCB fabrication, any inspection, printed parts, loose parts, taxes and
shipping separately. Keep the earlier $27.63 passive savings separate from
the LM5169 comparison because they use different cost baselines.
[Rev B cost workbook and exact variants](../../hardware/console-led-node-v0.1/pcb-rgbw-revb/jlcpcb/COST-PASS.md) ·
[Dated catalog snapshot](../../hardware/console-led-node-v0.1/pcb-rgbw-revb/jlcpcb/catalog-snapshot.csv) ·
[Batch cost calculation](../../hardware/console-led-node-v0.1/pcb-rgbw-revb/jlcpcb/assembly-estimate.json).

For Rev B, the next electrical evidence comes from a current-limited bench
build with the regulator output checked independently, followed by the real
ESP32 startup, RF load steps, and power-cycle tests. Record the tested BOM,
measured results and any changes before relying on the installed board.
