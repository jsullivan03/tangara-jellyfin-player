#include "fonts.hpp"

#include "lvgl.h"

/* Reads the given file completely into PSRAM. */
auto readFont(std::string path) -> std::span<uint8_t> {
  // This following is a bit C-brained. Sorry.
  FILE* f = fopen(path.c_str(), "r");
  if (!f) {
    return {};
  }

  uint8_t* data = NULL;
  long len = 0;

  if (fseek(f, 0, SEEK_END)) {
    goto fail;
  }

  len = ftell(f);
  if (len <= 0) {
    goto fail;
  }

  if (fseek(f, 0, SEEK_SET)) {
    len = 0;
    goto fail;
  }

  data = reinterpret_cast<uint8_t*>(heap_caps_malloc(len, MALLOC_CAP_SPIRAM));
  if (!data) {
    len = 0;
    goto fail;
  }

  if (fread(data, 1, len, f) < len) {
    heap_caps_free(data);
    len = 0;
  }

  fail:
  fclose(f);

  return {data, static_cast<size_t>(len)};
}

auto parseFont(std::span<uint8_t> data) -> lv_font_t* {
  if (data.empty()) {
    return nullptr;
  }

  lv_font_t* font = lv_binfont_create_from_buffer(data.data(), data.size());
  heap_caps_free(data.data());

  return font;
}

auto loadFont(const std::string& path,
              std::atomic<lv_font_t*>& pointer,
              tasks::WorkerPool& bg_worker_pool) -> void {
  // Accessing flash storage cannot be done from a background task,
  // so copy the file from flash into a buffer in SPIRAM before
  // parsing it in the worker pool.
  auto buffer = readFont(path);
  bg_worker_pool.Dispatch<void>([&pointer, buffer]() {
    pointer = parseFont(buffer);
    pointer.notify_all();
  });
}
