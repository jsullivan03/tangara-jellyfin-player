/*
 * Copyright 2025 ayumi <ayumi@noreply.codeberg.org>
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "alac.hpp"

#include <cstring>
#include <algorithm>

#include "esp_heap_caps.h"
#include "codec.hpp"
#include "result.hpp"
#include "sample.hpp"
#include "types.hpp"

namespace codecs {

[[maybe_unused]] static constexpr const char kTag[] = "alac";

static inline constexpr auto loadBe16(std::byte data[2]) -> uint16_t {
  return __builtin_bswap16(*reinterpret_cast<uint16_t*>(data));
}

static inline constexpr auto loadBe32(std::byte data[4]) -> uint32_t {
  return __builtin_bswap32(*reinterpret_cast<uint32_t*>(data));
}

static inline constexpr auto loadBe64(std::byte data[8]) -> uint64_t {
  return __builtin_bswap64(*reinterpret_cast<uint64_t*>(data));
}

static inline constexpr auto str4(const char str[4]) -> uint32_t {
  return static_cast<uint32_t>(str[0]) << 24
      | static_cast<uint32_t>(str[1]) << 16
      | static_cast<uint32_t>(str[2]) << 8
      | static_cast<uint32_t>(str[3]);
}

static inline constexpr auto loadLe16(std::byte* data) -> int16_t {
  return *reinterpret_cast<int16_t*>(data);
}

auto AlacDecoder::readBoxHeader()
    -> cpp::result<std::tuple<std::uint64_t, std::array<std::byte, 4>>, Error> {
  std::byte buf[4];
  input_->Read(buf);
  std::uint64_t size = loadBe32(buf);
  switch (size) {
  case 0:
    return cpp::fail(Error::kUnsupportedFormat);
  case 1:
    std::byte buf[8];
    input_->Read(buf);
    size = loadBe64(buf);
  }
  std::array<std::byte, 4> type;
  input_->Read(type);
  return std::make_tuple(size, type);
}

auto AlacDecoder::readFullBoxHeader()
    -> std::tuple<std::uint8_t, std::uint32_t> {
  std::byte buf1[1];
  input_->Read(buf1);
  const std::uint8_t version = static_cast<uint8_t>(buf1[0]);
  std::byte buf4[4] = {};
  input_->Read({
      static_cast<std::byte*>(buf4+1),
      static_cast<std::span<std::byte>::size_type>(3)
  });
  std::uint32_t flags = loadBe32(buf4);
  return std::make_tuple(version, flags);
}

auto AlacDecoder::readFtyp(uint64_t size) -> cpp::result<void, Error> {
  std::array<std::byte, 4> brand;
  input_->Read(brand);
  if (loadBe32(brand.data()) != str4("M4A "))
    return cpp::fail(Error::kUnsupportedFormat);
  input_->SeekTo(
      size - 12 - (size > std::numeric_limits<uint32_t>::max() ? 8 : 0),
      IStream::SeekFrom::kCurrentPosition
  );
  return {};
}

void AlacDecoder::readFree(uint64_t size) {
  input_->SeekTo(
      size - 8 - (size > std::numeric_limits<uint32_t>::max() ? 8 : 0),
      IStream::SeekFrom::kCurrentPosition
  );
}

auto AlacDecoder::readStsd() -> cpp::result<void, Error> {
  uint8_t version;
  uint32_t flags;
  std::tie(version, flags) = readFullBoxHeader();
  if (version != 0 || flags != 0)
    return cpp::fail(Error::kMalformedData);
  std::byte buf4[4];
  input_->Read(buf4);
  if (std::uint32_t entryCount = loadBe32(buf4); entryCount != 1)
    return cpp::fail(Error::kMalformedData);
  uint64_t size2;
  std::array<std::byte, 4> type;
  if (auto v = readBoxHeader(); v.has_value())
    std::tie(size2, type) = v.value();
  else
    return cpp::fail(v.error());
  if (loadBe32(type.data()) != str4("alac"))
    return cpp::fail(Error::kUnsupportedFormat);
  input_->SeekTo(6, IStream::SeekFrom::kCurrentPosition);
  std::byte buf2[2];
  input_->Read(buf2);
  index_ = loadBe16(buf2);
  input_->SeekTo(20, IStream::SeekFrom::kCurrentPosition);
  input_->Read(buf4);
  uint32_t alacInfoSize = loadBe32(buf4) - 12;
  input_->Read(buf4);
  if (loadBe32(buf4) != str4("alac"))
    return cpp::fail(Error::kUnsupportedFormat);
  input_->Read(buf4);
  if (uint32_t alacInfoVersion = loadBe32(buf4); alacInfoVersion != 0)
    return cpp::fail(Error::kUnsupportedFormat);
  std::vector<std::byte> cookie(alacInfoSize);
  input_->Read(cookie);
  bitdepth_ = static_cast<uint8_t>(cookie[5]);
  channels_ = static_cast<uint8_t>(cookie[9]);
  sampleRate_ = loadBe32(&cookie[20]);
  create_alac(&alac_, bitdepth_, channels_);
  alac_set_info(&alac_, reinterpret_cast<char*>(cookie.data()));
  alac_.predicterror_buffer_a = static_cast<int32_t*>(
      heap_caps_malloc(
          alac_.setinfo_max_samples_per_frame * 4,
          MALLOC_CAP_CACHE_ALIGNED | MALLOC_CAP_32BIT
  ));
  alac_.predicterror_buffer_b = static_cast<int32_t*>(
      heap_caps_malloc(
          alac_.setinfo_max_samples_per_frame * 4,
          MALLOC_CAP_CACHE_ALIGNED | MALLOC_CAP_32BIT
  ));
  alac_.outputsamples_buffer_a = static_cast<int32_t*>(
      heap_caps_malloc(
          alac_.setinfo_max_samples_per_frame * 4,
          MALLOC_CAP_CACHE_ALIGNED | MALLOC_CAP_32BIT
  ));
  alac_.outputsamples_buffer_b = static_cast<int32_t*>(
      heap_caps_malloc(
          alac_.setinfo_max_samples_per_frame * 4,
          MALLOC_CAP_CACHE_ALIGNED | MALLOC_CAP_32BIT
  ));
  alac_.uncompressed_bytes_buffer_a = static_cast<int32_t*>(
      heap_caps_malloc(
          alac_.setinfo_max_samples_per_frame * 4,
          MALLOC_CAP_CACHE_ALIGNED | MALLOC_CAP_32BIT
  ));
  alac_.uncompressed_bytes_buffer_b = static_cast<int32_t*>(
      heap_caps_malloc(
          alac_.setinfo_max_samples_per_frame * 4,
          MALLOC_CAP_CACHE_ALIGNED | MALLOC_CAP_32BIT
  ));
  return {};
}

auto AlacDecoder::readStts() -> cpp::result<void, Error> {
  uint8_t version;
  uint32_t flags;
  std::tie(version, flags) = readFullBoxHeader();
  if (version != 0 || flags != 0)
    return cpp::fail(Error::kMalformedData);
  std::byte buf[4];
  input_->Read(buf);
  uint32_t entryCount = loadBe32(buf);
  stts_.resize(entryCount);
  for (size_t i = 0; i < entryCount; i++) {
    input_->Read(buf);
    uint32_t count = loadBe32(buf);
    input_->Read(buf);
    uint32_t delta = loadBe32(buf);
    stts_[i] = std::make_tuple(count, delta);
  }
  hasStts_ = true;
  return {};
}

auto AlacDecoder::readStsc() -> cpp::result<void, Error> {
  uint8_t version;
  uint32_t flags;
  std::tie(version, flags) = readFullBoxHeader();
  if (version != 0 || flags != 0)
    return cpp::fail(Error::kMalformedData);
  std::byte buf[4];
  input_->Read(buf);
  uint32_t entryCount = loadBe32(buf);
  stsc_.resize(entryCount);
  for (size_t i = 0; i < entryCount; i++) {
    input_->Read(buf);
    uint32_t firstChunk = loadBe32(buf) - 1;
    input_->Read(buf);
    uint32_t samples = loadBe32(buf);
    input_->Read(buf);
    if (uint32_t index = loadBe32(buf); index != index_)
      return cpp::fail(Error::kMalformedData);
    stsc_[i] = std::make_tuple(firstChunk, samples);
  }
  hasStsc_ = true;
  return {};
}

auto AlacDecoder::readStsz() -> cpp::result<void, Error> {
  uint8_t version;
  uint32_t flags;
  std::tie(version, flags) = readFullBoxHeader();
  if (version != 0 || flags != 0)
    return cpp::fail(Error::kMalformedData);
  std::byte buf[4];
  input_->Read(buf);
  uint32_t sampleSize = loadBe32(buf);
  input_->Read(buf);
  uint32_t sampleCount = loadBe32(buf);
  if(sampleSize != 0) {
    stsz_ = sampleSize;
    return {};
  }
  stsz_ = std::vector<uint32_t>(sampleCount);
  for (size_t i = 0; i < sampleCount; i++) {
    input_->Read(buf);
    std::get<1>(stsz_)[i] = loadBe32(buf);
  }
  hasStsz_ = true;
  return {};
}

auto AlacDecoder::readStco() -> cpp::result<void, Error> {
  uint8_t version;
  uint32_t flags;
  std::tie(version, flags) = readFullBoxHeader();
  if (version != 0 || flags != 0)
    return cpp::fail(Error::kMalformedData);
  std::byte buf[4];
  input_->Read(buf);
  uint32_t entryCount = loadBe32(buf);
  stco_ = std::vector<uint64_t>(entryCount);
  for (size_t i = 0; i < entryCount; i++) {
    input_->Read(buf);
    stco_[i] = loadBe32(buf);
  }
  hasStco_ = true;
  return {};
}

auto AlacDecoder::readCo64() -> cpp::result<void, Error> {
  uint8_t version;
  uint32_t flags;
  std::tie(version, flags) = readFullBoxHeader();
  if (version != 0 || flags != 0)
    return cpp::fail(Error::kMalformedData);
  std::byte buf4[4];
  input_->Read(buf4);
  uint32_t entryCount = loadBe64(buf4);
  stco_ = std::vector<uint64_t>(entryCount);
  for (size_t i = 0; i < entryCount; i++) {
    std::byte buf8[8];
    input_->Read(buf8);
    stco_[i] = loadBe64(buf8);
  }
  hasStco_ = true;
  return {};
}

auto AlacDecoder::readBox() -> cpp::result<uint64_t, Error> {
  uint64_t size;
  std::array<std::byte, 4> type;
  if (auto v = readBoxHeader(); v.has_value())
    std::tie(size, type) = v.value();
  else
    return cpp::fail(v.error());
  switch (loadBe32(type.data())) {
  case str4("ftyp"):
    if(auto v = readFtyp(size); v.has_error())
      return cpp::fail(v.error());
    break;
  case str4("moov"):
  case str4("trak"):
  case str4("mdia"):
  case str4("minf"):
  case str4("stbl"):
    if(auto v = readContainer(size); v.has_error())
      return cpp::fail(v.error());
    break;
  case str4("stsd"):
    if(auto v = readStsd(); v.has_error())
      return cpp::fail(v.error());
    break;
  case str4("stts"):
    if(auto v = readStts(); v.has_error())
      return cpp::fail(v.error());
    break;
  case str4("stsc"):
    if(auto v = readStsc(); v.has_error())
      return cpp::fail(v.error());
    break;
  case str4("stsz"):
    if(auto v = readStsz(); v.has_error())
      return cpp::fail(v.error());
    break;
  case str4("stco"):
    if(auto v = readStco(); v.has_error())
      return cpp::fail(v.error());
    break;
  case str4("co64"):
    if(auto v = readCo64(); v.has_error())
      return cpp::fail(v.error());
    break;
  default:
    readFree(size);
  }
  return size;
}

auto AlacDecoder::readContainer(uint64_t size)
    -> cpp::result<uint64_t, Error> {
  size -= 8 + (size > std::numeric_limits<uint32_t>::max() ? 8 : 0);
  while (size != 0) {
    if (auto v = readBox(); v.has_value())
      size -= v.value();
    else
      return cpp::fail(v.error());
  }
  return {};
}

auto AlacDecoder::getFrameDuration(uint32_t frame)
    -> cpp::result<uint32_t, Error> {
  uint32_t base = 0;
  for (size_t i = 0; i < stts_.size(); i++) {
    uint32_t count, delta;
    std::tie(count, delta) = stts_[i];
    base += count;
    if (frame < base) {
      return delta;
    }
  }
  return cpp::fail(Error::kInternalError);
}

auto AlacDecoder::getFrameSize(uint32_t frame) -> uint32_t {
  switch(stsz_.index()) {
  case 0:
    return std::get<0>(stsz_);
  case 1:
    return std::get<1>(stsz_)[frame];
  default:
    return 0;
  }
}

auto AlacDecoder::getTotalSamples() -> uint64_t {
  uint64_t total = 0;
  for (size_t i = 0; i < stts_.size(); i++) {
    uint32_t count, delta;
    std::tie(count, delta) = stts_[i];
    total += count * delta;
  }
  return total;
}

auto AlacDecoder::getTotalFrames() -> uint32_t {
  uint32_t total = 0;
  for (size_t i = 0; i < stts_.size(); i++)
    total += std::get<0>(stts_[i]);
  return total;
}

auto AlacDecoder::getTotalFrameSize() -> uint64_t {
  if (stsz_.index() == 0)
    return static_cast<uint64_t>(std::get<0>(stsz_)) * getTotalFrames();
  uint64_t total = 0;
  for (size_t i = 0; i < std::get<1>(stsz_).size(); i++)
    total += std::get<1>(stsz_)[i];
  return total;
}

auto AlacDecoder::frameToOffset(uint32_t frame)
    -> cpp::result<std::tuple<uint64_t, uint32_t>, Error> {
  uint32_t chunk, frames, skip, targetFrame = frame;
  std::tie(chunk, frames) = stsc_[0];
  skip = frames;
  if (chunk != 0)
    return cpp::fail(Error::kMalformedData);
  if (frame < frames) {
    uint64_t offset = 0;
    for(size_t i = 0; i < targetFrame; i++)
      offset += getFrameSize(i);
    return std::make_tuple(stco_[0] + offset, 0);
  }
  for (size_t i = 1; i < stsc_.size(); i++) {
    frame -= frames;
    uint32_t newChunk, newFrames;
    std::tie(newChunk, newFrames) = stsc_[i];
    for (size_t i = chunk, j = 1; newChunk - i > 1; i++, j++) {
      if (frame < frames) {
        uint64_t offset = 0;
        for (size_t i = skip; i < targetFrame; i++)
          offset += getFrameSize(i);
        return std::make_tuple(stco_[i + j] + offset, i + j);
      }
      skip += frames;
      frame -= frames;
    }
    if (frame < newFrames) {
      uint64_t offset = 0;
      for (size_t i = skip; i < targetFrame; i++)
        offset += getFrameSize(i);
      return std::make_tuple(stco_[newChunk] + offset, newChunk);
    }
    skip += newFrames;
    chunk = newChunk;
    frames = newFrames;
  }
  return cpp::fail(Error::kInternalError);
}

auto AlacDecoder::getChunkFramesRange(uint32_t chunk)
    -> cpp::result<std::tuple<uint32_t, uint32_t>, Error> {
  uint32_t from, frames, max, min = 0;
  std::tie(from, frames) = stsc_[0];
  if (from != 0)
    return cpp::fail(Error::kMalformedData);
  max = frames;
  if(chunk == 0)
    return std::make_tuple(min, max);
  min = max;
  for (size_t i = 1; i < stsc_.size(); i++) {
    uint32_t newFrom, newFrames;
    std::tie(newFrom, newFrames) = stsc_[i];
    while (newFrom - from > 1) {
      max += frames;
      if(chunk == ++from)
        return std::make_tuple(min, max);
      min = max;
    }
    frames = newFrames;
    max += frames;
    if (chunk == newFrom)
      return std::make_tuple(min, max);
    min = max;
    from++;
  }
  return cpp::fail(Error::kInternalError);
}

auto AlacDecoder::sampleToFrame(uint64_t sample)
    -> cpp::result<std::tuple<uint32_t, uint32_t>, Error> {
  uint64_t accumulator = 0;
  uint32_t frame = 0;
  for (size_t i = 0; i < stts_.size(); i++) {
    uint32_t count, delta;
    std::tie(count, delta) = stts_[i];
    for (size_t i = 0; i < count; i++, frame++) {
      if (sample >= accumulator && sample < accumulator + delta)
        return std::make_tuple(frame, sample - accumulator);
      accumulator += delta;
    }
  }
  return cpp::fail(Error::kInternalError);
}

AlacDecoder::AlacDecoder() : input_() {
  alac_.predicterror_buffer_a = nullptr;
  alac_.predicterror_buffer_b = nullptr;
  alac_.outputsamples_buffer_a = nullptr;
  alac_.outputsamples_buffer_b = nullptr;
  alac_.uncompressed_bytes_buffer_a = nullptr;
  alac_.uncompressed_bytes_buffer_b = nullptr;
}

AlacDecoder::~AlacDecoder() {
  if (alac_.predicterror_buffer_a != nullptr)
    heap_caps_free(alac_.predicterror_buffer_a);
  if (alac_.predicterror_buffer_b != nullptr)
    heap_caps_free(alac_.predicterror_buffer_b);
  if (alac_.outputsamples_buffer_a != nullptr)
    heap_caps_free(alac_.outputsamples_buffer_a);
  if (alac_.outputsamples_buffer_b != nullptr)
    heap_caps_free(alac_.outputsamples_buffer_b);
  if (alac_.uncompressed_bytes_buffer_a != nullptr)
    heap_caps_free(alac_.uncompressed_bytes_buffer_a);
  if (alac_.uncompressed_bytes_buffer_b != nullptr)
    heap_caps_free(alac_.uncompressed_bytes_buffer_b);
}

auto AlacDecoder::OpenStream(std::shared_ptr<IStream> input, uint32_t offset)
    -> cpp::result<OutputFormat, Error> {
  input_ = input;
  while (!hasStts_ || !hasStsc_ || !hasStsz_ || !hasStco_)
    if (auto v = readBox(); v.has_error())
      return cpp::fail(v.error());
  uint32_t diff;
  if (
      auto v = sampleToFrame(static_cast<uint64_t>(offset) * sampleRate_);
      v.has_error()
  )
    return cpp::fail(v.error());
  else
    std::tie(frame_, diff) = v.value();
  uint64_t off;
  if (auto v = frameToOffset(frame_); v.has_error())
    return cpp::fail(v.error());
  else
    std::tie(off, chunk_) = v.value();
  input_->SeekTo(off, IStream::SeekFrom::kStartOfStream);
  in_.resize(getFrameSize(frame_));
  if(auto v = getFrameDuration(frame_); v.has_error())
    return cpp::fail(v.error());
  else
    out_.resize((bitdepth_ / 8) * channels_ * v.value());
  const auto size = input->Size();
  input_->SetPreambleFinished();
  if (auto v = UnpackFrame(diff); v.has_error())
    return cpp::fail(v.error());
  return OutputFormat{
    .num_channels = channels_,
    .sample_rate_hz = sampleRate_,
    .total_samples = getTotalSamples() * channels_,
    .bitrate_kbps = size
          ? std::optional(
              ((double)size.value() * 8.0)
              / ((double)getTotalFrameSize() / channels_ / sampleRate_) / 1000
            )
          : std::nullopt,
  };
}

auto AlacDecoder::UnpackFrame(uint32_t offset) -> cpp::result<void, Error> {
  uint32_t min, max;
  if (auto v = getChunkFramesRange(chunk_); v.has_error())
    return cpp::fail(v.error());
  else
    std::tie(min, max) = v.value();
  uint32_t duration;
  if (auto v = getFrameDuration(frame_); v.has_error())
    return cpp::fail(v.error());
  else
    duration = v.value();
  const uint32_t size = getFrameSize(frame_);
  if (in_.size() < size)
    in_.resize(size);
  int outputSize = (bitdepth_ / 8) * channels_ * duration;
  if (out_.size() < outputSize)
    out_.resize(outputSize);
  input_->Read({in_.data(), size});
  if (decode_frame(
      &alac_,
      reinterpret_cast<unsigned char*>(in_.data()),
      out_.data(),
      &outputSize) == 0)
    return cpp::fail(Error::kInternalError);
  outOff_ = offset * (bitdepth_ / 8) * channels_;
  outSize_ = outputSize - outOff_;
  if (++frame_ >= max) {
    if (chunk_++; chunk_ < stco_.size())
      input_->SeekTo(stco_[chunk_], IStream::SeekFrom::kStartOfStream);
    else
      outSize_ = 0;
  }
  return {};
}

auto AlacDecoder::DecodeTo(std::span<sample::Sample> output)
    -> cpp::result<OutputInfo, Error> {
  if (outSize_ == 0)
    if (auto v = UnpackFrame(0); v.has_error())
      return cpp::fail(v.error());
  if (outSize_ == 0)
    return OutputInfo{
        .samples_written = 0,
        .is_stream_finished = true,
    };
  const auto sampleSize = (bitdepth_ / 8);
  const auto size = std::min(outSize_ / sampleSize, output.size());
  switch (bitdepth_) {
  case 16:
    for (size_t i = 0; i < size; i++, outOff_ += 2)
      output[i] = loadLe16(out_.data()+outOff_);
    break;
  case 24:
    for (size_t i = 0; i < size; i++, outOff_ += 3)
      output[i] = sample::shiftWithDither(
          static_cast<uint32_t>(out_[outOff_])
              | static_cast<uint32_t>(out_[outOff_+1]) << 8
              | static_cast<uint32_t>(out_[outOff_+2]) << 16,
          8
      );
    break;
  default:
    return cpp::fail(Error::kInternalError);
  }
  outSize_ -= size * sampleSize;
  return OutputInfo{
      .samples_written = size,
      .is_stream_finished = false,
  };
}

}  // namespace codecs
