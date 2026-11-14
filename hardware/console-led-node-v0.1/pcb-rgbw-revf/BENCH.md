# Rev F prototype bring-up

Record the built PCB revision, JLCPCB BOM, fuse elements, power-supply
settings, ambient temperature, wire mapping, current and scope measurements.
Start with the controller on the bench and J2 disconnected. Use a 12 V
current-limited supply connected to J1-2 ACC and J1-1 GND.

## Before power

1. Confirm both clamp cathode bands and the regulator, protection IC, shunt and module
   pin-1 marks against the PCB assembly drawing. Check F1 is 3 A/58 V and F2 is 1 A/32 V.
2. Check for shorts from ACC and each rail to GND. Meter the tee from cavity
   to matching cavity with the controller disconnected. Check each capped
   tail, all four J1 conductors and the pod contacts by continuity.
3. Print the coupons before using the final case. Fit the two cable sleeves,
   one heat-set insert, its fastener and the tools in the intended material.
   Verify the jacket takes a hand pull with clearance at the solder joints.

## Apply power and record the rails

1. Use a low current limit for initial checks, then increase it as needed
   for radio startup. Measure about 5 V on C7 or C8 and about 3.38 V at TP14.
   With the load disconnected, check Q1–Q4 gates stay low until firmware
   enables PWM.
2. Scope the voltage at C7/C8 and TP14 while booting and sending sustained
   Wi‑Fi traffic. Cycle ACC and vary the bench input from 9 V through 14.4 V.
   Verify 4.5–5.5 V on the 5 V rail in steady operation and a 3.0–3.6 V
   module rail during operation. Check that the module starts cleanly without
   repeated reset. Record controlled ramp-down, ramp-up and recovery after
   measured crank and brief brownout profiles.
3. Verify main-path reverse protection and OV shutdown with a current-limited
   source and the pod disconnected. Expected steady rising cutoff is about
   14.92–15.99 V at ACC before harness drop. Record shutdown, recovery and
   any rail overshoot. Transient immunity requires the relevant bench
   waveforms in addition to this DC test. [TI input protector](https://www.ti.com/lit/ds/symlink/lm7480-q1.pdf).

## Sense and drive

1. At each sense pad apply a separate common-ground stimulus from 0 V to
   14.4 V. A settled 14.4 V signal corresponds to roughly 0.97–1.00 V at
   the ADC before firmware correction. Check ADC sampling, lights-on
   thresholds and the DIM PWM response using the measured vehicle waveform.
2. With a controlled pulse source, scope each clamp and corresponding ADC
   pin at cold and hot. Start with small amplitudes. Verify the switch stays
   within its pin limits and the ADC remains above −0.3 V. Positive shunt
   current and the resistor divider were calculated. Cold Schottky drop,
   hot leakage and fast parasitic overshoot require measurement.
   [TI analog switch](https://www.ti.com/lit/ds/symlink/sn3257-q1.pdf) ·
   [onsemi clamp](https://www.onsemi.com/download/data-sheet/pdf/bat54ht1-d.pdf).
3. Establish the pod's common positive and contact order, then connect one
   pod. Check channels individually at low duty and test the intended worst
   case with all active. Log total current, harness drop and warm-up
   temperatures at input protectors, vias, solder pads, inductor and case.
   The 3 A main fuse protects the branch. It does not establish a continuous
   LED load rating.
4. Compare the wired ACC source and fuse to the actual 2005 V8 truck before
   installation. With the box mounted, test the actual wireless gateway
   link, temperature around the ESP32, fuse service and strain relief. The
   N16R8 module's default published ambient upper limit is 65 °C.
   [Toyota meter worksheet](../connector-adapter/IR1-WIRE-PLAN.md#verify-on-the-truck-before-soldering) ·
   [Espressif module limits](https://documentation.espressif.com/esp32-s3-wroom-1_wroom-1u_datasheet_en.pdf).
