# Automotive RGB/RGBW strip research and Rev H support

Reviewed November 21, 2026. Owner selected **whole-strip RGB/RGBW color control**. The requested load is a flexible, wireable strip with protection in the strip itself. No addressable data output, extra CAN adapter, second power inlet or second controller board is selected.

For practical Amazon and AliExpress shopping links, see [marketplace sourcing](MARKETPLACE.md), including exact 12 V IP67 Amazon variants and clearly labeled AliExpress verification limits.

**Result: no reviewed exact RGB/RGBW strip is yet verified to meet the complete protection requirement and the existing board limits.** There are credible OEM automotive candidates. None is approved for purchase or vehicle installation from a family brochure alone. The static sourcing screen identifies real voltage/current mismatches and preserves unknowns; it is not physical testing.

## Shortlist and evidence

| Candidate | What its manufacturer documents | What prevents approval now |
|---|---|---|
| **Aspoeck FlexLED RGB/W** | Automotive color-strip family, including analog and separate digital options. Family literature describes IP6K9K, shock and vibration resistance. | Best first OEM RFQ lead. Exact 12 V common-positive analog SKU, current, PWM behavior and strip-local electrical protections still needed. Do not apply the monochrome sheet's voltage/protection claims to RGBW. |
| **OFOLux Flex Line RGB** | Vehicle-oriented flexible light line, RGB offered, family lists 12/24 V and IP67, custom lengths. | Exact RGB variant, operating range, current, pinout and integrated fault protection unpublished in the reviewed page. Flex FT's fuse claims do not establish Flex Line protection. |
| **Teknoware Wave YLN1231RGBWMW** | 12 V class, 9–16 V operating range, common-positive solder pads, reverse-input protection, automotive EMC/fire-related claims. | Interior strip; reviewed document does not establish underbody sealing/vibration or the complete fault protections. A 1 m worst-current screen exceeds Rev H. Smaller lengths remain qualification candidates only. |
| **TecNiq E46 analog five-wire RGBW** | Flexible, wire-ended, common-positive RGBW; 9–14 V; described as water resistant. | No IP or full electrical-fault qualification on the reviewed page. 14 V maximum is below Rev H's static OVP upper corner. Published per-section currents also exceed the board envelope; section text needs clarification. |
| **OFOLux Flex GS-RGB** | Reverse-input protection, IP65, divisible reel and soldered lead. | Specific technical text says 18–32 V despite generic voltage icons. Not a confirmed 12 V part and not a qualified underbody immersion product. |

Protection references, **not substitutes for the chosen RGB/RGBW function**:

- **Labcraft Orizon Flex** documents strip-integrated reverse-input and spike/load-dump protection, IP69K and in-house vibration testing. It is white-only. Its shortest listed 12 V bare-end model is 2.5 m / 12.5 W, approximately 1.04 A nominal on one channel: beyond this board's 0.5 A/channel screen.
- **Grote XTL** documents IP67 and IP69K plus named vibration, corrosion and other environmental tests. The reviewed models are single-color and specified for 10–14 V; complete electrical-fault protection is not established by that sheet.

