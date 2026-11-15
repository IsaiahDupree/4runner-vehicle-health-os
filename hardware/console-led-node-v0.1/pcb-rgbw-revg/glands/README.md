# Rev G cable glands and wire-mount connectors

The updated printable base has one removable gland plate. Two separate crimp
disconnects park in the front bay. The electrical board is Rev G. The Toyota
tee still passes cavities 1–6 through one-to-one where a factory mate is fitted.
The module branch carries ACC, ground, TAIL and DIM. The two reserved tails
stay capped and labeled outside the case.

[Open-case preview](generated/RevG-gland-service.png) ·
[FreeCAD assembly](generated/4Runner_RevG_Gland_Assembly.FCStd) ·
[STEP assembly ZIP](generated/4Runner_RevG_Gland_Assembly_STEP.zip)

## Gland hardware

| Lead | Gland and locknut | Round printed bore | Manufacturer's clamping range | Nominal jacket |
| --- | --- | --- | --- | --- |
| Toyota | LAPP 53017210 and 53119110, M16 × 1.5 | 16.6 mm | 3.5–8.0 mm | 7.2 mm |
| RGBW | LAPP 53010000 and 53119100, M12 × 1.5 | 12.5 mm | 3.5–7.0 mm | 5.5 mm |

The axes are 27 mm apart. The plate is 5 mm thick. The M16 gland has 12 mm of
mounting thread and the M12 has 15 mm. Nominal thread beyond the 5 mm locknuts
is 2 and 5 mm respectively before any seal washer. The 3-D envelopes use the
published maximum gland and locknut dimensions.

[LAPP M16 technical drawing](https://imager.lapp.com/e/lapp/5g92zdNtODrg0yJgJypzQA~~/DB53017010EN.pdf) ·
[LAPP M12 product](https://www.lapp.com/en_US/us/skintop-st-m-iso/skintop-str-m-iso/p/53010000) ·
[LAPP locknut drawing](https://imager.lapp.com/e/lapp/IxNMTvvLiYtWEfUsJRUaNg~~/DB53119000EN.pdf)

## Wire-mount disconnects

| Position | Live-source side, recessed crimp sockets | Other side, crimp pins |
| --- | --- | --- |
| Toyota branch, 4 positions | Cable receptacle Molex 43025-0400 | PCB pigtail plug Molex 43020-0401 |
| RGBW lead, 6 positions | PCB pigtail receptacle Molex 43025-0600 | Cable plug Molex 43020-0601 |

Use 43030-0007 sockets and 43031-0007 pins for 20–24 AWG with insulation
outside diameter at or below 1.85 mm. The prior nominal 1.95 mm 20 AWG TXL
exceeds that contact size. Use qualified thin-insulation harness wire or
approved pre-crimped 20 AWG adapters, then join to the existing TXL at the
tee with an appropriately sized insulated splice. Molex 79758-0002 provides
a 150 mm tin-plated 20 AWG female-to-female lead that can be split into two
pigtails. Molex 214763-1112 is a 150 mm tin-plated 20 AWG male pigtail.
For actual RGBW donor conductors in the 26–30 AWG range and at or below
1.27 mm insulation OD, use 43030-0010 sockets and 43031-0010 pins as
appropriate. Confirm the donor extension's actual gauge and insulation OD
before ordering contacts. The positions in the [disconnect schedule](WIRE-DISCONNECTS.csv)
follow the manufacturer's cavity numbering. Verify the external M8 mapping by
continuity through the actual donor. RGBW cavity 6 is empty.

[Molex plug catalog](https://www.molex.com/en-us/products/series-chart/43020) ·
[Molex 4-way socket drawing](https://www.molex.com/en-us/products/part-detail/0430250400) ·
[Molex 6-way socket drawing](https://www.molex.com/en-us/products/part-detail/430250600) ·
[Socket contacts](https://www.molex.com/en-us/products/series-chart/43030) ·
[Pin contacts](https://www.molex.com/en-us/products/series-chart/43031)

## Fabrication and service

1. Print the [base](generated/case_base.stl) floor-down, [lid](generated/case_lid.stl)
   exterior-down and [gland plate](generated/gland_plate.stl) face-down in the
   exported STL orientations. The base measures 194 × 76 × 36 mm including
   mounting ears. The lid adds 3.2 mm to the assembled body height. The front
   bay extends 30 mm and the front mounting location advances by the same
   amount relative to the PCB. Allow about 214.4 mm from the rear ear to the
   longest modeled gland cap, plus the actual cable bend and service access.
2. Install heat-set inserts with the case empty. Fit the enclosure to the actual
   console before routing the loom. Keep both gland tools outside the box while
   tightening their locknuts onto the loose printed plate. Use a continuous
   round jacket through each gland and measure the OD. Feed unterminated cable
   ends through the glands before adding the crimp housings or branch hardware.
3. Supply the assembler with the pin schedule and electrical tests. The assembler
   installs and strain-relieves the short pigtails at J1/J2, crimps the mating
   harness, and flashes the board. Unplugging either harness for service then
   takes no soldering. Fuse, ground, and external wire IDs remain in the original
   [wire register](../WIRE-REGISTER.csv).
4. Drop in the plate. Dress each connector with its latch upward and a relaxed
   service loop. Reserve at least 45 mm of free movement, then secure slack with
   soft harness ties or removable foam. Open the lid and lift one mated pair
   above the rim to unlatch it. Check the actual crimp, lever throw, wire bend
   and service-loop room on the prototype.
5. Record fit, locknut torque and pull test on the real print and jacket. The
   enclosure's assembly and printed seams need their own sealing test. Keep
   the sealed exterior M8 connection at the rock light and the Micro-Fit
   disconnects inside the console enclosure.

Run the source-pinned FreeCAD and Cura checks on Orion from
[the existing engineering runner](../../pcb-rgbw-revb/orion_client.py).

    python3 -B orion_client.py start UNIQUE-ID --stage toyota-rev-g-glands

Use the same identity for status, fetch and stop. The report checks actual
reopened printable solids and the original Rev G PCB. Connector models are
sizing envelopes. Printed fit, retention and actual console clearance are
physical acceptance steps.

The released model passed [60 geometry and clearance checks plus eight
insert tool paths](generated/gland-fit.json). The modeled wrench paths have
3.05 mm between the tool and the adjacent gland hardware. All three
[Orion Cura slices](generated/support-free.json) completed with support disabled.

## Assembly and service views

[Four-view sheet](generated/gallery/RevG-gallery.png) ·
[Closed case](generated/gallery/01-closed-case.png) ·
[Exploded assembly](generated/gallery/02-exploded-assembly.png) ·
[Gland plate dimensions](generated/gallery/03-gland-plate-dimensions.png) ·
[Connector removal](generated/gallery/04-disconnect-service.png)

The service review reopens the released FreeCAD assembly. It checks the
gland plate's full 34 mm lift with both glands installed and each disconnect's
28 mm lift with 0.10 mm lateral allowance per side. The lifted disconnect
has 12 mm of axial motion in either direction for unmating. The lid blocks
upward plate removal when installed. The fuse puller envelopes clear the
parked connectors. The actual harness still needs bend, latch access and
strain relief checks on the printed unit. [Service clearance report](generated/gallery/service-clearance.json)

Regenerate the pictures and clearance report with the same Orion runner.

    python3 -B orion_client.py start UNIQUE-ID --stage toyota-rev-g-gallery
