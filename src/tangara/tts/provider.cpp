/*
 * Copyright 2024 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "tts/provider.hpp"
#include <stdint.h>

#include <ios>
#include <optional>
#include <sstream>
#include <string>
#include <variant>

#include "drivers/storage.hpp"
#include "esp_log.h"

#include "komihash.h"
#include "tts/events.hpp"

namespace tts {

[[maybe_unused]] static constexpr char kTag[] = "tts";

static const char* kTtsPath = "/.tangara-tts/";

static auto textToFile(const std::string& text) -> std::optional<std::string> {
  uint64_t hash = komihash(text.data(), text.size(), 0);
  std::stringstream stream;
  // Assume the TTS sample is a .wav file; since we only support one low-RAM
  // overhead codec, we can presume the suffix. The suffix is needed, else we
  // fail to open the stream when it fails to autodetect the format when looking
  // up tags.
  stream << kTtsPath << std::hex << hash << ".wav";
  return stream.str();
}

Provider::Provider(drivers::NvsStorage& nvs) : nvs_(nvs) {
  tts_enabled_ = nvs_.UITextToSpeech();
}

auto Provider::player(std::unique_ptr<Player> p) -> void {
  player_ = std::move(p);
}

auto Provider::feed(const Event& e) -> void {
  if (std::holds_alternative<SimpleEvent>(e)) {
    // ESP_LOGI(kTag, "context changed");
  } else if (std::holds_alternative<TtsEnabledChanged>(e)) {
    auto ev = std::get<TtsEnabledChanged>(e);
    tts_enabled_ = ev.tts_enabled;
  } else if (std::holds_alternative<SelectionChanged>(e)) {
    auto ev = std::get<SelectionChanged>(e);
    if (!ev.new_selection) {
      // ESP_LOGI(kTag, "no selection");
    } else {
      // ESP_LOGI(kTag, "new selection: '%s', interactive? %i",
      // ev.new_selection->description.value_or("").c_str(),
      // ev.new_selection->is_interactive);
      auto text = ev.new_selection->description;
      if (!text) {
        ESP_LOGW(kTag, "missing description for element");
        return;
      }
      auto file = textToFile(*text);
      if (!file) {
        return;
      }

      if (player_ && tts_enabled_) {
        player_->playFile(*text, *file);
      }
    }
  }
}

bool Provider::SamplesOnSDCard() {
  // Does the /.tangara-tts/ path exist on the SD card?
  FILINFO fi;
  FRESULT status = f_stat(kTtsPath, &fi);

  switch (status) {
    case FR_NO_PATH:
    case FR_NO_FILE:
    case FR_NO_FILESYSTEM:
      // If the SD card isn't mounted, or no matching file, then no samples.
      return false;

    case FR_OK:
      // If /.tangara-tts exists, let's check it out first.
      break;

    default:
      // If things look odd, then assume samples aren't present.
      ESP_LOGW(kTag, "got unexpected %d status from f_stat(\"%s\")", status,
               kTtsPath);
      return false;
  }

  // If /.tangara-tts exists and is a directory, it probably contains samples.
  if (fi.fattrib & AM_DIR)
    return true;

  // Otherwise, for example, if it's a file, assume no samples present.
  ESP_LOGW(kTag, "got unexpected file attributes for %s: %d", kTtsPath,
           fi.fattrib);
  return false;
}

}  // namespace tts
