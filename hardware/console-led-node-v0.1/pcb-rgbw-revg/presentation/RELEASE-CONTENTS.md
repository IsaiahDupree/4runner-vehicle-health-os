# Rev G prototype handoff

The source repository is [4runner-vehicle-health-os](https://github.com/IsaiahDupree/4runner-vehicle-health-os).
Use the source attached to the media release to preserve its exact revision.

The design kit contains the editable KiCad PCB and schematic, PCB STEP,
Gerbers, factory BOM/CPL, gland enclosure, wiring documents, WLED integration
source, and the matching evaluation firmware images. The component CAD kit
adds the downloaded reference models, source URLs and inspection results.
The 3D source kit contains the Blender scenes, render scripts, pinned inputs,
accepted generated narration and captions. The picture kit contains the six
full-resolution PNGs and the contact sheet.

## Choose the current manufacturing files

The active enclosure is in
`hardware/console-led-node-v0.1/pcb-rgbw-revg/glands/generated/`:

- `4Runner_RevG_Gland_Assembly.FCStd` and its STEP archive;
- `case_base.stl`, `case_lid.stl` and `gland_plate.stl`.

The active PCB is in `pcb-rgbw-revg/generated/`. The finished-board quote
uses `pcb-rgbw-revg/jlcpcb/factory-holders/BOM.csv` and its matching `CPL.csv`.
Use `BOX-BUILD.md` to include programming, fuse insertion, crimps, harness
termination, enclosure assembly and functional testing in the supplier scope.
The historical price snapshots do not constitute a new factory quote.

The factory firmware image targets **ESP32-S3-WROOM-1-N16R2**, with 16 MB
flash and 2 MB PSRAM. Its documented serial offset is 0x0. Follow the board's
`BENCH.md` and the firmware README before first power or flashing. The release
includes the original build receipt, a fresh source/hash comparison, and
WLED's EUPL-1.2 license.

## Acceptance status

These assets document an evaluation prototype. The new studio images and
movie do not add physical acceptance evidence. Current/thermal behavior,
transients, first boot, sealing, actual connector mating, strain relief,
radio operation, vehicle fit and the live gateway-to-light path still need
bench and vehicle measurements. The rendered service loops and installed
connector poses are illustrative.

Digital design evidence is retained in the PCB and enclosure directories.
The presentation's `validation/` directory records the software checks,
voice/script bindings, source hashes and measured media checks. Keep the
release's `SHA256SUMS.txt` and each ZIP's `CONTENTS-SHA256.json` with the files.
