# Rev I: protected switched-supply voltage sensing

Rev I adds on-board sensing of **ACC_FUSED**, after the main fuse and before the input eFuse. The same six-wire Toyota inlet remains the only power source. ACC-off resting battery measurements are unavailable. This is a voltage monitor for the supply at the box, not a state-of-charge meter or a battery-post measurement.

The existing SN3257-Q1 switch has unused channels. Channel 3 now connects VOLT_CLAMP at U5 pin 10 to VOLT_SW at pin 9 when CHIP_EN is valid; its alternate input stays grounded. The new path reuses the exact Rev H protected TAIL/DIM network and goes to ESP32-S3 GPIO1 / U11 pad 39. The remaining switch channel and the Toyota reserve wires stay unused.

| Added references | Existing part reused | Quantity |
|---|---|---:|
| R40, R41 | RT1206BRD0749K9L, 49.9k 0.1% | 2 |
| R42, R44 | 0603WAF2202T5E, 22k 1% | 2 |
| R43 | 0603WAF1802T5E, 18k 1% | 1 |
| U12 | LM4040C25QFTA, 2.5 V automotive shunt clamp | 1 |
| D10 | NSVBAT54HT1G, negative clamp | 1 |
| C32 | CC0603KRX7R9BB104, 100 nF 50 V | 1 |

This adds **eight populated positions, zero unique manufacturer SKUs**. At the retained November 21 JLCPCB snapshot, the material increment is **$0.8485**, making nominal PCB component material **$24.4326**. It is not a fresh checkout quote or finished-product price. Existing holder/clamp stock limitations, supplier assembly, fabrication, box build, firmware programming and testing remain separate. All parts are factory fitted.

The nominal ADC gain is 0.0684815; a 14.4 V input produces approximately 0.986 V at the ADC. A 32-corner resistor screen gives approximately 0.971–1.002 V, excluding switch, ADC, temperature and other errors. Firmware labels nominal conversion as an **uncalibrated estimate** until two meter-referenced bench points are applied. The shunt clamp saturates the transfer above its linear range; this is not a wide-range automotive pulse recorder.

[voltage_screen.py](voltage_screen.py) checks the actual selected manufacturer identities and resistor tolerances. Its clamp bounds are explicitly conditional assumptions inherited from the existing sensing design, not physical pulse evidence. Factory calibration, reset/isolation, negative-pulse behavior, resistor/clamp energy and voltage accuracy still need bench verification.

The source starts with the accepted native Rev H board, keeps its 133 x 65 mm outline, terminal locations and mounting positions, and adds the sensing parts in the existing free component area. Native routing, ERC/DRC and populated-board enclosure checks must pass before a revised fabrication package is accepted. The prior Rev H kit remains a separate frozen artifact.

Software and UI behavior: [WLED/CAN/vehicle-input configuration](../../../firmware/console-led-revg/CONFIGURATION.md). Rev I firmware enables GPIO1 sense; the unmodified Rev H board must use the original target without that input.

This revision is evaluation hardware. No physical installation or manufacturing release is implied by source, static screening, a successful firmware build or digital fit checks.
