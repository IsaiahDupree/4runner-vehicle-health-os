# PCB, enclosure and JLCPCB learnings

Accepted Rev I snapshot: 2026-11-21. Native files, BOM and evidence are linked from the [Rev I hardware handoff](../../../hardware/console-led-node-v0.1/pcb-rgbw-revi/README.md). Use actual saved native data when changing components or geometry.

## Connector and wire ownership

The target is a **2005 Toyota 4Runner V8**. There is one six-wire Toyota power inlet, one integrated ESP32-S3/RGBW board and a five-wire LED outlet through glands. There is no additional external 12 V inlet or local CAN adapter. The inline harness preserves all six factory cavities one-to-one, with protected branches for the assigned functions.

The photographed socket was recorded as a candidate Yazaki `7283-1060` / Corsa `090IIU-6S-1`; candidate mating pin housing `7282-1060` / `090IIU-6P-1`. Treat this as the retained connector identification, not physical mating proof or proof of circuit function. Verify latch/keying, terminal series, cavity numbering, male/female terminal form and actual truck circuits before ordering or energizing. These are wire housings, not automatically PCB headers.

| Provisional Toyota cavity | Board termination | Current assignment |
|---|---|---|
| 6 | JT1-2 | ACC / VEH_ACC, sole positive supply |
| 5 | JT1-1 | GND |
| 1 | JT2-1 | TAIL_12V, protected input |
| 2 | JT2-2 | DIM_RETURN, protected input |
| 3 | JT3-1 | Individually isolated reserve |
| 4 | JT3-2 | Individually isolated reserve |

This is the design map, not a verified vehicle pinout. Read [WIRE-REGISTER.csv](../../../hardware/console-led-node-v0.1/pcb-rgbw-revi/WIRE-REGISTER.csv), orientation notes and evidence before using it. Unknown wires have labeled homes; they are not shorted together, connected to GPIO or repurposed by wire color.

LED map: JT4-1 R−, JT4-2 G−, JT5-1 B−, JT5-2 common LED+, JT6-1 W−; JT6-2 stays empty/isolated. PWM GPIO R/G/B/W is 18/17/14/2, driver enable 21, TAIL 5, DIM 4, Rev I supply ADC 1. WLED uses one `TYPE_ANALOG_4CH` bus (44), one logical pixel.

Six factory-fitted `KF128-5.08-2P-AA` / JLCPCB `C474952` two-position through-hole blocks accept the gland/panel leads. Check wire gauge, ferrule/clamp compatibility, current, pitch, footprint and actual assembly acceptance. Glands grip the outer jacket; model separated conductors from the jacket end to each block with stripping/service allowance, bend radius and screwdriver access. Connector mating loads should reach enclosure supports/strain relief rather than unsupported solder joints.

## Cost reduction without owner soldering

Optimize the complete factory process. Reusing manufacturer SKUs can avoid more feeder/extended-part cost than a small unit-price saving. Compare exact identity, package, temperature/electrical rating, stock quantity, assembly mode and quantity tiers before substituting. Do not remove automotive protection or select unrated substitutes simply to reach a price target.

The accepted sensor change reuses spare U5 SN3257-Q1 channel 3 and existing part types: **8 new populated positions, zero new SKUs**. Actual Rev I factory files reconcile to **75 populated positions / 31 manufacturer SKUs**. The retained November 21 catalog gives a **$0.8485 material increment** and **$24.4326 component-material subtotal**. These are dated inputs, not a live quote or a $24 finished unit.

Quote the following separately so the user can assess a plug-and-play target:

- Component materials and fabrication, with quantity/tier assumptions.
- SMT and through-hole assembly, feeder/extended-part charges and procurement restrictions.
- Fuse elements versus holders, terminal blocks, external harness housings/contacts and wire labor.
- Enclosure, glands, inserts/screws, programming, bench QA and final box assembly.
- Freight, tax and nonrecurring cost amortization.

