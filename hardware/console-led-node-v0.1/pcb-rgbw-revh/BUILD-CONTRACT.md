# Rev H terminal interface contract

Definition H.1; physical interface changes from Rev G. Evaluation hardware.

One integrated 133 x 65 mm, four-layer board retains Rev G power protection,
fuses, sensing, ESP32-S3 N16R2, GPIOs and RGBW driver. The Toyota six-cavity tee
is the sole power inlet. Factory connections pass straight through the tee;
all six branch conductors enter the M16 gland. The five-wire RGBW lead enters
the M12 gland. Vehicle telemetry arrives wirelessly from the existing CAN node.

Six identical factory-soldered KEFA KF128-5.08-2P-AA blocks replace the two wire
pad footprints and internal Micro-Fit pairs. Each block is JLCPCB C474952, a
through-hole Extended part. The live page advertises wave soldering on Economic
and Standard PCBA; catalog `assemblyMode=manualWeld` differs from that display.
The factory quote must resolve the production process and include all six
blocks and both fuse holders. No user soldering is part of this design.

JT1 GND/ACC, JT2 TAIL/DIM, JT3 IR1-3/IR1-4 isolated reserves. JT4 R-/G-, JT5
B-/protected +LED, JT6 W-/NC. Isolated reserves receive no pours or traces and
must never be tied to ground or assumed to be spare power. Vehicle cavity
identity and polarity still require measurement. Pad numbering follows this
board's explicit left-to-right pin-1 mark, not an undocumented manufacturer
numbering convention.

Manufacturer family drawing Rev A, 2021-03-13: 5.08 mm pitch, 10.16 x 10.7 x
14.1 mm body for two positions, 1.4 +0.10/-0.00 mm PCB holes, 4.3 +/-0.3 mm
tails, 6-7 mm stripping, 22-12 AWG solid/stranded wire, M2.5 maximum torque
0.4 N m. The AA suffix is associated by the exact JLCPCB listing; the family
drawing alone does not establish variant tolerances, screw-axis offsets or
ferrule approval. The CAD uses conservative body/tool envelopes and clearly
labels specification-based geometry. A purchased-part check is still required.

Glands grip intact jacket; individual wires separate only inside the enclosure.
No gland compression on individual conductors. Initial internal wire screen:
20 AWG, maximum 1.6 mm insulation OD; measured cable OD must fit the selected
gland. Do not tin stranded ends. Use ferrules only after confirming terminal
and ferrule compatibility. Clamp torque must be set by the approved assembly
instruction, never exceed the manufacturer's 0.4 N m maximum.

Service states: closed and wired; lid removed/terminal screws accessible;
circuits depowered/wires unclamped; board screws removed/board lifted; gland
plate removed after wires are released. Gland tightening occurs on the loose
plate. All terminal drive access is vertical with lid removed. Printed support
rails below the bank transfer screw-clamp load to the floor without contacting
through-hole pins. The bare board extends into the front bay; the power, driver and radio
placements and antenna edge remain unchanged. The LED blocks are staggered
3 mm inward. The D7 negative-clamp diode moves 3 mm without a circuit change.
MH1 moves to enclosure (45, 14) mm with a corresponding stronger case pillar. The outer case size is retained.
The enclosure and all exports are cross-audited on Orion.

Evidence gates: real KiCad ERC, schematic parity, DRC and unconnected checks;
unchanged non-interface circuits and copper baseline; native exported STEP and
FCStd interference, driver and fuse access; wire paths/entry direction and
minimum radius; manifold/support-free meshes and bounded Cura slices. These
are digital checks. Physical wire pull/torque/vibration, electrical transients,
hot enclosure temperature, truck pinout, radio, print fit and sealing remain
pending. Existing 1 A combined / 0.5 A per channel LED screen is unchanged;
terminal current rating does not increase the board's permitted load.
