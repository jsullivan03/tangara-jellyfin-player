#include "drivers/wifi.hpp"

#include <algorithm>
#include <cstring>
#include <string>

#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"

namespace drivers {

static constexpr char kTag[] = "wifi";

Wifi::Wifi(NvsStorage& nvs) : nvs_(nvs) {
  esp_err_t err = initialize();

  if (err != ESP_OK) {
    ESP_LOGE(kTag, "initialization failed: %s", esp_err_to_name(err));
    return;
  }

  err = reload();

  if (err != ESP_OK) {
    ESP_LOGE(kTag, "configuration failed: %s", esp_err_to_name(err));
  }
}

auto Wifi::initialize() -> esp_err_t {
  esp_err_t err = esp_netif_init();

  if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
    return err;
  }

  err = esp_event_loop_create_default();

  if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
    return err;
  }

  netif_ = esp_netif_create_default_wifi_sta();

  if (netif_ == nullptr) {
    return ESP_FAIL;
  }

  wifi_init_config_t config = WIFI_INIT_CONFIG_DEFAULT();

  err = esp_wifi_init(&config);

  if (err != ESP_OK) {
    return err;
  }

  err = esp_event_handler_instance_register(
      WIFI_EVENT,
      ESP_EVENT_ANY_ID,
      EventHandler,
      this,
      &wifi_handler_);

  if (err != ESP_OK) {
    return err;
  }

  err = esp_event_handler_instance_register(
      IP_EVENT,
      IP_EVENT_STA_GOT_IP,
      EventHandler,
      this,
      &ip_handler_);

  if (err != ESP_OK) {
    return err;
  }

  err = esp_wifi_set_storage(WIFI_STORAGE_RAM);

  if (err != ESP_OK) {
    return err;
  }

  err = esp_wifi_set_mode(WIFI_MODE_STA);

  if (err != ESP_OK) {
    return err;
  }

  initialized_ = true;
  return ESP_OK;
}

auto Wifi::reload() -> esp_err_t {
  if (!initialized_) {
    return ESP_ERR_INVALID_STATE;
  }

  auto ssid = nvs_.WifiSsid();

  if (!ssid || ssid->empty()) {
    connected_ = false;

    if (started_) {
      esp_wifi_stop();
      started_ = false;
    }

    ESP_LOGI(kTag, "Wi-Fi is not configured");
    return ESP_OK;
  }

  auto password = nvs_.WifiPassword().value_or("");

  wifi_config_t config{};

  if (ssid->size() > sizeof(config.sta.ssid) ||
      password.size() > sizeof(config.sta.password)) {
    return ESP_ERR_INVALID_ARG;
  }

  std::memcpy(
      config.sta.ssid,
      ssid->data(),
      std::min(ssid->size(), sizeof(config.sta.ssid)));

  std::memcpy(
      config.sta.password,
      password.data(),
      std::min(password.size(), sizeof(config.sta.password)));

  config.sta.threshold.authmode = WIFI_AUTH_OPEN;

  if (started_) {
    esp_wifi_disconnect();
  }

  esp_err_t err = esp_wifi_set_config(WIFI_IF_STA, &config);

  if (err != ESP_OK) {
    return err;
  }

  if (!started_) {
    err = esp_wifi_start();

    if (err == ESP_OK) {
      started_ = true;
    }

    return err;
  }

  return esp_wifi_connect();
}

auto Wifi::started() const -> bool {
  return started_.load();
}

auto Wifi::connected() const -> bool {
  return connected_.load();
}

auto Wifi::EventHandler(void* arg,
                        esp_event_base_t event_base,
                        int32_t event_id,
                        void* event_data) -> void {
  auto* wifi = static_cast<Wifi*>(arg);

  if (event_base == WIFI_EVENT &&
      event_id == WIFI_EVENT_STA_START) {
    esp_wifi_connect();
    return;
  }

  if (event_base == WIFI_EVENT &&
      event_id == WIFI_EVENT_STA_DISCONNECTED) {
    wifi->connected_ = false;
    esp_wifi_connect();
    return;
  }

  if (event_base == IP_EVENT &&
      event_id == IP_EVENT_STA_GOT_IP) {
    auto* event = static_cast<ip_event_got_ip_t*>(event_data);
    wifi->connected_ = true;

    ESP_LOGI(
        kTag,
        "connected with IP " IPSTR,
        IP2STR(&event->ip_info.ip));
  }
}

}
