/*
 * Copyright 2023 jacqueline <me@jacqueline.id.au>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <span>

#include "mad.h"
#include "sample.hpp"
#include "source_buffer.hpp"

#include "codec.hpp"

namespace codecs {

class MadMp3Decoder : public ICodec {
 public:
  MadMp3Decoder();
  ~MadMp3Decoder();

  auto OpenStream(std::shared_ptr<IStream> input,uint32_t offset)
      -> cpp::result<OutputFormat, Error> override;

  auto DecodeTo(std::span<sample::Sample> destination)
      -> cpp::result<OutputInfo, Error> override;

  MadMp3Decoder(const MadMp3Decoder&) = delete;
  MadMp3Decoder& operator=(const MadMp3Decoder&) = delete;

 private:
  auto SkipID3Tags(IStream& stream) -> std::optional<uint32_t>;

  struct Mp3Info {
    uint16_t starting_sample;
    uint32_t length;
    std::optional<uint32_t> bytes;
    std::optional<std::span<const unsigned char, 100>> toc;
  };

  auto GetMp3Info(const mad_header& header) -> std::optional<Mp3Info>;
  
  auto GetBytesUsed() -> std::size_t;

  std::shared_ptr<IStream> input_;
  SourceBuffer buffer_;

  std::unique_ptr<mad_stream> stream_;
  std::unique_ptr<mad_frame> frame_;
  std::unique_ptr<mad_synth> synth_;

  // Count of samples processed in the current frame (channels combined)
  int current_frame_sample_;
  // Count of samples processed in the current stream (channels separate, i.e. usually x2)
  int current_stream_sample_;
  // How many samples in the current stream (channels separate) with encoder delay/padding removed
  int total_samples_;
  // Encoder delay, i.e. how many samples to skip at the start of the stream
  int skip_samples_;
  bool is_eof_;
  bool is_eos_;
};

}  // namespace codecs
