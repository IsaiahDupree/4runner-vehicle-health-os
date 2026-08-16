# Exact hardware baseline

Decision date: 2026-08-16. Prices and availability are snapshots; verify them before ordering.

## Required field hardware

| Qty | Exact item | Role | Current source |
| ---: | --- | --- | --- |
| 1 | MeatPi **WiCAN Pro**, part `MP-WICAN-PRO`, hardware family `WiCAN-OBD-PRO` | Primary OBD-II gateway; ESP32-S3 application processor, dedicated all-protocol OBD interpreter, BLE/Wi-Fi/USB, microSD, RTC, IMU | [Crowd Supply](https://www.crowdsupply.com/meatpi-electronics/wican-pro) or [Mouser](https://www.mouser.com/ProductDetail/MeatPi/MP-WICAN-PRO) |
| 1 | OBDLink **MX+** | Independent read-only reference scan tool on iPhone; used to corroborate protocol, standard PIDs, DTC presence, and measurements | [OBDLink](https://www.obdlink.com/products/obdlink-mxp/) |
| 1 | iPhone capable of iOS 17 or newer | Primary Vehicle Health OS client | Existing device |
| 1 | USB-C data cable | Recovery flashing/debug of WiCAN Pro while it is separately powered from OBD | Any known-good USB-C data cable |

WiCAN Pro is the primary choice because the official design covers ISO 15765-4 CAN, ISO 9141-2, ISO 14230-4 slow/fast, SAE J1850 PWM/VPW, additional CAN networks, and raw CAN while retaining an open ESP32 firmware base. The official product documentation states that the USB-C connector does **not** power the unit; it must receive power through its OBD interface.

Use the OBDLink MX+ only as an independent reference. Do not clear codes, invoke bi-directional controls, or change vehicle configuration during discovery.

## Required bench hardware

| Qty | Exact item | Role | Current source |
| ---: | --- | --- | --- |
| 1 | B&K Precision **1550**, 1-36 V / 0-3 A CV/CC bench supply | Current-limited 12-14 V source for WiCAN Pro outside the vehicle | [B&K Precision](https://www.bkprecision.com/products/dc-electronic-loads/1550?region_code=na) |
| 1 | SparkFun **OBD-II to DE9 Cable**, `CAB-10087` | Exposes OBD pin 16 power, grounds, CAN, K/L, and J1850 pins on the bench | [SparkFun](https://www.sparkfun.com/obd-ii-to-de9-cable.html) |
| 1 | Adafruit **DE-9 Female Socket to Terminal Block**, product `3122` | Safe labeled terminal access to the SparkFun cable | [Adafruit](https://www.adafruit.com/product/3122) |
| 1 | CANable **2.0** | Independent USB CAN source/receiver for a two-node bench network and replay validation | [CANable](https://www.canable.io/) |
| 2 | 120-ohm 1% resistors | Termination only for the isolated two-node bench CAN bus | Electronics supplier |
| 1 | Digital multimeter | Verify polarity, OBD pin mapping, supply voltage, and ground before connection | Existing calibrated meter |

Bench power setup: confirm the DE9-to-OBD pin map with a continuity meter, set the supply to 13.6 V with a 1.0 A initial current limit, keep output disabled while wiring, then energize OBD pin 16 relative to signal/chassis ground. Adjust the current limit only from measured startup behavior. Never assume a DE9 pinout from another vendor.

For the isolated two-node bench bus, enable exactly two 120-ohm terminations. On the vehicle, disable CANable termination and never add another 120-ohm terminator to the already terminated vehicle bus.

## Optional OEM ground-truth hardware/software

Toyota Techstream Lite with the Toyota-approved MongoosePRO/MFC2 VIM is the OEM-developed reference path for 1996-and-newer North American Toyota vehicles. It is optional because of cost and Windows/TIS requirements, but it is the strongest source for enhanced Toyota Data List corroboration. Use Data List/read-only operations; ECU reflashing and Active Tests are outside this product scope.

- [Toyota Techstream Lite overview](https://www.toyotapartsandservice.com/collision_pros_pub/the-advantages-of-techstream-lite-over-aftermarket-scan-tools)
- [Toyota TIS library](https://techinfo.toyota.com/techInfoPortal/appmanager/t3/ti?_nfpb=true&_pageLabel=ti_toy_lib_content)

## Vehicle source documents

- [Official 2005 Toyota 4Runner Owner's Manual](https://assets.sia.toyota.com/publications/en/om-s/OM35843U/pdf/OM35843U.pdf)
- Toyota TIS repair manual and wiring diagrams for the VIN-resolved engine/drivetrain/option configuration.

The exact engine, drivetrain, trim, and rear-suspension configuration must be resolved before activating vehicle-specific signal or maintenance packs.

## Added-sensor V0 bench BOM

This is the exact development BOM for the Telemetry Build half of the project. It is a bench/prototype baseline, not approval for unattended engine-bay installation.

| Qty | Exact item | Role | Primary source |
| ---: | --- | --- | --- |
| 1 | Espressif **ESP32-S3-DevKitC-1-N8R8** | V0 sensor-node controller | [Espressif user guide](https://docs.espressif.com/projects/esp-dev-kits/en/latest/esp32s3/esp32-s3-devkitc-1/user_guide.html) |
| 1 | Adafruit **microSD Card Breakout**, product `4682` | SPI/SDIO prototype logging | [Adafruit](https://www.adafruit.com/product/4682) |
| 1 | SanDisk **MAX ENDURANCE 32 GB**, `SDSQQVR-032G-GN6IA` | High-endurance V0 log media | [Western Digital](https://www.westerndigital.com/products/memory-cards/sandisk-max-endurance-uhs-i-microsd) |
| 1 | Honeywell **PX2AF1XX200PSAAX** | Low-side R-134a pressure candidate; 0-200 psi sealed gauge, 5 V ratiometric | [Honeywell PX2 family](https://automation.honeywell.com/us/en/products-backup/sensing-solutions/sensors/pressure-sensors/packaged-pressure/px2-series) |
| 1 | Honeywell **PX2AF1XX600PSAAX** | High-side R-134a pressure candidate; 0-600 psi sealed gauge, 5 V ratiometric | [Honeywell PX2 family](https://automation.honeywell.com/us/en/products-backup/sensing-solutions/sensors/pressure-sensors/packaged-pressure/px2-series) |
| 2 | Honeywell **3685301** shielded Metri-Pack 150 mating cable, 1 m | Manufacturer-defined sensor harness pigtail | [PX2 datasheet](https://prod-edam.honeywell.com/content/dam/honeywell-edam/sps/siot/en-us/products/sensors/pressure-sensors/industrial-pressure-sensors/px2-series/documents/sps-siot-heavy-duty-pressure-px2-series-datasheet-50069942-i-en-ciid-142978.pdf) |
| 1 | YELLOW JACKET **41337** | R-134a high-side premium coupler, 1/4-inch male flare | [YELLOW JACKET](https://yellowjacket.com/product/automotive-r-134a-ac-couplers-premium-with-control-valve/) |
| 1 | YELLOW JACKET **41338** | R-134a low-side premium coupler, 1/4-inch male flare | [YELLOW JACKET](https://yellowjacket.com/product/automotive-r-134a-ac-couplers-premium-with-control-valve/) |
| 1 | Adafruit **ADS1115 16-bit ADC**, product `1085` | V0 pressure acquisition after protected scaling to the 3.3 V ADC domain | [Adafruit](https://www.adafruit.com/product/1085) |
| 6 | 10.0 kΩ / 20.0 kΩ, 0.1%, low-tempco resistors | Two characterized 2:1 pressure-signal dividers; final protection moves onto the V1 PCB | Qualified electronics distributor |
| 3 | Adafruit **PT1000 3-wire RTD**, product `3984` | V0 high line, low line, and ambient temperature probes | [Adafruit](https://www.adafruit.com/product/3984) |
| 3 | Adafruit **PT1000 MAX31865 amplifier**, product `3648` | V0 RTD interface | [Adafruit](https://www.adafruit.com/product/3648) |

The Honeywell PX2 family documentation explicitly lists R-134a media compatibility and offers the selected female-Schrader 1/4-inch flare port. The two pressure ranges preserve useful low-side resolution while retaining high-side headroom. Before purchase and vehicle connection, confirm distributor availability for the full catalog strings, obtain manufacturer/distributor confirmation for the exact variants, verify mating geometry, and have a qualified automotive A/C technician review the assembly. PAG-oil exposure, seals, hose/adapters, clearance, support, and leak-check procedure remain installation approval gates.

The Adafruit RTD assemblies and breakout boards are V0 development parts. They are not the V1 automotive PCB, sealed harness, or final engine-bay qualification. V1 must replace breakout wiring with protected inputs, sealed connectors, controlled sensor attachment, and environmental validation from `TEL-HW-002` through `TEL-HW-006`.
