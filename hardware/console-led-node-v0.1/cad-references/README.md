# Component CAD references for the console LED node

Six STEP models have been downloaded and imported on Orion. The original
downloads and a labeled FreeCAD/PNG reference catalog are retained locally in
`artifacts/4runner-console-cad-2026-11-07/`. This repository records their exact
URLs, hashes, provenance and inspection results. Third-party CAD files are not
republished through this Git repository.

These references support the existing proposed case/PCB work. They do not
resolve the owned board's revision, the Toyota plug identity, the LED load or
the electrical design. No part selection or installation is authorized by a
filename or a successful CAD import.

## Downloaded geometry

| Part / filename | Source quality | Inspection and proper use |
| --- | --- | --- |
| `Molex_43045-0600.step` — right-angle six-way PCB header | Public repository model; OpenCascade export with the exact product name, not a verified copy of Molex's STEP | Valid 7-solid CAD reference, approximately 13.15 × 12.24 × 12.58 mm in source axes. Requires comparison with the manufacturer drawing, retention pegs and actual component before layout release |
| `Molex_43025-0600.stp` — cable receptacle housing | Public mirror of a Pro/ENGINEER file identifying 430250600 | Valid single solid, 9.85 × 14.00 × 10.83 mm in source axes. Latch access, mating travel and real wire exits still need assembly verification |
| `Molex_43030-0007.stp` — female crimp contact | Public mirror; STEP header identifies TraceParts and 0430300007 | Valid 5-solid reference. Native conservative bounds differ from tessellated bounds; not a measured crimped-wire envelope |
| `ESP32-S3-WROOM-1.step` | **Direct Espressif manufacturer download** | Valid module model, **18.00 × 25.50 × 3.10 mm**. This is the radio module, not the complete DIYables UNO-shaped development board |
| `ruthex_RX-M3x5_7.stp` | **Direct ruthex manufacturer download** | Valid single solid. Tessellated extents about **4.60 × 4.60 × 5.70 mm** agree with nominal stock. Use the manufacturer's 4.0 mm pilot recommendation and the process coupon, not a hole inferred from this model |
| `Nexperia_SOT1205.step` | **Community package reference**, despite the filename; internal title says User Library LFPAK56D | Valid 7-solid model, 5.125 × 6.05 × 1.05 mm in source axes. A package reference for the BUK9K12-60E option; it is not an official Nexperia download or a verified orderable-part model |

Exact download URLs, file sizes, SHA-256 values and authority limits are in
[reference-models.json](reference-models.json). The renderer preserves each
source's scale. The catalog arrangement is exploded for viewing and is not an
installed PCB or a mated connector assembly.

The successful STEP imports are geometry-read evidence. Three combined STL
exports (contact, module and package) are not closed single meshes; they contain
multiple source solids and were not healed. Keep the STEP files as the primary
assembly references. The derived STLs are views, distinct from the printable
case files in the parent package.

## Two important source distinctions

The ruthex native CAD bounding box is approximately 4.70 × 4.77 × 5.95 mm;
tessellating the retained solid gives approximately 4.598 × 4.597 × 5.700 mm.
This is a conservative curved-surface bounding-box effect, not evidence of a
5.95 mm stock insert. Both observations are retained in
[the native inspection](evidence/native_inspection.json). The manufacturer
dimension drawing still governs nominal length, OD and recommended pilot.

Molex's direct model-download endpoints timed out from the Mac and from Orion.
The exact manufacturer header STEP ZIP is listed in its catalog, but its
bytes could not be checked against the public model. The header therefore
retains **public reference** status. A separate **Molex 430450600 3D PDF** was
downloaded from Newark/Farnell; it contains a `/3D` annotation and embedded 3D
stream, with no attached STEP file. It is included as a supplier reference,
without treating it as the source of the downloaded STEP geometry.

## Supporting files acquired

- **Official DIYables Fritzing part** (`DIYables-ESP32-S3-Uno.fzpz`), containing
  board breadboard/schematic/PCB artwork. This is useful wiring-library data,
  not a mechanical STEP model or a verified mounting-hole drawing.
- **KiCad 43045-0600 footprint**, downloaded from KiCad's official footprint
  repository. Its six pads, mechanical holes and numbering require the normal
  native EDA/manufacturer review before use. Its referenced 3D model path did
  not yield a downloadable model in the queried official packages library.
- **Supplier 3D PDF** for Molex 430450600 as described above.

