// SPDX-License-Identifier: EUPL-1.2
#include "../wled/revg_relay.h"
#include <cassert>
#include <cstdio>

using revg::Policy;
using revg::RelayRequest;
using revg::RelayStatus;
using revg::Rule;
using revg::Signal;

int main() {
  constexpr std::string_view key = "fixture-revg-key";
  constexpr std::string_view wrong = "fixture-read-key";
  constexpr RelayRequest start{key, "start", "42", "", "0", ""};
  constexpr RelayRequest on{key, "sample", "42", "10", "0", "160025"};
  constexpr RelayRequest stop{key, "stop", "42", "", "", ""};
  Policy policy;
  Rule rule;
  unsigned checks = 0;

  const auto send = [&](RelayRequest request, uint32_t now, RelayStatus status,
                        bool ready = true, bool resetOutput = false) {
    const auto result = revg::relay(policy, rule, ready, key, request, now);
    assert(result.status == status && result.resetOutput == resetOutput);
    ++checks;
  };

  send(start, 10, RelayStatus::forbidden, false);
  send({wrong, "start", "42", "", "0", ""}, 11, RelayStatus::forbidden);
  send({{}, "start", "42", "", "0", ""}, 12, RelayStatus::forbidden);
  send({key, "start", "0", "", "0", ""}, 13, RelayStatus::badRequest);
  send({key, "start", "2147483648", "", "0", ""}, 14, RelayStatus::badRequest);
  send({key, "start", "+42", "", "0", ""}, 15, RelayStatus::badRequest);
  send({key, "start", "", "", "0", ""}, 16, RelayStatus::badRequest);
  send({key, "start", "42 ", "", "0", ""}, 17, RelayStatus::badRequest);
  send({key, "START", "42", "", "0", ""}, 18, RelayStatus::badRequest);
  send({key, "start", "42", "", "1", ""}, 19, RelayStatus::conflict);
  send({key, "start", "42", "", "99999999999", ""}, 20, RelayStatus::conflict);
  send({key, "start", "42", "", "0.0", ""}, 21, RelayStatus::conflict);
  send(on, 22, RelayStatus::conflict);
  assert(!policy.automatic());
  send(start, 30, RelayStatus::accepted, true, true);
  send({key, "sample", "43", "1", "0", "170000"}, 31, RelayStatus::conflict);
  send({key, "sample", "42", "1", "4", "100"}, 32, RelayStatus::conflict);
  send({key, "sample", "42", "1", "0", "1600.25"}, 33, RelayStatus::conflict);
  send({key, "sample", "42", "1", "0", "1e5"}, 34, RelayStatus::conflict);
  send({key, "sample", "42", "1", "0", "-1"}, 35, RelayStatus::conflict);
  send({key, "sample", "42", "0", "0", "160025"}, 36, RelayStatus::conflict);
  send({key, "sample", "42", "1", "0", "1638376"}, 37, RelayStatus::conflict);
  send({key, "sample", "42", "1", "0", " 160025"}, 38, RelayStatus::conflict);
  send({key, "sample", "42", "1", "0", std::string_view("160025\0bad", 10)}, 39, RelayStatus::conflict);
  assert(policy.brightness(39) == 0);

  send(on, 100, RelayStatus::accepted);
  assert(policy.brightness(100) == rule.brightness);
  send(on, 2400, RelayStatus::conflict);
  send({key, "sample", "42", "9", "0", "160025"}, 2500, RelayStatus::conflict);
  send({key, "stop", "43", "", "", ""}, 2600, RelayStatus::conflict);
  assert(policy.brightness(2599) == rule.brightness);
  policy.expire(2600);
  assert(policy.automatic() && policy.brightness(2600) == 0);
  assert(policy.brightness(150) == 0); // Same timer phase, one full rollover later.
  send(on, 151, RelayStatus::conflict); // Preserve the last sequence through expiry.
  send({key, "sample", "42", "11", "0", "145000"}, 152, RelayStatus::accepted);
  assert(policy.brightness(152) == 0); // Re-entry uses the on threshold.
  send({key, "sample", "42", "12", "0", "150000"}, 153, RelayStatus::accepted);
  send({key, "sample", "42", "13", "0", "142000"}, 154, RelayStatus::accepted);
  assert(policy.brightness(154) == rule.brightness);
  send({key, "sample", "42", "14", "0", "139999"}, 155, RelayStatus::accepted);
  assert(policy.brightness(155) == 0);
  send(stop, 156, RelayStatus::accepted, true, true);
  send(stop, 157, RelayStatus::conflict);
  send(start, 158, RelayStatus::accepted, true, true);
  policy.manual(); // The WLED manual control hook uses the same call.
  send(on, 159, RelayStatus::conflict);
  send(start, 160, RelayStatus::accepted, true, true);
  send(on, UINT32_MAX - 100, RelayStatus::accepted);
  policy.expire(30);
  assert(policy.brightness(30) == rule.brightness);
  policy.expire(2400);
  assert(policy.brightness(2400) == 0);
  send({key, "start", "43", "", "0", ""}, 2401, RelayStatus::accepted, true, true);
  send(on, 2402, RelayStatus::conflict);
  send({key, "sample", "43", "1", "0", "160025"}, 2403, RelayStatus::accepted);

  rule = {Signal::coolant, -2000, -2100, 0x004080ff, 93};
  send({key, "start", "45", "", "2", ""}, 2500, RelayStatus::accepted, true, true);
  send({key, "sample", "45", "1", "2", "-1900"}, 2501, RelayStatus::accepted);
  assert(policy.brightness(2501) == 93);
  send({key, "sample", "45", "2", "2", "-4001"}, 2502, RelayStatus::conflict);
  send({key, "sample", "45", "2", "2", "-2200"}, 2503, RelayStatus::accepted);
  assert(policy.brightness(2503) == 0);
  std::printf("Rev G passed %u relay request cases and the output, timing and threshold assertions.\n", checks);
}