Primary sources: [Aspoeck 2025 vehicle leaflet](https://www.aspoeck.com/aspoeck/products/product-catalogs/image-Product-and-segment-leaflet/ASP_Construction_folder_032025_Einzelseiten.pdf), [Aspoeck family brochure](https://www.aspoeck.com/aspoeck/press/asp_imagefolder_flexled_en_052021.pdf), [OFOLux Flex Line](https://www.ofolux.it/en/2025-catalogue/116-flex-line.html), [Teknoware Wave datasheet](https://www.teknoware.com/app/uploads/Teknoware_Wave_RGB_RGBW_EN.pdf), [TecNiq E46](https://www.tecniqinc.com/product/E46), [OFOLux GS-RGB](https://www.ofolux.it/en/2025-catalogue/114-flex-gs-rgb.html), [Labcraft datasheet](https://www.labcraft.co.uk/media/wysiwyg/pdfs/Labcraft-Orizon-Flex-Strip-Light.pdf), [Grote XTL datasheet](https://www.grote.com/file-attachments/XTL_LED_Strips_Data_Sheet_-_GLB2019-098.pdf).

[sources.json](sources.json) records direct-capture hashes where available; sources observed through web research without a local capture are explicitly marked. External PDFs are linked rather than redistributed. [candidates.json](candidates.json) keeps observations, ambiguity and estimates separate.

## The existing board can drive this interface

Use an **analog common-positive** strip, four conductors for RGB or five for RGBW. WLED controls each whole strip as one color. [WLED's compatibility guide](https://kno.wled.ge/basics/compatible-led-strips/) distinguishes this from individual-pixel data protocols.

| Terminal | Strip conductor |
|---|---|
| JT4-1 | Red channel return, R− |
| JT4-2 | Green channel return, G− |
| JT5-1 | Blue channel return, B− |
| JT5-2 | Common positive, protected vehicle rail |
| JT6-1 | White channel return, W−; leave empty for RGB |
| JT6-2 | Empty isolated spare; never use as a ground return |

The current firmware requires its existing **four-channel analog bus** on GPIO18/17/14/2; retain that configuration for an RGB-only strip and leave the white terminal unused. A three-channel bus is not accepted by the existing arm/relay check. Wire colors are not polarity evidence: some manufacturers use black for positive.

Factory-soldered pigtails or an approved solder/reseal procedure can connect a strip to a jacketed cable. The enclosure gland grips that intact jacket; the individual cores fan out to the existing screw blocks. The factory completes soldering, sealing, strain relief and screw clamping. Do not assume cutting a sealed strip preserves ingress protection or leaves an electronic protection circuit on every remaining section. Mount underbody strips with the manufacturer's mechanical retention and abrasion/stone protection; adhesive alone is not the qualification evidence.

## Current electrical ceiling and what the screen means

Native [electrical-screen.json](../generated/electrical-screen.json) is hash-bound to the accepted PCB evidence. It specifies **0.5 A per channel and 1 A combined** for the LED load. The output is **protected vehicle voltage, not regulated 12 V**. Maximum static OVP rising corner is approximately **15.856 V**. The original loaded-floor estimate is **9.257 V at the load** with the specified low-input/drop assumptions. These are first-order screen bounds, not measurements or bounds on transient overshoot.

A strip rated only to 14 V fails that upper-voltage screen. A 24 V strip fails low-voltage operation. A nominal 12 V rating alone is insufficient. Check worst-case voltage/current at the actual length, hottest installation and all enabled channels. The 25% evaluation PWM duty ceiling does not reduce the instantaneous current while a channel is on.

The Teknoware 1 m upper-current table gives a conservative combined RGBW screen of 1.810 A, with white alone 0.725 A. A 400 mm linear estimate gives 0.724 A combined / 0.290 A white, which illustrates a length that fits the available current numbers; it is not a validated operating length. The datasheet labels a nominal-current column 24 V in the 12 V section, so the supplier must resolve that discrepancy. No brightness setting is used to approve an oversized load.

The [DRV8803](https://www.ti.com/product/DRV8803) has short/overcurrent, undervoltage and thermal shutdown functions; the [TPS2660](https://www.ti.com/product/TPS2660) adds the selected input-protection functions. Their IC ratings do not raise this PCB's screened limits or certify the completed installation. A protected strip does not replace upstream cable protection. Battery cranking can legitimately dim or shut off these lights; keeping constant brightness through a deep brownout would require a separately designed energy/boost solution on the same board and a verified source-current budget. [TI's automotive transient application report](https://www.ti.com/lit/an/snva681a/snva681a.pdf) describes that power-conversion distinction.

For multiple long underbody strips, establish their combined load first. If it exceeds this screen, revise and requalify the PCB driver/power path, copper, fuse, cable and thermal design using the same Toyota inlet. Do not assume the truck connector has an unmeasured spare current capacity.

## Supplier and physical acceptance still required

Request one exact cut length/SKU with:

- 12 V automotive operating range covering the actual protected-rail envelope, a common-positive R/G/B/W pinout and approved low-side PWM frequency/duty/inrush behavior;
- strip-local reverse-input, short/overcurrent, sustained-overvoltage and automotive pulse/load-dump behavior, with thresholds, test levels, recovery and protection location per cut unit;
- undervoltage/cold-crank and restart behavior; safe shutdown is distinct from constant-brightness ride-through;
- documented ingress tests for the completed strip ends and pigtails, vibration/shock, temperature, road chemicals/salt/UV and the specified mounting method;
- approved cutting, soldering, sealing and strain-relief instructions, maximum per-channel/all-channel current versus voltage/temperature, price, MOQ and lead time.

The bench program must then verify the exact delivered strip plus actual Rev H hardware: polarity/continuity, all-channel peak current, driver temperature, PWM/inrush, short response at each lead, startup and brownout/restart, protected-rail transients and the completed harness/seal/mount. No physical or pulse-generator test is claimed by this research.

Run the bounded sourcing check with `python3 hardware/console-led-node-v0.1/pcb-rgbw-revh/strips/screen.py`. [screen-results.json](screen-results.json) records eight real-product profiles, native/source hashes, mismatches and missing evidence. The PCB, Gerbers, CAD and firmware binary have not been silently changed or relabeled as strip-qualified.

## Strip-build material delta

The earlier [product BOM](../PRODUCT-BOM.md) prices an optional pod scenario. For this requested strip build, remove the DD7440 pod and the DD4084 M8 donor lead from the procurement assumption. Add the selected strip, approved jacketed lead, factory-sealed pigtail/end caps and mounting retainers in [STRIP-BOM.csv](STRIP-BOM.csv). Their price and geometry remain open until a part is selected. The remaining previously priced material subtotal is **$33.19**, still excluding unquoted board fabrication, enclosure/hardware, harness and factory work. No finished-product strip price is claimed.
