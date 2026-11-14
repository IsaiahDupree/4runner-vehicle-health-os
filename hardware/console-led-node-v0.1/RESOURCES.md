# 4Runner console LED controller resources

The current prototype is the **Toyota-powered Rev C for the 2005 V8 4Runner**.
The photographed white six-contact Toyota plug is the box's only wired
input. The shield uses its switched 12 V and ground to power the ESP32-S3
and drive the RGBW lights through the output cable. Vehicle data comes
wirelessly from the existing classic CAN ESP32 running the MrDIY VHOS target.
[Rev C build guide](pcb-rgbw-revc/README.md) ·
[Shared harness and case definition](pcb-rgbw-revb/toyota-power.json) ·
[Pinned gateway firmware](https://github.com/IsaiahDupree/4runner-vhos-firmware/tree/a523483abc984a406c73659653571198e46b04a0/targets/mrdiy-esp32-v13).

## Build files

| Resource | What to use |
| --- | --- |
| Wiring and shopping | [Rev C shield pad assignments](pcb-rgbw-revc/README.md) · [Shared harness and case parts](pcb-rgbw-revb/TOYOTA-POWER-PARTS.csv) |
| Toyota input wire routing | [Connector-to-pad layout and lengths](pcb-rgbw-revc/README.md#toyota-power-wire-routing) · [CAD cutaway](pcb-rgbw-revc/generated/wiring/Toyota-wire-route.png) |
| PCB model | [KiCad project](pcb-rgbw-revc/generated/vhos_rgbw_revc.kicad_pro) · [Shield STEP](pcb-rgbw-revc/generated/4Runner_RGBW_RevC_Shield.step) · [Board preview](pcb-rgbw-revc/generated/shield.png) |
| PCB fabrication | [Rev C four-layer Gerbers and drills](pcb-rgbw-revc/generated/4Runner_RGBW_RevC_Gerbers.zip) |
| JLCPCB assembly | [LM5169 SMT-only BOM](pcb-rgbw-revb/jlcpcb/truck-lm5169-smt/BOM.csv) · [Matching placement file](pcb-rgbw-revb/jlcpcb/truck-lm5169-smt/CPL.csv) |
| Matched case | [Base STL](pcb-rgbw-revb/toyota-power-cad/case_base.stl) · [Lid STL](pcb-rgbw-revb/toyota-power-cad/case_lid.stl) |
| Fit samples | [Cable-saddle coupon](pcb-rgbw-revb/toyota-power-cad/front_ports_coupon.stl) · [Lid slice](pcb-rgbw-revb/toyota-power-cad/front_lid_coupon.stl) · [M3 insert and screw coupon](pcb-rgbw-revb/toyota-power-cad/m3_tolerance_coupon.stl) |
| Digital checks | [Rev C verification receipt](pcb-rgbw-revc/generated/verification.json) · [Cable clearance and strain-relief geometry](pcb-rgbw-revb/toyota-power-cad/toyota-leads-fit.json) · [Tool access](pcb-rgbw-revb/toyota-power-cad/tool-access.json) · [Supports-off slices](pcb-rgbw-revb/toyota-power-cad/support-free.json) |

The Rev C package is **4Runner-RGBW-RevC-Prototype.zip**. Open its
`START-HERE.md` for the native board, STEP, fabrication and assembly files.
The offline **4Runner-Console-LED-Resources.zip** preserves the owner's
connector photos, datasheets, CAD references and Rev B project history.

## Connector, lighting and CAD references

- The pictured socket resembles **Yazaki 7283-1060**. Its catalog mate is
  **7282-1060**, available in Corsa kit **090IIU-6P-1**. The adjacent-year
  Toyota diagrams are identification references. Confirm latch fit, molded
  cavity numbers, switched power, return and upstream protection on this
  truck. [Yazaki catalog and CAD](https://connector.yazaki-group.com/cgi-bin/english/detail.cgi?part_id=7282-1060) ·
  [Corsa mating kit](https://www.corsa-technic.com/item.php?item_id=1359) ·
  [Connector research](connector-adapter/README.md).
- **Diode Dynamics DD7440** is the RGBW test-pod candidate. The **DD4083** and
  **DD4084** five-pin M8 extensions are donor-lead candidates. Confirm the
  conductor functions and actual pod load on the bench. [Pod](https://www.diodedynamics.com/stage-series-rgbw-led-rock-light-one.html) ·
  [M8 extension](https://www.diodedynamics.com/rgbw-m8-5-pin-extension-wire.html) ·
  [Underbody light research](led-selection/README.md).
- The CAD uses a nominal UNO-format lower board around the Espressif module
  STEP. Check the physical ShengYang board and cable sleeves with the fit
  samples. [Controller reference](controller-board/README.md) ·
  [CAD sources and model coverage](cad-references/README.md) ·
  [JLC3DP 3201 PA-F nylon](https://jlc3dp.com/help/article/3201pa-f-nylon).

## Lessons to reuse

- Compare JLCPCB **batch** cost, including feeder fees, loaded quantities and
  attrition. The November 12, 2026 estimate for two **LM5169 SMT-only**
  shields was **$110.93**. The subtotal covers setup, stencil, parts and
  modeled placement. Quote bare boards, prints, loose hardware, inspection,
  shipping and taxes separately. [Cost model](pcb-rgbw-revb/jlcpcb/assembly-estimate.json) ·
  [Dated catalog snapshot](pcb-rgbw-revb/jlcpcb/catalog-snapshot.csv) ·
  [JLCPCB fee schedule](https://jlcpcb.com/help/article/pcb-assembly-price).
- A footprint-compatible regulator swap still needs the matched circuit
  changes and a bench check. For this build use the LM5169 BOM and CPL as a
  pair, including the four resistor changes. The native schematic records
  the LM5164 baseline. [Regulator comparison](pcb-rgbw-revb/jlcpcb/COST-PASS.md#lm5169-board-build) ·
  [Reusable PCB and JLCPCB guide](../../docs/hardware/PCB-JLCPCB-PROTOTYPE-GUIDE.md).
- Check a cable's load path and the whole insert tool envelope. The captive
  lead sleeves tie to printed saddles and leave slack at the solder joints.
  Use the actual sleeves, inserts and tools on the coupons in the intended
  print material. The exported parts passed 61 CAD checks, all 11 insert
  and screw paths, and five supports-off slices. [Print and assembly guide](pcb-rgbw-revb/TOYOTA-POWER-BUILD.md#prototype-fabrication-and-enclosure) ·
  [Verification receipt](pcb-rgbw-revb/toyota-power-cad/verification.json).

Vehicle power and fit, the LM5169 bench load and the pod pinout still need
physical verification. The proposed relay uses the head unit or iPhone as
the gateway's one BLE client. That device forwards data or lighting commands
to the lighting ESP32-S3.
[Gateway configuration](https://github.com/IsaiahDupree/4runner-vhos-firmware/blob/a523483abc984a406c73659653571198e46b04a0/targets/mrdiy-esp32-v13/sdkconfig.defaults#L22).

The [captive-lead Rev B](pcb-rgbw-revb/TOYOTA-POWER-BUILD.md),
[two-plug Rev B](pcb-rgbw-revb/README.md) and [Rev A](pcb-rgbw-reva/README.md)
remain available for design history.
