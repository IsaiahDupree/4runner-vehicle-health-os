# Rev H finished-product supplier scope

The latest requested load is a whole-strip RGB/RGBW strip. Apply the
[strip interface and supplier acceptance requirements](strips/README.md)
before selecting the external load or its harness. The previous pod and M8
donor are an earlier option. No strip is currently qualified, and longer strips
may require a new power/driver revision; retain the sole Toyota power inlet.

Quote one assembled, programmed, wired and tested product. Customer soldering
is excluded. JLCPCB PCBA alone is not a complete wired enclosure product.

1. Fabricate the four-layer Rev H PCB. Populate every BOM line, including the
   six C474952 screw blocks and two C3205378 MINI fuse holders. Resolve wave
   versus manual insertion process, underside solder-tail clearance and
   selective-solder access. Confirm exact terminal variant against the saved
   drawing and sample. Inspect pin 1 and rotations in the assembly viewer.
2. Program the matching ESP32-S3 N16R2 evaluation firmware through its factory
   service pads. Verify firmware hash, boot, supply current and wireless relay.
   No additional CAN transceiver or wired data input is fitted.
3. Print Rev H base, retained lid and gland plate in the selected qualified
   process. Install inserts using the documented vertical tool approaches.
   Verify the strengthened MH1 pillar, rail height, all mounting holes, PCB
   support, connector lead clearance and lid closure on the physical assembly.
4. Install the M16 and M12 glands on the loose plate, then feed measured cables.
   Glands clamp intact jacket; strip the jacket only inside the case. Use the
   wire register and native routing CSV. Routing lengths do not include a
   production cut/strip allowance: develop it from a first article. Wire screen
   is 20 AWG, maximum 1.6 mm insulation OD. Check actual cable OD against gland
   clamping ranges. Do not substitute a bundle of loose wires for a round jacket.
5. Route each conductor to its labeled terminal. Manufacturer strip length is
   6–7 mm. Do not tin stranded ends. Approve ferrule compatibility before use.
   Establish a controlled tightening instruction at or below the manufacturer's
   0.4 N m maximum. Verify seating, no exposed strands and individual pull tests.
   JT3 receives the two labeled isolated reserves. JT6-2 stays empty.
6. Verify all six factory Toyota conductors pass straight through the tee and
   branch to the specified terminal. Continuity-test cavity identity, reserve
   isolation, ACC/GND polarity and the actual lamp common-positive pinout before
   applying power. Coordinate the upstream vehicle fuse with the cable gauge
   and short-circuit protection of the branch before F1; the 20 AWG geometry
   screen does not approve that unfused segment. Use the protected LED output
   and original 1 A combined limit.
7. Insert the specified fuses, attach the board and case fasteners, close the
   enclosure, and perform current-limited bench, radio, control/failsafe, thermal,
   transient, harness strain and sealing tests. Record serial number, firmware
   hash, part lots, torque, measured results and pass/fail disposition.

For service: remove power, open the lid and release the terminal wires before
lifting the gland plate or removing the PCB. The previous Micro-Fit lifting
sequence is superseded. Screws and clamps remain serviceable without soldering.

Still pending: actual terminal entry/screw dimensions and purchased-part fit;
wire/cable bend specification and production lengths; printed coupons and
measured tolerances; vibration and screw retention; current/temperature and
transient qualification; vehicle measurements and installed radio performance.
The enclosure has no verified ingress-protection rating.
