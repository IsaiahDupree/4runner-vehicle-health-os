# Amazon and AliExpress strip sourcing

Reviewed November 21, 2026. These are practical sample-shopping references for the owner's selected whole-strip analog RGB/RGBW architecture. They are not purchase orders, automotive qualification evidence or an approved production load.

## Shopping links and exact options

| Marketplace | Link | Exact selection / evidence status |
|---|---|---|
| Amazon US | [BTF-LIGHTING RGBW, cool-white channel — B089Y8CNF8](https://www.amazon.com/dp/B089Y8CNF8) | Indexed listing: 12 V, 60 LEDs/m, 5 m reel, black PCB, IP67 sleeve, five pins. |
| Amazon US | [BTF-LIGHTING RGBW, warm-white channel — B089Y4J37L](https://www.amazon.com/dp/B089Y4J37L) | The cool-white page's variant map identifies the same configuration with warm white. Its own page could not be fetched independently. Confirm the displayed options when opening it. |
| AliExpress | [Search BTF-LIGHTING 5050 RGBW 12V IP67 5pin](https://www.aliexpress.com/w/wholesale-btf-lighting-5050-rgbw-12v-ip67-5pin.html) | Search link, not a verified stock offer. Select analog/PWM RGBW, 12 V, five conductors and IP67 silicone sleeve. Direct AliExpress listing/store inspection was blocked during this review; seller identity, selected SKU, availability and delivered price remain unverified. |

Choose **strip only**, with factory-soldered/sealed leads for the finished harness. Our integrated PCB supplies the control function; an included wireless controller or mains adapter is not part of this build. For RGBW, verify five connections labeled common positive and R/G/B/W returns. Six-wire RGB+CCT and pixel strips such as WS2814/SK6812 require a different output interface.

Direct AliExpress item leads `32357409186` and `1005001572816186` were discovered during search, but could not be verified on AliExpress itself. They are deliberately not elevated to confirmed product offers. No marketplace checkout price, delivery date or stock quantity was verified. Manufacturer-site base prices must not be substituted for an Amazon/AliExpress IP67 variant price.

## What the Amazon source establishes

The [cool-white Amazon page](https://www.amazon.com/dp/B089Y8CNF8) was available through an indexed capture marked approximately three weeks old. A direct HTTP fetch returned a generic Amazon page. Current seller, stock and checkout price are not established.

Seller specifications: 12 mm PCB; approximately **14 mm wide, 3.85 mm high sleeved assembly**; **-20 to +40 degrees C** operation; no IP67 adhesive backing. Confirm the delivered revision. Mechanical clips, end sealing and lead strain relief are still required.

The [manufacturer's separate 10 mm RGBW family page](https://www.btf-lighting.com/products/5050-rgbw-5pin-led-strip-12v) also offers analog five-pin 12 V IP67 strips. Its dimensions, power figure, temperature range and base price must not be transferred to the four-in-one Amazon variant without an exact SKU match.

## Fit to Rev H and remaining qualification

Five-wire common-positive analog RGBW matches the **control interface**. The current [Rev H electrical screen](../generated/electrical-screen.json) allows **0.5 A per channel and 1 A combined**, and the LED output is protected **unregulated vehicle voltage**. These consumer nominal-12-V strips have not been established to tolerate that complete voltage envelope, per-channel peak load or installation temperature. No complete reel or cut length is approved by this research. A low PWM duty setting does not establish acceptable instantaneous current.

The listings' IP67 claim addresses ingress; the reviewed evidence does not establish automotive vibration/salt qualification or strip-local reverse polarity, short circuit, brownout ride-through or load-dump protection. A sample needs measured channel current versus voltage, thermal/PWM checks and an approved sealed termination/mounting method. If its supply must be regulated or its load exceeds the existing screen, revise the single-board power/driver path and requalify it using the same Toyota inlet and measured source budget.

See [the engineering report](README.md) for the terminal map and physical acceptance plan. This shopping update changes no PCB, CAD, fuse, firmware or manufacturing file and claims no physical test.
