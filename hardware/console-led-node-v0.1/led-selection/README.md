# Underbody LED research for the 2005 V8 4Runner

Researched **2026-11-07, America/New_York**. Status: candidates only; no light,
driver, fuse, outdoor connector or mounting position selected or ordered.
The user has now specified under-car mounting with water and basic physical
protection. This supersedes the temporary 5 V addressable bench assumption;
it does not change the earlier source-pinned PCB placement or case artifacts.

For this installation, my first choice is a **sealed, bolt-mounted RGBW rock
light pod**. An aluminum body and hard lens provide a useful starting point
for debris protection. An IP rating describes ingress protection; it is not a
quantified rock-impact rating. No verified impact rating or third-party test
report was obtained for these candidates. All ratings below are supplier claims.

| Candidate | Observed price, USD before shipping/tax | Published protection and electrical facts | Effect on our controller |
| --- | --- | --- | --- |
| [Diode Dynamics Stage Series RGBW, DD7440][dd-one] | $79.95 each; [4-pack family][dd-range] starts at $299.95, depending on harness/controller options | IP68; aluminum body, polycarbonate lens, center bolt; 9–16 V; separate white channel | Leading durable RGBW candidate. A custom four-channel power driver is a reasonable design direction, subject to confirming the M8 pinout and channel loading. |
| [Super Bright LEDs RLK-RGBW-6][sbl-list] | $54.99 for six pods; eight $69.99; twelve $99.99 | Manufacturer [RLK manual][sbl-manual]: IP67, 12–24 V, −45 to 80 °C; screw mounting | Budget candidate. Supplied app/controller are documented; direct ESP32 interface, maximum current and connector pinout are unresolved. |
| [Rhino Diamond RGB][rhino-product] | Four-light kit from $290; [configurator][rhino-range] lists optional controller +$60 | 9–16 V, digital RGB, 24 addressable LEDs; machined aluminum and resin potting; claimed IP69K washdown rating | Strong housed animation candidate. Published compatibility is Rhino RGB. Exact current-production data protocol, logic level and connector pinout need confirmation before an ESP32 interface is promised. |
| [BTF-LIGHTING WS2815 IP68, 5 m / 300 LEDs][btf] | Downloaded live-page metadata: $47.66; web tool listing: $53.99. Quote unresolved; supply/controller excluded | Silicone enclosure; 12 V DC; strip width 12 mm; advertised operating temperature −20 to **40 °C** | Addressable strip alternative, with regulated power and a protected channel/mounting system. The stated temperature ceiling is a material limitation for underbody selection. |

Prices were observed on manufacturer pages/search-indexed manufacturer
listings, not checkout quotes. The Super Bright LEDs listing was searchable,
but repeated direct page fetches timed out; its separate manufacturer PDF was
accessible. Prices, stock, included accessories and variants need rechecking
when a specific sample is chosen. No purchase is authorized by this report.

[Source-download receipts](source-downloads.json) retain exact URLs, observation
times, byte counts and SHA-256 hashes for five downloaded manufacturer pages
or documents. Full source copies are retained in the workspace artifact folder,
outside Git. The TE catalog download returned HTTP 403; its specifications were
available through the web tool and its public manufacturer product page.

The [manufacturer IP explanation][ip] distinguishes immersion ratings from
washdown ratings. **IP69K alone does not establish IP68 immersion performance**.
For occasional submerged use plus pressure washing, seek explicitly documented
ratings for both conditions. Cut ends, added splices and unmatched connectors
do not inherit a light's enclosure rating.

## Recommended first sample and PCB consequences

Use **one DD7440 RGBW pod with its matching M8 extension/pigtail** as the first
electrical and mounting sample. Start the vehicle layout with four pods at
the wheel wells; add side coverage after examining actual mounting positions.
This layout is a proposal, not verified 4Runner fitment. The manufacturer's
[installation guide][dd-install] documents the center-bolt mounting method,
factory-loom routing and avoidance of heat sources and moving parts.

Diode Dynamics' [compatible controller][dd-controller] supports common-positive
12 V RGBW products and all its RGBW products. **Inference:** its RGBW rock
lights are a good candidate for four low-side PWM channels on our shield.
This is not a verified M8 cavity assignment. Confirm the exact five-pin
connection, common-positive behavior, PWM suitability and current of each
color on the physical sample. A five-pin connector by itself proves none of
those things. The product is RGBW; three RGB channels would omit white.