[supporting-downloads.json](supporting-downloads.json) records their source
URLs, byte counts and hashes. No third-party model generator, cloud CAD
conversion, hosted build or paid API was run.

## Remaining model coverage

| Needed item | Current result | Next evidence needed |
| --- | --- | --- |
| Exact photographed Toyota plug and mating half | **Unresolved**. No confirmed model found for this physical connector; 90980-10760 and 90980-11148 remain catalog candidates, not identifications | Straight-on mating face, latch orientation, molded numbers, cavity count, exact 2005 V8/build applicability |
| Toyota 82390-35010 console sub-harness | Dealer catalog lead, no verified assembly STEP found | Actual harness variant, both connector ends, populated cavities and available space |
| Complete owned DIYables UNO-format ESP32 | Manufacturer wiring artwork found; **no verified full-board 3D model found** | Owned board identity/revision and a mechanical drawing or measured board/holes/header/USB envelope. A generic Arduino UNO or another ESP32 dev board is not substituted |
| LM5164-Q1 | TI links CAD for **8-pin DDA HSOIC** | Freeze exact orderable part/package, then obtain that CAD through the linked library |
| LM74700-Q1 | TI links CAD for **6-pin DBV** and **8-pin DDF** variants | Resolve the selected package first; these footprints are not interchangeable |
| SN74AHCT125-Q1 | TI lists **D, PW and BQA** package CAD choices | Select the actual package with the LED topology |
| UCC27524A-Q1 | TI lists **D SOIC** and **DGN HVSSOP** package CAD choices | Select the actual package; analog RGB remains an alternative to addressable LEDs |
| Fuse, TVS, external protection FET, inductor, power connectors and LEDs | Exact parts remain unselected | Electrical/current/thermal design and LED model/length |
| M3 pan-head screws and washers | Generic size requirements only; no exact manufacturer model selected | Actual stock/head dimensions, engagement and driver access |

TI's CAD links are catalog availability evidence, not downloaded/inspected models
in this bundle. A SPICE model is also not mechanical CAD.

## Using the references

1. Import the STEP files with their native units. Do not apply a global scale
   factor. The inspected radio-module dimensions are a useful unit sanity check.
2. Treat each model's source axes as its own datum. Establish the PCB plane,
   pin-1/latch orientation and mating travel from drawings and actual parts.
3. Add a mated-pair study and connector release/hand/wire keepouts before cutting
   the case wall. The original prototype's cable slots do not prove connector fit.
4. Replace the estimated controller box only with an identified full-board
   reference or a clearly recorded measurement-based model. Preserve RF, USB,
   shield-stack and screwdriver access.

## Reproduction and checks

The temporary authenticated Orion lane admits only six manifest-pinned STEP
files, bounded source-pinned inspection and a fixed preview. It accepts no
caller-provided code or geometry repairs. `inspect_models_job.py` creates the
reference catalog; `run_isolated_models.py` scopes the existing control-plane
worker to this job and expires the private controller. Source hashes, requests,
job receipts and native observations are retained under `evidence/`.

Run `python3 verify_references.py --asset-root /absolute/path/to/downloads` for
the bounded file/provenance checks. CAD parsing, tessellation and rendering run
on Orion. No case or PCB dimensions were changed by this acquisition task.

Manufacturer and library entry points:

- [Molex header](https://www.molex.com/en-us/products/part-detail/430450600),
  [housing](https://www.molex.com/en-us/products/part-detail/430250600),
  [contact](https://www.molex.com/en-us/products/part-detail/430300007).
- [Newark header CAD/PDF documents](https://www.newark.com/molex/43045-0600/connector-header-6pos-2row-3mm/dp/56H9486).
- [Espressif module CAD](https://www.espressif.com/en/products/modules/esp32-s3-wroom-1-wroom-1u).
- [ruthex STEP downloads](https://www.ruthex.de/pages/cad-daten).
- [DIYables board and Fritzing library](https://diyables.io/products/esp32-s3-development-board-with-esp32-s3-wroom-1-n16r8-wifi-bluetooth-uno-compatible-form-factor-works-with-arduino-ide).
- [Nexperia package CAD entry](https://www.nexperia.com/packages/SOT1205).
- [TI LM5164-Q1](https://www.ti.com/product/LM5164-Q1),
  [LM74700-Q1](https://www.ti.com/product/LM74700-Q1),
  [SN74AHCT125-Q1](https://www.ti.com/product/SN74AHCT125-Q1),
  [UCC27524A-Q1](https://www.ti.com/product/UCC27524A-Q1).
