# 2005 4Runner V8 console connector pinout and harness plan

IR1 joins the instrument-panel loom to the cigarette-lighter and ashtray
sub-loom at the center console. The 2005 4.7 L 2UZ-FE service diagrams assign
all six positions. The 2WD and 4WD V8 service indexes link to the same
circuit sheets. The connector location, six cavities and visible loom
colors support identifying the photographed white plug as IR1. Verify the
individual cavity markings, latch fit and voltages on the truck.
[2005 V8 connector location][location] · [2005 V8 lighter diagram][lighter] ·
[2005 V8 illumination diagram][illum].

## All six wires

Colors refer to the truck-side instrument-panel loom.

| IR1 cavity | Truck-side color | Factory function | Use in our harness |
| --- | --- | --- | --- |
| 1 | Green (G) | Ashtray lamp positive, on the TAIL relay feed | Branch to a future high-impedance lights-on sense input. This switches the display or accent lighting to night mode. |
| 2 | White/green (W–G) | Ashtray lamp dimmer return, white/black on the lamp side | Keep with pin 1 for an optional differential dimmer measurement. This can make controller brightness follow the dash dial. |
| 3 | Green (G) | Cigarette-lighter ring lamp positive, on the same TAIL relay feed | Carry through to the factory ring. If the ring is absent, reserve 3 and 4 for an equivalent low-current console locator light after checking the original lamp rating and dimmer compatibility. |
| 4 | White/green (W–G) | Lighter ring lamp dimmer return, white/black on the lamp side | Carry the lamp return with pin 3. This lets the ring or equivalent console light follow the dash dimmer. |
| 5 | White/black (W–B) | Lighter socket chassis ground, ground point II | Branch to the square **Rev C J1-1 GND** pad after verification. |
| 6 | Pink/blue (P–L) | Lighter socket ACC +12 V, through the 10 A CIG fuse in the service diagram | Branch to the round **Rev C J1-2 VEH_ACC** pad after verification. This is the sole supply for the controller and its RGBW drivers. |

The two green wires meet upstream at the same TAIL feed. The two white/green
returns meet upstream at the same dimmer circuit and run to the R13 rheostat.
The lamp pairs are duplicate access to those two electrical nodes. The TAIL
feed indicates parking lamps or headlights on. It gives the same night-mode
signal in either switch position. A voltage measurement across 1 and 2
captures what the ashtray lamp sees. Verify whether that voltage changes as
a steady level or as PWM before designing a brightness input.
[TAIL feed][tail] · [IR1 lamp pairs][illum] · [Rheostat and ground][dimmer] ·
[IR1 power and ground][lighter] · [ACC/ON service hints][lighter-hints].

## Mating-face reference

Toyota's 2003 routing drawing shows this cavity order. Look into the
contacts with the latch at the top. Match the molded marks and verify the
pink/blue lead at 6 and white/black lead at 5 on the 2005 plug before
terminating either half. [Toyota connector views, printed p. 53][faces].

```text
Truck socket           Mating pin housing
[1]         [2]        [2]         [1]
[3] [4] [5] [6]        [6] [5] [4] [3]
```

## Route the tee and the controller branch

1. If IR1 has a factory mate in use, run all six positions straight through
   between the two Toyota housings. Label both ends, use the molded IDs and
   match the factory wire size. The female and male mating-face views are
   mirrored. Identify each cavity by the molded mark or continuity to its
   factory endpoint. Color alone cannot distinguish the two green wires or
   the two white/green wires. If IR1 is an unused prewire, a removable mating
   plug can expose all six leads for measurement. Insulate any parked lead
   individually and keep the factory loom intact.
2. Route verified 5 and 6 down the existing two-wire sleeve to J1. Retain
   the shield's 3 A main and 1 A logic prototype fuses and confirm the
   takeoff and any branch protection against the wire and terminal ratings.
   Keep the lamps on their original circuits. Use the shield's protected
   RGBW output for the added pods and budget the total load against the
   actual upstream circuit and any shared factory load.
