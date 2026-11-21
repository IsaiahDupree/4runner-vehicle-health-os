// SPDX-License-Identifier: EUPL-1.2
#pragma once
#include <cstdint>

namespace revg {
constexpr uint8_t supplyPin = 1; // Rev I only; Rev H leaves this module pad isolated.
constexpr int32_t supplyLinearAdcMaximumMv = 1200; // Keep readings clear of the shunt-clamp region.
constexpr double supplyParallelOhm = 1.0 / (1.0 / 22000.0 + 1.0 / 40000.0);
constexpr double supplyAdcGain = supplyParallelOhm / (99800.0 + supplyParallelOhm) * 22000.0 / 40000.0;

struct VoltageCalibration {
  int32_t lowAdcMv = 0, lowInputMv = 0, highAdcMv = 0, highInputMv = 0;
  bool valid() const {
    const int32_t deltaAdc = highAdcMv - lowAdcMv, deltaInput = highInputMv - lowInputMv;
    return lowAdcMv >= 0 && highAdcMv <= supplyLinearAdcMaximumMv && deltaAdc >= 100 &&
           lowInputMv >= 6000 && highInputMv <= 17000 && deltaInput >= 1000 &&
           deltaInput >= 10 * deltaAdc && deltaInput <= 20 * deltaAdc &&
           lowAdcMv * 100 >= lowInputMv * 5 && lowAdcMv * 100 <= lowInputMv * 9 &&
           highAdcMv * 100 >= highInputMv * 5 && highAdcMv * 100 <= highInputMv * 9;
  }
  int32_t inputMv(int32_t adcMv) const {
    if (adcMv < 0 || adcMv > 3300) return -1;
    if (!valid()) return static_cast<int32_t>(adcMv / supplyAdcGain + 0.5);
    return lowInputMv + static_cast<int32_t>(static_cast<int64_t>(adcMv - lowAdcMv) *
        (highInputMv - lowInputMv) / (highAdcMv - lowAdcMv));
  }
};
} // namespace revg
