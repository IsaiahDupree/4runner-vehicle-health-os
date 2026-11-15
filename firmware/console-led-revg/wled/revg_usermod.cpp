// SPDX-License-Identifier: EUPL-1.2
#include "wled.h"
#include "revg_relay.h"
#include <esp_wifi.h>

namespace {

struct Settings {
  revg::Rule rule;
  bool armed = false;
  char key[65] = {};
};

Settings settings;
revg::Policy policy;
portMUX_TYPE lock = portMUX_INITIALIZER_UNLOCKED;
bool pinsReserved = false;
bool wiredOutputReady = false;
bool manualRequested = false;
bool applyOff = true;

std::string_view text(const String& value) {
  return {value.c_str(), value.length()};
}

std::string_view field(AsyncWebServerRequest* request, const char* name) {
  const auto* param = request->getParam(name, true);
  return param ? text(param->value()) : std::string_view{};
}

bool isolatedAP() {
  wifi_config_t ap{};
  if (!apActive || WiFi.softAPgetStationNum() == 0 || Network.isConnected() || esp_wifi_get_config(WIFI_IF_AP, &ap) != ESP_OK ||
      ap.ap.authmode < WIFI_AUTH_WPA2_PSK || ap.ap.authmode == WIFI_AUTH_WPA2_ENTERPRISE) return false;
  const char* password = reinterpret_cast<const char*>(ap.ap.password);
  return strnlen(password, sizeof(ap.ap.password)) >= 12 &&
         strncmp(password, DEFAULT_AP_PASS, sizeof(ap.ap.password)) != 0;
}

bool expectedPwmBus() {
  if (BusManager::getNumBusses() != 1 || doInitBusses) return false;
  const Bus* bus = BusManager::getBus(0);
  uint8_t pins[5] = {};
  return bus && bus->isOk() && bus->getType() == TYPE_ANALOG_4CH && !bus->isReversed() &&
         !bus->isOffRefreshRequired() && bus->getPins(pins) == sizeof(revg::channelPins) &&
         memcmp(pins, revg::channelPins, sizeof(revg::channelPins)) == 0;
}

void writeDerivedState(uint8_t brightness, uint32_t color) {
  Segment& segment = strip.getMainSegment();
  segment.setMode(FX_MODE_STATIC);
  segment.setColor(0, color);
  nightlightActive = false;
  strip.setTransition(0);
  bri = brightness;
  stateUpdated(CALL_MODE_NO_NOTIFY);
}

void relayRequest(AsyncWebServerRequest* request) {
  const auto* key = request->getHeader("X-VHOS-Key");
  const revg::RelayRequest form{
      key ? text(key->value()) : std::string_view{}, field(request, "action"),
      field(request, "session"), field(request, "seq"), field(request, "signal"), field(request, "centi")};
  portENTER_CRITICAL(&lock);
  const auto reply = revg::relay(policy, settings.rule, wiredOutputReady, settings.key, form, millis());
  if (reply.resetOutput) {
    manualRequested = false;
    applyOff = true;
  }
  portEXIT_CRITICAL(&lock);
  request->send(static_cast<int>(reply.status));
}

} // namespace

// Called before WLED loads any settings or allocates peripheral pins.
void revgInitPins() {
  digitalWrite(revg::enablePin, LOW);
  pinMode(revg::enablePin, OUTPUT);
  pinsReserved = PinManager::allocatePin(revg::enablePin, true, PinOwner::UM_Unspecified) &&
                 PinManager::allocatePin(revg::tailPin, false, PinOwner::UM_Unspecified) &&
                 PinManager::allocatePin(revg::dimPin, false, PinOwner::UM_Unspecified);
}

void revgRequestManual() {
  portENTER_CRITICAL(&lock);
  policy.manual();
  manualRequested = wiredOutputReady;
  applyOff = !wiredOutputReady;
  portEXIT_CRITICAL(&lock);
}

class UsermodRevG final : public Usermod {
 public:
  void setup() override {
    server.on("/vhos/lighting", HTTP_POST, relayRequest);
  }

