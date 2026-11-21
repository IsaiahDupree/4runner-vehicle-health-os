// SPDX-License-Identifier: EUPL-1.2
#pragma once
#include "revg_relay.h"
#include "revg_inputs.h"
#include <array>

namespace revg {

constexpr std::array<const char*, 16> configFields = {
    "signal", "on-centi", "off-centi", "red", "green", "blue", "white", "brightness",
    "tail-enabled", "tail-on-mv", "tail-off-mv", "dim-enabled", "dim-min-mv", "dim-max-mv",
    "dim-at-min-percent", "dim-at-max-percent"};

struct ControlConfig {
  Rule rule;
  CabinConfig cabin;
};

// Atomic replacement: an invalid field never changes the running configuration.
inline bool parseControlConfig(const std::array<std::string_view, 16>& fields, ControlConfig& out) {
  constexpr std::array<int32_t, 16> lower = {0, -4000, -4000, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0};
  constexpr std::array<int32_t, 16> upper = {4, 1638375, 1638375, 255, 255, 255, 255, 255,
                                           1, 3300, 3300, 1, 3300, 3300, 100, 100};
  std::array<int32_t, 16> n{};
  for (size_t i = 0; i < n.size(); ++i)
    if (!parseNumber(fields[i], lower[i], upper[i], n[i])) return false;
  ControlConfig next;
  next.rule = {static_cast<Signal>(n[0]), n[1], n[2],
               static_cast<uint32_t>(n[6]) << 24 | static_cast<uint32_t>(n[3]) << 16 |
               static_cast<uint32_t>(n[4]) << 8 | static_cast<uint32_t>(n[5]),
               static_cast<uint8_t>(n[7])};
  next.cabin = {n[8] == 1, n[9], n[10], n[11] == 1, n[12], n[13], n[14], n[15]};
  if (!next.rule.valid() || !next.cabin.valid()) return false;
  out = next;
  return true;
}

struct ManualColor { uint32_t rgbw = 0; uint8_t brightness = 0; };

inline bool parseManual(const std::array<std::string_view, 5>& fields, ManualColor& out) {
  std::array<int32_t, 5> n{};
  for (size_t i = 0; i < n.size(); ++i) if (!parseNumber(fields[i], 0, 255, n[i])) return false;
  out = {static_cast<uint32_t>(n[3]) << 24 | static_cast<uint32_t>(n[0]) << 16 |
         static_cast<uint32_t>(n[1]) << 8 | static_cast<uint32_t>(n[2]), static_cast<uint8_t>(n[4])};
  return true;
}

} // namespace revg