3. For a later shield revision, use a protected, high-impedance 12 V
   sense input from cavity 1 referenced to cavity 5. Use its 3.3 V logic
   output for `lights on`. To follow the dial, add a protected differential
   measurement across 1 and 2 if the meter or scope confirms a usable
   brightness signal. Carry both taps in the same Toyota harness branch.
   Check the sleeve and case saddle with the additional conductors. The
   existing CAD routes two power wires. Design the sense input to tolerate
   automotive transients and prevent backfeeding the controller when TAIL
   is live with ACC off. Preserve the factory path to R13 for both dimmer
   returns. Use IR1-5 for shield ground and the RGBW load return. Rev C has
   two vehicle pads, so park the sense leads insulated at the tee for a
   Rev C build. Preserve the dedicated RGBW output lead.

[Rev C wiring and case route](../pcb-rgbw-revc/README.md#toyota-power-wire-routing) ·
[Rev C J1/J2 pad assignments](../pcb-rgbw-revc/generated/harness-pads.json).

## Verify on the truck before soldering

Toyota's 2005 V8 service diagram draws cavity 6 through a 10 A CIG fuse.
Toyota's two 2005 owner-manual editions list position 45, CIG, as unused.
The standard front and rear 12 V outlets have their own PWR OUTLET feed.
Check the fuse population and prove which fuse supplies cavity 6 on this
truck. If cavity 6 stays dead in ACC, trace its pink/blue wire to driver-side
junction block connector 1L, terminal 17, before treating it as a power
source. Keep the lighting wires reserved for sensing and the original lamps.
[2005 lighter wiring][lighter] · [2005 outlet wiring][outlet] ·
[September 2004 production owner's manual, p. 406][early-manual] ·
[April 2005 edition owner's manual, p. 408][late-manual].

| State | Record with the shield disconnected | Expected from the diagrams |
| --- | --- | --- |
| Circuit de-energized | Continuity from IR1-5 to known chassis ground | Low resistance. Confirm this return again by voltage drop under a known load. |
| Key OFF, ACC, then ON, lamps off | DC voltage from IR1-6 to known chassis ground and to IR1-5 | If the feed is fitted, expect no battery voltage in OFF and near battery voltage in ACC and ON. |
| Key ON, lighting switch OFF, TAIL, then HEAD | IR1-1 and IR1-3 each to known chassis ground | Both green leads should follow the TAIL relay, rising near battery voltage in TAIL and HEAD. |
| Key ON, TAIL selected, dimmer high then low | Voltage across 1–2 and 3–4 with original lamps connected through the breakout if fitted. Repeat in ACC to check behavior with the engine off. | Look for a corresponding change on both pairs. Use a scope across the pair if a meter averages a pulsed signal. |
| ACC, verified source and return | Actual fuse feeding IR1-6, voltage from 6 to 5 and ground drop under a small fused test load | Feed and return should hold up under load. Check the proposed full RGBW load on the bench before qualifying the shared vehicle circuit. |

Use a high-impedance meter and insulated breakout terminals for the voltage
checks. Check continuity with the circuit de-energized. A battery-powered
scope with an isolated input or a differential probe can measure across the
lamp pair while preserving its return path. Record actual readings and the
populated fuse before qualifying the power and sense branches.

[location]: https://charm.li/images/IMP28Q313/asian751/1241836737/
[lighter]: https://charm.li/images/IMP28Q313/asian751/2057915083/
[lighter-hints]: https://charm.li/images/IMP28Q313/asian751/2057917088/
[tail]: https://charm.li/images/IMP28Q313/asian751/2072889745/
[illum]: https://charm.li/images/IMP28Q313/asian751/2072914008/
[dimmer]: https://charm.li/images/IMP28Q313/asian751/2072920757/
[outlet]: https://charm.li/images/IMP28Q313/asian751/1240469602/
[faces]: https://cdn3.guidessimo.com/view/1356/1356253-4runner_2003.pdf#page=63
[early-manual]: https://assets.sia.toyota.com/publications/en/om-s/OM35843U/pdf/OM35843U.pdf#page=418
[late-manual]: https://assets.sia.toyota.com/publications/en/om-s/OM35860U/pdf/OM35860U.pdf#page=418
