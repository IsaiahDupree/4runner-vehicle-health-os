# ShengYang listing: D1 UNO ESP32-S3 N16R8 board reference

The user's supplied product screenshot identifies the target as the **purple D1 UNO ESP32-S3 N16R8 / CH340 board sold by ShengYang**. This replaces the earlier DIYables brand assumption. It identifies the selected listing and visible layout; the actual board revision, electrical continuity and populated height have not been measured. No purchase is implied.

The listing says 16 MB flash and N16R8. Espressif's corresponding WROOM-1-N16R8 part has 8 MB octal PSRAM, but the listing does not by itself verify an exact genuine WROOM module or its fitted memory. Retain those as part-selection claims until a hardware memory read and marking check.

## What changes for the shield

The visible 10+8 digital and 8+6 power/analog header arrangement agrees with the UNO R3-style reference. Keep **SparkFun PRT-11417** as the stackable-header candidate and **Molex 43045-0600 / 43025-0600** as the PCB/cable interface. Final leg length, header seating and hole coordinates still need the actual board.

The seller-family pinout graphic agrees with the visible GPIO labels. `HEADER-MAP-DRAFT.csv` records 32 header positions, while `SHIELD-GPIO-PROPOSAL.csv` assigns a small subset for this project:

| Draft role | UNO position | This board's label / GPIO |
| --- | --- | --- |
| LED channel 1 / addressable data, or RGB red | D2 | IO18 / GPIO18 |
| LED channel 2, or RGB green | D3 | IO17 / GPIO17 |
| LED channel 3, or RGB blue | D7 | IO14 / GPIO14 |
| Driver enable request | D8 | IO21 / GPIO21 |
| Optional conditioned illumination sense | A0 | IO2 / GPIO2 |
| Optional conditioned supply sense | A1 | IO1 / GPIO1 |

These are **proposed unwired nets**, not firmware or a finished circuit. Added LEDs connect through the selected driver/buffer and separately rated power path. No Toyota pin or LED-load current connects directly to a GPIO. Addressable and analog RGB are alternatives until the LED type is supplied.

Use ESP32 GPIO numbers in firmware: the UNO-position name is only a physical locator. The photo/seller graphic puts **RST at the UNO AREF position**, **5 V at IOREF**, and **IO0 at the UNO NC position**. GPIO remains a **3.3 V domain**. Never infer electrical compatibility from an AVR UNO shield shape.

The draft avoids the GPIO0/3/45/46 strapping pins, UART0 GPIO43/44, native-USB GPIO19/20 and memory-related GPIO35/36/37. Leave extra solder pads unconnected. For the octal-memory variant, ESP-IDF documents restrictions on GPIO33–37. The seller's drawing also labels GPIO48 as connected to the onboard addressable LED; this was not continuity-tested.

## Power and mechanical evidence

Use the existing proposed fused automotive input, reverse/transient protection and regulated **5 V** supply. USB-C provides a documented board-family power entry for bench work; the final shield-to-board power connection needs the exact board's power path/backfeed behavior resolved. Do not infer an automotive transient rating from the barrel jack. The seller-family graphic says “DC 5–18 V”; that is an unverified seller annotation, not load-dump qualification or an instruction to wire the car directly into VIN.

A Makerbazar product-family PDF includes a dimension graphic on **PDF page 7**: main body length **66.00 mm**, additional projection **2.49 mm**, and width **53.34 mm**. That gives an approximate overall **68.49 × 53.34 mm** reference, consistent with the earlier approximately 68 × 53 mm estimate. It provides no trusted populated-height or full shield clearance. The left-hand mounting-hole layout needs particular checking; do not blindly copy the official Arduino hole coordinates.

The original case's **72 × 57 × 25 mm controller reserve remains an estimate**, and its original `design-inputs.json`, CAD and receipts are frozen historical artifacts. This new identity record does not retroactively validate that case. Full exact-board STEP and a manufacturer schematic for this ShengYang revision were not found. Use the seller dimension drawing as a **supplier/specification reference**, retaining the Arduino coordinates as nominal header references and the Espressif STEP as a module-only reference. No new 3D fit or manufacturing release is claimed.

The Toyota mating-face identification is still the outstanding vehicle-side item. The provisional IR1 adapter map remains unchanged.

## Retained sources

`board-reference.json` pins the user's screenshot and downloaded seller PDF by size/SHA-256. Original images/PDF are retained privately in `artifacts/4runner-controller-board-reference-2026-11-07/`; they are not republished in Git.

- [Seller family PDF with pinout and dimension graphics](https://5.imimg.com/data5/SELLER/Doc/2026/4/601423043/LE/RC/AT/123335792/esp32-s3-uno-development-board-wifi-bluetooth.pdf). This is a product-page printout, not a manufacturer schematic.
- [UNIT Electronics matching board's pin table](https://uelectronics.net/producto/esp32-s3-uno-wroom-1-n16r8-board-compatible-con-devkitc-1/). Supplier evidence for RXD/TXD GPIO numbers; exact physical revision unverified.
- [Espressif GPIO and memory-pin restrictions](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/api-reference/peripherals/gpio.html).
- [Espressif module variants and supply requirements](https://www.espressif.com/sites/default/files/documentation/esp32-s3-wroom-1_wroom-1u_datasheet_en.pdf).

The separate ElectroIoT/ESP32-S3-UNO open-hardware project has CP2102N, a different regulator arrangement and two buttons. It is not a replacement schematic/CAD model for the photographed single-button CH340 board.
