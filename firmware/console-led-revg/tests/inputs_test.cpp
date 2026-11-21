// SPDX-License-Identifier: EUPL-1.2
#include "../wled/revg_control.h"
#include "../wled/revg_voltage.h"
#include <cassert>
#include <cstdio>

int main() {
  revg::CabinInputs inputs;
  revg::CabinConfig c;
  assert(c.valid() && inputs.level(c, 255, 0) == 255);
  c.tailEnabled = true;
  assert(!c.valid() && inputs.level(c, 255, 0) == 0);
  c.tailOnMv = 900; c.tailOffMv = 700;
  assert(c.valid() && !inputs.tailAllowed(c, 0));
  inputs.observe(c, 1000, 500, 0);
  inputs.observe(c, 1000, 500, 199);
  assert(inputs.level(c, 255, 199) == 0);
  inputs.observe(c, 1000, 500, 200);
  assert(inputs.level(c, 255, 200) == 255);
  inputs.observe(c, 800, 500, 225); // Hysteresis holds within the band.
  assert(inputs.level(c, 255, 225) == 255);
  inputs.observe(c, 500, 500, 250);
  inputs.observe(c, 1000, 500, 275); // A brief off glitch cannot toggle output.
  assert(inputs.level(c, 255, 275) == 255);
  inputs.observe(c, 500, 500, 300);
  inputs.observe(c, 500, 500, 500);
  assert(inputs.level(c, 255, 500) == 0);
  inputs.reset();
  c.tailOnMv = 100; c.tailOffMv = 300; // Supports an inverted measured input.
  inputs.observe(c, 50, 500, UINT32_MAX - 100);
  inputs.observe(c, 50, 500, 99);
  assert(inputs.level(c, 255, 99) == 255);
  assert(inputs.level(c, 255, 349) == 0); // Deadline works across clock wrap.
  inputs.observe(c, 50, 500, 350); // A stale interval requires debounce again.
  assert(inputs.level(c, 255, 350) == 0);
  inputs.observe(c, 50, 500, 550);
  assert(inputs.level(c, 255, 550) == 255);
  inputs.observe(c, -1, 500, 551);
  assert(inputs.level(c, 255, 551) == 0);
  c.tailEnabled = false;
  c.dimEnabled = true; c.dimMinMv = 100; c.dimMaxMv = 1100;
  c.dimAtMinPercent = 10; c.dimAtMaxPercent = 90;
  for (int mv = 0; mv <= 3300; ++mv) {
    inputs.observe(c, 0, mv, static_cast<uint32_t>(mv));
    const int expected = 10 + (std::clamp(mv, 100, 1100) - 100) * 80 / 1000;
    assert(inputs.level(c, 200, mv) == 200 * expected / 100);
    assert(inputs.level(c, 0, mv) == 0);
  }
  assert(inputs.level(c, 200, 3550) == 0);
  c.dimAtMinPercent = 100; c.dimAtMaxPercent = 0;
  inputs.observe(c, 0, 600, 4000);
  assert(inputs.level(c, 200, 4000) == 100);
  inputs.observe(c, 0, 3301, 4001);
  assert(inputs.level(c, 200, 4001) == 0);
  c.dimMaxMv = c.dimMinMv;
  assert(!c.valid() && inputs.level(c, 200, 4002) == 0);

  std::array<std::string_view, 16> form = {
      "4", "100", "100", "255", "128", "0", "0", "96", "0", "0", "0", "0", "0", "0", "100", "100"};
  revg::ControlConfig config;
  assert(revg::parseControlConfig(form, config));
  assert(config.rule.signal == revg::Signal::activity && config.rule.rgbw == 0x00ff8000);
  for (size_t i = 0; i < form.size(); ++i) {
    auto bad = form; bad[i] = "1.0";
    assert(!revg::parseControlConfig(bad, config));
    assert(config.rule.signal == revg::Signal::activity); // No partial mutation.
    bad[i] = ""; assert(!revg::parseControlConfig(bad, config));
    bad[i] = "2147483648"; assert(!revg::parseControlConfig(bad, config));
  }
  auto bad = form; bad[1] = "99";
  assert(!revg::parseControlConfig(bad, config));
  bad = form; bad[8] = "1";
  assert(!revg::parseControlConfig(bad, config));
  bad = form; bad[11] = "1";
  assert(!revg::parseControlConfig(bad, config));
  revg::ManualColor manual;
  assert(revg::parseManual({"1", "2", "3", "4", "255"}, manual));
  assert(manual.rgbw == 0x04010203 && manual.brightness == 255);
  assert(!revg::parseManual({"1", "2", "3", "4", "256"}, manual));
  assert(!revg::parseManual({"1", "2", "3", "-1", "5"}, manual));
  revg::VoltageCalibration voltage;
  assert(!voltage.valid());
  assert(voltage.inputMv(-1) == -1 && voltage.inputMv(3301) == -1);
  assert(voltage.inputMv(1000) > 14000 && voltage.inputMv(1000) < 15000);
  voltage = {700, 10000, 1000, 14000};
  assert(voltage.valid() && voltage.inputMv(700) == 10000 && voltage.inputMv(1000) == 14000);
  assert(voltage.inputMv(850) == 12000);
  voltage.highAdcMv = voltage.lowAdcMv;
  assert(!voltage.valid());
  voltage = {100, 10000, 1000, 14000};
  assert(!voltage.valid()); // Reject implausible transfer, not merely increasing points.
  voltage = {700, 10000, 1300, 17000};
  assert(!voltage.valid()); // Never calibrate into the clamp region.
  std::puts("Cabin calibration, debounce, dim scaling, expiry, rollover and atomic command checks passed");
}
