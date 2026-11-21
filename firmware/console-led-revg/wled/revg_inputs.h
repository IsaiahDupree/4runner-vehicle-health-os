// SPDX-License-Identifier: EUPL-1.2
#pragma once
#include <algorithm>
#include <cstdint>

namespace revg {

// These are measured ESP32 ADC millivolts, not vehicle-wire volts.
// Disabled defaults deliberately contain no guessed Toyota calibration.
struct CabinConfig {
  bool tailEnabled = false;
  int32_t tailOnMv = 0;
  int32_t tailOffMv = 0;
  bool dimEnabled = false;
  int32_t dimMinMv = 0;
  int32_t dimMaxMv = 0;
  int32_t dimAtMinPercent = 100;
  int32_t dimAtMaxPercent = 100;

  bool valid() const {
    const auto adc = [](int32_t n) { return n >= 0 && n <= 3300; };
    const int32_t tailSpan = tailOnMv > tailOffMv ? tailOnMv - tailOffMv : tailOffMv - tailOnMv;
    return adc(tailOnMv) && adc(tailOffMv) && adc(dimMinMv) && adc(dimMaxMv) &&
           (!tailEnabled || tailSpan >= 50) &&
           (!dimEnabled || dimMaxMv - dimMinMv >= 100) &&
           dimAtMinPercent >= 0 && dimAtMinPercent <= 100 &&
           dimAtMaxPercent >= 0 && dimAtMaxPercent <= 100;
  }
};

class CabinInputs {
 public:
  static constexpr uint32_t maximumAgeMs = 250;
  static constexpr uint32_t debounceMs = 200;

  void reset() { received_ = false; stable_ = candidate_ = false; candidateStarted_ = false; }

  void observe(const CabinConfig& config, int32_t tailMv, int32_t dimMv, uint32_t now) {
    if (!config.valid() || tailMv < 0 || tailMv > 3300 || dimMv < 0 || dimMv > 3300) {
      reset();
      return;
    }
    if (received_ && now - receivedAt_ >= maximumAgeMs) reset();
    received_ = true;
    receivedAt_ = now;
    dimMv_ = dimMv;
    if (!config.tailEnabled) { stable_ = true; candidateStarted_ = false; return; }
    bool desired = stable_;
    if (config.tailOnMv > config.tailOffMv) {
      if (tailMv >= config.tailOnMv) desired = true;
      else if (tailMv <= config.tailOffMv) desired = false;
    } else {
      if (tailMv <= config.tailOnMv) desired = true;
      else if (tailMv >= config.tailOffMv) desired = false;
    }
    if (desired == stable_) { candidateStarted_ = false; return; }
    if (!candidateStarted_ || candidate_ != desired) {
      candidate_ = desired;
      candidateAt_ = now;
      candidateStarted_ = true;
    } else if (now - candidateAt_ >= debounceMs) {
      stable_ = candidate_;
      candidateStarted_ = false;
    }
  }

  bool tailAllowed(const CabinConfig& config, uint32_t now) const {
    return config.valid() && (!config.tailEnabled || (fresh(now) && stable_));
  }

  uint8_t level(const CabinConfig& config, uint8_t requested, uint32_t now) const {
    if (!tailAllowed(config, now) || (config.dimEnabled && !fresh(now))) return 0;
    if (!config.dimEnabled) return requested;
    const int32_t mv = std::clamp(dimMv_, config.dimMinMv, config.dimMaxMv);
    const int32_t percentage = config.dimAtMinPercent +
        (mv - config.dimMinMv) * (config.dimAtMaxPercent - config.dimAtMinPercent) /
        (config.dimMaxMv - config.dimMinMv);
    // Scale intent, never turn a zero-intensity channel on.
    return static_cast<uint8_t>((static_cast<uint32_t>(requested) * percentage) / 100);
  }

  bool fresh(uint32_t now) const { return received_ && now - receivedAt_ < maximumAgeMs; }

 private:
  bool received_ = false, stable_ = false, candidate_ = false, candidateStarted_ = false;
  int32_t dimMv_ = 0;
  uint32_t receivedAt_ = 0, candidateAt_ = 0;
};

} // namespace revg
