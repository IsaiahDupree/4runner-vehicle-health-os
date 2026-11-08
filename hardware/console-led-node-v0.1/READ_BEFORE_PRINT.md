# Fit-check parts only

These files are original proposed geometry generated on Orion. They do not
establish fit to the owned ESP32 board, Toyota connector or the console space.
Use the parts unpowered for measurement. No G-code, slicer-project approval or
printer dispatch is included.

1. Print `insert_coupon.stl` first in the intended material/process. With its
   long dimension along X, pilot centers X=8,20,32 mm have nominal diameters
   4.0,4.1,4.2 mm respectively. The holes are blind with 2.3 mm backing. Use
   the exact ruthex RX-M3x5.7 stock; measure dimensions, installation damage,
   pull-out and torque before choosing a pilot correction. The current case
   uses the manufacturer's nominal 4.0 mm pilot, not a calibrated compensation.
2. Base prints floor-down; lid and carrier template print flat. Every STL
   retains its CAD coordinates, so center/drop each part to the bed in the
   slicer. The base extends to X=-7 mm because of its mounting ears. Tiny
   bridges in the integral cable-tie anchors require a bridging inspection.
3. Proposed process: 0.4 mm nozzle, 0.2 mm layers, five perimeters, 30% infill.
   These are starting assumptions, not a verified printer profile. PETG is
   proposed for unpowered fit checks. ASA is a possible installed material,
   subject to a suitable printer setup and actual cabin heat/creep testing.
   No claim of IP, flame, automotive, structural or temperature qualification.
4. Overall installed geometry is 130 × 86 × 45 mm including ears. Check console
   clearance, bracket attachment, sharp metal edges and removal with cables.
   Mounting ears are geometry only; vehicle attachment hardware is unresolved.
5. Eight RX-M3x5.7 inserts serve four lid posts and four custom-carrier posts.
   All case pockets are 6.7 mm deep. Nominal radial plastic around the 4.6 mm
   insert OD on a carrier boss is 2.1 mm; the blind carrier pocket leaves
   3.3 mm of backing measured from the underside. Install inserts square,
   verify no breakthrough and allow to cool before fastening.
6. The lid uses four M3x8 pan-head screws through a 3 mm lid: nominal insert
   engagement 5 mm. A future 1.6 mm carrier uses four M3x6 screws plus 0.5 mm
   insulating washers: nominal engagement 3.9 mm. Check real screw/insert/head
   lengths and do not bottom them. No tightening torque is qualified here.
7. `carrier_drill_template.stl` has a proposed 80 × 52 mm hole rectangle. It is
   a dimensional template for our future 90 × 62 mm PCB, not an UNO adapter.
   Mount the carrier before fitting the controller module. Screwdriver access
   with the actual controller installed has not been established.
8. Cable openings are split at the lid seam for assembly without forcing an
   OEM plug through a small hole. Their 12 × 8 mm opening is a proposed bundle
   allowance. Secure the pigtail to the tie bridge and independently support
   the vehicle loom. Check abrasion, bend radius and tug behavior with the
   actual cable; these are not sealed glands or validated cable clamps.
9. USB service requires the lid removed until the owned board's connector
   position is measured. A shield stack and antenna keepout still require
   populated CAD. The estimated controller box is not an actual board model.

The main Orion capability discovery reported that its registered Cura snapshot
no longer matches a live `cura.log`. That profile was not refreshed or used in
this task. No printer upload, heating, homing or movement was sent. Before a
print dispatch, use a current verified material/printer profile and inspect the
actual bed and printer state.
