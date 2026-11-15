// SPDX-License-Identifier: EUPL-1.2
#pragma once

#include "revg_policy.h"
#include <string_view>

namespace revg {

struct RelayRequest {
  std::string_view key;
  std::string_view action;
  std::string_view session;
  std::string_view sequence;
  std::string_view signal;
  std::string_view centiUnits;
};

enum class RelayStatus { accepted = 204, badRequest = 400, forbidden = 403, conflict = 409 };

struct RelayReply {
  RelayStatus status;
  bool resetOutput = false;
};

inline bool acceptedKey(std::string_view supplied, std::string_view expected) {
  if (expected.size() < 16 || expected.size() > 64 || supplied.size() != expected.size()) return false;
  unsigned mismatch = 0;
  for (size_t i = 0; i < expected.size(); ++i) mismatch |= supplied[i] ^ expected[i];
  return mismatch == 0;
}

inline bool parseNumber(std::string_view input, int32_t lo, int32_t hi, int32_t& output) {
  if (input.empty() || input.size() > 11) return false;
  const bool negative = input.front() == '-';
  if (negative) input.remove_prefix(1);
  if (input.empty()) return false;
  int64_t magnitude = 0;
  for (char c : input) {
    if (c < '0' || c > '9') return false;
    magnitude = magnitude * 10 + (c - '0');
  }
  const int64_t value = negative ? -magnitude : magnitude;
  if (value < lo || value > hi) return false;
  output = static_cast<int32_t>(value);
  return true;
}

// The WLED adapter supplies decoded form fields and applies the returned reset.
// A rejected request cannot change the active session or refresh its timeout.
inline RelayReply relay(Policy& policy, const Rule& rule, bool ready, std::string_view expectedKey,
                       const RelayRequest& request, uint32_t now) {
  if (!ready || !acceptedKey(request.key, expectedKey)) return {RelayStatus::forbidden};
  constexpr int32_t maxNumber = INT32_MAX;
  int32_t session = 0;
  if (!parseNumber(request.session, 1, maxNumber, session)) return {RelayStatus::badRequest};
  if (request.action == "stop") {
    if (!policy.owns(session)) return {RelayStatus::conflict};
    policy.manual();
    return {RelayStatus::accepted, true};
  }
  if (request.action != "start" && request.action != "sample") return {RelayStatus::badRequest};
  int32_t signal = 0;
  if (!parseNumber(request.signal, 0, static_cast<int32_t>(Signal::activity), signal))
    return {RelayStatus::conflict};
  const auto selected = static_cast<Signal>(signal);
  if (request.action == "start") {
    if (selected != rule.signal || !policy.activate(rule, session)) return {RelayStatus::conflict};
    return {RelayStatus::accepted, true};
  }
  int32_t seq = 0, value = 0;
  if (!parseNumber(request.sequence, 1, maxNumber, seq) ||
      !parseNumber(request.centiUnits, -4000, 1638375, value) ||
      !policy.sample(session, seq, selected, value, now)) return {RelayStatus::conflict};
  return {RelayStatus::accepted};
}

} // namespace revg