  void loop() override {
    const uint32_t pollTime = millis();
    if (pollTime - lastPoll_ < 25) return;
    lastPoll_ = pollTime;
    const bool networkAndBus = pinsReserved && isolatedAP() && expectedPwmBus();

    portENTER_CRITICAL(&lock);
    // The HTTP task stamps samples under this lock. Read the clock here so
    // a newly received sample cannot be newer than the expiration check.
    const uint32_t now = millis();
    const bool ready = settings.armed && networkAndBus;
    if (wiredOutputReady && !ready) applyOff = true;
    wiredOutputReady = ready;
    if (!ready) {
      policy.manual();
      manualRequested = false;
    }
    policy.expire(now);
    const bool automatic = policy.automatic();
    const uint8_t target = policy.brightness(now);
    const uint32_t color = policy.color();
    const bool onlyReset = applyOff;
    const bool manuallyLit = manualRequested && bri != 0;
    applyOff = false;
    portEXIT_CRITICAL(&lock);

    if (!ready || onlyReset || (automatic && !target) || (!automatic && !manuallyLit))
      digitalWrite(revg::enablePin, LOW);
    if (automatic) {
      if (target != lastBrightness_ || color != lastColor_ || onlyReset)
        writeDerivedState(target, color);
      lastBrightness_ = target;
      lastColor_ = color;
    } else {
      lastBrightness_ = 0;
      if (onlyReset) writeDerivedState(0, 0);
    }
    if (ready && !onlyReset && (automatic ? target != 0 : manuallyLit))
      digitalWrite(revg::enablePin, HIGH);
  }

  void onStateChange(uint8_t caller) override {
    if (caller == CALL_MODE_DIRECT_CHANGE || caller == CALL_MODE_BUTTON)
      revgRequestManual();
  }

  void addToConfig(JsonObject& root) override {
    Settings current;
    portENTER_CRITICAL(&lock);
    current = settings;
    portEXIT_CRITICAL(&lock);
    auto out = root.createNestedObject("RevG");
    out["arm-output"] = current.armed;
    out["relay-key"] = current.key;
    out["signal"] = static_cast<uint8_t>(current.rule.signal);
    out["on-centi"] = current.rule.enter;
    out["off-centi"] = current.rule.exit;
    out["red"] = (current.rule.rgbw >> 16) & 255;
    out["green"] = (current.rule.rgbw >> 8) & 255;
    out["blue"] = current.rule.rgbw & 255;
    out["white"] = (current.rule.rgbw >> 24) & 255;
    out["brightness"] = current.rule.brightness;
  }

  bool readFromConfig(JsonObject& root) override {
    auto in = root["RevG"];
    Settings next;
    next.armed = in["arm-output"] | false;
    strlcpy(next.key, in["relay-key"] | "", sizeof(next.key));
    const int signal = in["signal"] | 0;
    next.rule.signal = static_cast<revg::Signal>(signal >= 0 && signal <= 4 ? signal : 255);
    next.rule.enter = in["on-centi"] | next.rule.enter;
    next.rule.exit = in["off-centi"] | next.rule.exit;
    const uint8_t red = constrain(in["red"] | 255, 0, 255);
    const uint8_t green = constrain(in["green"] | 128, 0, 255);
    const uint8_t blue = constrain(in["blue"] | 0, 0, 255);
    const uint8_t white = constrain(in["white"] | 0, 0, 255);
    next.rule.rgbw = RGBW32(red, green, blue, white);
    const auto level = in["brightness"] | 96;
    next.rule.brightness = level >= 1 && level <= 255 ? level : 0;
    portENTER_CRITICAL(&lock);
    settings = next;
    policy.manual();
    wiredOutputReady = false;
    manualRequested = false;
    applyOff = true;
    portEXIT_CRITICAL(&lock);
    return !in.isNull();
  }

  void addToJsonInfo(JsonObject& root) override {
    portENTER_CRITICAL(&lock);
    const bool ready = wiredOutputReady;
    const bool automatic = policy.automatic();
    const bool fresh = policy.fresh(millis());
    portEXIT_CRITICAL(&lock);
    auto info = root["u"].as<JsonObject>();
    if (info.isNull()) info = root.createNestedObject("u");
    info.createNestedArray("Rev G driver").add(ready ? "Ready" : "Disarmed");
    info.createNestedArray("CAN lighting").add(!automatic ? "Manual" : fresh ? "Live" : "Waiting for sample");
    if (pinsReserved) {
      info.createNestedArray("TAIL ADC (mV)").add(analogReadMilliVolts(revg::tailPin));
      info.createNestedArray("DIM ADC (mV)").add(analogReadMilliVolts(revg::dimPin));
    }
  }

 private:
  uint32_t lastPoll_ = 0;
  uint32_t lastColor_ = 0;
  uint8_t lastBrightness_ = 0;
};

static UsermodRevG lighting;
REGISTER_USERMOD(lighting);
