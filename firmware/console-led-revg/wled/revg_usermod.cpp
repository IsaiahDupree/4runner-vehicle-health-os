// SPDX-License-Identifier: EUPL-1.2
#include "wled.h"
#include "revg_control.h"
#include "revg_voltage.h"
#include "revg_ui.h"
#include <esp_wifi.h>

namespace {
struct Settings : revg::ControlConfig {
  bool armed = false;
  char key[65] = {};
  revg::VoltageCalibration voltage;
};
Settings settings;
revg::Policy policy;
revg::CabinInputs cabin;
portMUX_TYPE lock = portMUX_INITIALIZER_UNLOCKED;
bool pinsReserved = false, wiredOutputReady = false, manualRequested = false;
bool captureManual = false, applyManual = false, applyOff = true, saveConfig = false;
uint8_t manualLevel = 0;
uint32_t manualColor = 0;
int32_t tailMv = -1, dimMv = -1, supplyMv = -1;
#ifdef VHOS_SUPPLY_SENSE
constexpr bool hasSupply = true;
#else
constexpr bool hasSupply = false;
#endif

std::string_view text(const String& v) { return {v.c_str(), v.length()}; }
std::string_view field(AsyncWebServerRequest* r, const char* name) {
  const auto* p = r->getParam(name, true);
  return p ? text(p->value()) : std::string_view{};
}
bool authorized(AsyncWebServerRequest* r) {
  const auto* key = r->getHeader("X-VHOS-Key");
  portENTER_CRITICAL(&lock);
  const bool accepted = key && revg::acceptedKey(text(key->value()), settings.key);
  portEXIT_CRITICAL(&lock);
  return accepted;
}
bool isolatedAP() {
  wifi_config_t ap{};
  if (!apActive || WiFi.softAPgetStationNum() == 0 || Network.isConnected() ||
      esp_wifi_get_config(WIFI_IF_AP, &ap) != ESP_OK || ap.ap.authmode < WIFI_AUTH_WPA2_PSK ||
      ap.ap.authmode == WIFI_AUTH_WPA2_ENTERPRISE) return false;
  const char* pass = reinterpret_cast<const char*>(ap.ap.password);
  return strnlen(pass, sizeof(ap.ap.password)) >= 12 && strncmp(pass, DEFAULT_AP_PASS, sizeof(ap.ap.password)) != 0;
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
void resetIntent() {
  policy.manual(); manualRequested = captureManual = applyManual = false;
  manualLevel = 0;
  applyOff = true;
}
void relayRequest(AsyncWebServerRequest* r) {
  const auto* key = r->getHeader("X-VHOS-Key");
  const revg::RelayRequest form{key ? text(key->value()) : std::string_view{}, field(r, "action"),
      field(r, "session"), field(r, "seq"), field(r, "signal"), field(r, "centi")};
  portENTER_CRITICAL(&lock);
  const auto reply = revg::relay(policy, settings.rule, wiredOutputReady, settings.key, form, millis());
  if (reply.resetOutput) { manualRequested = captureManual = applyManual = false; applyOff = true; }
  portEXIT_CRITICAL(&lock);
  r->send(static_cast<int>(reply.status));
}
void manualRequest(AsyncWebServerRequest* r) {
  if (!authorized(r)) { r->send(403); return; }
  if (field(r, "action") == "off") {
    portENTER_CRITICAL(&lock); resetIntent(); portEXIT_CRITICAL(&lock);
    r->send(204); return;
  }
  if (field(r, "action") != "set") { r->send(400); return; }
  revg::ManualColor value;
  if (!revg::parseManual({field(r, "red"), field(r, "green"), field(r, "blue"),
                         field(r, "white"), field(r, "brightness")}, value)) { r->send(400); return; }
  portENTER_CRITICAL(&lock);
  const bool ready = wiredOutputReady;
  if (ready) {
    policy.manual(); manualRequested = true; captureManual = false; applyManual = true;
    manualLevel = value.brightness; manualColor = value.rgbw;
  }
  portEXIT_CRITICAL(&lock);
  r->send(ready ? 204 : 409);
}
void configRequest(AsyncWebServerRequest* r) {
  if (!authorized(r)) { r->send(403); return; }
  std::array<std::string_view, 16> fields;
  for (size_t i = 0; i < fields.size(); ++i) fields[i] = field(r, revg::configFields[i]);
  revg::ControlConfig next;
  if (!revg::parseControlConfig(fields, next)) { r->send(400); return; }
  portENTER_CRITICAL(&lock);
  settings.rule = next.rule; settings.cabin = next.cabin;
  cabin.reset(); resetIntent(); saveConfig = true;
  portEXIT_CRITICAL(&lock);
  r->send(202); // RAM applied; the main loop persists the WLED configuration.
}
void voltageRequest(AsyncWebServerRequest* r) {
  if (!authorized(r)) { r->send(403); return; }
  if (!hasSupply) { r->send(409); return; }
  revg::VoltageCalibration next;
  if (!revg::parseNumber(field(r, "low-adc-mv"), 0, 3300, next.lowAdcMv) ||
      !revg::parseNumber(field(r, "high-adc-mv"), 0, 3300, next.highAdcMv) ||
      !revg::parseNumber(field(r, "low-input-mv"), 6000, 20000, next.lowInputMv) ||
      !revg::parseNumber(field(r, "high-input-mv"), 6000, 20000, next.highInputMv) || !next.valid()) {
    r->send(400); return;
  }
  portENTER_CRITICAL(&lock); settings.voltage = next; saveConfig = true; portEXIT_CRITICAL(&lock);
  r->send(202);
}
void statusRequest(AsyncWebServerRequest* r) {
  if (!authorized(r)) { r->send(403); return; }
  Settings s; int32_t t, d, v, sampleValue; uint32_t sampleAge;
  bool ready, automatic, fresh, tail, pending; uint8_t intended, effective;
  portENTER_CRITICAL(&lock);
  const uint32_t now = millis();
  s = settings; t = tailMv; d = dimMv; v = supplyMv; ready = wiredOutputReady;
  automatic = policy.automatic(); fresh = policy.fresh(now); pending = saveConfig;
  sampleValue = policy.sampleValue(); sampleAge = policy.sampleAgeMs(now);
  intended = automatic ? policy.brightness(now) : manualRequested ? manualLevel : 0;
  effective = ready ? cabin.level(s.cabin, intended, now) : 0;
  tail = cabin.tailAllowed(s.cabin, now);
  portEXIT_CRITICAL(&lock);
  auto* response = new AsyncJsonResponse(3072);
  auto out = response->getRoot();
  out["contract"] = "vhos.lighting.status@1.0.0";
  out["board"] = hasSupply ? "Rev I supply sense" : "Rev G/H";
  out["ready"] = ready; out["armed"] = s.armed;
  out["mode"] = automatic ? "can" : intended ? "manual" : "off";
  out["canFresh"] = fresh; out["tailAllowed"] = tail;
  out["requestedBrightness"] = intended; out["effectiveBrightness"] = effective;
  out["configurationPendingSave"] = pending;
  out["reason"] = !ready ? "Check arming, private Wi-Fi and RGBW bus" : !tail ? "Waiting for TAIL input" :
      automatic && !fresh ? "Waiting for fresh CAN data" : effective ? "Output active" : "Output off";
  auto signal = out.createNestedObject("inputs");
  signal["tailAdcMv"] = t; signal["dimAdcMv"] = d; signal["supplyAdcMv"] = v;
  auto sample = out.createNestedObject("sample");
  sample["signal"] = static_cast<int>(s.rule.signal);
  if (fresh) { sample["centiUnits"] = sampleValue; sample["receiptAgeMs"] = sampleAge; }
  else { sample["centiUnits"] = nullptr; sample["receiptAgeMs"] = nullptr; }
  auto voltage = out.createNestedObject("voltage");
  voltage["fitted"] = hasSupply; voltage["calibrated"] = s.voltage.valid();
  voltage["source"] = "ACC_FUSED";
  voltage["quality"] = !hasSupply || v < 0 ? "unavailable" : v > revg::supplyLinearAdcMaximumMv ?
      "over-range" : s.voltage.valid() ? "calibrated" : "estimate";
  if (hasSupply && v >= 0 && v <= revg::supplyLinearAdcMaximumMv) voltage["inputMv"] = s.voltage.inputMv(v);
  else voltage["inputMv"] = nullptr;
  auto c = out.createNestedObject("config");
  c["signal"] = static_cast<int>(s.rule.signal); c["on-centi"] = s.rule.enter; c["off-centi"] = s.rule.exit;
  c["red"] = (s.rule.rgbw >> 16) & 255; c["green"] = (s.rule.rgbw >> 8) & 255;
  c["blue"] = s.rule.rgbw & 255; c["white"] = (s.rule.rgbw >> 24) & 255; c["brightness"] = s.rule.brightness;
  c["tail-enabled"] = s.cabin.tailEnabled ? 1 : 0;
  c["tail-on-mv"] = s.cabin.tailOnMv; c["tail-off-mv"] = s.cabin.tailOffMv;
  c["dim-enabled"] = s.cabin.dimEnabled ? 1 : 0;
  c["dim-min-mv"] = s.cabin.dimMinMv; c["dim-max-mv"] = s.cabin.dimMaxMv;
  c["dim-at-min-percent"] = s.cabin.dimAtMinPercent; c["dim-at-max-percent"] = s.cabin.dimAtMaxPercent;
  auto cal = out.createNestedObject("voltageCalibration");
  cal["low-adc-mv"] = s.voltage.lowAdcMv; cal["high-adc-mv"] = s.voltage.highAdcMv;
  cal["low-input-mv"] = s.voltage.lowInputMv; cal["high-input-mv"] = s.voltage.highInputMv;
  out["stripQualified"] = false;
  out["maximumChannelMa"] = 500; out["maximumCombinedMa"] = 1000;
  response->setLength(); response->addHeader("Cache-Control", "no-store"); r->send(response);
}
void uiRequest(AsyncWebServerRequest* r) {
  auto* response = r->beginResponse_P(200, "text/html; charset=utf-8", revgUi, sizeof(revgUi));
  response->addHeader("Content-Encoding", "gzip");
  response->addHeader("Cache-Control", "no-store");
  response->addHeader("X-Content-Type-Options", "nosniff");
  response->addHeader("Referrer-Policy", "no-referrer");
  response->addHeader("Content-Security-Policy", "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'");
  r->send(response);
}
} // namespace

void revgInitPins() {
  digitalWrite(revg::enablePin, LOW); pinMode(revg::enablePin, OUTPUT);
  pinsReserved = PinManager::allocatePin(revg::enablePin, true, PinOwner::UM_Unspecified) &&
      PinManager::allocatePin(revg::tailPin, false, PinOwner::UM_Unspecified) &&
      PinManager::allocatePin(revg::dimPin, false, PinOwner::UM_Unspecified);
  if (hasSupply) pinsReserved = PinManager::allocatePin(revg::supplyPin, false, PinOwner::UM_Unspecified) && pinsReserved;
}
void revgRequestManual() {
  portENTER_CRITICAL(&lock);
  policy.manual(); manualRequested = wiredOutputReady; captureManual = true; applyOff = !wiredOutputReady;
  portEXIT_CRITICAL(&lock);
}
class UsermodRevG final : public Usermod {
 public:
  void setup() override {
    server.on("/vhos/lighting", HTTP_POST, relayRequest);
    server.on("/vhos/manual", HTTP_POST, manualRequest);
    server.on("/vhos/config", HTTP_POST, configRequest);
    server.on("/vhos/voltage", HTTP_POST, voltageRequest);
    server.on("/vhos/status", HTTP_GET, statusRequest);
    server.on("/api/health", HTTP_GET, statusRequest);
    server.on("/vhos/ui", HTTP_GET, uiRequest);
    server.on("/vhos/ui/", HTTP_GET, uiRequest);
  }
  void loop() override {
    const uint32_t pollTime = millis();
    if (pollTime - lastPoll_ < 25) return;
    lastPoll_ = pollTime;
    const bool networkAndBus = pinsReserved && isolatedAP() && expectedPwmBus();
    const int32_t t = pinsReserved ? analogReadMilliVolts(revg::tailPin) : -1;
    const int32_t d = pinsReserved ? analogReadMilliVolts(revg::dimPin) : -1;
    const int32_t v = hasSupply && pinsReserved ? analogReadMilliVolts(revg::supplyPin) : -1;
    portENTER_CRITICAL(&lock);
    const uint32_t now = millis();
    tailMv = t; dimMv = d; supplyMv = v;
    const bool ready = settings.armed && networkAndBus && settings.cabin.valid();
    const bool wasReady = wiredOutputReady;
    wiredOutputReady = ready;
    if (!ready) {
      if (wasReady || manualRequested || policy.automatic() || bri != 0) resetIntent();
      else { policy.manual(); manualRequested = captureManual = applyManual = false; }
    }
    if (captureManual) { manualLevel = bri; captureManual = false; }
    cabin.observe(settings.cabin, t, d, now);
    policy.expire(now);
    const bool automatic = policy.automatic();
    const uint8_t intended = automatic ? policy.brightness(now) : manualRequested ? manualLevel : 0;
    const bool reset = applyOff;
    const uint8_t target = ready && !reset ? cabin.level(settings.cabin, intended, now) : 0;
    const uint32_t color = automatic ? policy.color() : manualColor;
    const bool paintManual = applyManual;
    const bool persist = saveConfig;
    applyOff = applyManual = saveConfig = false;
    portEXIT_CRITICAL(&lock);
    if (target == 0) digitalWrite(revg::enablePin, LOW);
    if (automatic || paintManual || reset) {
      if (bri != target || color != lastColor_ || paintManual || reset) writeDerivedState(target, color);
      lastColor_ = color;
    } else if (bri != target) { bri = target; stateUpdated(CALL_MODE_NO_NOTIFY); }
    if (target != 0) digitalWrite(revg::enablePin, HIGH);
    if (persist) serializeConfigToFS();
  }
  void onStateChange(uint8_t caller) override {
    if (caller == CALL_MODE_DIRECT_CHANGE || caller == CALL_MODE_BUTTON) revgRequestManual();
  }
  void addToConfig(JsonObject& root) override {
    Settings s;
    portENTER_CRITICAL(&lock); s = settings; portEXIT_CRITICAL(&lock);
    auto o = root.createNestedObject("RevG");
    o["arm-output"] = s.armed; o["relay-key"] = s.key;
    o["signal"] = static_cast<uint8_t>(s.rule.signal); o["on-centi"] = s.rule.enter; o["off-centi"] = s.rule.exit;
    o["red"] = (s.rule.rgbw >> 16) & 255; o["green"] = (s.rule.rgbw >> 8) & 255;
    o["blue"] = s.rule.rgbw & 255; o["white"] = (s.rule.rgbw >> 24) & 255; o["brightness"] = s.rule.brightness;
    o["tail-enabled"] = s.cabin.tailEnabled; o["tail-on-mv"] = s.cabin.tailOnMv; o["tail-off-mv"] = s.cabin.tailOffMv;
    o["dim-enabled"] = s.cabin.dimEnabled; o["dim-min-mv"] = s.cabin.dimMinMv; o["dim-max-mv"] = s.cabin.dimMaxMv;
    o["dim-at-min-percent"] = s.cabin.dimAtMinPercent; o["dim-at-max-percent"] = s.cabin.dimAtMaxPercent;
    o["voltage-low-adc-mv"] = s.voltage.lowAdcMv; o["voltage-high-adc-mv"] = s.voltage.highAdcMv;
    o["voltage-low-input-mv"] = s.voltage.lowInputMv; o["voltage-high-input-mv"] = s.voltage.highInputMv;
  }
  bool readFromConfig(JsonObject& root) override {
    auto i = root["RevG"];
    Settings n;
    n.armed = i["arm-output"] | false;
    strlcpy(n.key, i["relay-key"] | "", sizeof(n.key));
    const int sig = i["signal"] | 0;
    n.rule.signal = static_cast<revg::Signal>(sig >= 0 && sig <= 4 ? sig : 255);
    n.rule.enter = i["on-centi"] | n.rule.enter; n.rule.exit = i["off-centi"] | n.rule.exit;
    const uint8_t r = constrain(i["red"] | 255, 0, 255), g = constrain(i["green"] | 128, 0, 255);
    const uint8_t b = constrain(i["blue"] | 0, 0, 255), w = constrain(i["white"] | 0, 0, 255);
    n.rule.rgbw = RGBW32(r, g, b, w);
    const int level = i["brightness"] | 96;
    n.rule.brightness = level >= 1 && level <= 255 ? level : 0;
    n.cabin = {i["tail-enabled"] | false, i["tail-on-mv"] | 0, i["tail-off-mv"] | 0,
               i["dim-enabled"] | false, i["dim-min-mv"] | 0, i["dim-max-mv"] | 0,
               i["dim-at-min-percent"] | 100, i["dim-at-max-percent"] | 100};
    n.voltage = {i["voltage-low-adc-mv"] | 0, i["voltage-low-input-mv"] | 0,
                 i["voltage-high-adc-mv"] | 0, i["voltage-high-input-mv"] | 0};
    portENTER_CRITICAL(&lock);
    settings = n; cabin.reset(); resetIntent(); wiredOutputReady = false;
    portEXIT_CRITICAL(&lock);
    return !i.isNull();
  }
  void addToJsonInfo(JsonObject& root) override {
    portENTER_CRITICAL(&lock);
    const bool ready = wiredOutputReady, automatic = policy.automatic(), fresh = policy.fresh(millis());
    const int32_t t = tailMv, d = dimMv, v = supplyMv;
    const auto calibration = settings.voltage;
    portEXIT_CRITICAL(&lock);
    auto info = root["u"].as<JsonObject>();
    if (info.isNull()) info = root.createNestedObject("u");
    info.createNestedArray("Rev G driver").add(ready ? "Ready" : "Disarmed");
    info.createNestedArray("CAN lighting").add(!automatic ? "Manual" : fresh ? "Live" : "Waiting for sample");
    info.createNestedArray("TAIL ADC (mV)").add(t); info.createNestedArray("DIM ADC (mV)").add(d);
    if (hasSupply && v >= 0 && v <= revg::supplyLinearAdcMaximumMv)
      info.createNestedArray(calibration.valid() ? "ACC supply (mV)" : "ACC estimate (mV)").add(calibration.inputMv(v));
  }
 private:
  uint32_t lastPoll_ = 0, lastColor_ = 0;
};
static UsermodRevG lighting;
REGISTER_USERMOD(lighting);
