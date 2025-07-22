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
#include <variant>

extern "C" {
  #include "decomp.h"
}
#include "sample.hpp"

#include "codec.hpp"

namespace codecs {

class AlacDecoder : public ICodec {
 public:
  AlacDecoder();
  ~AlacDecoder();

  auto OpenStream(std::shared_ptr<IStream> input, uint32_t offset)
      -> cpp::result<OutputFormat, Error> override;
  auto DecodeTo(std::span<sample::Sample> destination)
      -> cpp::result<OutputInfo, Error> override;

  AlacDecoder(const AlacDecoder&) = delete;
  AlacDecoder& operator=(const AlacDecoder&) = delete;

 private:
  auto readBoxHeader()
      -> cpp::result<std::tuple<uint64_t, std::array<std::byte, 4>>, ICodec::Error>;
  auto readFullBoxHeader() -> std::tuple<uint8_t, uint32_t>;
  auto readFtyp(uint64_t size) -> cpp::result<void, ICodec::Error>;
  void readFree(uint64_t size);
  auto readStsd() -> cpp::result<void, ICodec::Error>;
  auto readStts() -> cpp::result<void, ICodec::Error>;
  auto readStsc() -> cpp::result<void, ICodec::Error>;
  auto readStsz() -> cpp::result<void, ICodec::Error>;
  auto readStco() -> cpp::result<void, ICodec::Error>;
  auto readCo64() -> cpp::result<void, ICodec::Error>;
  auto readBox() -> cpp::result<uint64_t, ICodec::Error>;
  auto readContainer(uint64_t size) -> cpp::result<uint64_t, ICodec::Error>;
  auto getFrameDuration(uint32_t frame) -> cpp::result<uint32_t, ICodec::Error>;
  auto getFrameSize(uint32_t frame) -> uint32_t;
  auto getTotalSamples() -> uint64_t;
  auto getTotalFrames() -> uint32_t;
  auto getTotalFrameSize() -> uint64_t;
  auto frameToOffset(uint32_t frame)
      -> cpp::result<std::tuple<uint64_t, uint32_t>, ICodec::Error>;
  auto getChunkMixMaxFrames(uint32_t chunk)
      -> cpp::result<std::tuple<uint32_t, uint32_t>, ICodec::Error>;
  auto sampleToFrame(uint64_t sample)
      -> cpp::result<std::tuple<uint32_t, uint32_t>, ICodec::Error>;
  auto UnpackFrame(uint32_t offset) -> cpp::result<void, ICodec::Error>;

  std::shared_ptr<IStream> input_;
  alac_file alac_;
  uint8_t bitdepth_;
  uint8_t channels_;
  uint16_t sampleRate_;
  uint16_t index_;

  std::vector<std::tuple<uint32_t, uint32_t>> stts_;
  std::vector<std::tuple<uint32_t, uint32_t>> stsc_;
  std::variant<uint32_t, std::vector<uint32_t>> stsz_;
  std::vector<uint64_t> stco_;

  bool hasStts_ = false;
  bool hasStsc_ = false;
  bool hasStsz_ = false;
  bool hasStco_ = false;

  uint32_t chunk_;
  uint32_t frame_;
  std::vector<std::byte> in_;
  std::vector<std::byte> out_;
  size_t outSize_;
  size_t outOff_;
};

}  // namespace codecs
