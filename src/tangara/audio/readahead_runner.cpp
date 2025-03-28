#include "audio/readahead_runner.hpp"
#include "audio/readahead_source.hpp"

#include "tasks.hpp"

namespace audio {

ReadaheadRunner::ReadaheadRunner()
: task_handle_(),
  queue_(xQueueCreate(1, sizeof(std::optional<ReadaheadSource*>))) {
  StaticTask_t* task_buffer = static_cast<StaticTask_t*>(heap_caps_malloc(
    sizeof(StaticTask_t), MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
  using namespace tasks;
  std::span<StackType_t> stack = AllocateStack<Type::kAudioFileReader>();
  task_handle_ = xTaskCreateStatic(
    &Main, "readahead", stack.size(), queue_,
    Priority<Type::kAudioFileReader>(),
    stack.data(), task_buffer);
}

auto ReadaheadRunner::TaskHandle() -> TaskHandle_t {
  return task_handle_;
}

auto ReadaheadRunner::RunInstance(ReadaheadSource* p) -> void {
  xQueueSend(queue_, &p, portMAX_DELAY);
}

auto ReadaheadRunner::Main(void* p) -> void {
  QueueHandle_t queue = reinterpret_cast<QueueHandle_t>(p);
  while (true) {
    ReadaheadSource* source;
    if (xQueueReceive(queue, &source, portMAX_DELAY)) {
      if (source) {
        source->ReadFile();
      }
    }
  }
}

ReadaheadRunner::~ReadaheadRunner() {
  // This should never happen; FreeRTOS tasks should run forever.
  assert("ReadaheadRunner destroyed" == 0);
}

} // namespace audio
