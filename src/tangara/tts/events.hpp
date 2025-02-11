/*
 * Copyright 2024 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#pragma once

#include <optional>
#include <string>
#include <variant>

namespace tts {

/*
 * 'Simple' TTS events are events that do not have any extra event-specific
 * details.
 */
enum class SimpleEvent {
  /*
   * Indicates that the screen's content has substantially changed. e.g. a new
   * screen has been pushed.
   */
  kContextChanged,
};

/*
 * Event indicating that the currently selected LVGL object has changed.
 */
struct SelectionChanged {
  struct Selection {
    std::optional<std::string> description;
    bool is_interactive;
  };

  std::optional<Selection> new_selection;
};

/*
  Event emitted when a user enables or disables the 'Spoken Interface' (TTS)
  setting on the device. This is used to convey the new state to the
  tts::Provider, but will not stop the current sample from being played.
*/
struct TtsEnabledChanged {
  bool tts_enabled;
};

using Event = std::variant<SimpleEvent, SelectionChanged, TtsEnabledChanged>;

}  // namespace tts
