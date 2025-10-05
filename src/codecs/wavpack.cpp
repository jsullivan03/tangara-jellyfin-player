/*
 * Copyright 2025 ayumi <ayumi@noreply.codeberg.org>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "wavpack.hpp"

#include <cstdint>
#include <cstring>
#include <algorithm>
#include <optional>

#include "esp_heap_caps.h"
#include "codec.hpp"
#include "esp_log.h"
#include "result.hpp"
#include "sample.hpp"
#include "types.hpp"

namespace codecs {

[[maybe_unused]] static constexpr const char kTag[] = "wavpack";
// kBufSize and audio::kCodecBufferLength must be equal
static constexpr const size_t kBufSize = 2048;

static inline constexpr auto loadLe16(std::byte* data) -> uint16_t {
  return *reinterpret_cast<uint16_t*>(data);
}

static inline constexpr auto loadLe32(std::byte* data) -> uint32_t {
  return *reinterpret_cast<uint32_t*>(data);
}

static auto readProc(void* data, void* buf, long size) -> long {
  IStream* stream = static_cast<IStream*>(data);
  const int32_t res = stream->Read({
      static_cast<std::byte*>(buf),
      static_cast<std::span<std::byte>::size_type>(size)
  });
  return res < 0 ? 0 : res;
}

WavPackDecoder::WavPackDecoder() : input_(), buf_() {
  buf_ = static_cast<int32_t*>(
      heap_caps_malloc(
          kBufSize * sizeof(int32_t),
          MALLOC_CAP_INTERNAL | MALLOC_CAP_32BIT
  ));
}

WavPackDecoder::~WavPackDecoder() {
  heap_caps_free(buf_);
}

auto WavPackDecoder::OpenStream(std::shared_ptr<IStream> input, uint32_t offset)
    -> cpp::result<OutputFormat, ICodec::Error> {
  char error[80];
  input_ = input;
  wavpack_ = {};
  if (!WavpackOpenFileInput(&wavpack_, readProc, input_.get(), error)) {
    ESP_LOGE(kTag, "WavpackOpenFileInput: %s", error);
    return cpp::fail(Error::kMalformedData);
  }

  channels_ = WavpackGetReducedChannels(&wavpack_);
  bitdepth_ = WavpackGetBitsPerSample(&wavpack_);
  size_ = kBufSize / channels_;
  const auto size = input->Size();
  const std::optional total = WavpackGetNumSamples(&wavpack_) == -1
      ? std::nullopt
      : std::optional(
          static_cast<uint64_t>(WavpackGetNumSamples(&wavpack_)) * channels_
        );
  const auto rate = WavpackGetSampleRate(&wavpack_);
  if (offset && total && input_.get()->CanSeek()) {
    const uint32_t want = offset * rate;
    if (total < want) {
      ESP_LOGE(kTag, "seeking: offset points beyond the end of the file");
      return cpp::fail(Error::kInternalError);
    }

    uint32_t target;
    input_->SeekTo(0, IStream::SeekFrom::kStartOfStream);
    while (true) {
      std::byte header[32];
      input_->Read(header);
      if (memcmp(header, "wvpk", 4) != 0) {
        ESP_LOGE(kTag, "seeking: header expected, but not found");
        return cpp::fail(Error::kMalformedData);
      }
      const uint32_t size = loadLe32(header + 4);
      const uint16_t version = loadLe16(header + 8);
      if (version < 0x402 || version > 0x410) {
        ESP_LOGE(kTag, "seeking: bad WavPack version (%x)", version);
        return cpp::fail(Error::kMalformedData);
      }
      const uint32_t blockIndex = loadLe32(header + 16);
      const uint32_t blockSamples = loadLe32(header + 20);
      if (want >= blockIndex && want == blockIndex + blockSamples) {
        input_->SeekTo(size - 24, IStream::SeekFrom::kCurrentPosition);
        target = 0;
        break;
      } else if (want >= blockIndex && want < blockIndex + blockSamples) {
        input_->SeekTo(-32, IStream::SeekFrom::kCurrentPosition);
        target = want - blockIndex;
        break;
      }
      input_->SeekTo(size - 24, IStream::SeekFrom::kCurrentPosition);
    }

    wavpack_ = {};
    if (!WavpackOpenFileInput(&wavpack_, readProc, input_.get(), error)) {
      ESP_LOGE(kTag, "WavpackOpenFileInput: %s", error);
      return cpp::fail(Error::kMalformedData);
    }

    input_->SetPreambleFinished();
    uint32_t samples = 0;
    for (size_t i = 0, n = target / size_; i < n; i++)
      samples += WavpackUnpackSamples(&wavpack_, buf_, size_);
    samples += WavpackUnpackSamples(&wavpack_, buf_, target % size_);
    if (WavpackGetNumErrors(&wavpack_) != 0) {
      ESP_LOGE(kTag, "CRC error");
      return cpp::fail(Error::kMalformedData);
    } else if (samples != target || WavpackGetSampleIndex(&wavpack_) != want) {
      ESP_LOGE(kTag, "seeking: seeking unsuccessful: want %lu, got %lu",
          target, samples
      );
      return cpp::fail(Error::kInternalError);
    }
  } else if (offset && (!total || !input_.get()->CanSeek())) {
    ESP_LOGE(kTag, "seeking: can’t seek");
    return cpp::fail(Error::kInternalError);
  } else
    input_->SetPreambleFinished();

  return OutputFormat{
      .num_channels = channels_,
      .sample_rate_hz = rate,
      .total_samples = total,
      .bitrate_kbps = size && total
          ? std::optional(
              ((double)size.value() * 8.0)
              / ((double)total.value() / channels_ / rate) / 1000
            )
          : std::nullopt,
  };
}

auto WavPackDecoder::DecodeTo(std::span<sample::Sample> output)
    -> cpp::result<OutputInfo, Error> {
  const auto size = std::min(size_, output.size() / channels_);
  const auto samples = WavpackUnpackSamples(&wavpack_, buf_, size) * channels_;
  if (WavpackGetNumErrors(&wavpack_) != 0) {
    ESP_LOGE(kTag, "CRC error");
    return cpp::fail(Error::kMalformedData);
  }
  if (bitdepth_ == 16)
    for (size_t i = 0; i < samples; i++)
      output[i] = buf_[i];
  else if (bitdepth_ > 16)
    for (size_t i = 0; i < samples; i++)
      output[i] = sample::shiftWithDither(buf_[i], bitdepth_ - 16);
  else for (size_t i = 0; i < samples; i++)
    output[i] = buf_[i] << (16 - bitdepth_);
  return OutputInfo{
      .samples_written = samples,
      .is_stream_finished = samples == 0,
  };
}

}  // namespace codecs
