# Rev G prototype bring-up

Record the actual setup, measurements, temperature and scope captures
for each step. Start with the controller, bench supply and resistive
loads on the workbench.

1. Confirm the eFuse pin 1, RGBW-driver pin 1, buck pin 1, module
   orientation, C17 polarity and D9 cathode on the protected positive rail.
   Check both exposed-pad joints. Inspect the through-hole fuse-holder
   joints and strain relief. Fit the specified 3 A/58 V main and 1 A/32 V
   logic fuse. Verify the six-position tee end-to-end and meter J1 and J2.
   Compare ground and the eFuse RTN plane for unintended metallic shorts.
2. Apply 12 V to ACC and ground at J1 with a low bench current limit and
   both RGBW and Toyota hardware disconnected. Verify protected voltage
   at TP5, buck input at TP7 and 3.3 V at TP14. Scope 3.3 V, CHIP_EN and
   LED_EN_N over fast and slow ramps, reconnects and cranking-like dropouts.
   Check the 6.51–7.23 V calculated eFuse restart, 14.94–15.86 V cutoff
   and 1.37–1.56 A current-limit estimates. Measure brownout and voltage
   recovery behavior with LEDs commanded off. On a rated current-limited
   fixture, test reverse battery and scoped terminal transients before
   testing with the vehicle.
3. Supply power through J1 for programming. Attach TP9 ground, TP10
   board TX to adapter RX and TP11 board RX to adapter TX on a 3.3 V
   UART with the adapter power wire isolated. Pull TP12 BOOT low and
   pulse TP13 EN low, then release EN before BOOT. The module variant is
   N16R2. Test boot, resets, communications loss and current spikes
   with the gateway and lights connected on the bench.
4. Use current-limited TAIL and DIM stimuli with the other board off,
   ramping and running. Confirm idle and reset isolation, scope the
   ADC pins and check the predicted 0.96–1.02 V at a 14.4 V stimulus.
   Verify readings against both actual factory illumination circuits.
5. Check that each J2 return is off before firmware enable. Drive each
   channel and run the combined worst-case load with 0.5 A maximum per
   channel and 1 A combined. Watch hot voltage drop, driver and PCB
   temperature, output after unplug/replug, and current-limit recovery.
   Scope output and supply during shorts and turn-off with the intended
   lead length. Follow with the measured DD7440 pod and all intended PWM
   combinations. Rate higher total loads only after electrical and
   thermal measurement. Confirm the Toyota branch has adequate current
   margin with its factory loads before drawing LED current from it.
6. Check cable sleeve fit, insert depth, screw purchase, fuse puller
   access and repeated mating on the coupons and assembled case.
   Confirm that the electronics clear the trim and moving parts, and
   test Wi-Fi/BLE range with the case installed. Record bench and actual
   vehicle results independently of the native CAD tests.
