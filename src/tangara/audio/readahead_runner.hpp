#pragma once

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

namespace audio {

class ReadaheadSource;
// Runs the background file reading for ReadaheadSource
// because FreeRTOS wants tasks to run forever, not get deleted.
class ReadaheadRunner {
 public:
  ReadaheadRunner();
  ~ReadaheadRunner();

  auto TaskHandle() -> TaskHandle_t;
  auto RunInstance(ReadaheadSource* p) -> void;

private:
  static auto Main(void* queue) -> void;

  TaskHandle_t task_handle_;
  QueueHandle_t queue_;
};

} // namespace audio
