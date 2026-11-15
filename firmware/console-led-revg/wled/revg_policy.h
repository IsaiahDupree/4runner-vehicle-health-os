// SPDX-License-Identifier: EUPL-1.2
#pragma once

#include <cstdint>

namespace revg {

constexpr uint32_t sampleMaximumAgeMs = 2500;
constexpr uint8_t enablePin = 21;
constexpr uint8_t tailPin = 5;
constexpr uint8_t dimPin = 4;
constexpr uint8_t channelPins[] = {18, 17, 14, 2};

enum class Signal : uint8_t { rpm = 0, speed = 1, coolant = 2, load = 3, activity = 4 };

inline bool inRange(Signal signal, int32_t centiUnits) {
  switch (signal) {
    case Signal::rpm: return centiUnits >= 0 && centiUnits <= 1638375;
    case Signal::speed: return centiUnits >= 0 && centiUnits <= 25500;
    case Signal::coolant: return centiUnits >= -4000 && centiUnits <= 21500;
    case Signal::load: return centiUnits >= 0 && centiUnits <= 10000;
    case Signal::activity: return centiUnits >= 0 && centiUnits <= 100;
  }
  return false;
}

struct Rule {
  Signal signal = Signal::rpm;
  int32_t enter = 150000;
  int32_t exit = 140000;
  uint32_t rgbw = 0x00ff8000; // packed WWRRGGBB, amber by default
  uint8_t brightness = 96;

  bool valid() const {
    return inRange(signal, enter) && inRange(signal, exit) && exit <= enter && brightness > 0;
  }
};

class Policy {
 public:
  bool activate(const Rule& rule, uint32_t session) {
    if (!rule.valid() || session == 0) return false;
    rule_ = rule;
    session_ = session;
    lastSequence_ = 0;
    lit_ = false;
    return true;
  }

  void manual() {
    session_ = 0;
    lastSequence_ = 0;
    lit_ = false;
  }

  bool automatic() const { return session_ != 0; }
  bool owns(uint32_t session) const { return automatic() && session_ == session; }

  bool sample(uint32_t session, uint32_t sequence, Signal signal, int32_t value, uint32_t now) {
    if (!owns(session) || sequence <= lastSequence_ || signal != rule_.signal ||
        !inRange(signal, value)) return false;
    if (!fresh(now)) lit_ = false;
    lastSequence_ = sequence;
    receiptTime_ = now;
    lit_ = lit_ ? value >= rule_.exit : value >= rule_.enter;
    return true;
  }

  bool fresh(uint32_t now) const {
    return automatic() && lastSequence_ > 0 && now - receiptTime_ < sampleMaximumAgeMs;
  }

  uint8_t brightness(uint32_t now) const { return fresh(now) && lit_ ? rule_.brightness : 0; }
  uint32_t color() const { return rule_.rgbw; }

 private:
  Rule rule_{};
  uint32_t session_ = 0;
  uint32_t lastSequence_ = 0;
  uint32_t receiptTime_ = 0;
  bool lit_ = false;
};

} // namespace revg
