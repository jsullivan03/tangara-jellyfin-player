/*
 * Copyright 2023 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#pragma once

#include <atomic>
#include <memory>

#include "freertos/FreeRTOS.h"
#include "freertos/stream_buffer.h"

#include "codec.hpp"

namespace audio {
class ReadaheadRunner;
/*
 * Wraps another stream, proactively buffering large chunks of it into memory
 * at a time.
 */
class ReadaheadSource : public codecs::IStream {
 public:
  ReadaheadSource(std::unique_ptr<codecs::IStream>, ReadaheadRunner&);
  ~ReadaheadSource();

  auto Read(std::span<std::byte> dest) -> ssize_t override;

  auto CanSeek() -> bool override;

  auto SeekTo(int64_t destination, SeekFrom from) -> void override;

  auto CurrentPosition() -> int64_t override;

  auto Size() -> std::optional<int64_t> override;

  auto SetPreambleFinished() -> void override;

  ReadaheadSource(const ReadaheadSource&) = delete;
  ReadaheadSource& operator=(const ReadaheadSource&) = delete;

 private:
  friend class ReadaheadRunner;
  // Only ReadaheadRunner should call this method.
  auto ReadFile() -> void;

  std::unique_ptr<codecs::IStream> wrapped_;
  int64_t tell_;

  StreamBufferHandle_t streambuffer_;
  StaticStreamBuffer_t streambuffer_static_;

  std::atomic<bool> reading_file_;
  std::atomic<bool> end_of_file_buffered_;
  std::atomic<bool> shutting_down_;

  ReadaheadRunner& runner_;
};

}  // namespace audio