Each independent RGBW zone requires four power channels. Four pods connected
in parallel constitute one color zone; independently coloring four pods
requires sixteen channels or separate compatible drivers. Digital addressable
lights use a different interface. A light's bundled Bluetooth app does not
establish an API our iOS/head-unit app can use; direct ESP32 control remains
our integration path to validate.

The DD7440 page specifies 0.36 A per light at 13.2 V. Eight times that listed
figure is **2.88 A**, a preliminary arithmetic budget only. It is not a measured
worst-case all-channel load and does not select a fuse. Supply, cable gauge,
connector, high-side disconnect and channel limits must follow the actual
chosen count and measured load. The 1 A logic buck candidate cannot supply
that eight-pod example. Keep LED power on a separate fused branch; keep the
console takeoff limited to the protected controller supply.

Basic protection to include in the resulting design:

- A fused power feed sized to the selected wire and measured load, plus
  reviewed reverse-polarity and vehicle-transient protection. A 9–16 V catalog
  range alone does not demonstrate load-dump survival.
- Sealed, correctly mated outdoor connectors and capped unused ports.
  [TE DEUTSCH DT][dt] is a possible custom-harness family; it does **not** mate
  directly to a pod's M8 connector. Select actual seals/contacts for the wire.
- Bolted brackets tucked behind existing structure, with the lens above the
  likely strike surface, plus abrasion sleeve, grommets and strain relief.
  Clear the tires, suspension, exhaust, lifting points and service access.
- Hardware default-off outputs and an explicit off state for lost or stale
  vehicle data. Keep the ESP32 and current unsealed printed enclosure inside
  the cabin. The Micro-Fit input pair is not an outdoor waterproof connector.

## Mechanical references available now

Only published envelopes were obtained; **no verified STEP model, hole-center
drawing or full installation CAD was obtained for these lights**.

| Exact reference | Published size | CAD status |
| --- | --- | --- |
| DD7440 product page | 2.4 × 2.4 × 0.6 in = 60.96 × 60.96 × 15.24 mm | Specification envelope; bolt details and cable exit require a sample/drawing |
| Rhino Diamond configurator drawing | 3 × 1.5 × 0.5 in = 76.2 × 38.1 × 12.7 mm | Published envelope; no STEP or verified mounting-hole coordinates |
| BTF strip, exact IP68 listing | 5000 × 12 × 3.85 mm | Silicone envelope; mount and cable ends not included in this geometry |
| Super Bright LEDs RLK | Not established | Do not invent a bracket footprint |

Route the final output section after choosing the light interface. Current
PCB files remain the earlier placement concept; no routing, ERC/DRC or
physical-fit qualification was completed by this research step.

[dd-one]: https://www.diodedynamics.com/stage-series-rgbw-led-rock-light-one.html
[dd-range]: https://www.diodedynamics.com/products/led-off-road-lights/rock-lights/rgbw.html
[dd-install]: https://www.diodedynamics.com/blog/rock-lights-install-guide
[dd-controller]: https://www.diodedynamics.com/rgbw-bluetooth-controller.html
[sbl-list]: https://www.superbrightleds.com/vehicle-lights/off-road-lights?beam_fil=90430%2C117100&product_applica=124146
[sbl-manual]: https://www.superbrightleds.com/amfile/file/download/file/ye4SRnrTViQceniVjfUJYlvYZ0LF8NIx/product/235007/
[rhino-product]: https://rhinoledlights.com/index.php/products/usa-made-rgb-rock-light
[rhino-range]: https://rhinoledlights.com/index.php/products/rock-lights
[btf]: https://www.btf-lighting.com/en-intl/products/ip68-ws2815-addressable-rgb-led-strip
[ip]: https://www.myhellalights.com/blogs/news/hella-ip69k-vs-ip67-vs-ip68-what-the-ratings-actually-mean-for-off-road-lighting
[dt]: https://www.te.com/en/products/connectors/automotive-connectors/intersection/deutsch-dt-series-connectors.html
