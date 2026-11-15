# Rev G finished-unit quote scope

For the gland enclosure option, include the removable plate, both glands and
locknuts, and the two factory-crimped harness disconnects in the finished-unit
quote. Use the [gland and disconnect schedule](glands/README.md) to specify parts
and let the assembler handle pigtail soldering and continuity testing.

Quote **two assembled 2005 Toyota 4Runner V8 RGBW controllers** with
the circuit board installed in the closed case, both fuse elements
installed, a terminated Toyota IR1 tee and a terminated Diode Dynamics
five-pin M8 output lead. Each unit should arrive flashed and tested.
Vehicle installation consists of mounting the box, plugging in the
Toyota tee and the light, and completing wireless setup with the
existing gateway. The integrator performs all soldering, crimps,
insert installation and internal wiring. The controller and LED load
share the switched supply from the six-position Toyota connection.

## Two-unit pricing

| Line | Amount | Basis |
| --- | ---: | --- |
| Rev G SMT assembly | $98.61 | Dated Economic model for two boards using part prices, loaded quantities and published fees |
| Four Keystone fuse holders and factory soldering | $19.92 | Parts, feeder allowance, one hand-soldering setup and 16 joints |
| Fabricate five bare boards, with three bare spares after assembly | $34.30 | Public calculator at 122 × 53.34 mm, four-layer 1.6 mm FR-4, lead-free HASL |
| **PCB order with two populated boards and soldered holders** | **$152.83** | Combined planning figure before delivery and approval of the actual assembly quote |
| Two 3 A and two 1 A fuse elements | $12.70 | Four fuse elements at listed small-quantity prices |
| Two sets of Toyota housings and contacts | $12.34 | Two pairs at $6.17 a pair |
| Two DD4084 3 m M8 donor leads | $11.90 | Two at $5.95 each |
| **Priced items for two controllers** | **$189.77** | PCB order and the listed fuse and cable materials |
| Wire, sleeve, ties, labels, insert and screw hardware | Quote | Use the hardware register and check any upstream branch protection needed |
| Two printed bases and lids | Quote | Price the supplied geometry and the chosen nylon and finish |
| Harness fabrication, wire-to-board soldering, case assembly, firmware flash and final testing | Quote | Request both nonrecurring setup and per-unit labor |
| Freight and any applicable taxes or tariffs | Quote | Include onward shipment to the integrator when using two suppliers |
| Optional DD7440 pod | $79.95 each | Price the pod separately so the controller can ship to an owner who already has it |

