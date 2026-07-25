#pragma once

#include <atomic>

#include "drivers/nvs.hpp"
#include "esp_err.h"
#include "esp_event.h"
#include "esp_netif.h"

namespace drivers {

class Wifi {
 public:
  explicit Wifi(NvsStorage& nvs);

  auto reload() -> esp_err_t;
  auto started() const -> bool;
  auto connected() const -> bool;

 private:
  static auto EventHandler(void* arg,
                           esp_event_base_t event_base,
                           int32_t event_id,
                           void* event_data) -> void;

  auto initialize() -> esp_err_t;

  NvsStorage& nvs_;
  esp_netif_t* netif_ = nullptr;
  esp_event_handler_instance_t wifi_handler_ = nullptr;
  esp_event_handler_instance_t ip_handler_ = nullptr;
  std::atomic<bool> initialized_{false};
  std::atomic<bool> started_{false};
  std::atomic<bool> connected_{false};
};

}
