/*
 * Copyright 2024 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#pragma once

#include "input/input_hook.hpp"
#include "audio/track_queue.hpp"

namespace input {
namespace actions {

auto select() -> HookCallback;

auto scrollUp() -> HookCallback;
auto scrollDown() -> HookCallback;

auto scrollToTop() -> HookCallback;
auto scrollToBottom() -> HookCallback;

auto goBack() -> HookCallback;

auto togglePlayPause() -> HookCallback;

auto nextTrack(audio::TrackQueue& queue) -> HookCallback;
auto prevTrack(audio::TrackQueue& queue) -> HookCallback;

auto skipBack() -> HookCallback;

auto volumeUp() -> HookCallback;
auto volumeDown() -> HookCallback;

auto longPress() -> HookCallback;

}  // namespace actions
}  // namespace input