All board components are intended to arrive factory fitted. A BOM/CPL does not confirm JLCPCB through-hole/fuse-holder acceptance, harness/box build, programming or the final delivered cost. Recheck current JLCPCB stock/assembly options against the manufacturer datasheet before a new purchasing recommendation. Keep external procurement/assembly distinct when the PCB supplier cannot supply the whole product.

Source inputs: [Rev I catalog-derived.json](../../../hardware/console-led-node-v0.1/pcb-rgbw-revi/jlcpcb/catalog-derived.json), [BOM](../../../hardware/console-led-node-v0.1/pcb-rgbw-revi/jlcpcb/BOM.csv), [CPL](../../../hardware/console-led-node-v0.1/pcb-rgbw-revi/jlcpcb/CPL.csv), [retained harness/case hardware](../../../hardware/console-led-node-v0.1/pcb-rgbw-revh/HARNESS-AND-CASE.csv).

## Electrical and geometry lessons

Rev I senses ACC_FUSED after F1, before the eFuse, using U5 channel 3 to isolate/clamp the GPIO1 path. The effective nominal gain is **0.06848152130850642**, including the loaded resistor network: 2×49.9k input, 22k shunt, 18k series, 22k ADC pulldown. Omitting that loading gives the wrong conversion. A 14.4 V input is about 0.986 V nominal; resistor-only corners do not include switch/ADC/temperature errors. See [voltage_screen.py](../../../hardware/console-led-node-v0.1/pcb-rgbw-revi/voltage_screen.py). Clamp assumptions and static screens do not prove pulse energy, brownout or reset isolation.

The output is **protected, unregulated vehicle voltage**, not regulated 12 V. Retain the current 0.5 A/channel and 1 A combined electrical screen until a new design is justified. A 25% PWM duty ceiling does not limit instantaneous current. The evaluated consumer nominal-12-V five-wire IP67 RGBW strip is not automotive-qualified; no full-reel/installed length has passed voltage, current, heat or sealing acceptance. IP67 marketing does not establish short, surge, vibration, cut-end or splice protection. See the [strip marketplace record](../../../hardware/console-led-node-v0.1/pcb-rgbw-revh/strips/MARKETPLACE.md).

Use real product CAD or verified manufacturer dimensions, recording downloaded/specification-based/estimated geometry. Design custom printed supports/interfaces around those constraints; a GrabCAD model is not mandatory for every custom mechanism. Keep connector keepouts, gland nut/wrench access, wire fanout, fuse service and straight insert/screw tool axes in the model. Record process-specific tolerances rather than claiming digital fit proves printed fit.

In the accepted revision, the 133×65 mm outline and existing connector/mount poses stayed fixed. New sensor parts occupied existing free area. Fit checks consumed the **actual populated-board STEP**, including all eight new references. Closed meshes and real support-disabled slicer outputs are stronger printability evidence than visual overhang inspection, but still require a physical print.

## Native-tool failures worth preventing

- Export component identity with KiCad 10 `GetLibNickname()` + `GetLibItemName()`; the older `LIB_ID.Format` overload failed in this environment.
- A shared schematic generator omitted integrated H/I sections until explicitly supported. Update the upstream generator and fail closed on unknown layouts/missing components; require schematic/native-board parity as well as ERC/DRC.
- Derive BOM/CPL counts and poses from the actual saved board, not a separate design list. Here the terminal body centroid differs from pad origin by x−0.05 mm / y+2.54 mm before JLC y conversion; audit rotations modulo 360. That offset is footprint-specific, not a universal terminal correction.
- Preserve the native STEP bytes. Text normalization must record separate native/published hashes; firmware/image/binary outputs stay byte identical.
- Fetch Windows job outputs with modern SFTP where needed. Legacy `scp -O` rejected recursive `out/.`; length/hash checks caught incomplete publication.

Use [publish_handoff.py](../../../hardware/console-led-node-v0.1/pcb-rgbw-revi/publish_handoff.py) and retained tests rather than recreating the factory export logic. Native generation/routing/fit/slicing must run on Orion; local publication and artifact inspection remain lightweight.