The $152.83 board estimate includes $25.00 for bare-board engineering,
$5.20 for lead-free finish and $4.10 for copper board fabrication.
The same settings in OSP gave a $29.10 bare-board figure. A hypothetical
99 × 53.34 mm board at the same specifications and lead-free finish
showed $13.10 for five. Rev G is 122 mm long. Any smaller board needs a
revised layout and case fit check.
[Rev G costing](jlcpcb/assembly-estimate.json) ·
[Factory holder calculation](jlcpcb/factory-holders/assembly-estimate.json) ·
[Bare-board calculator inputs](jlcpcb/factory-holders/bare-board-calculator.json) ·
[JLCPCB bare-board calculator](https://cart.jlcpcb.com/quote) ·
[JLCPCB assembly fees](https://jlcpcb.com/help/article/pcb-assembly-price).

The $189.77 figure is a subtotal assembled from public prices and the
board model. Get one quote that includes the open lines for the delivered
price. The shorter DD4083 1 m donor is $3.95 and saves $4.00 per pair if
vehicle routing permits it.
[3 A MINI fuse](https://www.digikey.com/en/products/detail/littelfuse-inc/0997003-WXN/701055) ·
[1 A MINI fuse](https://www.mouser.com/en/ProductDetail/Bussmann-Eaton/ATM-1?qs=67eC1vNVLiXluUOuCQSxUw%3D%3D) ·
[Toyota pin kit](https://www.corsa-technic.com/item.php?item_id=1359) ·
[Toyota socket kit](https://www.corsa-technic.com/item.php?item_id=1360) ·
[M8 leads](https://www.diodedynamics.com/rgbw-m8-5-pin-extension-wire.html) ·
[DD7440 pod](https://www.diodedynamics.com/stage-series-rgbw-led-rock-light-one.html).

## Production ownership

- A box-build supplier can quote fabrication, PCB assembly, enclosure,
  harness, programming and final delivery in one order. PCBWay publishes
  this option. Request the two-unit minimum and a firm price for the
  actual drawings, part sourcing and test procedure.
  [PCBWay box-build service](https://www.pcbway.com/blog/help_center/How_to_Place_an_OEM_Order_5d91cff0.html).
- To use JLCPCB for the board, quote all 59 SMT placements plus both
  fuse holders using the mixed files. JLCPCB's published scope covers
  PCB assembly. For the enclosure and final integration, a shop
  such as MiniProto can quote receiving the boards, building and
  attaching the harnesses, closing the case and running final tests,
  with no minimum order. Have the integrator confirm sourcing,
  final programming and testing in writing. If the JLCPCB holders
  sell out, have the integrator supply and solder the original black
  Keystone 3568. Confirm the ESP32 antenna overhang and tooling-rail
  position with the board assembler.
  [JLCPCB service scope](https://jlcpcb.com/blog/turnkey-pcb-assembly) ·
  [MiniProto box-build services](https://www.miniproto.com/services/box-build-assembly) ·
  [Keystone holder family](https://www.keyelco.com/category.cfm/Mini-Blade-Fuses/Color-Copded-Fully-Insulated-Mini-Auto-Fuse-Holders/id/599).
- If programming or functional testing is purchased from JLCPCB,
  those services use Standard PCBA. Programming is approximately
  $8 engineering plus $8 per operator hour. Functional testing is
  approximately $16 engineering plus $8 per operator hour. Ask the
  box-build supplier to price these steps together as well. The
  Economic subtotal in this document excludes those services.
  [Programming service](https://jlcpcb.com/help/article/pcba-programming-service) ·
  [Functional test service](https://jlcpcb.com/help/article/functional-test-service).

## Files for engineering review

| Operation | Input |
| --- | --- |
| PCB fabrication | [Rev G Gerbers and drills](generated/4Runner_RGBW_RevG_Gerbers.zip) |
| SMT and factory fuse holders | [Mixed BOM](jlcpcb/factory-holders/BOM.csv) · [Mixed CPL](jlcpcb/factory-holders/CPL.csv) · [Schematic](generated/schematic.pdf) |
| Case and mechanical assembly | [Base STL](generated/case_base.stl) · [Lid STL](generated/case_lid.stl) · [FreeCAD assembly](generated/4Runner_RevG_Assembly.FCStd) · [Installed loom CAD](generated/4Runner_RevG_Toyota_Wires.step) |
| Harness fabrication | [Wire register](WIRE-REGISTER.csv) · [Parts and hardware](HARNESS-AND-CASE.csv) · [Pad and cavity assignments](generated/wiring-interfaces.json) · [Lead routing](generated/ir1-wire-fit.json) |
| Factory software and acceptance | [Bench test procedure](BENCH.md) · [Board service pads](generated/controller-interface.json) |

## Finished-unit acceptance

1. Verify the actual Toyota connector latch, six cavity positions,
   switched ACC and ground. Check the existing feed and upstream
   load with the vehicle. Verify the exact DD7440 and donor lead
   with a current-limited fixture and record all five mating
   contact assignments and measured polarity. Freeze the lead
   lengths, crimp terminals and strain-relief arrangement from
   the first physical build.
2. Confirm all six pass-through paths, the two isolated reserve
   tails and the four wired inputs. Install both fuses, both
   restrained leads and all case hardware before delivery. Check
   that the cables can be handled without loading the PCB solder
   joints and that the lid clears the fuses.
3. Supply the release firmware binary and UART pad fixture or
   programming procedure. The existing CAN ESP32 is the telemetry
   source. A validated Rev G lighting binary and its gateway
   integration are still required before ordering a programmed
   unit. Check power-up, the 3.3 V rail, boot with outputs off,
   Bluetooth or Wi-Fi link, TAIL/DIM and the four RGBW channels
   into the intended load. Record the binary version and a serial
   number with each test result.
4. Record bench and truck validation separately. Current KiCad,
   FreeCAD and slicer checks cover the design files. A supplier
   first article must verify actual assembly and harness fit.
