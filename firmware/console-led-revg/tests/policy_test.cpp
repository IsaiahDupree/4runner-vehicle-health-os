// SPDX-License-Identifier: EUPL-1.2
#include "../wled/revg_policy.h"
#include <cassert>
#include <cstdio>

using revg::Policy;
using revg::Rule;
using revg::Signal;

int main() {
  Policy policy;
  Rule rule;
  assert(!policy.automatic() && policy.brightness(0) == 0);
  assert(!policy.activate(rule, 0));
  Rule invalid = rule;
  invalid.exit = invalid.enter + 1;
  assert(!policy.activate(invalid, 1));
  assert(policy.activate(rule, 10));
  assert(policy.brightness(100) == 0);
  assert(!policy.sample(99, 1, Signal::rpm, 170000, 100));
  assert(!policy.sample(10, 1, Signal::speed, 15000, 100));
  assert(!policy.sample(10, 1, Signal::rpm, -20, 100));
  assert(policy.sample(10, 1, Signal::rpm, 149999, 100));
  assert(policy.brightness(100) == 0);
  assert(policy.sample(10, 2, Signal::rpm, 150000, 101));
  assert(policy.brightness(101) == rule.brightness);
  assert(policy.sample(10, 3, Signal::rpm, 140000, 102));
  assert(policy.brightness(102) == rule.brightness);
  assert(!policy.sample(10, 3, Signal::rpm, 140000, 102 + 2400));
  assert(policy.brightness(102 + 2499) == rule.brightness);
  assert(policy.brightness(102 + 2500) == 0);
  assert(policy.sample(10, 4, Signal::rpm, 149999, 102 + 2600));
  assert(policy.brightness(102 + 2600) == 0);
  assert(policy.sample(10, 5, Signal::rpm, 160000, 102 + 2601));
  assert(policy.sample(10, 6, Signal::rpm, 139999, 102 + 2602));
  assert(policy.brightness(102 + 2602) == 0);
  policy.manual();
  assert(!policy.automatic() && !policy.sample(10, 7, Signal::rpm, 160000, 3000));

  Rule activity{Signal::activity, 100, 100, 0x80402010, 64};
  assert(policy.activate(activity, 11));
  assert(policy.sample(11, 1, Signal::activity, 100, UINT32_MAX - 100));
  assert(policy.brightness(20) == 64 && policy.color() == activity.rgbw);
  assert(policy.brightness(2450) == 0);
  assert(!policy.sample(11, 2, Signal::activity, 200, 2451));

  Rule coolant{Signal::coolant, -2000, -2100, 0x004080ff, 100};
  assert(policy.activate(coolant, 12));
  assert(policy.sample(12, 1, Signal::coolant, -1950, 2500));
  assert(policy.brightness(2500) == 100);
  assert(!policy.sample(12, 2, Signal::coolant, -4001, 2501));
  std::puts("Rev G policy tests passed");
}
