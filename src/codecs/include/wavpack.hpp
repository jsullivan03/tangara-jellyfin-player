/*
 * Copyright 2025 ayumi <ayumi@noreply.codeberg.org>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <utility>

#include "wavpack.h"
#include "sample.hpp"

#include "codec.hpp"

namespace codecs {

class WavPackDecoder : public ICodec {
 public:
  WavPackDecoder();
  ~WavPackDecoder();

  auto OpenStream(std::shared_ptr<IStream> input, uint32_t offset)
      -> cpp::result<OutputFormat, Error> override;

  auto DecodeTo(std::span<sample::Sample> destination)
      -> cpp::result<OutputInfo, Error> override;

  WavPackDecoder(const WavPackDecoder&) = delete;
  WavPackDecoder& operator=(const WavPackDecoder&) = delete;

 private:
  std::shared_ptr<IStream> input_;
  WavpackContext wavpack_;
  int32_t *buf_;
  uint8_t bitdepth_;
  uint8_t channels_;
  size_t size_;
};

}  // namespace codecs
